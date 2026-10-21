import Foundation
import RedisCore

/// A dedicated connection that can run MONITOR.
protocol MonitorTransport: Sendable {
    func monitor() async -> AsyncThrowingStream<MonitorLine, Error>
    func close() async
}

extension RedisConnection: MonitorTransport {}

/// One MONITOR connection plus the node it watches (`nil` label for standalone databases).
struct MonitorNodeConnection: Sendable {
    var nodeLabel: String?
    var transport: any MonitorTransport
}

struct ProfilerEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case command
        case error
    }

    let id: UUID
    let kind: Kind
    /// `HH:mm:ss.SSS`.
    let timeText: String
    /// `[0 127.0.0.1:60866]`.
    let contextText: String
    /// First argument, quoted.
    let commandText: String
    /// Remaining arguments, quoted and space-separated.
    let argumentsText: String
    let nodeLabel: String?
    /// The unparsed server line (copy action).
    let raw: String

    init(line: MonitorLine, nodeLabel: String?, timeZone: TimeZone) {
        self.id = line.id
        self.kind = .command
        self.timeText = ProfilerFormatting.time(line.time, timeZone: timeZone)
        self.contextText = ProfilerFormatting.context(database: line.database, source: line.source)
        self.commandText = line.args.first.map { BinaryText.quoted($0, limit: 200) } ?? ""
        self.argumentsText = ProfilerFormatting.displayArguments(line.args.dropFirst())
        self.nodeLabel = nodeLabel
        self.raw = line.raw
    }

    init(errorMessage: String, nodeLabel: String? = nil, date: Date = Date(), timeZone: TimeZone = .current) {
        self.id = UUID()
        self.kind = .error
        self.timeText = ProfilerFormatting.time(date.timeIntervalSince1970, timeZone: timeZone)
        self.contextText = ""
        self.commandText = errorMessage
        self.argumentsText = ""
        self.nodeLabel = nodeLabel
        self.raw = errorMessage
    }

    var isError: Bool { kind == .error }

    var copyText: String {
        if isError { return commandText }
        return [timeText, contextText, commandText, argumentsText].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum ProfilerPhase: Equatable, Sendable {
    case idle
    case starting
    case running
    case paused
    /// NOPERM: the user may not run MONITOR.
    case forbidden(String)

    var isStarted: Bool {
        switch self {
        case .starting, .running, .paused: return true
        default: return false
        }
    }
}

enum ProfilerEvent: Sendable {
    case line(generation: Int, ProfilerEntry)
    case ended(generation: Int, nodeLabel: String?, failure: ProfilerStreamFailure)

    /// Lines may be dropped from a backed-up queue; stream-end events never are.
    var droppableGeneration: Int? {
        if case .line(let generation, _) = self { return generation }
        return nil
    }
}

enum ProfilerStreamFailure: Equatable, Sendable {
    case forbidden
    case server(String)
    case connectionLost

    static func classify(_ error: Error?) -> ProfilerStreamFailure {
        guard let error else { return .connectionLost }
        if case RedisClientError.server(let reply) = error {
            if reply.code == "NOPERM" || reply.message.uppercased().hasPrefix("NOPERM") { return .forbidden }
            return .server(reply.message)
        }

        if let reply = error as? RESPError {
            return reply.code == "NOPERM" ? .forbidden : .server(reply.message)
        }

        return .connectionLost
    }
}

enum ProfilerFormatting {
    static let invalidTime = "Invalid time"
    static let argumentDisplayLimit = 300
    static let argumentsDisplayLimit = 2_000

    /// `HH:mm:ss.SSS` of a MONITOR time (`seconds.micros`); non-numeric input gives "Invalid time".
    static func time(_ raw: String, timeZone: TimeZone) -> String {
        guard let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds.isFinite else { return invalidTime }
        return time(seconds, timeZone: timeZone)
    }

    static func time(_ seconds: Double, timeZone: TimeZone) -> String {
        guard seconds.isFinite, abs(seconds) < 1e12 else { return invalidTime }
        let millis = Int64((seconds * 1000).rounded(.down))
        let offset = Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: seconds))) * 1000
        let day: Int64 = 86_400_000
        let ofDay = ((millis + offset) % day + day) % day
        let h = ofDay / 3_600_000
        let m = (ofDay / 60_000) % 60
        let s = (ofDay / 1000) % 60
        let ms = ofDay % 1000
        return pad(h, 2) + ":" + pad(m, 2) + ":" + pad(s, 2) + "." + pad(ms, 3)
    }

    static func context(database: Int, source: String) -> String {
        source.isEmpty ? "[\(database)]" : "[\(database) \(source)]"
    }

    /// Arguments quoted and joined; very long argument lists and values are truncated for display.
    static func displayArguments<C: Collection>(_ args: C) -> String where C.Element == Data {
        var out = ""
        for arg in args {
            if !out.isEmpty { out += " " }
            out += BinaryText.quoted(arg, limit: argumentDisplayLimit)
            if out.count > argumentsDisplayLimit {
                out += " …"
                break
            }
        }

        return out
    }

    /// Log file line: `<time> [<db> <source>] "<arg1>" "<arg2>"`, each argument JSON-string-encoded.
    static func logLine(_ line: MonitorLine) -> String {
        var out = line.time + " " + context(database: line.database, source: line.source)
        for arg in line.args {
            out += " "
            out += jsonQuoted(BinaryText.full(arg))
        }

        return out
    }

    /// `JSON.stringify` of a string.
    static func jsonQuoted(_ text: String) -> String {
        var out = "\""
        out.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + pad(Int64(scalar.value), 4, radix: 16)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }

        return out + "\""
    }

    /// Running time `2 min, 8 s` (units d, h, min, s).
    static func runningTime(_ interval: TimeInterval) -> String {
        var rest = max(Int(interval.rounded(.down)), 0)
        guard rest > 0 else { return "0 s" }
        var parts: [String] = []
        for (name, size) in [("d", 86_400), ("h", 3_600), ("min", 60), ("s", 1)] where rest >= size {
            parts.append("\(rest / size) \(name)")
            rest %= size
        }

        return parts.joined(separator: ", ")
    }

    /// 12-hour `hh:mm:ss` used by the paused summary.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "hh:mm:ss"
        return formatter.string(from: date)
    }

    /// `<dbName>-<startMs>-<nowMs>.txt` with path-hostile characters replaced.
    static func downloadFileName(databaseName: String, start: Date, end: Date) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        var name = String(databaseName.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) })
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "profiler" }
        let startMs = Int64((start.timeIntervalSince1970 * 1000).rounded(.down))
        let endMs = Int64((end.timeIntervalSince1970 * 1000).rounded(.down))
        return "\(name)-\(startMs)-\(endMs).txt"
    }

    private static func pad(_ value: Int64, _ width: Int, radix: Int = 10) -> String {
        let text = String(value, radix: radix)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}
