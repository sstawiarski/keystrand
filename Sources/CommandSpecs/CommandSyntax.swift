import Foundation

/// Renders command syntax such as `HSET key field value [field value ...]` for documentation and editor hints.
public enum CommandSyntax {
    /// `NAME arg1 [opt] ...` (empty argument renderings are skipped).
    public static func render(_ spec: CommandSpec) -> String {
        ([spec.name] + argumentNames(spec.arguments)).joined(separator: " ")
    }

    public static func render(_ argument: CommandArgument) -> String {
        syntax(argument)
    }

    /// `pureName` omits the `[x ...]` repetition suffix; `onlyMandatory` omits optional arguments.
    public static func syntax(_ argument: CommandArgument, pureName: Bool = false, onlyMandatory: Bool = false) -> String {
        if onlyMandatory && argument.optional { return "" }
        let display = argument.displayText ?? argument.name
        var args: String
        switch argument.type {
        case .block:
            args = argument.arguments.map { syntax($0) }.joined(separator: " ")
        case .oneof:
            args = argument.arguments.map { syntax($0) }.joined(separator: " | ")
        case .enumeration:
            args = (argument.enumValues ?? []).joined(separator: " | ")
        case .pureToken:
            args = ""
        default:
            args = display
        }

        var out = ""
        if let token = displayToken(argument) {
            out += token
            if argument.type != .pureToken { out += " " }
        }

        if argument.multiple && !pureName {
            if argument.multipleToken, let token = displayToken(argument) {
                out += "\(args) [\(token) \(args) ...]"
            } else {
                out += "\(args) [\(args) ...]"
            }
        } else {
            out += args
        }

        if argument.optional { out = "[\(out)]" }
        return out
    }

    /// Renders each top-level argument, excluding empty results.
    public static func argumentNames(_ arguments: [CommandArgument], pureName: Bool = false,
                                     onlyMandatory: Bool = false) -> [String] {
        arguments.map { syntax($0, pureName: pureName, onlyMandatory: onlyMandatory) }.filter { !$0.isEmpty }
    }

    /// Arguments without the command name (`key value [NX | XX] ...`), or nil when the command takes none.
    public static func argumentsLine(_ spec: CommandSpec) -> String? {
        let names = argumentNames(spec.arguments)
        return names.isEmpty ? nil : names.joined(separator: " ")
    }

    /// Returns Multiple, Optional or Required for the Arguments list badge.
    public static func kindLabel(_ argument: CommandArgument) -> String {
        if argument.multiple { return "Multiple" }
        if argument.optional { return "Optional" }
        return "Required"
    }

    /// `O(1)`-style complexity, or "" when the text is not a short big-O notation.
    public static func complexityShortNotation(_ complexity: String?) -> String {
        guard let value = complexity?.trimmingCharacters(in: .whitespaces) else { return "" }
        return value.hasPrefix("O") && value.hasSuffix(")") ? value : ""
    }

    /// Builds the Redis command documentation URL.
    public static func docURL(for commandName: String) -> URL? {
        let slug = commandName.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
        return URL(string: "https://redis.io/docs/latest/commands/\(slug)/")
    }

    /// Markdown for completion popups with a summary, Read more link and Arguments list.
    public static func markdownDocumentation(_ spec: CommandSpec) -> String {
        var lines: [String] = []
        var summary = spec.summary
        if let url = docURL(for: spec.name) { summary += " [Read more](\(url.absoluteString))" }
        lines.append(summary)
        if !spec.arguments.isEmpty {
            lines.append("### Arguments:")
            for argument in spec.arguments {
                lines.append("_\(kindLabel(argument))_ `\(syntax(argument, pureName: true))`")
            }
        }

        return lines.joined(separator: "\n\n")
    }

    /// Displays an empty token as `""`.
    static func displayToken(_ argument: CommandArgument) -> String? {
        guard let token = argument.token else { return nil }
        return token.isEmpty ? "\"\"" : token
    }
}
