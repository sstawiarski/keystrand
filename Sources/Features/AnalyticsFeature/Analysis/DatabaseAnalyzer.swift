import Foundation
import RedisCore

/// Samples keys on every primary node (SCAN up to `filter.count` per node), collects memory/type/TTL/length with
/// pipelines, aggregates the report and evaluates recommendations. All I/O and aggregation run off the main actor.
@MainActor
public struct DatabaseAnalyzer {
    nonisolated public static let scanBatchLimit = 2_000
    nonisolated public static let pipelineChunk = 1_000

    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public func analyze(delimiter: String, filter: AnalysisFilter = AnalysisFilter(),
                        onProgress: @escaping @Sendable (AnalysisProgress) -> Void = { _ in }) async throws -> DatabaseAnalysisReport {
        let nodes = try await session.nodes(role: .primary, context: .background)
        let routed: any RedisClient = try await session.client(context: .background)
        let context = Context(databaseId: session.id, db: session.effectiveDB, isCluster: session.isCluster,
                              delimiter: delimiter, filter: filter)
        return try await Self.run(nodes: nodes, routed: routed, context: context, onProgress: onProgress)
    }

    struct Context: Sendable {
        var databaseId: DatabaseID
        var db: Int
        var isCluster: Bool
        var delimiter: String
        var filter: AnalysisFilter
    }

    struct NodeScan: Sendable {
        var progress: AnalysisProgress
        var keys: [AnalyzedKey]
        var info: RedisInfo?
        var configs: [String: Int]
        var searchIndexes: [String]?
        var aclUsers: [String]?
        var node: NodeClient
    }

    nonisolated static func run(nodes: [NodeClient], routed: any RedisClient, context: Context,
                                onProgress: @escaping @Sendable (AnalysisProgress) -> Void) async throws -> DatabaseAnalysisReport {
        var scans: [NodeScan] = []
        var done = AnalysisProgress()
        for node in nodes {
            try Task.checkCancellation()
            let base = done
            let scan = try await scanNode(node, context: context) { partial in onProgress(base + partial) }
            done = done + scan.progress
            scans.append(scan)
            onProgress(done)
        }

        let allKeys = scans.flatMap(\.keys)
        let globalTotal = scans.reduce(0) { $0 + max($1.progress.total, 0) }
        var recommendations: [AnalysisRecommendation] = []
        var excluded: Set<String> = []
        for (index, scan) in scans.enumerated() {
            try Task.checkCancellation()
            let rtsKey = await probeTimeSeries(scan.node, keys: scan.keys)
            let searchKey = await probeSearchIndexes(scan.node, routed: routed, isCluster: context.isCluster, keys: scan.keys)
            let input = RecommendationInput(keys: scan.keys, globalTotalKeys: globalTotal, isCluster: context.isCluster,
                                            info: scan.info, configs: scan.configs, searchIndexes: scan.searchIndexes,
                                            aclUsers: scan.aclUsers, rtsKey: rtsKey, searchIndexesKey: searchKey)
            let found = RecommendationRules.evaluate(input, excluding: excluded)
            recommendations += found
            excluded.formUnion(found.map(\.name))
            if index == 0 { excluded.formUnion(RecommendationRules.databaseWideNames) }
        }

        let aggregate = AnalysisAggregator.aggregate(allKeys, delimiter: Data(context.delimiter.utf8))
        return DatabaseAnalysisReport(
            databaseId: context.databaseId, createdAt: Date(), db: context.db, delimiter: context.delimiter,
            filter: context.filter, progress: done, totalKeys: aggregate.totalKeys, totalMemory: aggregate.totalMemory,
            topKeysNsp: aggregate.topKeysNsp, topMemoryNsp: aggregate.topMemoryNsp, topKeysLength: aggregate.topKeysLength,
            topKeysMemory: aggregate.topKeysMemory, expirationGroups: aggregate.expirationGroups,
            recommendations: recommendations)
    }

    nonisolated static func scanNode(_ node: NodeClient, context: Context,
                                     onProgress: @Sendable (AnalysisProgress) -> Void) async throws -> NodeScan {
        let preamble = try await node.pipeline([
            ["DBSIZE"],
            ["INFO"],
            ["CONFIG", "GET", "set-max-intset-entries"],
            ["CONFIG", "GET", "hash-max-ziplist-entries"],
            ["CONFIG", "GET", "zset-max-ziplist-entries"],
            ["ACL", "LIST"],
            ["FT._LIST"],
        ])
        let info = preamble[safe: 1].flatMap { $0.isError ? nil : $0.stringValue }.map(ServerInfoParser.parse)
        var total: Int
        if let size = preamble[safe: 0]?.intValue, !(preamble[safe: 0]?.isError ?? true) {
            total = Int(size)
        } else if let info {
            total = info.keyspace[context.db]?.keys ?? 0
        } else {
            total = -1
        }

        var configs: [String: Int] = [:]
        for index in 2...4 {
            if let (name, value) = parseConfigPair(preamble[safe: index]) { configs[name] = value }
        }

        let acl: [String]? = preamble[safe: 5].flatMap { $0.isError ? nil : $0.arrayValue?.compactMap(\.stringValue) }
        let indexes: [String]? = preamble[safe: 6].flatMap { $0.isError ? nil : $0.arrayValue?.compactMap(\.stringValue) }

        let names = try await scanKeys(node, filter: context.filter) { scanned in
            onProgress(AnalysisProgress(total: max(total, 0), scanned: scanned, processed: 0))
        }
        total = max(total, names.count)
        var keys: [AnalyzedKey] = []
        keys.reserveCapacity(names.count)
        var start = 0
        while start < names.count {
            try Task.checkCancellation()
            let end = min(start + pipelineChunk, names.count)
            keys += try await collectMetadata(node, names: Array(names[start..<end]))
            start = end
            onProgress(AnalysisProgress(total: total, scanned: names.count, processed: keys.count))
        }

        let scanned = max(context.filter.count, names.count)
        return NodeScan(progress: AnalysisProgress(total: total, scanned: scanned, processed: keys.count), keys: keys,
                        info: info, configs: configs, searchIndexes: indexes, aclUsers: acl, node: node)
    }

    /// `SCAN` until `filter.count` keys were requested or the cursor wraps; duplicates are dropped.
    nonisolated static func scanKeys(_ node: NodeClient, filter: AnalysisFilter, onBatch: (Int) -> Void) async throws -> [Data] {
        let count = min(scanBatchLimit, max(filter.count, 1))
        var cursor = "0"
        var requested = 0
        var seen = Set<Data>()
        var names: [Data] = []
        repeat {
            try Task.checkCancellation()
            var args: [RedisArgument] = ["SCAN", .string(cursor), "COUNT", .int(Int64(count)), "MATCH", .string(filter.match)]
            if let type = filter.type { args += ["TYPE", .string(type)] }
            let reply = try await node.execute(args)
            guard let parts = reply.arrayValue, parts.count == 2 else {
                throw RedisClientError.protocolError("Unexpected SCAN reply")
            }
            cursor = parts[0].stringValue ?? "0"
            for item in parts[1].arrayValue ?? [] {
                if let name = item.dataValue, seen.insert(name).inserted { names.append(name) }
            }

            requested += count
            onBatch(names.count)
        } while requested < filter.count && cursor != "0"

        return names
    }

    nonisolated static func collectMetadata(_ node: NodeClient, names: [Data]) async throws -> [AnalyzedKey] {
        var commands: [[RedisArgument]] = []
        commands.reserveCapacity(names.count * 3)
        for name in names {
            commands.append(["MEMORY", "USAGE", .data(name), "SAMPLES", "0"])
            commands.append(["TYPE", .data(name)])
            commands.append(["TTL", .data(name)])
        }

        let replies = try await node.pipeline(commands)
        var keys: [AnalyzedKey] = names.enumerated().map { index, name in
            let memoryReply = replies[safe: index * 3]
            let typeReply = replies[safe: index * 3 + 1]
            let ttlReply = replies[safe: index * 3 + 2]
            let memory = memoryReply.flatMap { $0.isError || $0.isNull ? nil : $0.intValue.map(Int.init) }
            let type = typeReply.flatMap { $0.isError ? nil : $0.stringValue } ?? "N/A"
            let ttl = ttlReply.flatMap { $0.isError ? nil : $0.intValue.map(Int.init) } ?? -2
            return AnalyzedKey(name: name, type: type, memory: memory, length: nil, ttl: ttl)
        }
        try await fillLengths(node, keys: &keys)
        return keys
    }

    nonisolated static func lengthCommand(for type: String, key: Data) -> [RedisArgument]? {
        switch type {
        case "string": return ["STRLEN", .data(key)]
        case "hash": return ["HLEN", .data(key)]
        case "list": return ["LLEN", .data(key)]
        case "set": return ["SCARD", .data(key)]
        case "zset": return ["ZCARD", .data(key)]
        case "stream": return ["XLEN", .data(key)]
        case "ReJSON-RL": return ["JSON.TYPE", .data(key)]
        case "TSDB-TYPE": return ["TS.INFO", .data(key)]
        case "graphdata": return ["GRAPH.QUERY", .data(key), "MATCH (r) RETURN count(r)", "--compact"]
        default: return nil
        }
    }

    nonisolated static func fillLengths(_ node: NodeClient, keys: inout [AnalyzedKey]) async throws {
        var indices: [Int] = []
        var commands: [[RedisArgument]] = []
        for (index, key) in keys.enumerated() {
            if let command = lengthCommand(for: key.type, key: key.name) {
                indices.append(index)
                commands.append(command)
            }
        }

        guard !commands.isEmpty else { return }
        let replies = try await node.pipeline(commands)
        var jsonFollowUps: [(Int, [RedisArgument])] = []
        for (position, index) in indices.enumerated() {
            guard let reply = replies[safe: position], !reply.isError else { continue }
            let key = keys[index]
            switch key.type {
            case "ReJSON-RL":
                if let command = jsonLengthCommand(jsonType: jsonTypeName(reply), key: key.name) {
                    jsonFollowUps.append((index, command))
                }
            case "TSDB-TYPE":
                keys[index].length = timeSeriesSamples(reply)
            case "graphdata":
                keys[index].length = graphNodeCount(reply)
            default:
                keys[index].length = reply.intValue.map(Int.init)
            }
        }

        guard !jsonFollowUps.isEmpty else { return }
        let jsonReplies = try await node.pipeline(jsonFollowUps.map(\.1))
        for (position, followUp) in jsonFollowUps.enumerated() {
            guard let reply = jsonReplies[safe: position], !reply.isError else { continue }
            let value = reply.arrayValue?.first ?? reply
            keys[followUp.0].length = value.intValue.map(Int.init)
        }
    }

    nonisolated static func jsonTypeName(_ reply: RESPValue) -> String? {
        if let first = reply.arrayValue?.first { return first.stringValue }
        return reply.stringValue
    }

    nonisolated static func jsonLengthCommand(jsonType: String?, key: Data) -> [RedisArgument]? {
        switch jsonType {
        case "object": return ["JSON.OBJLEN", .data(key)]
        case "array": return ["JSON.ARRLEN", .data(key)]
        case "string": return ["JSON.STRLEN", .data(key)]
        default: return nil
        }
    }

    nonisolated static func timeSeriesSamples(_ reply: RESPValue) -> Int? {
        guard let pairs = reply.mapValue else { return nil }
        for (key, value) in pairs where key.stringValue == "totalSamples" {
            return value.intValue.map(Int.init)
        }

        return nil
    }

    /// `GRAPH.QUERY ... --compact` -> reply[1][0][0][1].
    nonisolated static func graphNodeCount(_ reply: RESPValue) -> Int? {
        guard let items = reply.arrayValue, items.count > 1, let rows = items[1].arrayValue,
              let row = rows.first?.arrayValue, let cell = row.first?.arrayValue, cell.count > 1 else { return nil }
        return cell[1].intValue.map(Int.init)
    }

    /// `CONFIG GET name` -> `(name, Int)`; RESP2 flat pairs or RESP3 map.
    nonisolated static func parseConfigPair(_ reply: RESPValue?) -> (String, Int)? {
        guard let reply, !reply.isError, let pairs = reply.mapValue, let pair = pairs.first,
              let name = pair.0.stringValue, let text = pair.1.stringValue, let value = Int(text) else { return nil }
        return (name, value)
    }

    /// First zset (of at most 101) whose first member or score looks like a timestamp.
    nonisolated static func probeTimeSeries(_ node: NodeClient, keys: [AnalyzedKey]) async -> Data? {
        let zsets = keys.filter { $0.type == "zset" }.prefix(RecommendationRules.zsetProbeLimit + 1)
        guard !zsets.isEmpty else { return nil }
        guard let replies = try? await node.pipeline(zsets.map { ["ZSCAN", .data($0.name), "0", "COUNT", "2"] }) else { return nil }
        for (key, reply) in zip(zsets, replies) {
            guard !reply.isError, let parts = reply.arrayValue, parts.count == 2, let items = parts[1].arrayValue else { continue }
            if RecommendationRules.looksLikeTimeSeries(member: items[safe: 0]?.stringValue, score: items[safe: 1]?.stringValue) {
                return key.name
            }
        }

        return nil
    }

    /// First zset (of at most 100) whose first member names a hash or JSON key.
    nonisolated static func probeSearchIndexes(_ node: NodeClient, routed: any RedisClient, isCluster: Bool,
                                               keys: [AnalyzedKey]) async -> Data? {
        let zsets = Array(keys.filter { $0.type == "zset" }.prefix(RecommendationRules.zsetProbeLimit))
        guard !zsets.isEmpty else { return nil }
        guard let ranges = try? await node.pipeline(zsets.map { ["ZRANGE", .data($0.name), "0", "0"] }) else { return nil }
        var candidates: [(Data, Data)] = []
        for (key, reply) in zip(zsets, ranges) {
            if !reply.isError, let member = reply.arrayValue?.first?.dataValue { candidates.append((key.name, member)) }
        }

        guard !candidates.isEmpty else { return nil }
        let typeCommands: [[RedisArgument]] = candidates.map { ["TYPE", .data($0.1)] }
        let types: [RESPValue]
        if isCluster {
            var collected: [RESPValue] = []
            for command in typeCommands {
                collected.append((try? await routed.execute(command)) ?? .null)
            }

            types = collected
        } else {
            guard let replies = try? await node.pipeline(typeCommands) else { return nil }
            types = replies
        }

        for (candidate, type) in zip(candidates, types) {
            if let name = type.stringValue, name == "ReJSON-RL" || name == "hash" { return candidate.0 }
        }

        return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
