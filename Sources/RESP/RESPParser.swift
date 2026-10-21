import Foundation

public enum RESPParserError: Error, LocalizedError, Sendable, Equatable {
    case invalidTypeByte(UInt8)
    case invalidLength(String)
    case invalidInteger(String)
    case invalidDouble(String)
    case invalidBoolean(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTypeByte(let b): return "Protocol error: unexpected type byte 0x\(String(b, radix: 16))"
        case .invalidLength(let s): return "Protocol error: invalid length \(s)"
        case .invalidInteger(let s): return "Protocol error: invalid integer \(s)"
        case .invalidDouble(let s): return "Protocol error: invalid double \(s)"
        case .invalidBoolean(let s): return "Protocol error: invalid boolean \(s)"
        case .malformed(let s): return "Protocol error: \(s)"
        }
    }
}

/// Incremental RESP2/RESP3 parser. Feed bytes as they arrive, then pop complete values.
///
///     var parser = RESPParser()
///     parser.feed(chunk)
///     while let value = try parser.next() { ... }
///
/// Partially received aggregates are kept on an internal stack, so a huge array that arrives in many
/// chunks is parsed in linear time. Attributes (`|`) are consumed and dropped. After a thrown error the
/// stream is unrecoverable; call `reset()` (or discard the connection).
public struct RESPParser: Sendable {
    public static let defaultMaxBulkLength = 512 * 1024 * 1024
    public static let defaultMaxDepth = 512

    private enum AggregateKind: Sendable {
        case array, set, push, map, attribute
    }

    private struct Frame: Sendable {
        var kind: AggregateKind
        var remaining: Int
        var items: [RESPValue]
    }

    private var buffer: [UInt8] = []
    private var offset = 0
    private var stack: [Frame] = []

    /// Parses lines without a RESP type byte as inline commands (`PING`, `SET a "b c"`) and returns arrays of bulk strings.
    public var allowInline: Bool
    public var maxBulkLength: Int
    public var maxDepth: Int

    public init(allowInline: Bool = false, maxBulkLength: Int = RESPParser.defaultMaxBulkLength,
                maxDepth: Int = RESPParser.defaultMaxDepth) {
        self.allowInline = allowInline
        self.maxBulkLength = maxBulkLength
        self.maxDepth = maxDepth
    }

    /// Number of bytes received but not yet consumed by `next()`.
    public var bufferedByteCount: Int { buffer.count - offset }

    /// True while an aggregate has been started but not finished.
    public var isInsideAggregate: Bool { !stack.isEmpty }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        offset = 0
        stack.removeAll()
    }

    public mutating func feed(_ data: Data) {
        compact()
        buffer.append(contentsOf: data)
    }

    public mutating func feed(_ bytes: [UInt8]) {
        compact()
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete value, or `nil` when more bytes are needed.
    public mutating func next() throws -> RESPValue? {
        while true {
            guard let token = try readToken() else { return nil }
            var completed: RESPValue?
            switch token {
            case .value(let v):
                completed = v
            case .begin(let kind, let count):
                if count == 0 {
                    completed = Self.build(kind: kind, items: [])
                    if kind == .attribute { completed = nil }
                } else {
                    guard stack.count < maxDepth else { throw RESPParserError.malformed("nesting too deep") }
                    stack.append(Frame(kind: kind, remaining: count, items: []))
                    stack[stack.count - 1].items.reserveCapacity(min(count, 1 << 16))
                    continue
                }
            }

            // Bubble the completed value up through finished frames.
            while let value = completed {
                guard !stack.isEmpty else { return value }
                let top = stack.count - 1
                stack[top].items.append(value)
                stack[top].remaining -= 1
                if stack[top].remaining > 0 { completed = nil; break }
                let frame = stack.removeLast()
                completed = frame.kind == .attribute ? nil : Self.build(kind: frame.kind, items: frame.items)
            }
        }
    }

    /// Parses every complete value currently buffered.
    public mutating func drain() throws -> [RESPValue] {
        var out: [RESPValue] = []
        while let value = try next() { out.append(value) }
        return out
    }

    /// Parses all replies from a complete buffer.
    public static func parseAll(_ data: Data) throws -> [RESPValue] {
        var parser = RESPParser()
        parser.feed(data)
        let values = try parser.drain()
        guard parser.bufferedByteCount == 0, !parser.isInsideAggregate else {
            throw RESPParserError.malformed("incomplete frame")
        }
        return values
    }

    // MARK: - Internals

    private enum Token {
        case value(RESPValue)
        case begin(AggregateKind, Int)
    }

    private mutating func compact() {
        if offset == 0 { return }
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.capacity <= 4 * 1024 * 1024)
            offset = 0
        } else if offset > 65_536 && offset * 2 > buffer.count {
            buffer.removeFirst(offset)
            offset = 0
        }
    }

    private static func build(kind: AggregateKind, items: [RESPValue]) -> RESPValue {
        switch kind {
        case .array: return .array(items)
        case .set: return .set(items)
        case .push: return .push(items)
        case .attribute: return .null
        case .map:
            var pairs: [(RESPValue, RESPValue)] = []
            pairs.reserveCapacity(items.count / 2)
            var i = 0
            while i + 1 < items.count {
                pairs.append((items[i], items[i + 1]))
                i += 2
            }

            return .map(pairs)
        }
    }

    /// Index of the `\r` of the next CRLF at or after `start`, or nil when not yet received.
    private func lineEnd(from start: Int) -> Int? {
        let count = buffer.count
        guard start < count else { return nil }
        return buffer.withUnsafeBufferPointer { ptr -> Int? in
            guard let base = ptr.baseAddress else { return nil }
            var i = start
            while i < count {
                guard let found = memchr(base + i, 0x0D, count - i) else { return nil }
                let index = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
                if index + 1 >= count { return nil }
                if base[index + 1] == 0x0A { return index }
                i = index + 1
            }

            return nil
        }
    }

    private func text(_ range: Range<Int>) -> String {
        String(decoding: buffer[range], as: UTF8.self)
    }

    private func integer(_ range: Range<Int>) -> Int64? {
        guard !range.isEmpty, range.count <= 20 else { return nil }
        var i = range.lowerBound
        var negative = false
        if buffer[i] == UInt8(ascii: "-") { negative = true; i += 1 } else if buffer[i] == UInt8(ascii: "+") { i += 1 }
        guard i < range.upperBound else { return nil }
        var value: Int64 = 0
        while i < range.upperBound {
            let b = buffer[i]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (s, o2) = negative ? m.subtractingReportingOverflow(Int64(b - 0x30)) : m.addingReportingOverflow(Int64(b - 0x30))
            if o1 || o2 { return nil }
            value = s
            i += 1
        }

        return value
    }

    private func length(_ range: Range<Int>) throws -> Int {
        guard let n = integer(range), n >= -1, n <= Int64(Int.max) else {
            throw RESPParserError.invalidLength(text(range))
        }
        return Int(n)
    }

    /// Reads one scalar value or aggregate header. Commits `offset` only when the token is complete.
    private mutating func readToken() throws -> Token? {
        guard offset < buffer.count else { return nil }
        let type = buffer[offset]
        let lineStart = offset + 1
        guard let end = lineEnd(from: lineStart) else {
            if buffer.count - offset > 64 * 1024 && (type == UInt8(ascii: "$") || type == UInt8(ascii: "*")) {
                throw RESPParserError.malformed("header line too long")
            }

            return nil
        }
        let line = lineStart..<end
        var next = end + 2
        let token: Token

        switch type {
        case UInt8(ascii: "+"):
            token = .value(.simpleString(text(line)))
        case UInt8(ascii: "-"):
            token = .value(.error(RESPError(text(line))))
        case UInt8(ascii: ":"):
            guard let i = integer(line) else { throw RESPParserError.invalidInteger(text(line)) }
            token = .value(.integer(i))
        case UInt8(ascii: "$"), UInt8(ascii: "!"), UInt8(ascii: "="):
            let n = try length(line)
            if n == -1 {
                token = .value(type == UInt8(ascii: "$") ? .bulkString(nil) : .null)
            } else {
                guard n <= maxBulkLength else { throw RESPParserError.invalidLength(String(n)) }
                guard next + n + 2 <= buffer.count else {
                    let needed = next + n + 2
                    if buffer.capacity < needed { buffer.reserveCapacity(needed) }
                    return nil
                }
                guard buffer[next + n] == 0x0D, buffer[next + n + 1] == 0x0A else {
                    throw RESPParserError.malformed("bulk string not terminated by CRLF")
                }
                let blob = Data(buffer[next..<(next + n)])
                next += n + 2
                switch type {
                case UInt8(ascii: "$"):
                    token = .value(.bulkString(blob))
                case UInt8(ascii: "!"):
                    token = .value(.error(RESPError(String(decoding: blob, as: UTF8.self))))
                default:
                    if blob.count >= 4, blob[blob.startIndex + 3] == UInt8(ascii: ":") {
                        let format = String(decoding: blob.prefix(3), as: UTF8.self)
                        token = .value(.verbatimString(format: format, text: Data(blob.dropFirst(4))))
                    } else {
                        token = .value(.verbatimString(format: "txt", text: blob))
                    }
                }
            }
        case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: ">"), UInt8(ascii: "%"), UInt8(ascii: "|"):
            let n = try length(line)
            let kind: AggregateKind
            switch type {
            case UInt8(ascii: "*"): kind = .array
            case UInt8(ascii: "~"): kind = .set
            case UInt8(ascii: ">"): kind = .push
            case UInt8(ascii: "%"): kind = .map
            default: kind = .attribute
            }

            if n == -1 {
                token = .value(kind == .array ? .array(nil) : .null)
            } else {
                let (count, overflow) = n.multipliedReportingOverflow(by: (kind == .map || kind == .attribute) ? 2 : 1)
                guard !overflow else { throw RESPParserError.invalidLength(String(n)) }
                token = .begin(kind, count)
            }
        case UInt8(ascii: "_"):
            token = .value(.null)
        case UInt8(ascii: ","):
            let s = text(line)
            switch s.lowercased() {
            case "inf", "+inf": token = .value(.double(.infinity))
            case "-inf": token = .value(.double(-.infinity))
            case "nan", "-nan", "+nan": token = .value(.double(.nan))
            default:
                guard let d = Double(s) else { throw RESPParserError.invalidDouble(s) }
                token = .value(.double(d))
            }
        case UInt8(ascii: "#"):
            switch text(line) {
            case "t": token = .value(.boolean(true))
            case "f": token = .value(.boolean(false))
            case let other: throw RESPParserError.invalidBoolean(other)
            }
        case UInt8(ascii: "("):
            token = .value(.bigNumber(text(line)))
        default:
            guard allowInline, stack.isEmpty else { throw RESPParserError.invalidTypeByte(type) }
            let args = RESPParser.splitInline(Array(buffer[offset..<end]))
            offset = end + 2
            return .value(.array(args.map { .bulkString($0) }))
        }

        offset = next
        return token
    }

    /// Minimal inline-command splitter (whitespace separated, double/single quotes, `\` escapes in double quotes).
    static func splitInline(_ bytes: [UInt8]) -> [Data] {
        var args: [Data] = []
        var current: [UInt8] = []
        var inArg = false
        var quote: UInt8?
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if let q = quote {
                if b == q {
                    quote = nil
                } else if q == UInt8(ascii: "\"") && b == UInt8(ascii: "\\") && i + 1 < bytes.count {
                    i += 1
                    switch bytes[i] {
                    case UInt8(ascii: "n"): current.append(0x0A)
                    case UInt8(ascii: "r"): current.append(0x0D)
                    case UInt8(ascii: "t"): current.append(0x09)
                    default: current.append(bytes[i])
                    }
                } else {
                    current.append(b)
                }
            } else if b == 0x20 || b == 0x09 {
                if inArg { args.append(Data(current)); current.removeAll(); inArg = false }
            } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                quote = b
                inArg = true
            } else {
                current.append(b)
                inArg = true
            }

            i += 1
        }

        if inArg { args.append(Data(current)) }
        return args
    }
}
