import AppKit
import SwiftUI

/// Single-line monospace command input for the CLI: Enter submits, Up/Down walk history, Tab / Shift+Tab cycle
/// completions, Esc and Cmd+K / Ctrl+L are reported. No spellcheck, autocorrect or smart quotes.
///
/// History and Tab callbacks return the replacement text (nil leaves the input unchanged); the caret moves to the end.
public struct CommandLineField: View {
    @Binding public var text: String
    public var placeholder: String
    public var isEnabled: Bool
    /// Dim argument hint drawn immediately after the typed text.
    public var trailingHint: String?
    public var fontSize: CGFloat
    public var controller: CodeEditorController?
    public var autoFocus: Bool
    public let onSubmit: (String) -> Void
    public var onHistoryUp: (() -> String?)?
    public var onHistoryDown: (() -> String?)?
    /// Called with `backwards == true` for Shift+Tab.
    public var onTab: ((_ backwards: Bool) -> String?)?
    public var onEscape: (() -> Void)?
    /// Cmd+K or Ctrl+L.
    public var onClear: (() -> Void)?

    public init(text: Binding<String>, placeholder: String = "", isEnabled: Bool = true, trailingHint: String? = nil,
                fontSize: CGFloat = 13, controller: CodeEditorController? = nil, autoFocus: Bool = false,
                onSubmit: @escaping (String) -> Void, onHistoryUp: (() -> String?)? = nil,
                onHistoryDown: (() -> String?)? = nil, onTab: ((_ backwards: Bool) -> String?)? = nil,
                onEscape: (() -> Void)? = nil, onClear: (() -> Void)? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.trailingHint = trailingHint
        self.fontSize = fontSize
        self.controller = controller
        self.autoFocus = autoFocus
        self.onSubmit = onSubmit
        self.onHistoryUp = onHistoryUp
        self.onHistoryDown = onHistoryDown
        self.onTab = onTab
        self.onEscape = onEscape
        self.onClear = onClear
    }

    public var body: some View {
        CommandLineTextFieldRepresentable(field: self)
            .overlay(alignment: .leading) {
                if let trailingHint, !trailingHint.isEmpty {
                    Text(trailingHint)
                        .font(Font(EditorAppearance.font(size: fontSize)))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .offset(x: Self.textWidth(text, fontSize: fontSize) + 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: fontSize + 8)
    }

    nonisolated static func textWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: EditorAppearance.font(size: fontSize)]).width)
    }
}

struct CommandLineTextFieldRepresentable: NSViewRepresentable {
    let field: CommandLineField

    func makeCoordinator() -> Coordinator { Coordinator(field: field) }

    func makeNSView(context: Context) -> CommandLineTextField {
        let textField = CommandLineTextField()
        textField.delegate = context.coordinator
        textField.coordinator = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.lineBreakMode = .byClipping
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.textColor = EditorAppearance.nsText
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: textField, coordinator: context.coordinator)
        if field.autoFocus {
            Task { @MainActor [weak textField] in
                guard let textField, let window = textField.window else { return }
                window.makeFirstResponder(textField)
            }
        }

        return textField
    }

    func updateNSView(_ textField: CommandLineTextField, context: Context) {
        context.coordinator.field = field
        apply(to: textField, coordinator: context.coordinator)
    }

    private func apply(to textField: CommandLineTextField, coordinator: Coordinator) {
        let font = EditorAppearance.font(size: field.fontSize)
        if textField.font != font { textField.font = font }
        if textField.stringValue != field.text {
            textField.stringValue = field.text
            if let editor = textField.currentEditor() {
                editor.selectedRange = NSRange(location: (field.text as NSString).length, length: 0)
            }
        }

        if textField.isEnabled != field.isEnabled { textField.isEnabled = field.isEnabled }
        textField.placeholderAttributedString = NSAttributedString(string: field.placeholder, attributes: [
            .font: font,
            .foregroundColor: EditorAppearance.placeholder,
        ])
        if let controller = field.controller {
            controller.textField = textField
        }
    }

    static func dismantleNSView(_ textField: CommandLineTextField, coordinator: Coordinator) {
        if coordinator.field.controller?.textField === textField { coordinator.field.controller?.textField = nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: CommandLineField

        init(field: CommandLineField) {
            self.field = field
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            if field.text != textField.stringValue { field.text = textField.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                field.onSubmit(textView.string)
                return true
            case #selector(NSResponder.moveUp(_:)):
                if let replacement = field.onHistoryUp?() { replace(textView, with: replacement, control: control) }
                return true
            case #selector(NSResponder.moveDown(_:)):
                if let replacement = field.onHistoryDown?() { replace(textView, with: replacement, control: control) }
                return true
            case #selector(NSResponder.insertTab(_:)):
                guard let onTab = field.onTab else { return false }
                if let replacement = onTab(false) { replace(textView, with: replacement, control: control) }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                guard let onTab = field.onTab else { return false }
                if let replacement = onTab(true) { replace(textView, with: replacement, control: control) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard let onEscape = field.onEscape else { return false }
                onEscape()
                return true
            case #selector(NSResponder.centerSelectionInVisibleArea(_:)):
                guard let onClear = field.onClear else { return false }
                onClear()
                return true
            case #selector(NSResponder.complete(_:)):
                return true
            default:
                return false
            }
        }

        private func replace(_ textView: NSTextView, with text: String, control: NSControl) {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            (control as? NSTextField)?.stringValue = text
            if field.text != text { field.text = text }
        }

        func handleClearShortcut() -> Bool {
            guard let onClear = field.onClear else { return false }
            onClear()
            return true
        }
    }
}

final class CommandLineTextField: NSTextField {
    weak var coordinator: CommandLineTextFieldRepresentable.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.smartInsertDeleteEnabled = false
        }

        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if currentEditor() != nil, flags == .command, event.charactersIgnoringModifiers?.lowercased() == "k",
           coordinator?.handleClearShortcut() == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
