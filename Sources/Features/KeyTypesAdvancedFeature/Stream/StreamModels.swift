import Foundation
import RedisUI

struct StreamField: Hashable, Sendable {
    var name: Data
    var value: Data
}

struct StreamEntry: Identifiable, Hashable, Sendable {
    var id: String
    var fields: [StreamField]
}

struct StreamInfo: Hashable, Sendable {
    var length: Int
    var lastGeneratedId: String
    var firstEntryId: String?
    var lastEntryId: String?
}

struct ConsumerGroup: Identifiable, Hashable, Sendable {
    var name: Data
    var consumers: Int
    var pending: Int
    var lastDeliveredId: String
    var smallestPendingId: String?
    var greatestPendingId: String?
    var id: Data { name }
    var displayName: String { Bytes.text(name) }
}

struct StreamConsumer: Identifiable, Hashable, Sendable {
    var name: Data
    var pending: Int
    var idleMs: Int
    var id: Data { name }
    var displayName: String { Bytes.text(name) }
}

struct PendingEntry: Identifiable, Hashable, Sendable {
    var id: String
    var consumer: Data
    var idleMs: Int
    var delivered: Int
}

enum StreamPage: Hashable {
    case entries, groups

    init(_ viewType: StreamViewType) {
        self = viewType == .data ? .entries : .groups
    }
}

enum ClaimTimeMode: String, CaseIterable, Identifiable {
    case relative = "Relative Time"
    case timestamp = "Timestamp"
    var id: String { rawValue }
}

struct ClaimOptions: Hashable, Sendable {
    var consumer: Data
    var minIdleMs: Int
    var idleMs: Int?
    var timeMs: Int?
    var retryCount: Int?
    var force: Bool = false
}

enum StreamViewType: Hashable {
    case data, groups, consumers, messages
}

/// Stream ID arithmetic and validation.
enum StreamID {
    struct Parts: Comparable, Hashable {
        var timestamp: UInt64
        var sequence: UInt64

        static func < (lhs: Parts, rhs: Parts) -> Bool {
            (lhs.timestamp, lhs.sequence) < (rhs.timestamp, rhs.sequence)
        }
    }

    static func parts(_ id: String) -> Parts? {
        let pieces = id.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = pieces.first, let ts = UInt64(first) else { return nil }
        if pieces.count == 1 { return Parts(timestamp: ts, sequence: 0) }
        guard pieces.count == 2, let seq = UInt64(pieces[1]) else { return nil }
        return Parts(timestamp: ts, sequence: seq)
    }

    static func timestampText(_ id: String) -> String {
        String(id.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// Milliseconds of the ID, or nil when it is not a plausible timestamp (≥ 16 digits).
    static func milliseconds(_ id: String) -> Double? {
        let text = timestampText(id)
        guard !text.isEmpty, text.count < 16, let value = Double(text) else { return nil }
        return value
    }

    /// First ID after (`asc`) or before (`desc`) `lastId`, for the next page; nil when there is none.
    static func nextId(after lastId: String, order: KeySortOrder) -> String? {
        if !lastId.contains("-") {
            return lastId + "-1"
        }

        guard let p = parts(lastId) else { return nil }
        switch order {
        case .desc:
            if p.sequence == 0 {
                guard p.timestamp > 0 else { return nil }
                return String(p.timestamp - 1)
            }

            return "\(p.timestamp)-\(p.sequence - 1)"
        case .asc:
            if p.sequence == UInt64.max {
                guard p.timestamp < UInt64.max else { return nil }
                return "\(p.timestamp + 1)-0"
            }

            return "\(p.timestamp)-\(p.sequence + 1)"
        }
    }

    static func filterEntryId(_ text: String) -> String {
        String(text.filter { $0.isASCII && ($0.isNumber || $0 == "-" || $0 == "*") })
    }

    static func filterGroupId(_ text: String) -> String {
        String(text.filter { $0.isASCII && ($0.isNumber || $0 == "-" || $0 == "$") })
    }

    static func isValidEntryIdFormat(_ id: String) -> Bool {
        if id == "*" { return true }
        let pieces = id.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, pieces[0].allSatisfy(\.isNumber) else { return false }
        return pieces[1] == "*" || (!pieces[1].isEmpty && pieces[1].allSatisfy(\.isNumber))
    }

    static func isValidGroupId(_ id: String) -> Bool {
        if id == "$" || id == "0" { return true }
        let pieces = id.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        return pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func entryIdError(_ id: String, lastGeneratedId: String?) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Entry ID is required" }
        guard isValidEntryIdFormat(trimmed) else { return "Entry ID format is incorrect" }
        guard trimmed != "*", let lastGeneratedId, let last = parts(lastGeneratedId) else { return nil }
        let pieces = trimmed.split(separator: "-")
        guard let ts = UInt64(pieces[0]) else { return "Entry ID format is incorrect" }
        if pieces.count == 2, pieces[1] == "*" {
            return ts >= last.timestamp ? nil : "Must be greater than the last ID"
        }

        guard let candidate = parts(trimmed), candidate > last else { return "Must be greater than the last ID" }
        return nil
    }

    static func normalizeOnBlur(_ id: String) -> String {
        id == "0-0" ? "0-1" : id
    }
}

enum StreamCommands {
    static let pageSize = 500

    static func bound(_ ms: Double?, edge: Double?, open: String) -> String {
        guard let ms, let edge, ms != edge else { return open }
        return String(Int64(ms.rounded()))
    }

    static func entries(key: Data, start: String, end: String, order: KeySortOrder, count: Int = pageSize) -> [RedisArgument] {
        if order == .asc {
            return ["XRANGE", .data(key), .string(start), .string(end), "COUNT", .int(Int64(count))]
        }

        return ["XREVRANGE", .data(key), .string(end), .string(start), "COUNT", .int(Int64(count))]
    }

    static func add(key: Data, id: String, fields: [StreamField]) -> [RedisArgument] {
        var args: [RedisArgument] = ["XADD", .data(key), .string(id)]
        for field in fields {
            args.append(.data(field.name))
            args.append(.data(field.value))
        }

        return args
    }

    static func claim(key: Data, group: Data, ids: [String], options: ClaimOptions) -> [RedisArgument] {
        var args: [RedisArgument] = ["XCLAIM", .data(key), .data(group), .data(options.consumer), .int(Int64(max(options.minIdleMs, 0)))]
        args += ids.map { .string($0) }
        if let idle = options.idleMs {
            args += ["IDLE", .int(Int64(idle))]
        } else if let time = options.timeMs {
            args += ["TIME", .int(Int64(time))]
        }

        if let retry = options.retryCount { args += ["RETRYCOUNT", .int(Int64(retry))] }
        if options.force { args.append("FORCE") }
        args.append("JUSTID")
        return args
    }

    static func autoClaim(key: Data, group: Data, consumer: Data, minIdleMs: Int, start: String, count: Int) -> [RedisArgument] {
        ["XAUTOCLAIM", .data(key), .data(group), .data(consumer), .int(Int64(max(minIdleMs, 0))), .string(start),
         "COUNT", .int(Int64(max(count, 1))), "JUSTID"]
    }

    static func pending(key: Data, group: Data, consumer: Data, start: String, end: String = "+",
                        count: Int = pageSize) -> [RedisArgument] {
        ["XPENDING", .data(key), .data(group), .string(start), .string(end), .int(Int64(count)), .data(consumer)]
    }

    static func parseEntries(_ reply: RESPValue) -> [StreamEntry] {
        Reply.items(reply).compactMap(parseEntry)
    }

    static func parseEntry(_ value: RESPValue) -> StreamEntry? {
        let parts = Reply.items(value)
        guard parts.count >= 2, let id = parts[0].stringValue else { return nil }
        let flat: [RESPValue]
        if case .map(let pairs) = parts[1] {
            flat = pairs.flatMap { [$0.0, $0.1] }
        } else {
            flat = Reply.items(parts[1])
        }

        var fields: [StreamField] = []
        fields.reserveCapacity(flat.count / 2)
        var index = 0
        while index + 1 < flat.count {
            fields.append(StreamField(name: flat[index].dataValue ?? Data(), value: flat[index + 1].dataValue ?? Data()))
            index += 2
        }

        return StreamEntry(id: id, fields: fields)
    }

    static func parseInfo(_ reply: RESPValue) -> StreamInfo {
        let map = Reply.map(reply)
        return StreamInfo(length: Reply.int(map["length"]),
                          lastGeneratedId: Reply.text(map["last-generated-id"]) ?? "0-0",
                          firstEntryId: map["first-entry"].flatMap(parseEntry)?.id,
                          lastEntryId: map["last-entry"].flatMap(parseEntry)?.id)
    }

    static func parseGroups(_ reply: RESPValue) -> [ConsumerGroup] {
        Reply.items(reply).map { item in
            let map = Reply.map(item)
            return ConsumerGroup(name: Reply.data(map["name"]) ?? Data(), consumers: Reply.int(map["consumers"]),
                                 pending: Reply.int(map["pending"]),
                                 lastDeliveredId: Reply.text(map["last-delivered-id"]) ?? "")
        }
    }

    static func parseConsumers(_ reply: RESPValue) -> [StreamConsumer] {
        Reply.items(reply).map { item in
            let map = Reply.map(item)
            return StreamConsumer(name: Reply.data(map["name"]) ?? Data(), pending: Reply.int(map["pending"]),
                                  idleMs: Reply.int(map["idle"]))
        }
    }

    static func parsePending(_ reply: RESPValue) -> [PendingEntry] {
        Reply.items(reply).compactMap { item in
            let parts = Reply.items(item)
            guard parts.count >= 4, let id = parts[0].stringValue else { return nil }
            return PendingEntry(id: id, consumer: parts[1].dataValue ?? Data(), idleMs: Reply.int(parts[2]),
                                delivered: Reply.int(parts[3]))
        }
    }

    /// `XAUTOCLAIM … JUSTID` → `[next, [ids…], [deleted…]]`.
    static func parseAutoClaim(_ reply: RESPValue) -> (next: String, ids: [String]) {
        let parts = Reply.items(reply)
        guard parts.count >= 2 else { return ("0-0", []) }
        return (parts[0].stringValue ?? "0-0", Reply.items(parts[1]).compactMap(\.stringValue))
    }

    /// Column layout for the data grid: field names in first-seen order; repeated names inside one entry add columns.
    static func columns(for entries: [StreamEntry]) -> [StreamColumn] {
        var seen = Set<StreamColumn>()
        var columns: [StreamColumn] = []
        for entry in entries {
            var occurrences: [Data: Int] = [:]
            for field in entry.fields {
                let occurrence = occurrences[field.name, default: 0]
                occurrences[field.name] = occurrence + 1
                let column = StreamColumn(name: field.name, occurrence: occurrence)
                if seen.insert(column).inserted { columns.append(column) }
            }
        }

        return columns
    }

    static func values(of entry: StreamEntry) -> [StreamColumn: Data] {
        var out: [StreamColumn: Data] = [:]
        var occurrences: [Data: Int] = [:]
        for field in entry.fields {
            let occurrence = occurrences[field.name, default: 0]
            occurrences[field.name] = occurrence + 1
            out[StreamColumn(name: field.name, occurrence: occurrence)] = field.value
        }

        return out
    }
}

struct StreamColumn: Hashable, Sendable {
    var name: Data
    var occurrence: Int
}

enum StreamDates {
    static func entryDate(_ id: String, pattern: String, timeZone: TimeZone) -> String? {
        guard id.count < 25, let ms = StreamID.milliseconds(id) else { return nil }
        return TimestampFormatter.format(milliseconds: ms, pattern: pattern, timeZone: timeZone)
    }

    static func idleText(_ ms: Int) -> String {
        NumberFormatting.grouped(ms)
    }
}

extension ConsumerGroup {
    /// Numeric-aware sort key for the last delivered ID.
    var lastDeliveredSortKey: String {
        guard let parts = StreamID.parts(lastDeliveredId) else { return lastDeliveredId }
        return String(format: "%020llu-%020llu", parts.timestamp, parts.sequence)
    }

    var pendingRangeText: String? {
        guard pending > 0, let smallest = smallestPendingId, let greatest = greatestPendingId else { return nil }
        return "\(smallest) – \(greatest)"
    }
}
