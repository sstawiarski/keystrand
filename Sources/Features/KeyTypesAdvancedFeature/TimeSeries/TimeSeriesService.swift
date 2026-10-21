import Foundation
import RedisUI

struct TimeSeriesSample: Identifiable, Hashable, Sendable {
    var timestamp: Int64
    var value: Double
    /// Value text as Redis returned it (keeps the exact representation for display and copy).
    var valueText: String
    var id: Int64 { timestamp }
}

struct TimeSeriesRule: Hashable, Sendable {
    var destination: Data
    var bucketMs: Int64
    var aggregation: String
    var alignment: Int64
}

struct TimeSeriesInfo: Hashable, Sendable {
    var totalSamples = 0
    var memoryUsage: Int?
    var firstTimestamp: Int64 = 0
    var lastTimestamp: Int64 = 0
    var retentionMs: Int64 = 0
    var chunkCount: Int?
    var chunkSize: Int?
    var chunkType: String?
    var duplicatePolicy: String?
    var ignoreMaxTimeDiff: Int64?
    var ignoreMaxValDiff: String?
    var labels: [TimeSeriesLabel] = []
    var sourceKey: Data?
    var rules: [TimeSeriesRule] = []
}

struct TimeSeriesLabel: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var value: String
}

enum TimeSeriesAggregation: String, CaseIterable, Identifiable, Sendable {
    case avg, sum, min, max, range, count, first, last
    case stdP = "std.p"
    case stdS = "std.s"
    case varP = "var.p"
    case varS = "var.s"
    case twa
    var id: String { rawValue }
}

enum TimeSeriesDuplicatePolicy: String, CaseIterable, Identifiable, Sendable {
    case block = "BLOCK", first = "FIRST", last = "LAST", min = "MIN", max = "MAX", sum = "SUM"
    var id: String { rawValue }
}

struct TimeSeriesQuery: Hashable, Sendable {
    /// `-` or milliseconds.
    var from = "-"
    /// `+` or milliseconds.
    var to = "+"
    var order: KeySortOrder = .desc
    var count = TimeSeriesCommands.pageSize
    var aggregation: TimeSeriesAggregation?
    var bucketMs: Int64 = 60_000
    var emptyBuckets = false
    var minValue: Double?
    var maxValue: Double?
}

enum TimeSeriesCommands {
    static let pageSize = 500
    static let chartPointLimit = 2_000

    static func range(key: Data, query: TimeSeriesQuery) -> [RedisArgument] {
        var args: [RedisArgument] = [query.order == .asc ? "TS.RANGE" : "TS.REVRANGE", .data(key),
                                     .string(query.from), .string(query.to)]
        if let min = query.minValue, let max = query.maxValue {
            args += ["FILTER_BY_VALUE", .string(RedisArgument.format(min)), .string(RedisArgument.format(max))]
        }

        args += ["COUNT", .int(Int64(max(query.count, 1)))]
        if let aggregation = query.aggregation {
            args += ["AGGREGATION", .string(aggregation.rawValue), .int(max(query.bucketMs, 1))]
            if query.emptyBuckets { args.append("EMPTY") }
        }

        return args
    }

    /// Query for the page after `last` (exclusive), keeping the other options.
    static func nextPage(after last: Int64, query: TimeSeriesQuery) -> TimeSeriesQuery? {
        var next = query
        let step: Int64 = query.aggregation == nil ? 1 : max(query.bucketMs, 1)
        switch query.order {
        case .asc:
            let (value, overflow) = last.addingReportingOverflow(step)
            guard !overflow else { return nil }
            if let to = Int64(query.to), value > to { return nil }
            next.from = String(value)
        case .desc:
            guard last > 0 else { return nil }
            let value = last - 1
            if let from = Int64(query.from), value < from { return nil }
            next.to = String(value)
        }

        return next
    }

    static func add(key: Data, timestamp: String, value: String, onDuplicate: TimeSeriesDuplicatePolicy?) -> [RedisArgument] {
        var args: [RedisArgument] = ["TS.ADD", .data(key), .string(timestamp), .string(value)]
        if let onDuplicate { args += ["ON_DUPLICATE", .string(onDuplicate.rawValue)] }
        return args
    }

    static func delete(key: Data, from: Int64, to: Int64) -> [RedisArgument] {
        ["TS.DEL", .data(key), .int(from), .int(to)]
    }

    static func alter(key: Data, retentionMs: Int64?, duplicatePolicy: TimeSeriesDuplicatePolicy?,
                      labels: [TimeSeriesLabel]?) -> [RedisArgument] {
        var args: [RedisArgument] = ["TS.ALTER", .data(key)]
        if let retentionMs { args += ["RETENTION", .int(max(retentionMs, 0))] }
        if let duplicatePolicy { args += ["DUPLICATE_POLICY", .string(duplicatePolicy.rawValue)] }
        if let labels {
            args.append("LABELS")
            for label in labels where !label.name.isEmpty {
                args += [.string(label.name), .string(label.value)]
            }
        }

        return args
    }

    static func parseSamples(_ reply: RESPValue) -> [TimeSeriesSample] {
        Reply.items(reply).compactMap(parseSample)
    }

    static func parseSample(_ value: RESPValue) -> TimeSeriesSample? {
        let parts = Reply.items(value)
        guard parts.count >= 2, let ts = parts[0].intValue ?? parts[0].stringValue.flatMap({ Int64($0) }) else { return nil }
        let text = valueText(parts[1])
        let number = parts[1].doubleValue ?? Double(text) ?? .nan
        return TimeSeriesSample(timestamp: ts, value: number, valueText: text)
    }

    static func valueText(_ value: RESPValue) -> String {
        switch value {
        case .double(let d):
            if d.isNaN { return "NaN" }
            if d == .infinity { return "inf" }
            if d == -.infinity { return "-inf" }
            return RedisArgument.format(d)
        default:
            return value.stringValue ?? ""
        }
    }

    static func parseInfo(_ reply: RESPValue) -> TimeSeriesInfo {
        let map = Reply.map(reply)
        var info = TimeSeriesInfo()
        info.totalSamples = Reply.int(map["totalSamples"])
        info.memoryUsage = Reply.optionalInt(map["memoryUsage"])
        info.firstTimestamp = map["firstTimestamp"]?.intValue ?? 0
        info.lastTimestamp = map["lastTimestamp"]?.intValue ?? 0
        info.retentionMs = map["retentionTime"]?.intValue ?? 0
        info.chunkCount = Reply.optionalInt(map["chunkCount"])
        info.chunkSize = Reply.optionalInt(map["chunkSize"])
        info.chunkType = Reply.text(map["chunkType"])
        info.duplicatePolicy = Reply.text(map["duplicatePolicy"])
        info.ignoreMaxTimeDiff = map["ignoreMaxTimeDiff"]?.intValue
        info.ignoreMaxValDiff = map["ignoreMaxValDiff"].flatMap(Reply.text)
        if let source = Reply.data(map["sourceKey"]), !source.isEmpty { info.sourceKey = source }
        info.labels = parseLabels(map["labels"])
        info.rules = Reply.items(map["rules"]).compactMap { rule in
            let parts = Reply.items(rule)
            guard parts.count >= 3, let destination = parts[0].dataValue else { return nil }
            return TimeSeriesRule(destination: destination, bucketMs: parts[1].intValue ?? 0,
                                  aggregation: Reply.text(parts[2]) ?? "",
                                  alignment: parts.count > 3 ? (parts[3].intValue ?? 0) : 0)
        }
        return info
    }

    /// Labels arrive as a RESP3 map, an array of `[name, value]` pairs, or a flat list.
    static func parseLabels(_ value: RESPValue?) -> [TimeSeriesLabel] {
        guard let value, !value.isNull else { return [] }
        if case .map(let pairs) = value {
            return pairs.compactMap { pair in
                guard let name = Reply.text(pair.0) else { return nil }
                return TimeSeriesLabel(name: name, value: Reply.text(pair.1) ?? "")
            }
        }

        let items = Reply.items(value)
        if items.allSatisfy({ $0.arrayValue != nil }) {
            return items.compactMap { item in
                let parts = Reply.items(item)
                guard parts.count >= 2, let name = Reply.text(parts[0]) else { return nil }
                return TimeSeriesLabel(name: name, value: Reply.text(parts[1]) ?? "")
            }
        }

        var labels: [TimeSeriesLabel] = []
        var index = 0
        while index + 1 < items.count {
            if let name = Reply.text(items[index]) {
                labels.append(TimeSeriesLabel(name: name, value: Reply.text(items[index + 1]) ?? ""))
            }

            index += 2
        }

        return labels
    }

    static func isValidTimestamp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "*" { return true }
        return !trimmed.isEmpty && trimmed.allSatisfy(\.isASCIIDigit) && Int64(trimmed) != nil
    }

    /// A range bound: `-`/`+`, empty (open), or a non-negative integer.
    static func isValidBound(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "-" || trimmed == "+" { return true }
        return trimmed.allSatisfy(\.isASCIIDigit) && Int64(trimmed) != nil
    }

    static func isValidValue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return false }
        return !value.isNaN
    }

    /// Evenly thins `samples` (sorted by time) to at most `limit` points for charting, keeping both ends.
    static func chartPoints(_ samples: [TimeSeriesSample], limit: Int = chartPointLimit) -> [TimeSeriesSample] {
        let finite = samples.filter { $0.value.isFinite }
        guard finite.count > limit, limit > 1 else { return finite }
        let stride = Double(finite.count - 1) / Double(limit - 1)
        return (0..<limit).map { finite[Int((Double($0) * stride).rounded())] }
    }

    static func durationText(ms: Int64) -> String {
        guard ms > 0 else { return "No limit" }
        if ms % 1000 != 0 { return "\(NumberFormatting.grouped(Int(clamping: ms))) ms" }
        return DurationText.full(seconds: Int(clamping: ms / 1000))
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

@MainActor
struct TimeSeriesService {
    let session: DatabaseSession
    let key: Data

    func info() async throws -> TimeSeriesInfo {
        do {
            return TimeSeriesCommands.parseInfo(try await session.execute(["TS.INFO", .data(key)]))
        } catch {
            throw Self.map(error)
        }
    }

    func samples(_ query: TimeSeriesQuery) async throws -> [TimeSeriesSample] {
        do {
            return TimeSeriesCommands.parseSamples(try await session.execute(TimeSeriesCommands.range(key: key, query: query)))
        } catch {
            throw Self.map(error)
        }
    }

    @discardableResult
    func add(timestamp: String, value: String, onDuplicate: TimeSeriesDuplicatePolicy?) async throws -> Int64 {
        do {
            let reply = try await session.execute(TimeSeriesCommands.add(key: key, timestamp: timestamp, value: value,
                                                                          onDuplicate: onDuplicate))
            return reply.intValue ?? 0
        } catch {
            throw Self.map(error)
        }
    }

    func delete(from: Int64, to: Int64) async throws -> Int {
        do {
            return Reply.int(try await session.execute(TimeSeriesCommands.delete(key: key, from: from, to: to)))
        } catch {
            throw Self.map(error)
        }
    }

    func alter(retentionMs: Int64?, duplicatePolicy: TimeSeriesDuplicatePolicy?, labels: [TimeSeriesLabel]?) async throws {
        do {
            _ = try await session.execute(TimeSeriesCommands.alter(key: key, retentionMs: retentionMs,
                                                                   duplicatePolicy: duplicatePolicy, labels: labels))
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: Error) -> Error {
        if Reply.isUnknownCommand(error) { return KeyValueError.moduleNotLoaded("TimeSeries") }
        if let message = Reply.serverMessage(error)?.lowercased(), message.contains("key does not exist") {
            return KeyOperationError.keyNotFound
        }

        return error
    }
}
