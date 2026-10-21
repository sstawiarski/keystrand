import Foundation
import RedisCore

public struct SlowLogEntry: Hashable, Sendable, Identifiable {
    public var id: String
    public var entryID: Int
    /// Unix seconds.
    public var time: Int
    public var durationUs: Int
    public var args: String
    public var source: String?
    public var client: String?
    public var node: String?

    public init(entryID: Int, time: Int, durationUs: Int, args: String, source: String? = nil, client: String? = nil, node: String? = nil) {
        self.id = "\(node ?? "")#\(entryID)#\(time)"
        self.entryID = entryID
        self.time = time
        self.durationUs = durationUs
        self.args = args
        self.source = source
        self.client = client
        self.node = node
    }

    /// `clientName (source)`, either part when the other is missing.
    public var clientText: String {
        switch (client?.isEmpty == false ? client : nil, source?.isEmpty == false ? source : nil) {
        case let (name?, address?): return "\(name) (\(address))"
        case let (name?, nil): return name
        case let (nil, address?): return address
        default: return "-"
        }
    }
}

public struct SlowLogConfig: Hashable, Sendable {
    public var slowlogMaxLen: Int
    /// Microseconds; -1 disables the Slow Log.
    public var slowlogLogSlowerThan: Int

    public init(slowlogMaxLen: Int = 128, slowlogLogSlowerThan: Int = 10_000) {
        self.slowlogMaxLen = slowlogMaxLen
        self.slowlogLogSlowerThan = slowlogLogSlowerThan
    }
}

public enum SlowLogError: Error, LocalizedError, Equatable {
    case clusterConfiguration
    /// Some cluster nodes failed; the message names each node and its error.
    case nodesFailed(String)

    public var errorDescription: String? {
        switch self {
        case .clusterConfiguration: return "Slow Log settings can't be changed for a whole cluster. Change them on each node instead."
        case .nodesFailed(let message): return message
        }
    }
}

/// Slow Log entries of every node that answered, and the error of each node that did not.
public struct SlowLogFetch: Sendable {
    public var entries: [SlowLogEntry]
    public var failures: [SlowLogNodeFailure]

    /// Inline text for the nodes that failed; nil when every node answered.
    public var failureMessage: String? {
        SlowLogNodeFailure.message(failures, action: "read the Slow Log")
    }
}

public struct SlowLogNodeFailure: Hashable, Sendable {
    public var node: String
    public var message: String

    static func message(_ failures: [SlowLogNodeFailure], action: String) -> String? {
        guard !failures.isEmpty else { return nil }
        let lines = failures.map { "\($0.node): \($0.message)" }
        let subject = failures.count == 1 ? "1 node" : "\(failures.count) nodes"
        return "Could not \(action) of \(subject).\n" + lines.joined(separator: "\n")
    }
}

public enum SlowLogParser {
    /// `SLOWLOG GET` reply: `[[id, time, durationUs, [args...], source?, clientName?], ...]`.
    public static func parseEntries(_ reply: RESPValue, node: String? = nil) -> [SlowLogEntry] {
        guard let items = reply.arrayValue else { return [] }
        return items.compactMap { item -> SlowLogEntry? in
            guard let fields = item.arrayValue, fields.count >= 4,
                  let id = fields[0].intValue, let time = fields[1].intValue, let duration = fields[2].intValue else { return nil }
            let args = (fields[3].arrayValue ?? []).map { $0.stringValue ?? "" }.joined(separator: " ")
            return SlowLogEntry(entryID: Int(id), time: Int(time), durationUs: Int(duration), args: args,
                                source: fields.count > 4 ? fields[4].stringValue : nil,
                                client: fields.count > 5 ? fields[5].stringValue : nil, node: node)
        }
    }

    /// `CONFIG GET slowlog*` reply (RESP2 pairs or RESP3 map); unparsable values fall back to 0.
    public static func parseConfig(_ reply: RESPValue) -> SlowLogConfig {
        var values: [String: Int] = [:]
        for (key, value) in reply.mapValue ?? [] {
            guard let name = key.stringValue else { continue }
            values[name] = value.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        }

        return SlowLogConfig(slowlogMaxLen: values["slowlog-max-len"] ?? 0,
                             slowlogLogSlowerThan: values["slowlog-log-slower-than"] ?? 0)
    }
}

/// Slow Log commands for the session (every node of a cluster for GET/RESET).
@MainActor
public struct SlowLogService {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// Entries of every node that answered. Throws only when no node answered.
    public func fetch(count: Int) async throws -> SlowLogFetch {
        let nodes = try await session.nodes()
        let isCluster = session.isCluster
        return try await Self.fetchPerNode(nodes: nodes, count: count, labelNodes: isCluster)
    }

    nonisolated static func fetch(nodes: [NodeClient], count: Int, labelNodes: Bool) async throws -> [SlowLogEntry] {
        try await fetchPerNode(nodes: nodes, count: count, labelNodes: labelNodes).entries
    }

    nonisolated static func fetchPerNode(nodes: [NodeClient], count: Int, labelNodes: Bool) async throws -> SlowLogFetch {
        let results = await forEachNode(nodes) { node in
            try await node.execute(["SLOWLOG", "GET", .int(Int64(count))])
        }
        var out = SlowLogFetch(entries: [], failures: [])
        var firstError: Error?
        for (node, result) in results {
            switch result {
            case .success(let reply):
                out.entries += SlowLogParser.parseEntries(reply, node: labelNodes ? node.endpoint.description : nil)
            case .failure(let error):
                firstError = firstError ?? error
                out.failures.append(SlowLogNodeFailure(node: node.endpoint.description, message: error.localizedDescription))
            }
        }

        if let firstError, out.failures.count == nodes.count { throw firstError }
        return out
    }

    /// Resets every node it can reach; throws naming the nodes that failed.
    public func reset() async throws {
        let nodes = try await session.nodes()
        let results = await Self.forEachNode(nodes) { node in try await node.execute(["SLOWLOG", "RESET"]) }
        var failures: [SlowLogNodeFailure] = []
        for (node, result) in results {
            if case .failure(let error) = result {
                if nodes.count == 1 { throw error }
                failures.append(SlowLogNodeFailure(node: node.endpoint.description, message: error.localizedDescription))
            }
        }

        if let message = SlowLogNodeFailure.message(failures, action: "clear the Slow Log") {
            throw SlowLogError.nodesFailed(message)
        }
    }

    /// Runs `body` on every node concurrently; results keep the order of `nodes`.
    nonisolated static func forEachNode(
        _ nodes: [NodeClient], _ body: @escaping @Sendable (NodeClient) async throws -> RESPValue
    ) async -> [(NodeClient, Result<RESPValue, Error>)] {
        await withTaskGroup(of: (Int, Result<RESPValue, Error>).self) { group in
            for (index, node) in nodes.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await body(node)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            var results = [Result<RESPValue, Error>?](repeating: nil, count: nodes.count)
            for await (index, result) in group { results[index] = result }
            return zip(nodes, results).compactMap { node, result in result.map { (node, $0) } }
        }
    }

    public func config() async throws -> SlowLogConfig {
        let reply = try await session.execute(["CONFIG", "GET", "slowlog*"])
        return SlowLogParser.parseConfig(reply)
    }

    public func setConfig(slowerThanUs: Int?, maxLen: Int?) async throws {
        guard !session.isCluster else { throw SlowLogError.clusterConfiguration }
        var commands: [[RedisArgument]] = []
        if let slowerThanUs { commands.append(["CONFIG", "SET", "slowlog-log-slower-than", .int(Int64(slowerThanUs))]) }
        if let maxLen { commands.append(["CONFIG", "SET", "slowlog-max-len", .int(Int64(maxLen))]) }
        guard !commands.isEmpty else { return }
        let replies = try await session.pipeline(commands)
        if let error = replies.compactMap(\.errorValue).first { throw RedisClientError.server(error) }
    }
}

/// Configure-popover form state (pure, testable).
public struct SlowLogConfigForm: Hashable, Sendable {
    public static let defaultMaxLen = 128
    public static let defaultSlowerThanMs = 10
    /// Largest accepted slower-than value (about 31.7 years); keeps every conversion inside `Int`.
    public static let maxSlowerThanMicroseconds: Double = 1e15
    static let maxSlowerThanLength = 20

    public var slowerThan: String
    public var unit: SlowLogDurationUnit
    public var maxLen: String

    public init(slowerThan: String = "", unit: SlowLogDurationUnit = .milliseconds, maxLen: String = "") {
        self.slowerThan = slowerThan
        self.unit = unit
        self.maxLen = maxLen
    }

    public init(config: SlowLogConfig, unit: SlowLogDurationUnit) {
        let us = config.slowlogLogSlowerThan
        let text: String
        if us == -1 {
            text = "-1"
        } else {
            text = unit == .milliseconds ? Self.plain(Double(us) / 1000) : String(us)
        }

        self.init(slowerThan: text, unit: unit, maxLen: String(config.slowlogMaxLen))
    }

    public mutating func applyDefaults() {
        slowerThan = String(Self.defaultSlowerThanMs)
        unit = .milliseconds
        maxLen = String(Self.defaultMaxLen)
    }

    /// User picked another unit: the typed value is converted so it keeps the same duration.
    public mutating func changeUnit(to newUnit: SlowLogDurationUnit) {
        guard newUnit != unit else { return }
        let oldUnit = unit
        unit = newUnit
        let trimmed = slowerThan.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value != -1 else { return }
        let converted = oldUnit == .milliseconds ? value * 1000 : value / 1000
        slowerThan = Self.plain(converted)
    }

    /// Digits and `-` for the slower-than field (`.` too for msec); digits only for max length.
    public static func sanitizeSlowerThan(_ text: String, unit: SlowLogDurationUnit) -> String {
        String(text.filter { $0.isASCII && ($0.isNumber || $0 == "-" || (unit == .milliseconds && $0 == ".")) }
            .prefix(maxSlowerThanLength))
    }

    public static func sanitizeMaxLen(_ text: String) -> String {
        text.filter { $0.isASCII && $0.isNumber }
    }

    public var isSlowerThanValid: Bool {
        let trimmed = slowerThan.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let pattern = unit == .milliseconds ? #"^-?\d+(\.\d{1,3})?$"# : #"^-?\d+$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil, let value = Double(trimmed) else { return false }
        let microseconds = unit == .milliseconds ? value * 1000 : value
        return value >= -1 && microseconds <= Self.maxSlowerThanMicroseconds
    }

    public var isValid: Bool { isSlowerThanValid }

    /// Microseconds to send; empty -> 10 msec, `-1` stays -1.
    public var slowerThanMicroseconds: Int? {
        let trimmed = slowerThan.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Self.defaultSlowerThanMs * 1000 }
        guard isSlowerThanValid, let value = Double(trimmed) else { return nil }
        if value == -1 { return -1 }
        return Int(exactly: unit == .milliseconds ? (value * 1000).rounded() : value.rounded())
    }

    public var maxLenValue: Int {
        Int(maxLen.trimmingCharacters(in: .whitespaces)) ?? Self.defaultMaxLen
    }

    /// Helper line showing the value in the other unit.
    public var conversionHint: String {
        let other: SlowLogDurationUnit = unit == .milliseconds ? .microseconds : .milliseconds
        let trimmed = slowerThan.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), isSlowerThanValid else { return "- \(other.shortLabel)" }
        if value == -1 { return "-1 \(other.shortLabel)" }
        let converted = unit == .milliseconds ? value * 1000 : value / 1000
        return "\(AnalyticsFormat.decimal(converted, maxDecimals: 3)) \(other.shortLabel)"
    }

    /// Up to 3 decimals, trailing zeros dropped; `-` when the value does not fit an `Int`.
    static func plain(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        guard rounded.isFinite, abs(rounded) < 9e18 else { return "-" }
        if rounded == rounded.rounded(), let integer = Int(exactly: rounded) { return String(integer) }
        var s = String(format: "%.3f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
}
