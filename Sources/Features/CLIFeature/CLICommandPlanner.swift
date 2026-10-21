import Foundation
import RedisCore

/// A command line ready to send: split arguments, repeat count and the verb.
public struct CLIPreparedCommand: Hashable, Sendable {
    /// The command line without the repeat prefix.
    public var commandLine: String
    public var args: [Data]
    public var repeatCount: Int

    public var verb: String {
        args.first.map { String(decoding: $0, as: UTF8.self).uppercased() } ?? ""
    }
}

/// What the CLI does with a submitted line, decided before anything is sent.
public enum CLIInputAction: Hashable, Sendable {
    case empty
    case clear
    case invalidRepeat
    case guidance(CommandRules.Guidance)
    case unsupported(message: String)
    case parseError(message: String)
    case execute(CLIPreparedCommand)
}

/// Checks repeats, guidance, unsupported commands, then splits arguments.
/// Checks guidance and unsupported commands again after rebuilding the line from split arguments.
public enum CLICommandPlanner {
    public static let connectionClosedMessage =
        "The connection was closed. Run the command again once the CLI reconnects."
    public static let invalidRepeatMessage = "The repeat count before the command isn't valid."
    public static let commandCancelledMessage = "Command cancelled."
    public static let introPrefix = "For multi-line scripts and visual results, try "
    public static let introLink = "Workbench"
    public static let introSuffix = ". Tutorials in the inspector walk you through Redis features."
    static let maxRepeat = 2_147_483_647

    public static func plan(_ raw: String) -> CLIInputAction {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if trimmed.lowercased() == "clear" { return .clear }

        let (commandLine, count) = repeatPrefix(trimmed)
        guard let count else { return .invalidRepeat }
        if let refusal = refusal(for: commandLine) { return refusal }
        let args: [Data]
        do {
            args = try CommandLineSplitter.split(commandLine)
        } catch {
            return .parseError(message: error.localizedDescription)
        }

        guard !args.isEmpty else { return .empty }
        let canonical = CommandRules.canonicalLine(args.map { String(decoding: $0, as: UTF8.self) })
        if let refusal = refusal(for: canonical) { return refusal }
        return .execute(CLIPreparedCommand(commandLine: commandLine, args: args, repeatCount: count))
    }

    /// Guidance or the unsupported message for `line`, or nil when the CLI may send it.
    private static func refusal(for line: String) -> CLIInputAction? {
        if let guidance = CommandRules.guidance(for: line) { return .guidance(guidance) }
        guard let entry = CommandRules.cliUnsupportedMatch(line) else { return nil }
        let typed = String(line.trimmingCharacters(in: .whitespaces).prefix(entry.count))
        return .unsupported(message: CommandRules.cliUnsupportedMessage(typed))
    }

    /// `10 INCR c` -> (`INCR c`, 10). A first word that is not an integer is part of the command (count 1);
    /// an integer outside 1...2147483647 gives a nil count (invalid repeat).
    public static func repeatPrefix(_ line: String) -> (command: String, count: Int?) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return (trimmed, 1) }
        let first = trimmed[..<space]
        let rest = trimmed[space...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, let number = integerValue(String(first)) else { return (trimmed, 1) }
        guard number >= 1, number <= Double(maxRepeat) else { return (rest, nil) }
        return (rest, Int(number))
    }

    /// The line without a numeric repeat prefix (for hints and Command Helper matching); trailing spaces are kept.
    public static func strippingRepeat(_ line: String) -> String {
        let body = line.drop(while: { $0.isWhitespace })
        guard let space = body.firstIndex(where: { $0 == " " || $0 == "\t" }),
              integerValue(String(body[..<space])) != nil else { return line }
        return String(body[space...].drop(while: { $0.isWhitespace }))
    }

    private static func integerValue(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite, value == value.rounded(.towardZero) else { return nil }
        guard text.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "+" || $0 == "." || $0 == "e" || $0 == "E" }) else {
            return nil
        }
        return value
    }

    /// `> ` for db 0, `[db3] > ` otherwise.
    public static func prompt(db: Int) -> String {
        db > 0 ? "[db\(db)] > " : "> "
    }

    /// `host:port[db3]` (db suffix only when db > 0).
    public static func endpointLabel(host: String, port: Int, db: Int) -> String {
        "\(host):\(port)" + (db > 0 ? "[db\(db)]" : "")
    }

    /// New logical DB after a successful `SELECT`, or nil when the command is not a SELECT or the index is not numeric.
    public static func selectedDB(args: [Data]) -> Int? {
        guard args.count >= 2, String(decoding: args[0], as: UTF8.self).uppercased() == "SELECT" else { return nil }
        let raw = String(decoding: args[1], as: UTF8.self)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Int(raw)
    }

    /// Output for MONITOR / SUBSCRIBE / PSUBSCRIBE / HELLO 3, with the tool name as a link.
    public static func guidanceSegments(_ guidance: CommandRules.Guidance) -> [CLIOutputSegment] {
        let message = guidance.message
        let link: (word: String, target: CLILink)?
        switch guidance {
        case .monitor: link = ("Profiler", .profiler)
        case .subscribe, .psubscribe: link = ("Pub/Sub", .pubSub)
        case .resp3: link = nil
        }

        guard let link, let range = message.range(of: link.word) else {
            return [CLIOutputSegment(message, style: .error)]
        }
        return [
            CLIOutputSegment(String(message[..<range.lowerBound]), style: .error),
            CLIOutputSegment(link.word, style: .error, link: link.target),
            CLIOutputSegment(String(message[range.upperBound...]), style: .error),
        ]
    }

    /// Warning shown before every FLUSHDB / FLUSHALL, or nil for other verbs. An empty module list means the
    /// modules are unknown (not loaded yet or MODULE LIST denied), so the index-loss sentence is included.
    public static func flushWarning(verb: String, modules: [String]) -> String? {
        let upper = verb.uppercased()
        guard upper == "FLUSHDB" || upper == "FLUSHALL" else { return nil }
        return CommandWarnings.flushMessage(verbs: [upper],
                                            mayDropIndexes: CommandWarnings.flushMayDropIndexes(modules: modules))
    }

    /// True when the split arguments need the production type-to-confirm (`CONFIG SET` matches `config|set`).
    public static func isDangerous(args: [Data], dangerous: Set<String>, catalog: CommandCatalog?) -> Bool {
        let head = args.prefix(2).map { String(decoding: $0, as: UTF8.self) }
        return DangerousCommandClassifier(serverList: dangerous, catalog: catalog).dangerousVerb(head) != nil
    }
}

/// Walks through command history from newest to oldest.
public struct CLIHistoryCursor: Hashable, Sendable {
    public private(set) var index = -1

    public init() {}

    /// Older entry, or nil at the oldest one.
    public mutating func up(_ history: [String]) -> String? {
        guard index + 1 < history.count else { return nil }
        index += 1
        return history[index]
    }

    /// Newer entry; Down past the newest is a no-op (nil).
    public mutating func down(_ history: [String]) -> String? {
        guard index > 0, index - 1 < history.count else { return nil }
        index -= 1
        return history[index]
    }

    public mutating func reset() {
        index = -1
    }
}
