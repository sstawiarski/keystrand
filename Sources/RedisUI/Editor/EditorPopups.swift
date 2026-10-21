import AppKit
import SwiftUI

/// Borderless child panel that never takes key status, so the text view keeps the keyboard.
final class EditorPopupPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class CompletionListModel {
    var items: [CodeCompletion] = []
    var selectedIndex = 0
    var onPick: (Int) -> Void = { _ in }

    var selected: CodeCompletion? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }
}

struct CompletionListView: View {
    let model: CompletionListModel
    static let rowHeight: CGFloat = 22
    static let maxVisibleRows = 9
    static let width: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                            row(item, selected: index == model.selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { model.onPick(index) }
                        }
                    }
                }
                .frame(height: CGFloat(min(model.items.count, Self.maxVisibleRows)) * Self.rowHeight)
                .onChange(of: model.selectedIndex) { _, index in proxy.scrollTo(index) }
            }
            if let documentation = model.selected?.documentation, !documentation.isEmpty {
                Divider()
                Text(documentation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
    }

    private func row(_ item: CodeCompletion, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(item.kind))
                .imageScale(.small)
                .foregroundStyle(selected ? Color.white : Color(nsColor: EditorAppearance.Syntax.keyword))
                .frame(width: 14)
            Text(item.label)
                .font(.callout.monospaced().weight(.medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = item.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
    }

    private func icon(_ kind: CodeCompletion.Kind) -> String {
        switch kind {
        case .command: return "terminal"
        case .argument: return "chevron.left.forwardslash.chevron.right"
        case .keyword: return "textformat"
        case .index: return "list.bullet.rectangle"
        case .field: return "at"
        case .snippet: return "curlybraces"
        case .other: return "circle.fill"
        }
    }

    static func height(for model: CompletionListModel) -> CGFloat {
        var height = CGFloat(min(model.items.count, maxVisibleRows)) * rowHeight
        if let documentation = model.selected?.documentation, !documentation.isEmpty { height += 64 }
        return height + 2
    }
}

struct SignatureHintView: View {
    let hint: CodeSignatureHint

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attributed)
                .font(.callout.monospaced())
                .lineLimit(2)
            if let documentation = hint.documentation, !documentation.isEmpty {
                Text(documentation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 560, alignment: .leading)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
    }

    private var attributed: AttributedString {
        var result = AttributedString(hint.label)
        result.foregroundColor = Color.secondary
        guard let highlight = hint.highlight,
              let range = Range(highlight, in: hint.label),
              let lower = AttributedString.Index(range.lowerBound, within: result),
              let upper = AttributedString.Index(range.upperBound, within: result) else { return result }
        result[lower..<upper].foregroundColor = Color.primary
        result[lower..<upper].font = Font.callout.monospaced().bold()
        result[lower..<upper].underlineStyle = .single
        return result
    }
}

/// Owns the completion and signature-hint panels of one text view.
@MainActor
final class EditorPopupController {
    let completionModel = CompletionListModel()
    private var completionPanel: EditorPopupPanel?
    private var completionHost: NSHostingView<AnyView>?
    private var hintPanel: EditorPopupPanel?
    private var hintHost: NSHostingView<AnyView>?

    var isCompletionVisible: Bool { completionPanel?.isVisible == true }
    var isHintVisible: Bool { hintPanel?.isVisible == true }

    func showCompletions(_ items: [CodeCompletion], in textView: NSTextView, at caret: Int) {
        guard !items.isEmpty, let window = textView.window else {
            hideCompletions()
            return
        }
        let previous = completionModel.selected?.id
        completionModel.items = items
        completionModel.selectedIndex = items.firstIndex { $0.id == previous } ?? 0
        let panel = completionPanel ?? makePanel()
        completionPanel = panel
        if completionHost == nil {
            let host = NSHostingView(rootView: AnyView(CompletionListView(model: completionModel)))
            completionHost = host
            panel.contentView = host
        }

        panel.appearance = textView.effectiveAppearance
        let size = NSSize(width: CompletionListView.width, height: CompletionListView.height(for: completionModel))
        position(panel, size: size, below: true, textView: textView, caret: caret, window: window)
    }

    func refreshCompletionLayout(in textView: NSTextView, caret: Int) {
        guard let panel = completionPanel, panel.isVisible, let window = textView.window else { return }
        let size = NSSize(width: CompletionListView.width, height: CompletionListView.height(for: completionModel))
        position(panel, size: size, below: true, textView: textView, caret: caret, window: window)
    }

    func moveSelection(by delta: Int) {
        let count = completionModel.items.count
        guard count > 0 else { return }
        completionModel.selectedIndex = (completionModel.selectedIndex + delta + count) % count
    }

    func hideCompletions() {
        guard let panel = completionPanel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func showHint(_ hint: CodeSignatureHint, in textView: NSTextView, at caret: Int) {
        guard let window = textView.window else { return }
        let panel = hintPanel ?? makePanel()
        panel.ignoresMouseEvents = true
        hintPanel = panel
        let view = AnyView(SignatureHintView(hint: hint))
        if let hintHost {
            hintHost.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            hintHost = host
            panel.contentView = host
        }

        panel.appearance = textView.effectiveAppearance
        let size = hintHost?.fittingSize ?? NSSize(width: 300, height: 24)
        position(panel, size: size, below: false, textView: textView, caret: caret, window: window)
    }

    func hideHint() {
        guard let panel = hintPanel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func hideAll() {
        hideCompletions()
        hideHint()
    }

    private func makePanel() -> EditorPopupPanel {
        EditorPopupPanel()
    }

    /// Top of the editor's visible area in screen coordinates, keeping hints below the window toolbar.
    private static func visibleTop(of textView: NSTextView, window: NSWindow) -> CGFloat? {
        let view: NSView = textView.enclosingScrollView ?? textView
        let rectInWindow = view.convert(view.visibleRect, to: nil)
        return window.convertToScreen(rectInWindow).maxY
    }

    private func position(_ panel: NSPanel, size: NSSize, below: Bool, textView: NSTextView, caret: Int, window: NSWindow) {
        let length = (textView.string as NSString).length
        let range = NSRange(location: min(caret, length), length: 0)
        var caretRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        if caretRect.height < 1 { caretRect.size.height = textView.font?.boundingRectForFont.height ?? 16 }
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: caretRect.minX - 4, y: below ? caretRect.minY - size.height - 2 : caretRect.maxY + 2)
        if below, origin.y < screenFrame.minY { origin.y = caretRect.maxY + 2 }
        let visibleTop = Self.visibleTop(of: textView, window: window) ?? screenFrame.maxY
        if !below, origin.y + size.height > min(screenFrame.maxY, visibleTop) { origin.y = caretRect.minY - size.height - 2 }
        if origin.x + size.width > screenFrame.maxX { origin.x = max(screenFrame.minX, screenFrame.maxX - size.width) }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
}
