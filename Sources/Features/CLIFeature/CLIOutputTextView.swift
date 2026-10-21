import AppKit
import RedisUI
import SwiftUI

/// Appends terminal output incrementally in a read-only, selectable TextKit 1 view and removes trimmed chunks.
/// Appends scroll to the end unless the user scrolls up; `scrollToEndToken` forces a jump to the end.
struct CLIOutputTextView: NSViewRepresentable {
    let buffer: CLIOutputBuffer
    var scrollToEndToken = 0
    var onLink: (CLILink) -> Void
    var onClickWithoutSelection: () -> Void
    var onClear: () -> Void
    var onScrolledAwayChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let storage = NSTextStorage()
        let layoutManager = EditorLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: scrollView.contentSize.width,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = CLIOutputNSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize),
                                           textContainer: container)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.setAccessibilityLabel("CLI output")
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.textView = textView
        context.coordinator.observeScrolling(scrollView)
        context.coordinator.render(buffer)
        context.coordinator.renderedScrollToken = scrollToEndToken
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(buffer)
        if context.coordinator.renderedScrollToken != scrollToEndToken {
            context.coordinator.renderedScrollToken = scrollToEndToken
            context.coordinator.scrollToEnd()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CLIOutputTextView
        weak var textView: NSTextView?
        var renderedScrollToken = 0
        private var renderedGeneration = -1
        private var rendered: [(id: Int, length: Int)] = []
        private var renderedHead = 0
        private var isPinnedToEnd = true
        private var reportedScrolledAway = false
        private var isProgrammaticScroll = false
        private var boundsObserver: NSObjectProtocol?

        init(parent: CLIOutputTextView) {
            self.parent = parent
        }

        func observeScrolling(_ scrollView: NSScrollView) {
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollPositionChanged() }
            }
        }

        func stopObserving() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
        }

        private func scrollPositionChanged() {
            guard !isProgrammaticScroll, let textView, let scrollView = textView.enclosingScrollView else { return }
            isPinnedToEnd = Self.isAtEnd(visible: scrollView.contentView.bounds, documentHeight: textView.frame.height)
            report()
        }

        /// The end counts as reached within a few points, so rounding never unpins the view.
        static func isAtEnd(visible: NSRect, documentHeight: CGFloat) -> Bool {
            visible.maxY >= documentHeight - 4
        }

        private func report() {
            let away = !isPinnedToEnd
            guard away != reportedScrolledAway else { return }
            reportedScrolledAway = away
            parent.onScrolledAwayChange(away)
        }

        func scrollToEnd() {
            isProgrammaticScroll = true
            textView?.scrollToEndOfDocument(nil)
            isProgrammaticScroll = false
            isPinnedToEnd = true
            report()
        }

        func render(_ buffer: CLIOutputBuffer) {
            guard let textView, let storage = textView.textStorage else { return }
            var changed = false
            storage.beginEditing()
            if buffer.generation != renderedGeneration {
                storage.setAttributedString(NSAttributedString())
                rendered.removeAll()
                renderedHead = 0
                renderedGeneration = buffer.generation
                changed = true
            }

            let firstID = buffer.chunks.first?.id ?? Int.max
            var removeLength = 0
            while renderedHead < rendered.count, rendered[renderedHead].id < firstID {
                removeLength += rendered[renderedHead].length
                renderedHead += 1
            }

            if removeLength > 0 {
                storage.deleteCharacters(in: NSRange(location: 0, length: min(removeLength, storage.length)))
                changed = true
            }

            if renderedHead > 512 {
                rendered.removeFirst(renderedHead)
                renderedHead = 0
            }

            let lastID = renderedHead < rendered.count ? rendered[rendered.count - 1].id : -1
            var startIndex = buffer.chunks.count
            while startIndex > 0, buffer.chunks[startIndex - 1].id > lastID { startIndex -= 1 }
            if startIndex < buffer.chunks.count {
                let appended = NSMutableAttributedString()
                for chunk in buffer.chunks[startIndex...] {
                    let piece = Self.attributed(chunk)
                    rendered.append((chunk.id, piece.length))
                    appended.append(piece)
                }

                storage.append(appended)
                changed = true
            }

            storage.endEditing()
            if changed, isPinnedToEnd || buffer.chunks.isEmpty {
                scrollToEnd()
            }
        }

        static func attributed(_ chunk: CLIOutputChunk) -> NSAttributedString {
            let out = NSMutableAttributedString()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            for segment in chunk.segments {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: segment.style == .command
                        ? EditorAppearance.font(weight: .bold)
                        : EditorAppearance.font(),
                    .foregroundColor: color(for: segment.style),
                    .paragraphStyle: paragraph,
                ]
                if let link = segment.link {
                    attributes[.link] = link.url
                }

                out.append(NSAttributedString(string: segment.text, attributes: attributes))
            }

            return out
        }

        static func color(for style: CLITextStyle) -> NSColor {
            switch style {
            case .command: return .labelColor
            case .plain, .reply: return EditorAppearance.nsText
            case .error: return .systemRed
            case .intro, .muted: return .secondaryLabelColor
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let target = CLILink(url: url) else { return false }
            parent.onLink(target)
            return true
        }

        func clickedWithoutSelection() {
            parent.onClickWithoutSelection()
        }

        func clear() {
            parent.onClear()
        }
    }
}

/// Output text view: a single click that selects nothing focuses the CLI input (after a 300 ms double-click guard);
/// Cmd+K / Ctrl+L clear the output.
final class CLIOutputNSTextView: NSTextView {
    weak var coordinator: CLIOutputTextView.Coordinator?
    private var pendingFocus: Task<Void, Never>?

    override func mouseDown(with event: NSEvent) {
        pendingFocus?.cancel()
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        pendingFocus = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.selectedRange().length == 0 else { return }
            self.coordinator?.clickedWithoutSelection()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if window?.firstResponder === self, flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "k" {
            coordinator?.clear()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags == .control, event.charactersIgnoringModifiers?.lowercased() == "l" {
            coordinator?.clear()
            return
        }

        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Output", action: #selector(clearOutput(_:)), keyEquivalent: "k")
        clear.keyEquivalentModifierMask = .command
        clear.target = self
        menu.addItem(clear)
        return menu
    }

    @objc private func clearOutput(_ sender: Any?) {
        coordinator?.clear()
    }
}
