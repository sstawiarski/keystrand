import Foundation
import RedisCore

public enum KeyValueError: Error, LocalizedError, Equatable, Sendable {
    case indexOutOfRange
    case memberNotFound
    case popCountUnsupported
    case elementChanged
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .indexOutOfRange: return "Index is out of range."
        case .elementChanged: return "The element has changed, refresh and try again."
        case .memberNotFound: return "This member no longer exists."
        case .popCountUnsupported: return "Removing several elements at once needs Redis 6.2 or newer."
        case .invalid(let message): return message
        }
    }
}

/// Reply parsing shared by the collection services.
public enum KeyValueParsing {
    /// `[cursor, [item, ...]]` from HSCAN / SSCAN.
    public static func scanReply(_ reply: RESPValue) -> (cursor: UInt64, items: [Data])? {
        guard let parts = reply.arrayValue, parts.count == 2, let cursor = parts[0].uint64Value else { return nil }
        let items = (parts[1].arrayValue ?? []).compactMap(\.dataValue)
        return (cursor, items)
    }

    /// Flat `[f1, v1, f2, v2]` -> pairs (a trailing odd item is dropped).
    public static func pairs(_ items: [Data]) -> [(Data, Data)] {
        stride(from: 0, to: items.count - items.count % 2, by: 2).map { (items[$0], items[$0 + 1]) }
    }

    /// `HTTL` reply -> one value per field (`-1` no TTL, `-2` field missing); nil entries for unknown.
    public static func fieldTTLs(_ reply: RESPValue, count: Int) -> [Int?] {
        guard let items = reply.arrayValue else { return Array(repeating: nil, count: count) }
        var out = items.map { $0.intValue.map(Int.init) }
        if out.count < count { out += Array(repeating: nil, count: count - out.count) }
        return Array(out.prefix(count))
    }

    /// LPOP/RPOP reply (single bulk or array with COUNT) -> popped values.
    public static func poppedValues(_ reply: RESPValue) -> [Data] {
        if reply.isNull { return [] }
        if let items = reply.arrayValue { return items.compactMap(\.dataValue) }
        return reply.dataValue.map { [$0] } ?? []
    }

    /// Exact (non-glob) search text -> bytes to look up; nil when the text is a glob pattern.
    public static func exactMatch(_ pattern: String) -> Data? {
        guard !pattern.isEmpty, !KeyPattern.isGlob(pattern) else { return nil }
        return KeyPattern.literalBytes(pattern)
    }

    /// Parses a list index from digits only.
    public static func listIndex(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(trimmed)
    }

    static func throwIfError(_ reply: RESPValue) throws {
        if let error = reply.errorValue { throw RedisClientError.server(error) }
    }
}

// MARK: - String

public struct StringValueSnapshot: Hashable, Sendable {
    public var value: Data
    /// STRLEN of the whole value.
    public var length: Int

    public var isFull: Bool { value.count >= length }
}

@MainActor
public struct StringService {
    public let session: DatabaseSession
    /// Loads the first 5,000 bytes initially.
    public nonisolated static let initialLoadBytes = 5_000

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// `GETRANGE k 0 <end>`; `end == nil` loads the first 5,000 bytes, `-1` the whole value.
    public func load(_ key: Data, end: Int? = nil) async throws -> StringValueSnapshot {
        let k = RedisArgument.data(key)
        let last = end ?? (Self.initialLoadBytes - 1)
        let replies = try await session.pipeline([["EXISTS", k], ["STRLEN", k], ["GETRANGE", k, "0", .int(Int64(last))]])
        guard replies.count == 3 else { throw KeyValueError.invalid("Unexpected reply") }
        try replies.forEach(KeyValueParsing.throwIfError)
        guard (replies[0].intValue ?? 0) > 0 else { throw KeyOperationError.keyNotFound }
        return StringValueSnapshot(value: replies[2].dataValue ?? Data(), length: Int(replies[1].intValue ?? 0))
    }

    /// `GET k` for downloads.
    public func fullValue(_ key: Data) async throws -> Data {
        let reply = try await session.execute(["GET", .data(key)])
        guard let data = reply.dataValue else { throw KeyOperationError.keyNotFound }
        return data
    }

    /// `SET k v XX KEEPTTL` (Redis < 6: `SET k v XX` then `EXPIRE` with the previous TTL).
    public func update(_ key: Data, value: Data) async throws {
        let k = RedisArgument.data(key)
        let caps = session.capabilities
        if caps.redisVersion == nil || caps.isVersion(atLeast: "6.0.0") {
            let reply = try await session.execute(["SET", k, .data(value), "XX", "KEEPTTL"])
            if reply.isNull { throw KeyOperationError.keyNotFound }
            return
        }

        let ttl = Int(try await session.execute(["TTL", k]).intValue ?? -1)
        if ttl == -2 { throw KeyOperationError.keyNotFound }
        let reply = try await session.execute(["SET", k, .data(value), "XX"])
        if reply.isNull { throw KeyOperationError.keyNotFound }
        if ttl > 0 { _ = try await session.execute(["EXPIRE", k, .int(Int64(ttl))]) }
    }
}

// MARK: - Hash

public struct HashFieldsPage: Hashable, Sendable {
    public var fields: [HashField]
    public var nextCursor: UInt64
    public var total: Int
}

@MainActor
public struct HashService {
    public let session: DatabaseSession
    public nonisolated static let pageSize = 500

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// `HLEN`, then `HGET` for an exact field or `HSCAN ... MATCH` until `pageSize` fields or the end.
    /// With `includeTTL`, `HTTL` fills `expire` (errors ignored).
    public func fields(_ key: Data, match: String = "*", cursor: UInt64 = 0, count: Int = pageSize,
                       includeTTL: Bool = false) async throws -> HashFieldsPage {
        let k = RedisArgument.data(key)
        let total = Int(try await session.execute(["HLEN", k]).intValue ?? 0)
        guard total > 0 else { throw KeyOperationError.keyNotFound }
        let pattern = match.isEmpty ? "*" : match
        var fields: [HashField] = []
        var next: UInt64 = 0
        if let exact = KeyValueParsing.exactMatch(pattern) {
            if cursor == 0, let value = try await session.execute(["HGET", k, .data(exact)]).dataValue {
                fields = [HashField(field: exact, value: value)]
            }
        } else {
            next = cursor
            repeat {
                try Task.checkCancellation()
                let reply = try await session.execute(["HSCAN", k, .uint(next), "MATCH", .data(KeyPattern.matchBytes(pattern)),
                                                       "COUNT", .int(Int64(count))])
                guard let page = KeyValueParsing.scanReply(reply) else { throw KeyValueError.invalid("Unexpected HSCAN reply") }
                next = page.cursor
                fields += KeyValueParsing.pairs(page.items).map { HashField(field: $0.0, value: $0.1) }
            } while next != 0 && fields.count < count
        }

        if includeTTL, !fields.isEmpty {
            let ttls = await fieldTTLs(key, fields: fields.map(\.field))
            for index in fields.indices { fields[index].expire = ttls[index] }
        }

        return HashFieldsPage(fields: fields, nextCursor: next, total: total)
    }

    /// `HTTL k FIELDS n f...` in chunks; any failure yields nil TTLs.
    public func fieldTTLs(_ key: Data, fields: [Data]) async -> [Int?] {
        var out: [Int?] = []
        var start = 0
        while start < fields.count {
            let chunk = Array(fields[start..<min(start + 1_000, fields.count)])
            start += 1_000
            let args: [RedisArgument] = ["HTTL", .data(key), "FIELDS", .int(Int64(chunk.count))] + chunk.map { .data($0) }
            guard let reply = try? await session.execute(args) else {
                out += Array(repeating: nil, count: chunk.count)
                continue
            }
            out += KeyValueParsing.fieldTTLs(reply, count: chunk.count)
        }

        return out
    }

    /// How a write keeps the TTL of fields that are overwritten without a new TTL (plain `HSET` clears it).
    public enum FieldTTLStrategy: Hashable, Sendable {
        /// `HSETEX k KEEPTTL FIELDS n f v ...` (Redis 8.0+, Valkey 9.0+).
        case keepTTL
        /// Read `HPEXPIRETIME`, then `HSET` and `HPEXPIREAT` the same absolute time (Redis 7.4).
        case restoreExpireTime
        /// No hash field TTLs.
        case plain

        public static func `for`(_ capabilities: DatabaseCapabilities) -> FieldTTLStrategy {
            guard capabilities.supportsHashFieldTTL else { return .plain }
            return capabilities.supportsHashFieldKeepTTL ? .keepTTL : .restoreExpireTime
        }
    }

    /// `EXISTS`, then writes the fields keeping existing field TTLs, plus `HEXPIRE` for fields with a
    /// positive `expire` when `applyExpire`.
    public func setFields(_ key: Data, _ fields: [HashField], applyExpire: Bool = true) async throws {
        try await setFields(key, fields, applyExpire: applyExpire, strategy: .for(session.capabilities))
    }

    func setFields(_ key: Data, _ fields: [HashField], applyExpire: Bool, strategy: FieldTTLStrategy) async throws {
        guard !fields.isEmpty else { return }
        let k = RedisArgument.data(key)
        guard try await KeyOperations(session: session).exists(key) else { throw KeyOperationError.keyNotFound }
        let expiring = applyExpire ? fields.filter { ($0.expire ?? 0) > 0 } : []
        let expiringNames = Set(expiring.map(\.field))
        let keeping = fields.filter { !expiringNames.contains($0.field) }

        func pairs(_ list: [HashField]) -> [RedisArgument] {
            list.flatMap { [RedisArgument.data($0.field), .data($0.value)] }
        }

        var commands: [[RedisArgument]] = []
        switch strategy {
        case .keepTTL:
            if !keeping.isEmpty {
                commands.append(["HSETEX", k, "KEEPTTL", "FIELDS", .int(Int64(keeping.count))] + pairs(keeping))
            }

            if !expiring.isEmpty { commands.append(["HSET", k] + pairs(expiring)) }
        case .restoreExpireTime:
            let times = try await fieldExpireTimes(key, fields: keeping.map(\.field))
            commands.append(["HSET", k] + pairs(fields))
            for (field, time) in zip(keeping, times) where time > 0 {
                commands.append(["HPEXPIREAT", k, .int(Int64(time)), "FIELDS", "1", .data(field.field)])
            }
        case .plain:
            commands.append(["HSET", k] + pairs(fields))
        }

        for field in expiring {
            commands.append(["HEXPIRE", k, .int(Int64(field.expire ?? 0)), "FIELDS", "1", .data(field.field)])
        }

        let replies = try await session.pipeline(commands)
        try replies.forEach(KeyValueParsing.throwIfError)
    }

    /// `HPEXPIRETIME k FIELDS n f...`: absolute expiry in ms per field (`-1` none, `-2` missing).
    func fieldExpireTimes(_ key: Data, fields: [Data]) async throws -> [Int] {
        guard !fields.isEmpty else { return [] }
        let args: [RedisArgument] = ["HPEXPIRETIME", .data(key), "FIELDS", .int(Int64(fields.count))] + fields.map { .data($0) }
        let reply = try await session.execute(args)
        return KeyValueParsing.fieldTTLs(reply, count: fields.count).map { $0 ?? -1 }
    }

    /// `HPERSIST` (ttl -1) or `HEXPIRE` (ttl >= 0; 0 removes the field).
    public func setFieldTTL(_ key: Data, field: Data, ttl: Int) async throws {
        let k = RedisArgument.data(key)
        let args: [RedisArgument] = ttl < 0
            ? ["HPERSIST", k, "FIELDS", "1", .data(field)]
            : ["HEXPIRE", k, .int(Int64(ttl)), "FIELDS", "1", .data(field)]
        let reply = try await session.execute(args)
        if let code = reply.arrayValue?.first?.intValue, code == -2 { throw KeyValueError.invalid("Field does not exist.") }
    }

    /// `HDEL`; returns the removed count and whether the key is gone.
    public func deleteFields(_ key: Data, _ fields: [Data]) async throws -> (removed: Int, keyDeleted: Bool) {
        let k = RedisArgument.data(key)
        guard try await KeyOperations(session: session).exists(key) else { throw KeyOperationError.keyNotFound }
        let removed = Int(try await session.execute(["HDEL", k] + fields.map { .data($0) }).intValue ?? 0)
        let exists = try await KeyOperations(session: session).exists(key)
        return (removed, !exists)
    }
}

// MARK: - List

public struct ListElement: Hashable, Sendable, Identifiable {
    public var index: Int
    public var value: Data
    public var id: Int { index }

    public init(index: Int, value: Data) {
        self.index = index
        self.value = value
    }
}

@MainActor
public struct ListService {
    public let session: DatabaseSession
    public nonisolated static let pageSize = 500

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// `LLEN` + `LRANGE offset offset+count-1`.
    public func elements(_ key: Data, offset: Int, count: Int = pageSize) async throws -> (total: Int, elements: [ListElement]) {
        let k = RedisArgument.data(key)
        let replies = try await session.pipeline([["LLEN", k],
                                                  ["LRANGE", k, .int(Int64(offset)), .int(Int64(offset + count - 1))]])
        guard replies.count == 2 else { throw KeyValueError.invalid("Unexpected reply") }
        try replies.forEach(KeyValueParsing.throwIfError)
        let total = Int(replies[0].intValue ?? 0)
        guard total > 0 else { throw KeyOperationError.keyNotFound }
        let values = (replies[1].arrayValue ?? []).compactMap(\.dataValue)
        return (total, values.enumerated().map { ListElement(index: offset + $0.offset, value: $0.element) })
    }

    /// `LINDEX`; nil reply -> "Index is out of range."
    public func element(_ key: Data, index: Int) async throws -> ListElement {
        let k = RedisArgument.data(key)
        let replies = try await session.pipeline([["EXISTS", k], ["LINDEX", k, .int(Int64(index))]])
        guard replies.count == 2 else { throw KeyValueError.invalid("Unexpected reply") }
        try replies.forEach(KeyValueParsing.throwIfError)
        guard (replies[0].intValue ?? 0) > 0 else { throw KeyOperationError.keyNotFound }
        guard let value = replies[1].dataValue else { throw KeyValueError.indexOutOfRange }
        return ListElement(index: index, value: value)
    }

    public func set(_ key: Data, index: Int, value: Data) async throws {
        guard try await KeyOperations(session: session).exists(key) else { throw KeyOperationError.keyNotFound }
        do {
            _ = try await session.execute(["LSET", .data(key), .int(Int64(index)), .data(value)])
        } catch RedisClientError.server(let error) where error.message.lowercased().contains("out of range") {
            throw KeyValueError.indexOutOfRange
        }
    }

    static let compareAndSetScript = """
        local current = redis.call('LINDEX', KEYS[1], ARGV[1])
        if current == false then return -1 end
        if current ~= ARGV[2] then return 0 end
        redis.call('LSET', KEYS[1], ARGV[1], ARGV[3])
        return 1
        """

    /// `LSET` only while the element at `index` still equals `expected` (atomic `EVAL`; falls back to
    /// `LINDEX` + `LSET` when scripting is unavailable). Throws `elementChanged` when it differs.
    public func set(_ key: Data, index: Int, value: Data, expected: Data) async throws {
        let k = RedisArgument.data(key)
        let code: Int
        do {
            let reply = try await session.execute(["EVAL", .string(Self.compareAndSetScript), "1", k,
                                                   .int(Int64(index)), .data(expected), .data(value)])
            code = Int(reply.intValue ?? 0)
        } catch RedisClientError.server(let error) where Self.isScriptingUnavailable(error.message) {
            let current = try await element(key, index: index)
            guard current.value == expected else { throw KeyValueError.elementChanged }
            try await set(key, index: index, value: value)
            return
        }

        switch code {
        case 1:
            return
        case 0:
            throw KeyValueError.elementChanged
        default:
            guard try await KeyOperations(session: session).exists(key) else { throw KeyOperationError.keyNotFound }
            throw KeyValueError.indexOutOfRange
        }
    }

    static func isScriptingUnavailable(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unknown command") || lower.contains("noperm") || lower.contains("no permissions")
            || lower.contains("noscript") || lower.contains("not allowed")
    }

    /// `RPUSHX` (tail) / `LPUSHX` (head). Returns the new length.
    @discardableResult
    public func push(_ key: Data, elements: [Data], destination: ListDestination) async throws -> Int {
        guard !elements.isEmpty else { return 0 }
        let verb: RedisArgument = destination == .head ? "LPUSHX" : "RPUSHX"
        let length = Int(try await session.execute([verb, .data(key)] + elements.map { .data($0) }).intValue ?? 0)
        if length == 0 { throw KeyOperationError.keyNotFound }
        return length
    }

    /// `RPOP` / `LPOP` (count appended only when > 1). Returns the removed values.
    public func pop(_ key: Data, count: Int, destination: ListDestination) async throws -> [Data] {
        let verb: RedisArgument = destination == .head ? "LPOP" : "RPOP"
        var args: [RedisArgument] = [verb, .data(key)]
        if count > 1 { args.append(.int(Int64(count))) }
        let reply: RESPValue
        do {
            reply = try await session.execute(args)
        } catch RedisClientError.server(let error) where count > 1 && error.message.lowercased().contains("wrong number") {
            throw KeyValueError.popCountUnsupported
        }

        if reply.isNull { throw KeyOperationError.keyNotFound }
        return KeyValueParsing.poppedValues(reply)
    }
}

// MARK: - Set

public struct SetMembersPage: Hashable, Sendable {
    public var members: [Data]
    public var nextCursor: UInt64
    public var total: Int
}

@MainActor
public struct SetService {
    public let session: DatabaseSession
    public nonisolated static let pageSize = 500

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// `SCARD`, then `SISMEMBER` for an exact member or `SSCAN ... MATCH` until `pageSize` members or the end.
    public func members(_ key: Data, match: String = "*", cursor: UInt64 = 0, count: Int = pageSize) async throws -> SetMembersPage {
        let k = RedisArgument.data(key)
        let total = Int(try await session.execute(["SCARD", k]).intValue ?? 0)
        guard total > 0 else { throw KeyOperationError.keyNotFound }
        let pattern = match.isEmpty ? "*" : match
        var members: [Data] = []
        var next: UInt64 = 0
        if let exact = KeyValueParsing.exactMatch(pattern) {
            if cursor == 0, (try await session.execute(["SISMEMBER", k, .data(exact)]).intValue ?? 0) > 0 {
                members = [exact]
            }
        } else {
            next = cursor
            repeat {
                try Task.checkCancellation()
                let reply = try await session.execute(["SSCAN", k, .uint(next), "MATCH", .data(KeyPattern.matchBytes(pattern)),
                                                       "COUNT", .int(Int64(count))])
                guard let page = KeyValueParsing.scanReply(reply) else { throw KeyValueError.invalid("Unexpected SSCAN reply") }
                next = page.cursor
                members += page.items
            } while next != 0 && members.count < count
        }

        return SetMembersPage(members: members, nextCursor: next, total: total)
    }

    /// `EXISTS` + `SADD`. Returns the number of new members.
    @discardableResult
    public func add(_ key: Data, members: [Data]) async throws -> Int {
        guard !members.isEmpty else { return 0 }
        guard try await KeyOperations(session: session).exists(key) else { throw KeyOperationError.keyNotFound }
        return Int(try await session.execute(["SADD", .data(key)] + members.map { .data($0) }).intValue ?? 0)
    }

    /// `EXISTS` + `SREM`; returns the removed count and whether the key is gone.
    public func remove(_ key: Data, members: [Data]) async throws -> (removed: Int, keyDeleted: Bool) {
        let operations = KeyOperations(session: session)
        guard try await operations.exists(key) else { throw KeyOperationError.keyNotFound }
        let removed = Int(try await session.execute(["SREM", .data(key)] + members.map { .data($0) }).intValue ?? 0)
        if removed == 0 { throw KeyValueError.memberNotFound }
        return (removed, !(try await operations.exists(key)))
    }
}
