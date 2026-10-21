import AppKit
import SwiftUI

public enum CodeLanguage: String, Sendable, Hashable {
    case redis
    case json
    case plain
}

public struct CodeCompletion: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable { case command, argument, keyword, index, field, snippet, other }

    public var id: String { kind.rawValue + ":" + label }
    public var label: String
    /// Replaces the token before the caret. Supports snippet placeholders `${1:text}` and `$1`; the first
    /// placeholder is selected after insertion.
    public var insertText: String
    public var detail: String?
    public var documentation: String?
    public var kind: Kind

    public init(label: String, insertText: String? = nil, detail: String? = nil, documentation: String? = nil,
                kind: Kind = .other) {
        self.label = label
        self.insertText = insertText ?? label
        self.detail = detail
        self.documentation = documentation
        self.kind = kind
    }
}

/// Returns suggestions for the text and caret offset (UTF-16).
public typealias CodeCompletionProvider = @MainActor (_ text: String, _ cursorOffset: Int) -> [CodeCompletion]

/// Parameter hint shown above the caret, e.g. `SET key value [NX | XX]` with `value` highlighted.
public struct CodeSignatureHint: Hashable, Sendable {
    public var label: String
    /// UTF-16 range inside `label` to emphasize (the current argument).
    public var highlight: NSRange?
    public var documentation: String?

    public init(label: String, highlight: NSRange? = nil, documentation: String? = nil) {
        self.label = label
        self.highlight = highlight
        self.documentation = documentation
    }
}

/// Returns a signature hint for the text and caret offset (UTF-16), or nil to hide it.
public typealias CodeSignatureHintProvider = @MainActor (_ text: String, _ cursorOffset: Int) -> CodeSignatureHint?

/// Pure text helpers used by the editors (and available to completion providers).
public enum CodeEditorText {
    static let tokenStops: Set<UInt16> = [Char.space, Char.tab, Char.newline, Char.carriageReturn, Char.doubleQuote,
                                          Char.singleQuote, Char.openParen, Char.closeParen, Char.comma, 123, 125]

    /// Range of the word immediately before `cursor` (UTF-16), possibly empty. Stops at whitespace, quotes,
    /// parentheses, commas and braces, so `'@na|` yields `@na`.
    public static func tokenRange(in text: String, cursor: Int) -> NSRange {
        let ns = text as NSString
        let caret = max(0, min(cursor, ns.length))
        var start = caret
        while start > 0, !tokenStops.contains(ns.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: caret - start)
    }

    public static func token(in text: String, cursor: Int) -> String {
        (text as NSString).substring(with: tokenRange(in: text, cursor: cursor))
    }

    /// Zero-based line index and UTF-16 column of `offset`.
    public static func lineAndColumn(in text: String, offset: Int) -> (line: Int, column: Int) {
        let ns = text as NSString
        let target = max(0, min(offset, ns.length))
        var line = 0
        var lineStart = 0
        var i = 0
        while i < target {
            if ns.character(at: i) == Char.newline {
                line += 1
                lineStart = i + 1
            }

            i += 1
        }

        return (line, target - lineStart)
    }

    /// UTF-16 offsets where each line starts (always contains 0).
    public static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        var index = 0
        for unit in text.utf16 {
            index += 1
            if unit == Char.newline { starts.append(index) }
        }

        return starts
    }

    /// Index of the line containing `offset`, by binary search over `lineStarts`.
    public static func lineIndex(forOffset offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }

        return low
    }
}

/// Snippet expansion for completion insert text.
public enum CodeSnippet {
    /// Expands `${n:placeholder}`, `${n}` and `$n` (VS Code style). Returns the plain text and the UTF-16 range of the
    /// lowest-numbered placeholder (`$0` last), or nil when the text has no placeholders.
    public static func expand(_ snippet: String) -> (text: String, selection: NSRange?) {
        let chars = Array(snippet.utf16)
        var output: [UInt16] = []
        var placeholders: [(number: Int, range: NSRange)] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == Char.backslash, i + 1 < chars.count, chars[i + 1] == 36 || chars[i + 1] == 125 {
                output.append(chars[i + 1])
                i += 2
                continue
            }

            if c == 36, i + 1 < chars.count {
                if chars[i + 1] == 123, let parsed = parseBraced(chars, from: i + 2) {
                    let location = output.count
                    output.append(contentsOf: parsed.placeholder)
                    placeholders.append((parsed.number, NSRange(location: location, length: parsed.placeholder.count)))
                    i = parsed.end
                    continue
                }

                if Char.isDigit(chars[i + 1]) {
                    var j = i + 1
                    var number = 0
                    while j < chars.count, Char.isDigit(chars[j]) {
                        number = number * 10 + Int(chars[j] - 48)
                        j += 1
                    }

                    placeholders.append((number, NSRange(location: output.count, length: 0)))
                    i = j
                    continue
                }
            }

            output.append(c)
            i += 1
        }

        let text = String(utf16CodeUnits: output, count: output.count)
        let first = placeholders.min { lhs, rhs in
            let l = lhs.number == 0 ? Int.max : lhs.number
            let r = rhs.number == 0 ? Int.max : rhs.number
            return l < r
        }
        return (text, first?.range)
    }

    private static func parseBraced(_ chars: [UInt16], from start: Int) -> (number: Int, placeholder: [UInt16], end: Int)? {
        var i = start
        var number = 0
        let digitsStart = i
        while i < chars.count, Char.isDigit(chars[i]) {
            number = number * 10 + Int(chars[i] - 48)
            i += 1
        }

        guard i > digitsStart, i < chars.count else { return nil }
        if chars[i] == 125 { return (number, [], i + 1) }
        guard chars[i] == Char.colon else { return nil }
        i += 1
        var placeholder: [UInt16] = []
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == Char.backslash, i + 1 < chars.count {
                placeholder.append(chars[i + 1])
                i += 2
                continue
            }

            if c == 123 { depth += 1 }
            if c == 125 {
                if depth == 0 { return (number, placeholder, i + 1) }
                depth -= 1
            }

            placeholder.append(c)
            i += 1
        }

        return nil
    }
}

/// Imperative handle for an editor or command-line field: insert at caret, focus, replace text.
/// Pass the same instance to `CodeEditorView(controller:)` or `CommandLineField(controller:)`.
@MainActor
public final class CodeEditorController {
    weak var textView: NSTextView?
    weak var textField: NSTextField?
    var explicitCompletionHandler: (() -> Void)?

    public init() {}

    private var editor: NSTextView? {
        if let textView { return textView }
        return textField?.currentEditor() as? NSTextView
    }

    public var isAttached: Bool { textView != nil || textField != nil }

    public var isFocused: Bool {
        if let textView { return textView.window?.firstResponder === textView }
        if let textField, let editor = textField.currentEditor() { return textField.window?.firstResponder === editor }
        return false
    }

    /// Current selection (UTF-16), or nil when detached.
    public var selectedRange: NSRange? { editor?.selectedRange() }

    /// Inserts at the caret, replacing the selection, as an undoable user edit.
    public func insert(_ text: String) {
        if let editorView = textView as? EditorTextView {
            editorView.programmaticInsert(text, replacementRange: editorView.selectedRange())
            return
        }

        if textField != nil, textView == nil { focus() }
        guard let editor else { return }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// Replaces the whole content as an undoable edit and puts the caret at the end.
    public func replaceAll(with text: String) {
        if let textField, textView == nil {
            textField.stringValue = text
            if let fieldEditor = textField.currentEditor() {
                fieldEditor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }

            textField.sendTextDidChange()
            return
        }

        guard let editor else { return }
        let full = NSRange(location: 0, length: (editor.string as NSString).length)
        if let editorView = editor as? EditorTextView {
            editorView.programmaticInsert(text, replacementRange: full)
        } else {
            editor.insertText(text, replacementRange: full)
        }
    }

    public func focus() {
        if let textView {
            textView.window?.makeFirstResponder(textView)
        } else if let textField {
            textField.window?.makeFirstResponder(textField)
        }
    }

    public func moveCaretToEnd() {
        if textField != nil, textView == nil { focus() }
        guard let editor else { return }
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    public func selectAll() {
        editor?.selectAll(nil)
    }

    /// Opens the completion list as if Ctrl+Space was pressed (CodeEditorView only).
    public func showCompletions() {
        explicitCompletionHandler?()
    }
}

extension NSTextField {
    func sendTextDidChange() {
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: self)
    }
}
