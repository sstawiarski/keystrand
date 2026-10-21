import Foundation
import RedisUI

/// One array slot; `value` is nil for an empty index (only shown when "Show empty indexes" is on).
struct ArrayElement: Identifiable, Hashable, Sendable {
    /// Unsigned 64-bit decimal index.
    var index: String
    var value: Data?
    var id: String { index }
}

enum ArrayGrepCriteria: String, CaseIterable, Identifiable, Sendable {
    case exact = "EXACT", match = "MATCH", glob = "GLOB", re = "RE"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .exact: return "Exact"
        case .match: return "Match"
        case .glob: return "Glob"
        case .re: return "Regex"
        }
    }
}

enum ArrayAggregateOp: String, CaseIterable, Identifiable, Sendable {
    case sum = "SUM", min = "MIN", max = "MAX", and = "AND", or = "OR", xor = "XOR", match = "MATCH", used = "USED"
    var id: String { rawValue }
}

struct ArrayGrepPredicate: Identifiable, Hashable, Sendable {
    var id = UUID()
    var criteria: ArrayGrepCriteria = .match
    var pattern = ""
}

struct ArrayGrepRequest: Hashable, Sendable {
    var start: String?
    var end: String?
    var predicates: [ArrayGrepPredicate]
    var combineWithAnd = false
    var noCase = false
    var withValues = true
    var limit: Int?
}

/// Unsigned 64-bit index helpers (indexes never go through Double).
enum ArrayIndex {
    static let maxIndex: UInt64 = 18_446_744_073_709_551_614
    static let maxSpan: UInt64 = 1_000_000
    static let indexError = "Enter a whole-number index that fits in 64 bits"
    static let addIndexError = "Use a whole-number index from 0 to 18446744073709551614"

    /// Canonical decimal (`007` is rejected), at most 20 digits, ≤ 2^64 − 2.
    static func parse(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 20, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(trimmed), value <= maxIndex, String(value) == trimmed else { return nil }
        return value
    }

    static func span(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let distance = a > b ? a - b : b - a
        return distance == UInt64.max ? UInt64.max : distance + 1
    }

    /// Index `offset` steps from `start` towards `end` (ranges may be reversed).
    static func index(from start: UInt64, toward end: UInt64, offset: Int) -> UInt64 {
        start <= end ? start + UInt64(offset) : start - UInt64(offset)
    }

    /// Window of 10 ending at `index`: `[max(0, i − 9), i]`.
    static func revealWindow(for index: UInt64) -> (start: UInt64, end: UInt64) {
        (index >= 9 ? index - 9 : 0, index)
    }

    /// Reads an exact unsigned/signed integer reply as decimal text.
    static func text(_ value: RESPValue) -> String? {
        switch value {
        case .integer(let i): return String(i)
        case .bigNumber(let s): return s
        default:
            guard !value.isNull else { return nil }
            return value.stringValue
        }
    }
}

/// Pure builders and parsers for Redis 8.8+ array commands.
enum ArrayCommands {
    static let scanLimit = 1_000_000

    static func range(key: Data, start: UInt64, end: UInt64) -> [RedisArgument] {
        ["ARGETRANGE", .data(key), .uint(start), .uint(end)]
    }

    static func scan(key: Data, start: UInt64, end: UInt64, limit: Int = scanLimit) -> [RedisArgument] {
        ["ARSCAN", .data(key), .uint(start), .uint(end), "LIMIT", .int(Int64(limit))]
    }

    static func grep(key: Data, request: ArrayGrepRequest) -> [RedisArgument] {
        var args: [RedisArgument] = ["ARGREP", .data(key)]
        let start = request.start?.trimmingCharacters(in: .whitespaces) ?? ""
        let end = request.end?.trimmingCharacters(in: .whitespaces) ?? ""
        args.append(.string(start.isEmpty ? "-" : start))
        args.append(.string(end.isEmpty ? "+" : end))
        for predicate in request.predicates {
            args.append(.string(predicate.criteria.rawValue))
            args.append(.string(predicate.pattern))
        }

        if request.predicates.count >= 2 { args.append(request.combineWithAnd ? "AND" : "OR") }
        if request.noCase { args.append("NOCASE") }
        if request.withValues { args.append("WITHVALUES") }
        if let limit = request.limit { args += ["LIMIT", .int(Int64(limit))] }
        return args
    }

    static func aggregate(key: Data, start: UInt64, end: UInt64, op: ArrayAggregateOp, value: String?) -> [RedisArgument] {
        var args: [RedisArgument] = ["AROP", .data(key), .uint(start), .uint(end), .string(op.rawValue)]
        if op == .match { args.append(.string(value ?? "")) }
        return args
    }

    /// `ARGETRANGE` → one reply per index (nil = empty), in the order of the requested range.
    static func parseRange(_ reply: RESPValue, start: UInt64, end: UInt64) -> [ArrayElement] {
        Reply.items(reply).enumerated().map { offset, item in
            ArrayElement(index: String(ArrayIndex.index(from: start, toward: end, offset: offset)),
                         value: item.isNull ? nil : item.dataValue)
        }
    }

    /// `ARSCAN` / `ARGREP … WITHVALUES`: nested `[[idx, val]…]` or flat `[idx, val, …]`; nil values dropped.
    static func parsePairs(_ reply: RESPValue) -> [ArrayElement] {
        let items = Reply.items(reply)
        if let first = items.first, first.arrayValue != nil {
            return items.compactMap { pair in
                let parts = Reply.items(pair)
                guard parts.count >= 2, let index = ArrayIndex.text(parts[0]), !parts[1].isNull else { return nil }
                return ArrayElement(index: index, value: parts[1].dataValue)
            }
        }

        var out: [ArrayElement] = []
        var position = 0
        while position + 1 < items.count {
            if let index = ArrayIndex.text(items[position]), !items[position + 1].isNull {
                out.append(ArrayElement(index: index, value: items[position + 1].dataValue))
            }

            position += 2
        }

        return out
    }

    /// `ARGREP` reply: pairs when values were requested, otherwise a flat list of indexes.
    static func parseGrep(_ reply: RESPValue, withValues: Bool) -> [ArrayElement] {
        if withValues { return parsePairs(reply) }
        let items = Reply.items(reply)
        if let first = items.first, first.arrayValue != nil { return parsePairs(reply) }
        return items.compactMap { ArrayIndex.text($0).map { ArrayElement(index: $0, value: nil) } }
    }

    static func preview(_ args: [RedisArgument]) -> String {
        VectorSetCommands.preview(args)
    }
}

enum ArrayError: Error, LocalizedError, Equatable {
    case rangeTooLarge
    case aggregateRangeTooLarge
    case arrayFull

    var errorDescription: String? {
        switch self {
        case .rangeTooLarge: return "Request no more than 1,000,000 indexes in a single range"
        case .aggregateRangeTooLarge: return "Aggregate no more than 1,000,000 indexes in a single range"
        case .arrayFull: return "Nothing can be appended: the array already uses its last possible index (2^64-2)."
        }
    }
}

/// Array (Redis 8.8+) reads and writes for one key.
@MainActor
struct ArrayService {
    let session: DatabaseSession
    let key: Data

    func counts() async throws -> (length: String, count: String) {
        let replies = try await session.pipeline([["ARLEN", .data(key)], ["ARCOUNT", .data(key)]])
        guard replies.count == 2 else { throw KeyValueError.invalid("Unexpected reply") }
        return (ArrayIndex.text(try Reply.checked(replies[0])) ?? "0", ArrayIndex.text(try Reply.checked(replies[1])) ?? "0")
    }

    func range(start: UInt64, end: UInt64, showEmpty: Bool) async throws -> [ArrayElement] {
        if showEmpty {
            guard ArrayIndex.span(start, end) <= ArrayIndex.maxSpan else { throw ArrayError.rangeTooLarge }
            return ArrayCommands.parseRange(try await session.execute(ArrayCommands.range(key: key, start: start, end: end)),
                                            start: start, end: end)
        }

        return ArrayCommands.parsePairs(try await session.execute(ArrayCommands.scan(key: key, start: start, end: end)))
    }

    func grep(_ request: ArrayGrepRequest) async throws -> [ArrayElement] {
        ArrayCommands.parseGrep(try await session.execute(ArrayCommands.grep(key: key, request: request)),
                                withValues: request.withValues)
    }

    /// Exact integer result as text; nil reply → nil.
    func aggregate(start: UInt64, end: UInt64, op: ArrayAggregateOp, value: String?) async throws -> String? {
        guard ArrayIndex.span(start, end) <= ArrayIndex.maxSpan else { throw ArrayError.aggregateRangeTooLarge }
        if op == .match, value == nil { throw KeyValueError.invalid("value is required for MATCH operation.") }
        let reply = try await session.execute(ArrayCommands.aggregate(key: key, start: start, end: end, op: op, value: value))
        return reply.isNull ? nil : (ArrayIndex.text(reply) ?? Reply.text(reply))
    }

    func set(index: String, value: Data) async throws {
        _ = try await session.execute(["ARSET", .data(key), .string(index), .data(value)])
    }

    /// Appends at `ARLEN`; returns the index used.
    func append(_ value: Data) async throws -> String {
        let length = ArrayIndex.text(try await session.execute(["ARLEN", .data(key)])) ?? "0"
        guard let index = UInt64(length), index <= ArrayIndex.maxIndex else { throw ArrayError.arrayFull }
        try await set(index: String(index), value: value)
        return String(index)
    }

    func delete(indexes: [String]) async throws -> Int {
        guard !indexes.isEmpty else { return 0 }
        return Reply.int(try await session.execute([.string("ARDEL"), .data(key)] + indexes.map { .string($0) }))
    }

    func deleteRange(start: UInt64, end: UInt64) async throws -> Int {
        Reply.int(try await session.execute(["ARDELRANGE", .data(key), .uint(start), .uint(end)]))
    }

    func exists() async throws -> Bool {
        Reply.int(try await session.execute(["EXISTS", .data(key)])) > 0
    }
}
