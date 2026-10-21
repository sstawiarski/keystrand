import Foundation
import RedisUI

struct ZSetMember: Hashable, Sendable {
    var name: Data
    /// Score text as Redis returned it (`inf`, `-inf`, `1.5`).
    var score: String

    var numericScore: Double? {
        switch score.lowercased() {
        case "inf", "+inf": return .infinity
        case "-inf": return -.infinity
        default: return Double(score)
        }
    }

    /// `inf` / `-inf` are shown raw and cannot be edited.
    var isScoreEditable: Bool { numericScore?.isFinite ?? false }
}

struct ZSetPage: Sendable {
    var total: Int
    var members: [ZSetMember]
    /// ZSCAN cursor for search pages (0 = finished).
    var nextCursor: UInt64
}

enum ZSetCommands {
    static let pageSize = 500

    static func range(key: Data, offset: Int, count: Int, order: KeySortOrder) -> [RedisArgument] {
        [order == .asc ? "ZRANGE" : "ZREVRANGE", .data(key), .int(Int64(offset)), .int(Int64(offset + count - 1)), "WITHSCORES"]
    }

    static func scan(key: Data, cursor: UInt64, pattern: String, count: Int = pageSize) -> [RedisArgument] {
        ["ZSCAN", .data(key), .uint(cursor), "MATCH", .data(KeyPattern.matchBytes(pattern)), "COUNT", .int(Int64(count))]
    }

    static func add(key: Data, members: [(member: Data, score: String)]) -> [RedisArgument] {
        var args: [RedisArgument] = ["ZADD", .data(key)]
        for item in members {
            args.append(.string(item.score))
            args.append(.data(item.member))
        }

        return args
    }

    static func updateScore(key: Data, member: Data, score: String) -> [RedisArgument] {
        ["ZADD", .data(key), "XX", "CH", .string(score), .data(member)]
    }

    /// `[m, s, m, s]` (RESP2) or `[[m, s], …]` (RESP3).
    static func parseScored(_ reply: RESPValue) -> [ZSetMember] {
        let items = Reply.items(reply)
        if let first = items.first, first.arrayValue != nil {
            return items.compactMap { pair in
                let parts = Reply.items(pair)
                guard parts.count >= 2, let name = parts[0].dataValue else { return nil }
                return ZSetMember(name: name, score: scoreText(parts[1]))
            }
        }

        var members: [ZSetMember] = []
        members.reserveCapacity(items.count / 2)
        var index = 0
        while index + 1 < items.count {
            if let name = items[index].dataValue {
                members.append(ZSetMember(name: name, score: scoreText(items[index + 1])))
            }

            index += 2
        }

        return members
    }

    static func scoreText(_ value: RESPValue) -> String {
        if case .double(let d) = value {
            if d == .infinity { return "inf" }
            if d == -.infinity { return "-inf" }
            return RedisArgument.format(d)
        }

        return value.stringValue ?? ""
    }

    /// Keeps `[-0-9.]`, one `.`, a leading `-`, and at most 15 fractional digits.
    static func sanitizeScore(_ input: String) -> String {
        var out = ""
        var seenDot = false
        var fraction = 0
        for ch in input.prefix(200) {
            switch ch {
            case "-":
                if out.isEmpty { out.append(ch) }
            case ".":
                if !seenDot {
                    seenDot = true
                    out.append(ch)
                }
            case "0"..."9":
                if seenDot {
                    guard fraction < 15 else { continue }
                    fraction += 1
                }

                out.append(ch)
            default:
                continue
            }
        }

        return out
    }

    /// Removes a trailing decimal point and keeps decimal or exponent forms verbatim.
    /// Rewrites other finite forms, such as hex floats, as decimals; returns empty text for invalid or non-finite input.
    static func normalizeScore(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("."), text.count > 1 { text.removeLast() }
        guard !text.isEmpty, let value = Double(text), value.isFinite else { return "" }
        if text.allSatisfy({ "0123456789+-.eE".contains($0) }) { return text }
        return RedisArgument.format(value)
    }

    static func scoreError(_ input: String) -> String? {
        normalizeScore(input).isEmpty ? "Enter a number" : nil
    }

    static func isValidScore(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Double(text) else { return false }
        return value.isFinite
    }
}

@MainActor
struct ZSetService {
    let session: DatabaseSession
    let key: Data

    func load(offset: Int, count: Int, order: KeySortOrder) async throws -> ZSetPage {
        let replies = try await session.pipeline([
            ["ZCARD", .data(key)],
            ZSetCommands.range(key: key, offset: offset, count: count, order: order),
        ])
        guard replies.count == 2 else { throw KeyValueError.invalid("Unexpected reply") }
        let total = Reply.int(try Reply.checked(replies[0]))
        if total == 0 { throw KeyOperationError.keyNotFound }
        let members = ZSetCommands.parseScored(try Reply.checked(replies[1]))
        return ZSetPage(total: total, members: members, nextCursor: 0)
    }

    /// Exact `ZSCORE` lookup when the pattern has no glob, else a `ZSCAN` loop until ≥ 500 matches or the end.
    func search(pattern: String, cursor: UInt64) async throws -> ZSetPage {
        let total = Reply.int(try await session.execute(["ZCARD", .data(key)]))
        if total == 0 { throw KeyOperationError.keyNotFound }
        if !KeyPattern.isGlob(pattern) {
            let member = KeyPattern.literalBytes(pattern)
            let reply = try await session.execute(["ZSCORE", .data(key), .data(member)])
            guard !reply.isNull, reply.dataValue != nil || reply.doubleValue != nil else {
                return ZSetPage(total: total, members: [], nextCursor: 0)
            }
            return ZSetPage(total: total, members: [ZSetMember(name: member, score: ZSetCommands.scoreText(reply))],
                            nextCursor: 0)
        }

        var next = cursor
        var members: [ZSetMember] = []
        repeat {
            try Task.checkCancellation()
            let reply = try await session.execute(ZSetCommands.scan(key: key, cursor: next, pattern: pattern))
            let parts = Reply.items(reply)
            guard parts.count == 2 else { break }
            next = parts[0].uint64Value ?? UInt64(parts[0].stringValue ?? "0") ?? 0
            members += ZSetCommands.parseScored(parts[1])
        } while next != 0 && members.count < ZSetCommands.pageSize

        return ZSetPage(total: total, members: members, nextCursor: next)
    }

    func add(_ members: [(member: Data, score: String)]) async throws {
        _ = try await session.execute(ZSetCommands.add(key: key, members: members))
    }

    /// `ZADD XX CH`; a 0 reply with an existing member means the score did not change.
    func updateScore(member: Data, score: String) async throws {
        let changed = Reply.int(try await session.execute(ZSetCommands.updateScore(key: key, member: member, score: score)))
        if changed == 0 {
            let exists = try await session.execute(["ZSCORE", .data(key), .data(member)])
            if exists.isNull || (exists.dataValue == nil && exists.doubleValue == nil) { throw KeyValueError.memberNotFound }
        }
    }

    func remove(_ members: [Data]) async throws -> Int {
        let replies = try await session.pipeline([
            [.string("ZREM"), .data(key)] + members.map { .data($0) },
            ["ZCARD", .data(key)],
        ])
        guard replies.count == 2 else { return 0 }
        try Reply.checked(replies[0])
        return Reply.int(try Reply.checked(replies[1]))
    }
}
