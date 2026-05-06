import AppKit
import Foundation
import Combine

/// A segment of markdown content — either regular markdown or a rendered fenced code block.
enum MarkdownSegment: Identifiable {
    case markdown(id: String, content: String)
    case fencedCode(id: String, language: String, code: String, renderedImage: NSImage?)

    var id: String {
        switch self {
        case .markdown(let id, _): return id
        case .fencedCode(let id, _, _, _): return id
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
    private let watchQueue = DispatchQueue(label: "com.stage11.c11.markdown-file-watch", qos: .utility)

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
        try? flushSave()
        isClosed = true
        stopFileWatcher()
        stopAppearanceObserver()
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File I/O

    private func loadFileContent() {
        guard let filePath else {
            content = ""
            sourceEncoding = .utf8
            lastWrittenBytes = nil
            isFileUnavailable = false
            parseSegments()
            return
        }
        guard let data = FileManager.default.contents(atPath: filePath) else {
            isFileUnavailable = true
            lastWrittenBytes = nil
            parseSegments()
            return
        }
        // Self-write suppression: the watcher's `.delete|.rename` path always
        // fires after our atomic write. If the bytes on disk match what we
        // just wrote, treat the reload as a no-op.
        if let last = lastWrittenBytes, last == data {
            isFileUnavailable = false
            return
        }
        // External change — clear suppression and decode.
        lastWrittenBytes = nil
        if let utf8 = String(data: data, encoding: .utf8) {
            content = utf8
            sourceEncoding = .utf8
            isFileUnavailable = false
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            // ISO Latin-1 accepts all 256 byte values, covering legacy
            // encodings like Windows-1252.
            content = latin1
            sourceEncoding = .isoLatin1
            isFileUnavailable = false
        } else {
            isFileUnavailable = true
        }
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

    // MARK: - Fenced code segment parsing

    /// Stable ID from segment index and content prefix.
    private static func segmentId(index: Int, content: String) -> String {
        let prefix = String(content.prefix(64))
        return "\(index):\(prefix.hashValue)"
    }

    /// Cached regex matching fenced code blocks for all registered renderer tags.
    /// Pattern captures: group 1 = language tag, group 2 = code content.
    ///
    /// Compiling the regex on every `parseSegments()` call (toggle, autosave,
    /// external reload) was a hot-path allocation. Renderers register exactly
    /// once at app startup (`AppDelegate.applicationDidFinishLaunching`), so
    /// `supportedTags` is stable by the time any markdown panel parses
    /// content; a `static let` evaluated lazily on first access is safe.
    /// Swift `static let` initialization is itself thread-safe (dispatch_once
    /// semantics), and `NSRegularExpression` is documented as thread-safe to
    /// use from multiple threads after construction.
    private static let fencedCodePattern: NSRegularExpression? = {
        let tags = FencedCodeRendererRegistry.shared.supportedTags
        guard !tags.isEmpty else { return nil }
        let escaped = tags.map { NSRegularExpression.escapedPattern(for: $0) }
        let alternation = escaped.joined(separator: "|")
        let pattern = "```(\(alternation))\\s*\\n([\\s\\S]*?)```"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Parse content into segments, splitting on fenced code blocks with registered renderers.
    private func parseSegments() {
        let text = content
        guard !text.isEmpty else {
            segments = []
            return
        }

        guard let pattern = Self.fencedCodePattern else {
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
            result.append(.fencedCode(id: Self.segmentId(index: segIndex, content: code), language: language, code: code, renderedImage: nil))
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

        // Preserve rendered images for segments whose content hasn't changed
        let oldSegments = segments
        for (i, seg) in result.enumerated() {
            if case .fencedCode(let id, let lang, let code, _) = seg,
               let old = oldSegments.first(where: { $0.id == id }),
               case .fencedCode(_, _, _, let oldImage) = old,
               oldImage != nil {
                result[i] = .fencedCode(id: id, language: lang, code: code, renderedImage: oldImage)
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
            guard case .fencedCode(_, let language, let code, let existingImage) = segment else { continue }
            if existingImage != nil { continue }
            guard let renderer = registry.renderer(for: language) else { continue }
            let key = renderer.renderCacheKey(code: code, isDark: isDark)
            activeKeysByRenderer[language, default: []].insert(key)
        }
        for (language, keys) in activeKeysByRenderer {
            registry.renderer(for: language)?.cancelRendersExcept(activeKeys: keys)
        }

        for (index, segment) in segments.enumerated() {
            guard case .fencedCode(let id, let language, let code, let existingImage) = segment else { continue }
            if existingImage != nil { continue }
            guard let renderer = registry.renderer(for: language) else { continue }
            renderer.render(code: code, isDark: isDark) { [weak self] image in
                guard let self else { return }
                guard index < self.segments.count,
                      case .fencedCode(let currentId, _, _, _) = self.segments[index],
                      currentId == id else { return }
                self.segments[index] = .fencedCode(id: id, language: language, code: code, renderedImage: image)
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
            if case .fencedCode(let id, let lang, let code, let image) = segment, image != nil {
                segments[i] = .fencedCode(id: id, language: lang, code: code, renderedImage: nil)
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
                    self.loadFileContent()
                    if self.isFileUnavailable {
                        // File not yet replaced — retry until it reappears.
                        self.scheduleReattach(attempt: 1)
                    } else {
                        // File already replaced — reattach to the new inode immediately.
                        self.startFileWatcher()
                    }
                }
            } else {
                // Content changed — reload.
                DispatchQueue.main.async {
                    self.loadFileContent()
                }
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
