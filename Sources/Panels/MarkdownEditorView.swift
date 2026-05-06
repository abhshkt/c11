import AppKit
import Combine
import SwiftUI

/// NSTextView-backed markdown editor surface. Composes with `MarkdownPanel`'s
/// dirty-buffer state machine: typing updates `panel.dirtyContent`, an internal
/// debounce flushes to disk, and the file watcher's self-write suppression
/// keeps the panel from bouncing on its own writes.
struct MarkdownEditorView: NSViewRepresentable {
    @ObservedObject var panel: MarkdownPanel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themeManager = ThemeManager.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> MarkdownEditorContainerView {
        let container = MarkdownEditorContainerView()
        let coordinator = context.coordinator
        coordinator.textView = container.textView
        container.textView.coordinator = coordinator
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        // Synchronous handle for `TabManager.startSearch()` so Cmd-F can dispatch
        // `performTextFinderAction(_:)` on the same runloop tick the SwiftUI
        // menu hands over the action. Cleared in `dismantleNSView`.
        panel.activeTextView = container.textView

        coordinator.applyTheme(colorScheme: colorScheme, themeManager: themeManager)
        coordinator.assignContent(panel.dirtyContent ?? panel.content)
        coordinator.applyHighlight()
        coordinator.startObserving()
        // Pre-mount focus reconciliation: panel.$focusRequestToken.dropFirst()
        // discards events fired before this view mounts. On session restore
        // where editMode == true and the panel was the focused panel, the
        // initial focus request is lost. Re-issue makeFirstResponder here so
        // the user lands in an editable buffer rather than a no-responder pane.
        if panel.editMode {
            DispatchQueue.main.async { [weak container] in
                container?.window?.makeFirstResponder(container?.textView)
            }
        }
        return container
    }

    func updateNSView(_ container: MarkdownEditorContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.applyTheme(colorScheme: colorScheme, themeManager: themeManager)
        coordinator.syncIfNeeded()
    }

    static func dismantleNSView(_ container: MarkdownEditorContainerView, coordinator: Coordinator) {
        coordinator.cancelTasks()
        // Commit any pending edits before the editor view goes away. The
        // panel.close() path also flushes; this catches the toggle-to-preview
        // path where the panel keeps living but the editor surface unmounts.
        let panel = coordinator.panel
        // Drop the synchronous text-view handle so `TabManager.startSearch()`
        // falls into the deferred-find path while the editor is unmounted.
        if panel.activeTextView === container.textView {
            panel.activeTextView = nil
        }
        do {
            try panel.flushSave()
        } catch {
            NSLog("[MarkdownEditor] save failed during dismantle for panel %@: %@", panel.id.uuidString, "\(error)")
            let template = String(
                localized: "markdown.editor.saveFailed.message",
                defaultValue: "%@ could not be written. Your edits remain in the buffer; try saving again."
            )
            let message = String(format: template, panel.filePath ?? "")
            // Defer the property mutation: dismantleNSView fires inside a
            // SwiftUI body re-render (e.g. toggling to preview), so mutating
            // the @Published property synchronously trips the cycle warning.
            DispatchQueue.main.async {
                panel.saveFailureMessage = message
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        unowned let panel: MarkdownPanel
        weak var textView: MarkdownEditorTextView?

        private var autoSaveTask: Task<Void, Never>?
        private var asyncHighlightTask: Task<Void, Never>?
        private var generation: Int = 0
        private var isApplyingAttributes = false
        private var isAssigningContent = false
        private var cancellables: [AnyCancellable] = []
        private var colors = MarkdownEditorColors.fallback(isDark: false)

        private static let autoSaveDebounceNanos: UInt64 = 600_000_000      // 600 ms

        init(panel: MarkdownPanel) {
            self.panel = panel
            super.init()
        }

        // MARK: - Theme

        func applyTheme(colorScheme: ColorScheme, themeManager: ThemeManager) {
            let resolved = MarkdownEditorColors.resolve(colorScheme: colorScheme, themeManager: themeManager)
            colors = resolved
            guard let tv = textView else { return }
            tv.backgroundColor = resolved.background
            tv.insertionPointColor = resolved.text
            tv.textColor = resolved.text
            // Re-highlight so existing token attributes pick up the new palette.
            applyHighlight()
        }

        // MARK: - Buffer sync

        func assignContent(_ newContent: String) {
            guard let tv = textView else { return }
            if tv.string == newContent { return }
            if tv.hasMarkedText() { return }
            isAssigningContent = true
            tv.string = newContent
            tv.undoManager?.removeAllActions()
            isAssigningContent = false
            applyHighlight()
        }

        /// Called by `updateNSView` to reflect external panel changes (file
        /// watcher reload, programmatic content updates) into the textview
        /// without clobbering in-flight typing.
        func syncIfNeeded() {
            guard let tv = textView else { return }
            let target = panel.dirtyContent ?? panel.content
            if tv.string != target && !tv.hasMarkedText() {
                assignContent(target)
            }
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isAssigningContent, let tv = textView else { return }
            // Skip during IME composition — marked text is candidate, not committed.
            // The commit fires textDidChange again with hasMarkedText() == false.
            if tv.hasMarkedText() { return }
            panel.updateBuffer(tv.string)
            scheduleAutoSave()
        }

        func textDidEndEditing(_ notification: Notification) {
            // Blur flush — commit before the textview loses focus so
            // tab-switching or window-cycling doesn't strand edits.
            flushNow()
        }

        // MARK: - NSTextStorageDelegate

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard !isApplyingAttributes else { return }
            guard editedMask.contains(.editedCharacters) else { return }
            generation &+= 1
            applyHighlight()
        }

        // MARK: - Save

        func flushNow() {
            autoSaveTask?.cancel()
            do {
                try panel.flushSave()
            } catch {
                NSLog("[MarkdownEditor] save failed for panel %@: %@", panel.id.uuidString, "\(error)")
                let template = String(
                    localized: "markdown.editor.saveFailed.message",
                    defaultValue: "%@ could not be written. Your edits remain in the buffer; try saving again."
                )
                let message = String(format: template, panel.filePath ?? "")
                panel.saveFailureMessage = message
            }
        }

        private func scheduleAutoSave() {
            autoSaveTask?.cancel()
            autoSaveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.autoSaveDebounceNanos)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    self?.flushNow()
                }
            }
        }

        // MARK: - Highlight

        func applyHighlight() {
            // Synchronous: when invoked from the storage delegate this runs
            // inside the edit transaction, so attribute changes coalesce with
            // the keystroke into a single layout/display pass — no flicker.
            // Tokenizer is sub-millisecond on typical markdown files.
            // Large files (>256KB) hand off to an async/debounced path: the
            // tokenizer measures ~63ms at 510KB and ~130ms at 1MB, which is a
            // visible hitch when run on every keystroke from the storage
            // delegate.
            guard let tv = textView else { return }
            let nsSnapshot = tv.string as NSString
            if nsSnapshot.length > 256_000 {
                scheduleAsyncHighlight(snapshot: nsSnapshot)
                return
            }
            let tokens = MarkdownSyntaxTokenizer.tokenize(nsSnapshot)
            applyTokens(tokens, in: tv, snapshotLength: nsSnapshot.length)
        }

        private func scheduleAsyncHighlight(snapshot: NSString) {
            let myGen = generation
            let snapshotLength = snapshot.length
            // Cancel the prior in-flight async highlight before queuing a new
            // one. Previously each typing tick over the 256KB threshold spawned
            // an unstored Task: only the `generation` check filtered stale
            // RESULTS, but the tokenization (~130ms at 1MB) ran to completion
            // and could pile up on the .utility queue when typing crossed the
            // 250ms debounce window in bursts.
            //
            // Cancellation lands in two phases:
            //   1. The 250ms `Task.sleep` throws on cancel — `try?` swallows
            //      it and the `if Task.isCancelled` guard returns immediately.
            //      This is the common case during fast typing.
            //   2. After the sleep, `Task.detached` doesn't inherit our
            //      cancellation, and `MarkdownSyntaxTokenizer.tokenize` is a
            //      tight CPU loop with no cooperative cancellation hooks.
            //      The pre-/post-`.value` and pre-`applyTokens` `isCancelled`
            //      checks suppress the apply step; worst case we waste one
            //      already-running tokenization. The `generation == myGen`
            //      guard is the backup correctness check.
            asyncHighlightTask?.cancel()
            asyncHighlightTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms debounce
                if Task.isCancelled { return }
                let tokens = await Task.detached(priority: .utility) {
                    MarkdownSyntaxTokenizer.tokenize(snapshot)
                }.value
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    guard self.generation == myGen else { return }
                    guard let tv = self.textView else { return }
                    self.applyTokens(tokens, in: tv, snapshotLength: snapshotLength)
                }
            }
        }

        private func applyTokens(_ tokens: [MarkdownToken], in tv: NSTextView, snapshotLength: Int) {
            guard let storage = tv.textStorage else { return }
            // If the storage has changed since we tokenized, ranges may be invalid.
            guard storage.length == snapshotLength else { return }
            isApplyingAttributes = true
            storage.beginEditing()
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.setAttributes(MarkdownEditorStyling.baseAttributes(colors: colors), range: fullRange)
            for token in tokens {
                let bounded = NSIntersectionRange(token.range, fullRange)
                guard bounded.length > 0 else { continue }
                storage.addAttributes(
                    MarkdownEditorStyling.attributes(for: token.kind, colors: colors),
                    range: bounded
                )
            }
            storage.endEditing()
            isApplyingAttributes = false
        }

        // MARK: - Panel observation

        func startObserving() {
            cancellables.removeAll()
            panel.$focusRequestToken
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.makeFirstResponder()
                    // Deferred-find rendezvous: `TabManager.startSearch()`
                    // sets `pendingFindRequest` when the panel had no live
                    // text view at Cmd-F time. We've now made the text view
                    // first responder, so dispatching the find action will
                    // route through it correctly.
                    if self.panel.pendingFindRequest {
                        self.panel.pendingFindRequest = false
                        if let tv = self.textView {
                            let item = NSMenuItem()
                            item.tag = NSTextFinder.Action.showFindInterface.rawValue
                            tv.performTextFinderAction(item)
                        }
                    }
                }
                .store(in: &cancellables)
            panel.$bufferRevertToken
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.assignContent(self.panel.content)
                }
                .store(in: &cancellables)
            panel.$content
                .dropFirst()
                .sink { [weak self] _ in self?.syncIfNeeded() }
                .store(in: &cancellables)
        }

        func makeFirstResponder() {
            guard let tv = textView, let window = tv.window else { return }
            window.makeFirstResponder(tv)
        }

        func cancelTasks() {
            autoSaveTask?.cancel()
            asyncHighlightTask?.cancel()
            cancellables.removeAll()
        }
    }
}

// MARK: - Container

final class MarkdownEditorContainerView: NSView {
    let scrollView = NSScrollView()
    let textView = MarkdownEditorTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        // The textView is NSScrollView's documentView; it must use autoresizing
        // (NOT AutoLayout) inside the scrollView's clip view, otherwise on
        // macOS Sonoma+ the text container width collapses to 0 and typed text
        // is invisible. Mirrors TextBoxInput.swift:919.
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 24, height: 16)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.font = MarkdownEditorStyling.baseFont

        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - TextView

final class MarkdownEditorTextView: NSTextView {
    weak var coordinator: MarkdownEditorView.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            coordinator?.flushNow()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Styling

struct MarkdownEditorColors {
    let background: NSColor
    let text: NSColor
    let syntaxFaded: NSColor
    let heading: NSColor
    let inlineCode: NSColor
    let codeBlockBackground: NSColor
    let link: NSColor
    let blockquote: NSColor

    static func fallback(isDark: Bool) -> MarkdownEditorColors {
        let codeBg: NSColor = isDark
            ? NSColor(white: 0.18, alpha: 1.0)
            : NSColor(white: 0.92, alpha: 1.0)
        let inlineCodeColor: NSColor = isDark
            ? NSColor(red: 0.85, green: 0.6, blue: 0.95, alpha: 1.0)
            : NSColor(red: 0.6, green: 0.2, blue: 0.7, alpha: 1.0)
        let bg: NSColor = isDark
            ? NSColor(white: 0.12, alpha: 1.0)
            : NSColor(white: 0.98, alpha: 1.0)
        return MarkdownEditorColors(
            background: bg,
            text: .labelColor,
            syntaxFaded: .secondaryLabelColor,
            heading: .labelColor,
            inlineCode: inlineCodeColor,
            codeBlockBackground: codeBg,
            link: .controlAccentColor,
            blockquote: .secondaryLabelColor
        )
    }

    @MainActor
    static func resolve(colorScheme: ColorScheme, themeManager _: ThemeManager) -> MarkdownEditorColors {
        // Theme-driven editor colors are deferred to a follow-up that wires
        // the role schema through C11muxTheme.MarkdownChrome. v1 uses fallbacks.
        return MarkdownEditorColors.fallback(isDark: colorScheme == .dark)
    }
}

enum MarkdownEditorStyling {
    static let baseFontSize: CGFloat = 14
    static let baseFont: NSFont = .systemFont(ofSize: baseFontSize)
    static let monoFont: NSFont = .monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular)
    static let italicFont: NSFont = {
        let descriptor = NSFont.systemFont(ofSize: baseFontSize)
            .fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: baseFontSize) ?? .systemFont(ofSize: baseFontSize)
    }()
    static let boldFont: NSFont = .boldSystemFont(ofSize: baseFontSize)

    static func baseAttributes(colors: MarkdownEditorColors) -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: colors.text,
        ]
    }

    static func attributes(for kind: MarkdownTokenKind, colors: MarkdownEditorColors) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .headingMarker:
            return [.foregroundColor: colors.syntaxFaded]
        case .headingText(let level):
            let scale = max(0.0, CGFloat(7 - level)) * 1.5 + baseFontSize
            return [
                .font: NSFont.boldSystemFont(ofSize: scale),
                .foregroundColor: colors.heading,
            ]
        case .listMarker, .blockquoteMarker, .codeFence, .codeFenceLang, .escape, .thematicBreak:
            return [.foregroundColor: colors.syntaxFaded]
        case .codeBody:
            return [
                .font: monoFont,
                .backgroundColor: colors.codeBlockBackground,
            ]
        case .bold:
            return [.font: boldFont]
        case .italic:
            return [.font: italicFont]
        case .strikethrough:
            return [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: colors.text,
            ]
        case .inlineCode:
            return [
                .font: monoFont,
                .foregroundColor: colors.inlineCode,
                .backgroundColor: colors.codeBlockBackground,
            ]
        case .link:
            return [
                .foregroundColor: colors.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
    }
}
