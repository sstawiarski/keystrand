import Foundation
import RedisCore

/// One rendered line of a Text result view.
public struct ResultLine: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        case normal
        case error
        /// Group mode `> COMMAND` echo (bold).
        case command
        case notice
    }

    public var text: String
    public var style: Style

    public init(_ text: String, style: Style = .normal) {
        self.text = text
        self.style = style
    }
}

/// Pure, thread-safe redis-cli formatting of results, titles, tooltips and timing labels for use off the main actor.
public enum WorkbenchResultFormatter {
    /// Lines longer than this are cut in the Text view (Copy result still copies everything).
    public static let maxDisplayLineLength = 20_000
    public static let tooBigToSaveMessage = "This result is too large to keep, so it will be discarded when the app quits."

    /// Lines for the Text view of a card. `truncate` shortens very long lines for display.
    public static func lines(for execution: CommandExecution, truncate: Bool = true) -> [ResultLine] {
        guard let result = execution.result?.first else { return [] }
        var out: [ResultLine] = []
        switch result.response {
        case .message(let message):
            out = split(message, style: result.status == .fail ? .error : .normal)
        case .reply(let node):
            out = replyLines(node, command: execution.command, failed: result.status == .fail)
        case .group(let items):
            let prefix = dbPrefix(execution.db)
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(ResultLine("")) }
                out.append(ResultLine("\(prefix)> \(item.command)", style: .command))
                if let special = specialMessage(for: item.command) {
                    out += split(special, style: .notice)
                } else {
                    out += replyLines(item.response, command: item.command, failed: item.status == .fail)
                }
            }
        }

        guard truncate else { return out }
        return out.map { line in
            guard line.text.utf16.count > maxDisplayLineLength else { return line }
            let prefix = String(line.text.prefix(maxDisplayLineLength))
            let hidden = line.text.count - prefix.count
            return ResultLine(prefix + " … (\(hidden) more characters; use Copy result to get the full text)",
                              style: line.style)
        }
    }

    /// Full text copied by `Copy result`.
    public static func copyText(for execution: CommandExecution) -> String {
        lines(for: execution, truncate: false).map(\.text).joined(separator: "\n")
    }

    static func replyLines(_ node: ReplyNode, command: String, failed: Bool) -> [ResultLine] {
        if failed || isError(node) {
            if case .error(let message) = node { return split(message, style: .error) }
            return split(ReplyTextFormatter.text(node, command: command), style: .error)
        }

        return split(ReplyTextFormatter.text(replaceEmpty(node), command: command), style: .normal)
    }

    static func isError(_ node: ReplyNode) -> Bool {
        if case .error = node { return true }
        return false
    }

    /// An empty top-level string renders as `(nil)`.
    public static func replaceEmpty(_ node: ReplyNode) -> ReplyNode {
        if case .string(let s) = node, s.isEmpty { return .null }
        return node
    }

    static func split(_ text: String, style: ResultLine.Style) -> [ResultLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            ResultLine(line.hasSuffix("\r") ? String(line.dropLast()) : String(line), style: style)
        }
    }

    /// What a card shows instead of a raw error for a command `CommandExecutor` refuses.
    enum Notice: Sendable {
        case guidance(CommandRules.Guidance)
        case unsupported(String)

        var message: String {
            switch self {
            case .guidance(let guidance): guidance.message
            case .unsupported(let message): message
            }
        }
    }

    static func notice(for command: String) -> Notice? {
        let arguments = WorkbenchScriptParser.arguments(of: command) ?? []
        if let guidance = CommandRules.guidance(for: command, arguments: arguments) { return .guidance(guidance) }
        if let entry = CommandRules.workbenchUnsupportedMatch(command, arguments: arguments) {
            return .unsupported(CommandRules.workbenchUnsupportedMessage(entry.uppercased()))
        }

        return nil
    }

    /// Guidance or unsupported-command text for commands the executor refuses.
    public static func specialMessage(for command: String) -> String? {
        notice(for: command)?.message
    }

    // MARK: - Header texts

    public static func dbPrefix(_ db: Int?) -> String {
        guard let db, db != 0 else { return "" }
        return "[db\(db)] "
    }

    /// `[db3] GET foo` (single line).
    public static func title(command: String, db: Int?) -> String {
        let oneLine = command.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        return dbPrefix(db) + oneLine
    }

    /// Hover text: numbered lines (max 20: first 18, `...`, last), each cut at 497 characters.
    public static func commandTooltip(_ command: String) -> String {
        let lines = command.components(separatedBy: .newlines).filter { !$0.isEmpty }
        func cut(_ line: String) -> String { line.count > 497 ? String(line.prefix(497)) + "…" : line }
        var numbered = lines.enumerated().map { "\($0.offset + 1). \(cut($0.element))" }
        if numbered.count > 20 {
            let last = numbered[numbered.count - 1]
            numbered = Array(numbered.prefix(18)) + ["…", last]
        }

        return numbered.joined(separator: "\n")
    }

    /// `3 Command(s) - 2 success, 1 error(s)`; silent cards omit the errors part when there are none.
    public static func summaryText(_ summary: ResultsSummary?, resultsMode: ResultsMode, commandCount: Int,
                                   isRunning: Bool) -> String {
        guard !isRunning, let summary else { return "\(commandCount) - Command(s)" }
        var text = "\(summary.total) Command(s) - \(summary.success) success"
        if !(resultsMode == .silent && summary.fail == 0) { text += ", \(summary.fail) error(s)" }
        return text
    }

    /// Short execution time label: `0.24 msec`, `12 msec`, `2 s`, `3 min`.
    public static func timeLabel(microseconds: Int) -> String {
        guard microseconds >= 1 else { return "0.001 msec" }
        let ms = Double(microseconds) / 1000
        if ms < 1000 {
            let digits = ms < 10 ? 3 : (ms < 100 ? 2 : 1)
            return trimmed(ms, maxFractionDigits: digits) + " msec"
        }

        let seconds = ms / 1000
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return "\(Int(seconds / 3600)) h"
    }

    /// `Processing Time: 1,234.567 msec`.
    public static func timeTooltip(microseconds: Int) -> String {
        guard microseconds >= 1 else { return "Processing Time: 0.001 msec" }
        let ms = Double(microseconds) / 1000
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 3
        formatter.maximumFractionDigits = 3
        let text = formatter.string(from: NSNumber(value: ms)) ?? String(format: "%.3f", ms)
        return "Processing Time: \(text) msec"
    }

    static func trimmed(_ value: Double, maxFractionDigits: Int) -> String {
        var text = String(format: "%.\(maxFractionDigits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }

        return text
    }

    /// Header message of a rendered search table.
    public static func headerMessage(matched: String) -> String {
        "Matched:\(matched)"
    }

    /// Collapsed-header form of a visualization message: 13 characters, then `...`.
    public static func truncatedHeaderMessage(_ text: String, maxLength: Int = 13) -> String {
        text.count >= maxLength ? String(text.prefix(maxLength)) + "…" : text
    }

    /// Mode tags for the "…" parameters icon.
    public static func parameterTags(mode: RunQueryMode, resultsMode: ResultsMode) -> [String] {
        var tags: [String] = []
        if resultsMode == .group { tags.append("Group mode") }
        if resultsMode == .silent { tags.append("Silent mode") }
        if mode == .raw { tags.append("Raw mode") }
        return tags
    }

    /// Header caption for non-default run modes, for example "Raw · Grouped" (nil for the defaults).
    public static func modeCaption(mode: RunQueryMode, resultsMode: ResultsMode) -> String? {
        var parts: [String] = []
        if mode == .raw { parts.append("Raw") }
        if resultsMode == .group { parts.append("Grouped") }
        if resultsMode == .silent { parts.append("Silent") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
