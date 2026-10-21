import Foundation
import RESP

public enum PubSubMessageKind: String, Sendable, Hashable {
    case message
    case pmessage
    case smessage
    case subscribe
    case psubscribe
    case unsubscribe
    case punsubscribe
}

public struct PubSubMessage: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: PubSubMessageKind
    public var channel: Data
    public var message: Data
    /// Matching pattern for `pmessage`.
    public var pattern: Data?
    /// Subscription count for subscribe/unsubscribe confirmations.
    public var subscriptionCount: Int?
    public var receivedAt: Date

    public init(id: UUID = UUID(), kind: PubSubMessageKind, channel: Data, message: Data = Data(),
                pattern: Data? = nil, subscriptionCount: Int? = nil, receivedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.channel = channel
        self.message = message
        self.pattern = pattern
        self.subscriptionCount = subscriptionCount
        self.receivedAt = receivedAt
    }
}

/// One `MONITOR` output line: `1339518083.107412 [0 127.0.0.1:60866] "keys" "*"`.
public struct MonitorLine: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// `seconds.micros` exactly as printed (any leading `[` removed).
    public var time: String
    public var database: Int
    /// `127.0.0.1:60866`, `lua`, `unix:/tmp/redis.sock`.
    public var source: String
    public var args: [Data]
    public var raw: String

    public init(id: UUID = UUID(), time: String, database: Int, source: String, args: [Data], raw: String) {
        self.id = id
        self.time = time
        self.database = database
        self.source = source
        self.args = args
        self.raw = raw
    }
}

public enum MonitorLineParseError: Error, LocalizedError, Sendable, Equatable {
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let line): return "Unrecognized MONITOR line: \(line)"
        }
    }
}

/// Pure parser for MONITOR lines (quoted args with C escapes, lua/unix sources, `[` stripped from time).
public enum MonitorLineParser {
    public static func parse(_ line: String) throws -> MonitorLine {
        let bytes = Array(line.utf8)
        guard let open = firstIndex(of: UInt8(ascii: "["), in: bytes, from: 0, requiringSpaceBefore: true),
              let close = closingBracket(in: bytes, after: open) else {
            throw MonitorLineParseError.malformed(line)
        }
        var timeBytes = bytes[0..<open]
        while timeBytes.last == 0x20 { timeBytes = timeBytes.dropLast() }
        if let bracket = timeBytes.firstIndex(of: UInt8(ascii: "[")) { timeBytes = timeBytes[..<bracket] }
        let time = String(decoding: timeBytes, as: UTF8.self)

        let inside = String(decoding: bytes[(open + 1)..<close], as: UTF8.self)
        let parts = inside.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let dbText = parts.first, let database = Int(dbText) else { throw MonitorLineParseError.malformed(line) }
        let source = parts.count > 1 ? String(parts[1]) : ""

        let args = try parseQuotedArgs(Array(bytes[(close + 1)...]), line: line)
        return MonitorLine(time: time, database: database, source: source, args: args, raw: line)
    }

    /// Finds the `[db source]` opener after a space because some providers include a stray `[` in the time.
    private static func firstIndex(of byte: UInt8, in bytes: [UInt8], from: Int, requiringSpaceBefore: Bool) -> Int? {
        var i = from
        while i < bytes.count {
            if bytes[i] == byte, !requiringSpaceBefore || (i > 0 && bytes[i - 1] == 0x20) { return i }
            i += 1
        }

        return nil
    }

    /// Finds the source block’s closing `]` before ` "` or the line end. IPv6 sources can contain `]`.
    private static func closingBracket(in bytes: [UInt8], after open: Int) -> Int? {
        var i = open + 1
        var fallback: Int?
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "]") {
                if fallback == nil { fallback = i }
                if i + 1 == bytes.count || (bytes[i + 1] == 0x20 && i + 2 < bytes.count && bytes[i + 2] == UInt8(ascii: "\"")) {
                    return i
                }
            }

            i += 1
        }

        return fallback
    }

    /// Parses `"a" "b\"c" "\x00"` into raw byte arguments.
    static func parseQuotedArgs(_ bytes: [UInt8], line: String) throws -> [Data] {
        var args: [Data] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x20 { i += 1; continue }
            guard bytes[i] == UInt8(ascii: "\"") else { throw MonitorLineParseError.malformed(line) }
            i += 1
            var current: [UInt8] = []
            var closed = false
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\\"), i + 1 < bytes.count {
                    let e = bytes[i + 1]
                    switch e {
                    case UInt8(ascii: "n"): current.append(0x0A); i += 2
                    case UInt8(ascii: "r"): current.append(0x0D); i += 2
                    case UInt8(ascii: "t"): current.append(0x09); i += 2
                    case UInt8(ascii: "a"): current.append(0x07); i += 2
                    case UInt8(ascii: "b"): current.append(0x08); i += 2
                    case UInt8(ascii: "x") where i + 3 < bytes.count:
                        if let value = UInt8(String(decoding: bytes[(i + 2)...(i + 3)], as: UTF8.self), radix: 16) {
                            current.append(value)
                            i += 4
                        } else {
                            current.append(e)
                            i += 2
                        }
                    default: current.append(e); i += 2
                    }
                } else if b == UInt8(ascii: "\"") {
                    closed = true
                    i += 1
                    break
                } else {
                    current.append(b)
                    i += 1
                }
            }

            guard closed else { throw MonitorLineParseError.malformed(line) }
            args.append(Data(current))
        }

        return args
    }
}

/// Decodes Pub/Sub frames (RESP2 arrays and RESP3 pushes).
public enum PubSubFrameParser {
    public static func parse(_ value: RESPValue, receivedAt: Date = Date()) -> PubSubMessage? {
        let items: [RESPValue]
        switch value {
        case .push(let a): items = a
        case .array(let a?): items = a
        default: return nil
        }

        guard let kindText = items.first?.stringValue?.lowercased() else { return nil }
        func data(_ index: Int) -> Data? { index < items.count ? items[index].dataValue : nil }
        switch kindText {
        case "message", "smessage":
            guard items.count >= 3, let channel = data(1) else { return nil }
            return PubSubMessage(kind: kindText == "message" ? .message : .smessage, channel: channel,
                                 message: data(2) ?? Data(), receivedAt: receivedAt)
        case "pmessage":
            guard items.count >= 4, let channel = data(2) else { return nil }
            return PubSubMessage(kind: .pmessage, channel: channel, message: data(3) ?? Data(), pattern: data(1),
                                 receivedAt: receivedAt)
        case "subscribe", "ssubscribe", "psubscribe", "unsubscribe", "sunsubscribe", "punsubscribe":
            let kind: PubSubMessageKind
            switch kindText {
            case "psubscribe": kind = .psubscribe
            case "unsubscribe", "sunsubscribe": kind = .unsubscribe
            case "punsubscribe": kind = .punsubscribe
            default: kind = .subscribe
            }

            let count = items.count >= 3 ? items[2].intValue.map(Int.init) : nil
            let name = data(1) ?? Data()
            return PubSubMessage(kind: kind, channel: name, pattern: kind == .psubscribe || kind == .punsubscribe ? name : nil,
                                 subscriptionCount: count, receivedAt: receivedAt)
        default:
            return nil
        }
    }

    /// True for confirmation frames (subscribe/unsubscribe family), false for delivered messages.
    public static func isConfirmation(_ kind: PubSubMessageKind) -> Bool {
        switch kind {
        case .message, .pmessage, .smessage: return false
        default: return true
        }
    }
}
