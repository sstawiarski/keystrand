import AppKit
import SwiftUI

/// NSTextView-based code editor with line numbers, syntax highlighting (Redis / JSON), a completion popup,
/// signature hints, bracket auto-close, Cmd/Ctrl+Enter submit and history hooks.
///
/// Keys: Cmd+Enter or Ctrl+Enter → `onSubmit`; Enter / Shift+Enter → newline (Enter accepts an open completion);
/// Tab accepts a completion or inserts 4 spaces; Esc dismisses popups (completions stay dismissed until the next
/// word or an explicit Ctrl+Space / Option+Esc); Cmd+Shift+Space shows the signature hint; Up on the first line →
/// `onHistoryUp`, Down on the last line → `onHistoryDown`.
public struct CodeEditorView: NSViewRepresentable {
    @Binding public var text: String
    public var language: CodeLanguage
    public var isEditable: Bool
    public var completions: CodeCompletionProvider?
    /// Cmd+Enter / Ctrl+Enter.
    public var onSubmit: (() -> Void)?
    /// Up arrow while the caret is on the first line; return true when handled (Workbench/CLI history).
    public var onHistoryUp: (() -> Bool)?
    /// Down arrow while the caret is on the last line; return true when handled.
    public var onHistoryDown: (() -> Bool)?
    public var signatureHint: CodeSignatureHintProvider?
    /// Command names to highlight in `.redis` mode (upper-cased). nil uses the bundled command catalog.
    public var keywords: Set<String>?
    public var placeholder: String?
    public var showsLineNumbers: Bool
    /// Dim play marker in the gutter on lines that start a command (`.redis` only).
    public var showsCommandMarkers: Bool
    public var wrapsLines: Bool
    public var fontSize: CGFloat
    /// When either bound is set the editor sizes itself to its content, clamped to the bounds.
    public var minHeight: CGFloat?
    public var maxHeight: CGFloat?
    public var autoCloseBrackets: Bool
    public var controller: CodeEditorController?
    /// Esc with no popup open; return true when handled.
    public var onEscape: (() -> Bool)?
    public var onFocusChange: ((Bool) -> Void)?
    public var autoFocus: Bool
    public var drawsBackground: Bool

    public init(text: Binding<String>, language: CodeLanguage = .plain, isEditable: Bool = true,
                completions: CodeCompletionProvider? = nil, onSubmit: (() -> Void)? = nil,
                onHistoryUp: (() -> Bool)? = nil, onHistoryDown: (() -> Bool)? = nil,
                signatureHint: CodeSignatureHintProvider? = nil, keywords: Set<String>? = nil,
                placeholder: String? = nil, showsLineNumbers: Bool = true, showsCommandMarkers: Bool = false,
                wrapsLines: Bool = true, fontSize: CGFloat = 13, minHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
                autoCloseBrackets: Bool = true, controller: CodeEditorController? = nil,
                onEscape: (() -> Bool)? = nil, onFocusChange: ((Bool) -> Void)? = nil, autoFocus: Bool = false,
                drawsBackground: Bool = true) {
        self._text = text
        self.language = language
        self.isEditable = isEditable
        self.completions = completions
        self.onSubmit = onSubmit
        self.onHistoryUp = onHistoryUp
        self.onHistoryDown = onHistoryDown
        self.signatureHint = signatureHint
        self.keywords = keywords
        self.placeholder = placeholder
        self.showsLineNumbers = showsLineNumbers
        self.showsCommandMarkers = showsCommandMarkers
        self.wrapsLines = wrapsLines
        self.fontSize = fontSize
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.autoCloseBrackets = autoCloseBrackets
        self.controller = controller
        self.onEscape = onEscape
        self.onFocusChange = onFocusChange
        self.autoFocus = autoFocus
        self.drawsBackground = drawsBackground
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = EditorLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), textContainer: container)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textColor = EditorAppearance.Syntax.text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.findBarPosition = .aboveContent

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        context.coordinator.ruler = ruler
        context.coordinator.textView = textView

        context.coordinator.configure(textView: textView, scrollView: scrollView, initial: true)
        context.coordinator.replaceText(text)
        context.coordinator.observeScrolling(scrollView)
        context.coordinator.attachController()

        if autoFocus {
            Task { @MainActor [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        coordinator.configure(textView: textView, scrollView: scrollView, initial: false)
        coordinator.attachController()
        if text != coordinator.lastText {
            coordinator.setTextProgrammatically(text)
        } else if previous.language != language || previous.keywords != keywords
                    || previous.showsCommandMarkers != showsCommandMarkers {
            coordinator.refreshDecorations()
        }
    }

    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard minHeight != nil || maxHeight != nil, let textView = context.coordinator.textView,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: container)
        let content = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2 + 2
        let height = min(max(content, minHeight ?? 0), maxHeight ?? .greatestFiniteMagnitude)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? max(nsView.frame.width, 200)
        return CGSize(width: width, height: height)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        enum PendingChange: Equatable {
            case none
            case typed(String)
            case deleted
        }

        var parent: CodeEditorView
        weak var textView: EditorTextView?
        weak var ruler: LineNumberRulerView?
        let popups = EditorPopupController()
        var pendingChange: PendingChange = .none
        var isProgrammaticChange = false
        var completionsSuppressed = false
        private var popupLine: Int?
        private var lineStarts: [Int] = [0]
        private var scrollObserver: NSObjectProtocol?
        /// The text last read from or written to the text view, so updates skip bridging the whole document.
        private(set) var lastText = ""
        /// Tokens of a large document, colored lazily as their ranges scroll into view.
        private var lazyTokens: [SyntaxToken] = []
        private var coloredRanges = IndexSet()
        private var highlightGeneration = 0

        init(parent: CodeEditorView) {
            self.parent = parent
            super.init()
            popups.completionModel.onPick = { [weak self] index in self?.acceptCompletion(at: index) }
        }

        // MARK: Configuration

        func configure(textView: EditorTextView, scrollView: NSScrollView, initial: Bool) {
            let font = EditorAppearance.font(size: parent.fontSize)
            if initial || textView.font != font {
                textView.font = font
                textView.typingAttributes[.font] = font
                ruler?.font = EditorAppearance.font(size: max(parent.fontSize - 2, 9))
            }

            if textView.isEditable != parent.isEditable { textView.isEditable = parent.isEditable }
            textView.isSelectable = true
            textView.placeholder = parent.placeholder
            textView.drawsBackground = parent.drawsBackground
            textView.backgroundColor = EditorAppearance.nsBackground
            scrollView.drawsBackground = parent.drawsBackground
            scrollView.backgroundColor = EditorAppearance.nsBackground
            if scrollView.rulersVisible != parent.showsLineNumbers { scrollView.rulersVisible = parent.showsLineNumbers }
            ruler?.showsCommandMarkers = parent.showsCommandMarkers && parent.language == .redis

            if initial || textView.wrapsLines != parent.wrapsLines {
                textView.wrapsLines = parent.wrapsLines
                guard let container = textView.textContainer else { return }
                if parent.wrapsLines {
                    container.widthTracksTextView = true
                    container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                    textView.isHorizontallyResizable = false
                    scrollView.hasHorizontalScroller = false
                    textView.frame.size.width = scrollView.contentSize.width
                } else {
                    container.widthTracksTextView = false
                    container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    textView.isHorizontallyResizable = true
                    scrollView.hasHorizontalScroller = true
                }
            }
        }

        func attachController() {
            guard let controller = parent.controller else { return }
            controller.textView = textView
            controller.explicitCompletionHandler = { [weak self] in self?.triggerCompletions(explicit: true) }
        }

        func observeScrolling(_ scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.popups.hideAll()
                    self?.colorVisibleRange()
                }
            }
        }

        func teardown() {
            popups.hideAll()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
            if parent.controller?.textView === textView { parent.controller?.textView = nil }
        }

        // MARK: Text changes

        func setTextProgrammatically(_ newText: String) {
            guard let textView else { return }
            isProgrammaticChange = true
            defer { isProgrammaticChange = false }
            popups.hideAll()
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.isEditable, textView.window != nil, textView.shouldChangeText(in: full, replacementString: newText) {
                textView.replaceCharacters(in: full, with: newText)
                textView.didChangeText()
                let end = (newText as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
            } else {
                replaceText(newText)
            }
        }

        /// Replaces text without undo. Resets read-only views to the start to avoid laying out the whole document.
        func replaceText(_ newText: String) {
            guard let textView else { return }
            textView.string = newText
            if !textView.isEditable { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
            refreshDecorations(newText)
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let string = textView.string
            if !isProgrammaticChange || parent.text != string { parent.text = string }
            refreshDecorations(string)
            let change = pendingChange
            pendingChange = .none
            guard !isProgrammaticChange else { return }
            handleUserChange(change)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
            guard let textView else { return }
            let selection = textView.selectedRange()
            let line = CodeEditorText.lineIndex(forOffset: selection.location, lineStarts: lineStarts)
            if selection.length > 0 || (popupLine != nil && popupLine != line) {
                popups.hideAll()
                popupLine = nil
            }
        }

        func textViewFocusChanged(_ focused: Bool) {
            if !focused { popups.hideAll() }
            parent.onFocusChange?(focused)
        }

        func refreshDecorations(_ current: String? = nil) {
            guard let textView else { return }
            let string = current ?? textView.string
            lastText = string
            lineStarts = CodeEditorText.lineStarts(of: string)
            ruler?.lineStarts = lineStarts
            if parent.showsCommandMarkers, parent.language == .redis {
                ruler?.commandLines = Set(RedisSyntaxHighlighter.commandLineIndices(string))
            }

            applyHighlighting(textView, text: string)
            textView.needsDisplay = true
        }

        /// Colors small documents immediately; tokenizes larger ones off the main actor and colors only visible text.
        private func applyHighlighting(_ textView: NSTextView, text: String) {
            guard let layoutManager = textView.layoutManager else { return }
            highlightGeneration += 1
            lazyTokens = []
            coloredRanges = IndexSet()
            let length = textView.textStorage?.length ?? 0
            guard parent.language != .plain, length <= Self.maxHighlightLength else {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
                return
            }
            let (language, keywords) = (parent.language, parent.keywords)
            guard length > Self.lazyHighlightLength else {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
                for token in RedisSyntaxHighlighter.tokenize(text, language: language, keywords: keywords) {
                    guard NSMaxRange(token.range) <= length else { continue }
                    let color = EditorAppearance.Syntax.color(for: token.kind)
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
                }

                return
            }
            let generation = highlightGeneration
            Task { @MainActor [weak self] in
                let tokens = await Task.detached(priority: .userInitiated) {
                    RedisSyntaxHighlighter.tokenize(text, language: language, keywords: keywords)
                }.value
                guard let self, generation == self.highlightGeneration else { return }
                self.lazyTokens = tokens
                self.colorVisibleRange()
            }
        }

        /// Colors the visible text plus a margin from `lazyTokens`, once per range until the next text change.
        func colorVisibleRange() {
            guard !lazyTokens.isEmpty, let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            let length = textView.textStorage?.length ?? 0
            var visible = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
            visible = visible.insetBy(dx: 0, dy: -visible.height)
            let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
            let range = NSIntersectionRange(layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil),
                                            NSRange(location: 0, length: length))
            guard range.length > 0, let span = Range(range),
                  !coloredRanges.contains(integersIn: span) else { return }
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            var index = Self.firstToken(endingAfter: range.location, in: lazyTokens)
            while index < lazyTokens.count, lazyTokens[index].range.location < NSMaxRange(range) {
                let token = lazyTokens[index]
                index += 1
                guard NSMaxRange(token.range) <= length else { continue }
                let color = EditorAppearance.Syntax.color(for: token.kind)
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
            }

            coloredRanges.insert(integersIn: span)
        }

        static let lazyHighlightLength = 50_000
        static let maxHighlightLength = 400_000

        /// Index of the first token whose range ends after `location`; tokens are in document order.
        nonisolated static func firstToken(endingAfter location: Int, in tokens: [SyntaxToken]) -> Int {
            var low = 0
            var high = tokens.count
            while low < high {
                let mid = (low + high) / 2
                if NSMaxRange(tokens[mid].range) <= location { low = mid + 1 } else { high = mid }
            }

            return low
        }

        private func handleUserChange(_ change: PendingChange) {
            switch change {
            case .typed(let typed):
                if typed.contains(where: { $0.isWhitespace || $0.isNewline }) {
                    completionsSuppressed = false
                    popups.hideCompletions()
                } else if !completionsSuppressed {
                    triggerCompletions(explicit: false)
                }

                updateHint(explicit: false)
            case .deleted:
                if popups.isCompletionVisible { triggerCompletions(explicit: false) }
                if popups.isHintVisible { updateHint(explicit: false) }
            case .none:
                popups.hideAll()
            }
        }

        // MARK: Completions

        func triggerCompletions(explicit: Bool) {
            guard let textView, let provider = parent.completions, parent.isEditable else { return }
            if explicit { completionsSuppressed = false }
            let caret = textView.selectedRange().location
            let token = CodeEditorText.token(in: textView.string, cursor: caret)
            guard explicit || !token.isEmpty else {
                popups.hideCompletions()
                return
            }
            var items = provider(textView.string, caret)
            if items.count == 1, items[0].insertText == token { items = [] }
            guard !items.isEmpty else {
                popups.hideCompletions()
                return
            }
            popupLine = CodeEditorText.lineIndex(forOffset: caret, lineStarts: lineStarts)
            let anchor = CodeEditorText.tokenRange(in: textView.string, cursor: caret).location
            popups.showCompletions(items, in: textView, at: anchor)
        }

        func acceptCompletion(at index: Int) {
            guard let textView, popups.completionModel.items.indices.contains(index) else { return }
            let item = popups.completionModel.items[index]
            popups.hideCompletions()
            let caret = textView.selectedRange().location
            let tokenRange = CodeEditorText.tokenRange(in: textView.string, cursor: caret)
            let expanded = CodeSnippet.expand(item.insertText)
            textView.programmaticInsert(expanded.text, replacementRange: tokenRange)
            if let selection = expanded.selection {
                textView.setSelectedRange(NSRange(location: tokenRange.location + selection.location, length: selection.length))
            }

            updateHint(explicit: false)
        }

        func updateHint(explicit: Bool) {
            guard let textView, let provider = parent.signatureHint else { return }
            let caret = textView.selectedRange().location
            if let hint = provider(textView.string, caret) {
                popupLine = CodeEditorText.lineIndex(forOffset: caret, lineStarts: lineStarts)
                popups.showHint(hint, in: textView, at: caret)
            } else {
                popups.hideHint()
            }
        }

        // MARK: Keys

        func handleSubmit() -> Bool {
            guard let onSubmit = parent.onSubmit else { return false }
            popups.hideAll()
            onSubmit()
            return true
        }

        func handleKeyDown(_ event: NSEvent, in textView: EditorTextView) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            let completionVisible = popups.isCompletionVisible
            switch event.keyCode {
            case 36, 76:
                if flags.contains(.command) || flags.contains(.control) { return handleSubmit() }
                if completionVisible, flags.isEmpty {
                    acceptCompletion(at: popups.completionModel.selectedIndex)
                    return true
                }

                if flags == .shift, textView.isEditable {
                    textView.insertNewline(nil)
                    return true
                }

                return false
            case 48:
                if completionVisible, flags.isEmpty {
                    acceptCompletion(at: popups.completionModel.selectedIndex)
                    return true
                }

                if flags.isEmpty, textView.isEditable {
                    textView.insertText("    ", replacementRange: textView.selectedRange())
                    return true
                }

                return false
            case 53:
                if completionVisible {
                    popups.hideCompletions()
                    completionsSuppressed = true
                    return true
                }

                if popups.isHintVisible {
                    popups.hideHint()
                    return true
                }

                if parent.onEscape?() == true { return true }
                return true
            case 126:
                if completionVisible, flags.isEmpty {
                    popups.moveSelection(by: -1)
                    return true
                }

                if flags.isEmpty, parent.onHistoryUp != nil, isCaretOnFirstLine(textView) {
                    return parent.onHistoryUp?() ?? false
                }

                return false
            case 125:
                if completionVisible, flags.isEmpty {
                    popups.moveSelection(by: 1)
                    return true
                }

                if flags.isEmpty, parent.onHistoryDown != nil, isCaretOnLastLine(textView) {
                    return parent.onHistoryDown?() ?? false
                }

                return false
            case 116, 121:
                guard completionVisible else { return false }
                popups.moveSelection(by: event.keyCode == 116 ? -8 : 8)
                return true
            case 49:
                if flags == .control {
                    triggerCompletions(explicit: true)
                    return true
                }

                if flags == [.command, .shift] {
                    updateHint(explicit: true)
                    return true
                }

                return false
            default:
                return false
            }
        }

        private func isCaretOnFirstLine(_ textView: NSTextView) -> Bool {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }
            let prefix = (textView.string as NSString).substring(to: min(selection.location, (textView.string as NSString).length))
            return !prefix.contains("\n")
        }

        private func isCaretOnLastLine(_ textView: NSTextView) -> Bool {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }
            let ns = textView.string as NSString
            let suffix = ns.substring(from: min(selection.location, ns.length))
            return !suffix.contains("\n")
        }
    }
}

final class EditorTextView: NSTextView {
    weak var coordinator: CodeEditorView.Coordinator?

    var placeholder: String? {
        didSet { if oldValue != placeholder { needsDisplay = true } }
    }

    var wrapsLines = true
    private var isProgrammaticInsert = false

    private static let pairs: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125, 34: 34, 39: 39]
    private static let closers: Set<UInt16> = [41, 93, 125, 34, 39]
    /// Characters before which an opening bracket or quote is auto-closed: `) ] } , : ;` and newline.
    private static let closeBefore: Set<UInt16> = [41, 93, 125, 44, 58, 59, Char.newline]

    override func keyDown(with event: NSEvent) {
        if let coordinator, coordinator.handleKeyDown(event, in: self) { return }
        super.keyDown(with: event)
    }

    override func complete(_ sender: Any?) {
        if coordinator?.parent.completions != nil {
            coordinator?.triggerCompletions(explicit: true)
        } else {
            super.complete(sender)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { coordinator?.textViewFocusChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.textViewFocusChanged(false) }
        return resigned
    }

    /// Inserts without triggering completion / auto-close logic (still undoable and reported to the binding).
    func programmaticInsert(_ text: String, replacementRange: NSRange) {
        isProgrammaticInsert = true
        defer { isProgrammaticInsert = false }
        insertText(text, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !isProgrammaticInsert, let coordinator else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        coordinator.pendingChange = .typed(typed)
        let units = Array(typed.utf16)
        if coordinator.parent.autoCloseBrackets, coordinator.parent.language != .plain, units.count == 1,
           replacementRange.location == NSNotFound, handleAutoClose(units[0], typed: typed) {
            return
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    private func handleAutoClose(_ char: UInt16, typed: String) -> Bool {
        let ns = string as NSString
        let selection = selectedRange()
        let after = NSMaxRange(selection)
        let next: UInt16? = after < ns.length ? ns.character(at: after) : nil
        let previous: UInt16? = selection.location > 0 ? ns.character(at: selection.location - 1) : nil

        if selection.length == 0, Self.closers.contains(char), next == char {
            let isQuote = char == 34 || char == 39
            if !isQuote || previous != 92 {
                setSelectedRange(NSRange(location: after + 1, length: 0))
                coordinator?.pendingChange = .none
                return true
            }
        }

        guard let closer = Self.pairs[char] else { return false }
        let isQuote = char == 34 || char == 39
        if selection.length > 0 {
            let inner = ns.substring(with: selection)
            let pairText = typed + inner + String(utf16CodeUnits: [closer], count: 1)
            super.insertText(pairText, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
            return true
        }

        let nextAllows = next.map { Self.closeBefore.contains($0) || Char.isSpace($0) } ?? true
        let previousAllows = !isQuote || previous.map { previous in
            Char.isSpace(previous) || previous == Char.newline || Self.pairs[previous] != nil
                || previous == 58 || previous == 44 || previous == 61
        } ?? true
        guard nextAllows, previousAllows else { return false }
        super.insertText(typed + String(utf16CodeUnits: [closer], count: 1), replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        return true
    }

    override func deleteBackward(_ sender: Any?) {
        coordinator?.pendingChange = .deleted
        let ns = string as NSString
        let selection = selectedRange()
        if coordinator?.parent.autoCloseBrackets == true, selection.length == 0, selection.location > 0,
           selection.location < ns.length {
            let previous = ns.character(at: selection.location - 1)
            let next = ns.character(at: selection.location)
            if let closer = Self.pairs[previous], closer == next {
                let range = NSRange(location: selection.location - 1, length: 2)
                if shouldChangeText(in: range, replacementString: "") {
                    replaceCharacters(in: range, with: "")
                    didChangeText()
                }

                return
            }
        }

        super.deleteBackward(sender)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? EditorAppearance.font(),
            .foregroundColor: EditorAppearance.placeholder,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        let width = bounds.width - origin.x - padding
        (placeholder as NSString).draw(in: NSRect(x: origin.x, y: origin.y, width: max(width, 10), height: bounds.height),
                                       withAttributes: attributes)
    }
}
