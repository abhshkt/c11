import AppKit
import Foundation
import Combine

/// A segment of markdown content — either regular markdown or a rendered fenced code block.
enum MarkdownSegment: Identifiable {
    case markdown(id: String, content: String)
    /// `errorHint` is set when the most recent render attempt failed and the
    /// renderer surfaced operator-actionable diagnostic text (e.g. missing
    /// runtime dependency with a copy-pasteable install command). nil when the
    /// segment has not yet been rendered, is rendering, or rendered cleanly.
    case fencedCode(id: String, language: String, code: String, renderedImage: NSImage?, errorHint: String?)

    var id: String {
        switch self {
        case .markdown(let id, _): return id
        case .fencedCode(let id, _, _, _, _): return id
        }
    }
}

/// A panel that renders a markdown file with live file-watching.
/// When the file changes on disk, the content is automatically reloaded.
@MainActor
final class MarkdownPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .markdown

    /// Absolute path to the markdown file being displayed, or nil when the
    /// panel is unbound (empty state — user hasn't picked a file yet).
    @Published private(set) var filePath: String?

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current markdown content read from the file.
    @Published private(set) var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.richtext" }

    /// Whether the file has been deleted or is unreadable. Always false for
    /// an unbound panel (nil filePath) — the empty state is a distinct mode.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Parsed segments of the content (markdown + mermaid blocks).
    @Published private(set) var segments: [MarkdownSegment] = []

    /// When true, the panel renders an NSTextView editor instead of the
    /// MarkdownUI preview. Persisted across session restore.
    @Published var editMode: Bool = false

    /// Unsaved buffer when the operator is editing. nil means the panel is
    /// in sync with `content` (which mirrors disk).
    @Published private(set) var dirtyContent: String?

    /// Bumped when `focus()` is called in edit mode — the editor view observes
    /// this to make its NSTextView first responder. Mirrors `focusFlashToken`.
    @Published private(set) var focusRequestToken: Int = 0

    /// Bumped when `discardEdits()` is called — the editor view observes this
    /// to reset its NSTextView's text back to `content`.
    @Published private(set) var bufferRevertToken: Int = 0

    /// Synchronous handle to the editor's NSTextView while a `MarkdownEditorView`
    /// is mounted (edit mode). The editor's `makeNSView`/`dismantleNSView` set
    /// and clear this. `TabManager.startSearch()` reads it to dispatch
    /// `performTextFinderAction(_:)` directly without first walking through the
    /// async `focusRequestToken` Combine sink — Cmd-F has to fire on the same
    /// runloop tick the menu hands the action over, so the responder chain
    /// can't be relied on for the first-responder transition.
    /// Not @Published: this is a referencing handle, not observable state.
    weak var activeTextView: NSTextView?

    /// Returns `activeTextView` only when it's currently attached to a window.
    /// The text view reference can outlive its window briefly during the
    /// dismantle cycle (between AppKit's `viewWillMove(toWindow: nil)` and
    /// the editor's `dismantleNSView` clearing the handle). Dispatching
    /// `performTextFinderAction(_:)` to a windowless text view is a silent
    /// no-op until the next focus, so synchronous Cmd-F dispatch should
    /// consult this getter and fall through to the `pendingFindRequest`
    /// deferred path when nil.
    var liveActiveTextView: NSTextView? {
        guard let tv = activeTextView, tv.window != nil else { return nil }
        return tv
    }

    /// One-shot flag set by `TabManager.startSearch()` when the markdown panel
    /// is in preview-only mode (no live text view). The Coordinator's
    /// `focusRequestToken` sink reads-and-clears it after `makeFirstResponder`
    /// succeeds and then fires the find action. This covers the case where
    /// the operator hits Cmd-F before the editor view has mounted.
    var pendingFindRequest: Bool = false

    /// Set to a localized error message when a save attempt fails (write or
    /// encoding error). The panel view binds this to a SwiftUI `.alert(...)`
    /// so the operator sees the failure instead of a silently-swallowed throw.
    /// Cleared back to nil when the alert is dismissed.
    @Published var saveFailureMessage: String? = nil

    /// Base content font size for preview and edit mode. This is panel-local:
    /// zooming one markdown surface should not resize other markdown notes.
    @Published private(set) var markdownFontSize: CGFloat = MarkdownPanel.defaultMarkdownFontSize

    static let defaultMarkdownFontSize: CGFloat = 14
    static let minimumMarkdownFontSize: CGFloat = 9
    static let maximumMarkdownFontSize: CGFloat = 32
    private static let markdownFontSizeStep: CGFloat = 1

    // MARK: - Font scale compatibility

    /// Multiplier-like zoom value used by upstream snapshots/tests. The fork's
    /// user-visible contract remains point-size based (`markdownFontSize`), so
    /// this facade maps each 1pt step to a 0.1 scale step.
    var fontScale: Double {
        Self.fontScale(forMarkdownFontSize: markdownFontSize)
    }

    static let fontScaleStep: Double = 0.1
    static let fontScaleRange: ClosedRange<Double> = 0.5...2.8
    private static let fontScaleDefaultsKey = "markdown.fontScale.lastUsed"

    static func normalizedFontScale(_ value: Double) -> Double {
        let clamped = min(max(value, fontScaleRange.lowerBound), fontScaleRange.upperBound)
        return (clamped * 10).rounded() / 10
    }

    private static func fontScale(forMarkdownFontSize fontSize: CGFloat) -> Double {
        let steps = Double((fontSize - defaultMarkdownFontSize) / markdownFontSizeStep)
        return normalizedFontScale(1.0 + steps * fontScaleStep)
    }

    private static func markdownFontSize(forFontScale scale: Double) -> CGFloat {
        let normalized = normalizedFontScale(scale)
        let steps = (normalized - 1.0) / fontScaleStep
        return defaultMarkdownFontSize + CGFloat(steps) * markdownFontSizeStep
    }

    private static func lastUsedFontScale() -> Double {
        let stored = UserDefaults.standard.double(forKey: fontScaleDefaultsKey)
        guard stored > 0 else { return 1.0 }
        return normalizedFontScale(stored)
    }

    /// Last bytes successfully written to disk. Compared inside
    /// `loadFileContent` to suppress the watcher's own self-write reload.
    /// Byte-equality is correct; `hashValue` would not be process-stable.
    private var lastWrittenBytes: Data?

    /// Encoding the file was last decoded with. Re-used on save so a
    /// Latin-1 file round-trips without silent UTF-8 conversion.
    private var sourceEncoding: String.Encoding = .utf8

    /// Tracks the appearance used for the last mermaid render pass.
    private var lastRenderedDark: Bool?

    /// Observer for system appearance changes.
    private var appearanceObserver: NSObjectProtocol?

    // MARK: - File watching

    // nonisolated(unsafe) because deinit is not guaranteed to run on the
    // main actor, but DispatchSource.cancel() is thread-safe.
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private nonisolated let watchQueue = DispatchQueue(label: "com.stage11.c11.markdown-file-watch", qos: .utility)

    /// Pending debounced reload. Accessed only on `watchQueue`.
    private nonisolated(unsafe) var pendingReload: DispatchWorkItem?
    /// Trailing debounce applied to watcher-driven reloads so agents
    /// stream-appending to a watched file coalesce into one reparse per
    /// burst instead of one per write event.
    private static let reloadDebounce: TimeInterval = 0.15

    /// Number of fast-phase reattach attempts after a file delete/rename
    /// event. Covers atomic-replace and short delete-recreate windows.
    private static let maxReattachAttempts = 6
    /// Delay between fast-phase reattach attempts (fast window: 3s total).
    private static let reattachDelay: TimeInterval = 0.5
    /// Delay between slow-phase reattach attempts. After the fast window
    /// expires, retries continue indefinitely at this cadence until the
    /// panel is closed or unbound, so a delete-then-late-recreate eventually
    /// reconnects without operator intervention.
    private static let reattachBackoffDelay: TimeInterval = 5.0

    // MARK: - Init

    /// - Parameter id: Stable panel UUID. Pass `nil` for fresh creation; pass a
    ///   snapshot's panel id during session restore to keep IDs stable across
    ///   app restarts (Tier 1 persistence, Phase 1).
    /// - Parameter filePath: Absolute path to a markdown file, or `nil` to
    ///   create an unbound panel (empty state — user binds via drag-drop or
    ///   the in-panel "Open Markdown File" button).
    /// - Parameter editMode: Restore-time hint to start the panel in edit mode.
    init(id: UUID? = nil, workspaceId: UUID, filePath: String? = nil, editMode: Bool = false) {
        self.id = id ?? UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = Self.titleForFilePath(filePath)
        self.editMode = editMode
        if filePath == nil {
            self.markdownFontSize = Self.markdownFontSize(forFontScale: Self.lastUsedFontScale())
        }

        if filePath != nil {
            loadFileContent()
            startFileWatcher()
            if isFileUnavailable && fileWatchSource == nil {
                // Session restore can create a panel before the file is recreated.
                // Retry briefly so atomic-rename recreations can reconnect.
                scheduleReattach(attempt: 1)
            }
        }
        startAppearanceObserver()
    }

    private static func titleForFilePath(_ filePath: String?) -> String {
        guard let filePath else {
            return String(localized: "markdown.untitled", defaultValue: "Untitled")
        }
        return (filePath as NSString).lastPathComponent
    }

    /// Bind this panel to a markdown file post-construction. Called from the
    /// empty-state UI after the user drops a file or picks one via NSOpenPanel.
    /// No-op if the panel is already bound — rebinding requires a fresh panel.
    func bindFilePath(_ path: String) {
        guard filePath == nil, !isClosed else { return }
        filePath = path
        displayTitle = Self.titleForFilePath(path)
        loadFileContent()
        startFileWatcher()
        if isFileUnavailable && fileWatchSource == nil {
            scheduleReattach(attempt: 1)
        }
    }

    // MARK: - Panel protocol

    var isDirty: Bool {
        guard let dirty = dirtyContent else { return false }
        return dirty != content
    }

    func focus() {
        guard !isClosed else { return }
        // Re-arm the watcher if a delete-recreate cycle stranded the panel
        // (the slow-backoff poll may not have fired yet, or the file was
        // recreated long after we gave the slow phase up to). Strict gate
        // keeps the available case a no-op for the ordinary focus path.
        if isFileUnavailable, fileWatchSource == nil, filePath != nil {
            loadFileContent()
            if !isFileUnavailable {
                startFileWatcher()
            }
        }
        guard editMode else { return }
        focusRequestToken &+= 1
    }

    func unfocus() {
        // No-op; resigning first responder is the editor view's responsibility.
    }

    func close() {
        // Try to commit any dirty buffer BEFORE flipping `isClosed`. If we
        // flipped first, `flushSave()`'s `guard !isClosed` would short-circuit
        // and the dismantleNSView fallback at MarkdownEditorView.swift would
        // also no-op — silently dropping the buffer.
        //
        // On success: flip `isClosed` so subsequent calls (incl. the editor's
        // dismantle-flush) are no-ops as before.
        // On failure: surface the error via the existing `saveFailureMessage`
        // pipeline (mirroring the dismantle pattern in MarkdownEditorView), and
        // keep `isClosed` false so the dismantle-flush downstream still gets a
        // chance against the still-dirty buffer. flushSave is idempotent —
        // a second call with the same buffer either succeeds or throws again,
        // it cannot double-write.
        //
        // The watcher and appearance observer are external-notification
        // teardowns, independent of the buffer's persistence; tear them down
        // unconditionally.
        do {
            try flushSave()
            isClosed = true
        } catch {
            NSLog("[MarkdownPanel] save failed during close for panel %@: %@", id.uuidString, "\(error)")
            let template = String(
                localized: "markdown.editor.saveFailed.message",
                defaultValue: "%@ could not be written. Your edits remain in the buffer; try saving again."
            )
            let message = String(format: template, filePath ?? "")
            // Defer the @Published mutation: close() can be invoked while a
            // SwiftUI body re-render is propagating panel removal, and a
            // synchronous mutation would trip the cycle warning. Mirrors the
            // dismantleNSView pattern.
            DispatchQueue.main.async { [weak self] in
                self?.saveFailureMessage = message
            }
        }
        stopFileWatcher()
        stopAppearanceObserver()
        watchQueue.async { [weak self] in
            self?.pendingReload?.cancel()
            self?.pendingReload = nil
        }
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Zoom

    @discardableResult
    func zoomIn() -> Bool {
        setMarkdownFontSize(markdownFontSize + Self.markdownFontSizeStep, updateLastUsedScale: true)
    }

    @discardableResult
    func zoomOut() -> Bool {
        setMarkdownFontSize(markdownFontSize - Self.markdownFontSizeStep, updateLastUsedScale: true)
    }

    @discardableResult
    func resetZoom() -> Bool {
        setMarkdownFontSize(Self.defaultMarkdownFontSize, updateLastUsedScale: true)
    }

    /// Restore a persisted scale without updating the last-used default.
    func applyRestoredFontScale(_ value: Double) {
        _ = setMarkdownFontSize(
            Self.markdownFontSize(forFontScale: value),
            updateLastUsedScale: false
        )
    }

    /// Apply a persisted font size on session restore. Clamped to the valid
    /// range so out-of-range stored values can't escape the zoom bounds.
    @discardableResult
    func setMarkdownFontSize(_ candidate: CGFloat) -> Bool {
        setMarkdownFontSize(candidate, updateLastUsedScale: false)
    }

    @discardableResult
    private func setMarkdownFontSize(_ candidate: CGFloat, updateLastUsedScale: Bool) -> Bool {
        let clamped = min(Self.maximumMarkdownFontSize, max(Self.minimumMarkdownFontSize, candidate))
        let changed = abs(markdownFontSize - clamped) > 0.001
        guard changed else { return false }
        markdownFontSize = clamped
        if updateLastUsedScale {
            UserDefaults.standard.set(fontScale, forKey: Self.fontScaleDefaultsKey)
        }
        return true
    }

    // MARK: - File I/O

    private struct LoadedContent: Sendable {
        let text: String
        let encoding: String.Encoding
        let data: Data
    }

    private func loadFileContent() {
        guard let filePath else {
            content = ""
            sourceEncoding = .utf8
            lastWrittenBytes = nil
            isFileUnavailable = false
            parseSegments()
            return
        }
        applyExternalContent(Self.readContent(path: filePath))
    }

    /// Read file content with the UTF-8 → ISO Latin-1 fallback chain.
    /// Safe to call from any queue.
    private nonisolated static func readContent(path: String) -> LoadedContent? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        if let content = String(data: data, encoding: .utf8) {
            return LoadedContent(text: content, encoding: .utf8, data: data)
        }
        // Fallback: try ISO Latin-1, which accepts all 256 byte values,
        // covering legacy encodings like Windows-1252.
        if let decoded = String(data: data, encoding: .isoLatin1) {
            return LoadedContent(text: decoded, encoding: .isoLatin1, data: data)
        }
        return nil
    }

    /// Apply content produced by a read (sync or debounced). Skips the
    /// reparse + republish entirely when the content is unchanged, which is
    /// the common case for spurious watcher events.
    private func applyExternalContent(_ loaded: LoadedContent?) {
        guard !isClosed else { return }
        guard let loaded else {
            isFileUnavailable = true
            lastWrittenBytes = nil
            return
        }
        // Self-write suppression: the watcher's `.delete|.rename` path always
        // fires after our atomic write. If the bytes on disk match what we
        // just wrote, treat the reload as a no-op.
        if let last = lastWrittenBytes, last == loaded.data {
            lastWrittenBytes = nil
            sourceEncoding = loaded.encoding
            isFileUnavailable = false
            return
        }
        lastWrittenBytes = nil
        let wasUnavailable = isFileUnavailable
        isFileUnavailable = false
        sourceEncoding = loaded.encoding
        guard loaded.text != content || wasUnavailable else { return }
        content = loaded.text
        parseSegments()
    }

    // MARK: - Edit-mode buffer

    /// Update the unsaved buffer from the editor coordinator. Pass the
    /// current text content of the NSTextView; the panel decides whether
    /// it diverges from `content` (and therefore whether `isDirty` flips).
    func updateBuffer(_ buffer: String) {
        guard !isClosed else { return }
        if buffer == content {
            if dirtyContent != nil { dirtyContent = nil }
        } else {
            dirtyContent = buffer
        }
    }

    /// Atomically write the current buffer to disk and reset dirty state.
    /// No-op when the panel is closed, unbound, or has no pending edits.
    /// Throws if encoding the buffer or writing to disk fails.
    func flushSave() throws {
        guard !isClosed, let filePath else { return }
        guard let buffer = dirtyContent, buffer != content else { return }
        guard let data = buffer.data(using: sourceEncoding) else {
            throw MarkdownPanelError.encodingFailed
        }
        // Set the suppression sentinel BEFORE the write so the watcher
        // event sees it whether dispatched synchronously or asynchronously.
        lastWrittenBytes = data
        let url = URL(fileURLWithPath: filePath)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // Failed write: clear the sentinel so a future external write
            // of these exact bytes isn't falsely suppressed as a self-write.
            lastWrittenBytes = nil
            throw error
        }
        content = buffer
        dirtyContent = nil
        parseSegments()
    }

    /// Discard the unsaved buffer and bump `bufferRevertToken` so the editor
    /// view re-syncs its NSTextView to `content`.
    func discardEdits() {
        guard dirtyContent != nil else { return }
        dirtyContent = nil
        bufferRevertToken &+= 1
    }

    /// Schedule a debounced reload on the watch queue. Coalesces bursts of
    /// file events; the file read happens off the main thread.
    private nonisolated func scheduleDebouncedReload(path: String) {
        watchQueue.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let result = Self.readContent(path: path)
                DispatchQueue.main.async {
                    self.applyExternalContent(result)
                }
            }
            self.pendingReload = item
            self.watchQueue.asyncAfter(deadline: .now() + Self.reloadDebounce, execute: item)
        }
    }

    // MARK: - Fenced code segment parsing

    /// Stable ID from segment index and full content. Hashing the whole
    /// content (not a prefix) guarantees the ID changes whenever the segment
    /// changes — a prefix hash let edits past the prefix keep a stale ID,
    /// which preserved outdated rendered diagrams indefinitely.
    static func segmentId(index: Int, content: String) -> String {
        "\(index):\(content.count):\(content.hashValue)"
    }

    /// Compiled fenced-code pattern cached per tag set. Renderers register at
    /// app startup, so in practice this compiles once.
    private static var cachedFencedCodePattern: (tags: Set<String>, regex: NSRegularExpression?)?

    /// Build a regex that matches fenced code blocks for all registered renderer tags.
    /// Pattern captures: group 1 = language tag, group 2 = code content.
    private static func buildFencedCodePattern() -> NSRegularExpression? {
        let tags = FencedCodeRendererRegistry.shared.supportedTags
        guard !tags.isEmpty else { return nil }
        if let cached = cachedFencedCodePattern, cached.tags == tags {
            return cached.regex
        }
        let escaped = tags.map { NSRegularExpression.escapedPattern(for: $0) }
        let alternation = escaped.joined(separator: "|")
        let pattern = "```(\(alternation))\\s*\\n([\\s\\S]*?)```"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        cachedFencedCodePattern = (tags, regex)
        return regex
    }

    /// Parse content into segments, splitting on fenced code blocks with registered renderers.
    private func parseSegments() {
        let text = content
        guard !text.isEmpty else {
            segments = []
            return
        }

        guard let pattern = Self.buildFencedCodePattern() else {
            // No renderers registered — plain markdown
            segments = [.markdown(id: Self.segmentId(index: 0, content: text), content: text)]
            return
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = pattern.matches(in: text, range: fullRange)

        guard !matches.isEmpty else {
            segments = [.markdown(id: Self.segmentId(index: 0, content: text), content: text)]
            return
        }

        var result: [MarkdownSegment] = []
        var lastEnd = 0
        var segIndex = 0

        for match in matches {
            let matchRange = match.range
            // Add preceding markdown text
            if matchRange.location > lastEnd {
                let mdRange = NSRange(location: lastEnd, length: matchRange.location - lastEnd)
                let mdText = nsText.substring(with: mdRange)
                if !mdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(id: Self.segmentId(index: segIndex, content: mdText), content: mdText))
                    segIndex += 1
                }
            }
            // Extract language tag (capture group 1) and code (capture group 2)
            let langRange = match.range(at: 1)
            let language = nsText.substring(with: langRange).lowercased()
            let codeRange = match.range(at: 2)
            let code = nsText.substring(with: codeRange).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(.fencedCode(id: Self.segmentId(index: segIndex, content: code), language: language, code: code, renderedImage: nil, errorHint: nil))
            segIndex += 1
            lastEnd = matchRange.location + matchRange.length
        }

        // Add trailing markdown text
        if lastEnd < nsText.length {
            let mdText = nsText.substring(from: lastEnd)
            if !mdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(id: Self.segmentId(index: segIndex, content: mdText), content: mdText))
            }
        }

        // Preserve rendered images for segments whose content hasn't changed.
        // Drop any prior errorHint — a fresh parse should re-render and recompute.
        let oldSegments = segments
        for (i, seg) in result.enumerated() {
            if case .fencedCode(let id, let lang, let code, _, _) = seg,
               let old = oldSegments.first(where: { $0.id == id }),
               case .fencedCode(_, _, _, let oldImage, _) = old,
               oldImage != nil {
                result[i] = .fencedCode(id: id, language: lang, code: code, renderedImage: oldImage, errorHint: nil)
            }
        }

        segments = result
        renderFencedCodeSegments()
    }

    /// Render fenced code segments asynchronously via their registered renderers.
    private func renderFencedCodeSegments() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        lastRenderedDark = isDark

        let registry = FencedCodeRendererRegistry.shared

        // Build active keys per renderer for cancellation
        var activeKeysByRenderer: [String: Set<String>] = [:]
        for segment in segments {
            guard case .fencedCode(_, let language, let code, let existingImage, _) = segment else { continue }
            if existingImage != nil { continue }
            guard let renderer = registry.renderer(for: language) else { continue }
            let key = renderer.renderCacheKey(code: code, isDark: isDark)
            activeKeysByRenderer[language, default: []].insert(key)
        }
        for (language, keys) in activeKeysByRenderer {
            registry.renderer(for: language)?.cancelRendersExcept(activeKeys: keys)
        }

        for (index, segment) in segments.enumerated() {
            guard case .fencedCode(let id, let language, let code, let existingImage, _) = segment else { continue }
            if existingImage != nil { continue }
            guard let renderer = registry.renderer(for: language) else { continue }
            renderer.render(code: code, isDark: isDark) { [weak self] image, hint in
                guard let self else { return }
                guard index < self.segments.count,
                      case .fencedCode(let currentId, _, _, _, _) = self.segments[index],
                      currentId == id else { return }
                self.segments[index] = .fencedCode(id: id, language: language, code: code, renderedImage: image, errorHint: hint)
            }
        }
    }

    // MARK: - Appearance change observation

    private func startAppearanceObserver() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppearanceChangeIfNeeded()
        }
        // Also observe the effective appearance key path
        // NSApp posts this when system appearance changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    private func stopAppearanceObserver() {
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
            appearanceObserver = nil
        }
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private nonisolated func systemAppearanceDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAppearanceChangeIfNeeded()
        }
    }

    private func handleAppearanceChangeIfNeeded() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard isDark != lastRenderedDark else { return }
        // Clear rendered images so they re-render with the new theme
        for (i, segment) in segments.enumerated() {
            if case .fencedCode(let id, let lang, let code, let image, _) = segment, image != nil {
                segments[i] = .fencedCode(id: id, language: lang, code: code, renderedImage: nil, errorHint: nil)
            }
        }
        renderFencedCodeSegments()
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        guard let filePath else { return }
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was deleted or renamed. The old file descriptor points to
                // a stale inode, so we must always stop and reattach the watcher
                // even if the new file is already readable (atomic save case).
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    guard let path = self.filePath else { return }
                    if FileManager.default.fileExists(atPath: path) {
                        // File already replaced — reattach to the new inode
                        // immediately; content loads via the debounced path.
                        self.startFileWatcher()
                        self.scheduleDebouncedReload(path: path)
                    } else {
                        // File not yet replaced — retry until it reappears.
                        self.isFileUnavailable = true
                        self.scheduleReattach(attempt: 1)
                    }
                }
            } else {
                // Content changed — reload (debounced, read off-main).
                self.scheduleDebouncedReload(path: filePath)
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    /// Retry reattaching the file watcher after a delete/rename event.
    /// Phase 1: the first `maxReattachAttempts` attempts poll every
    /// `reattachDelay` seconds — fast recovery for atomic-replace and short
    /// delete-recreate windows. Phase 2: subsequent attempts back off to
    /// `reattachBackoffDelay` and continue indefinitely until the panel is
    /// closed or the file is unbound, so a late recreate eventually
    /// reconnects on its own. Each attempt also bails if some other path
    /// (e.g. `focus()`) has already re-armed the watcher.
    private func scheduleReattach(attempt: Int) {
        let delay: TimeInterval = attempt <= Self.maxReattachAttempts
            ? Self.reattachDelay
            : Self.reattachBackoffDelay
        watchQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed, let filePath = self.filePath else { return }
                // Another path (focus() re-arm, watcher already restarted)
                // brought the watcher back — stop polling.
                if self.fileWatchSource != nil { return }
                if FileManager.default.fileExists(atPath: filePath) {
                    self.isFileUnavailable = false
                    self.loadFileContent()
                    self.startFileWatcher()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        // File descriptor is closed by the cancel handler.
        fileDescriptor = -1
    }

    deinit {
        // DispatchSource cancel is safe from any thread.
        fileWatchSource?.cancel()
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

enum MarkdownPanelError: Error {
    case encodingFailed
}
