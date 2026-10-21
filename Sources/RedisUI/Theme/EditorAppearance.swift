import AppKit
import SwiftUI

/// Colors and font of code editors, the CLI and the Profiler output. Every color is a dynamic system color, so
/// AppKit and SwiftUI resolve it per appearance.
public enum EditorAppearance {
    /// The only explicit background allowed in content: code editors, CLI output and Profiler output.
    public static var background: Color { Color(nsColor: .textBackgroundColor) }
    public static var nsBackground: NSColor { .textBackgroundColor }
    public static var text: Color { Color(nsColor: .textColor) }
    public static var nsText: NSColor { .textColor }
    public static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    public static var error: Color { Color(nsColor: .systemRed) }
    public static var success: Color { Color(nsColor: .labelColor) }
    public static var gutterText: NSColor { .tertiaryLabelColor }
    public static var gutterActiveText: NSColor { .secondaryLabelColor }
    public static var commandMarker: NSColor { .systemGreen }
    public static var placeholder: NSColor { .placeholderTextColor }

    /// Monospaced editor font; the size defaults to the system font size (13).
    public static func font(size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    public enum Syntax {
        public static var text: NSColor { .textColor }
        public static var keyword: NSColor { .systemPink }
        public static var function: NSColor { .systemPurple }
        public static var string: NSColor { .systemRed }
        public static var number: NSColor { .systemBlue }
        public static var comment: NSColor { .secondaryLabelColor }
        public static var bracket: NSColor { .labelColor }
        public static var params: NSColor { .systemOrange }
        public static var operatorToken: NSColor { .systemTeal }

        /// Editor color of a highlighter token (JSON tokens use the JSON colors).
        public static func color(for kind: SyntaxTokenKind) -> NSColor {
            switch kind {
            case .keyword: return keyword
            case .string: return string
            case .number: return number
            case .comment: return comment
            case .bracket: return bracket
            case .params: return params
            case .key: return JSON.nsKey
            case .boolean, .null: return .systemPink
            case .punctuation: return .secondaryLabelColor
            }
        }
    }

    public enum JSON {
        public static var key: Color { .primary }
        public static var arrayKey: Color { .secondary }
        public static var string: Color { Color(nsColor: .systemRed) }
        public static var number: Color { Color(nsColor: .systemBlue) }
        public static var boolean: Color { Color(nsColor: .systemPink) }
        public static var null: Color { Color(nsColor: .systemPink) }
        public static var punctuation: Color { .secondary }
        static var nsKey: NSColor { .labelColor }
    }
}
