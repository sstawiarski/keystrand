import Foundation

public enum KeyScanError: Error, LocalizedError, Sendable, Equatable {
    case typeFilterUnsupported
    case incorrectClusterCursor

    public var errorDescription: String? {
        switch self {
        case .typeFilterUnsupported: return "Filtering keys by type needs Redis 6.0 or newer."
        case .incorrectClusterCursor: return "The cluster scan cursor is malformed."
        }
    }
}

/// SCAN for the key list (standalone and cluster with composite cursor), exact lookup, totals.
@MainActor
public struct KeyScanner {
    public let session: DatabaseSession
    /// Standalone SCAN COUNT cap.
    public nonisolated static let maxStandaloneCount = 2_000

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// Continues `state` (or starts when nil) until about `request.count` keys were found or the scan threshold
    /// (Settings "Keys to Scan") was scanned on every node, or the cursor completes. Metadata (TTL/size) is not
    /// loaded here; `type` is pre-filled when filtering by type.
    public func scan(_ request: ScanRequest, continuing state: KeyScanState? = nil) async throws -> KeyScanState {
        let threshold = max(session.services.settings.app.effectiveScanThreshold, request.count)
        let match = request.match.isEmpty ? "*" : request.match
        if !KeyPattern.isGlob(match) {
            return try await exactScan(name: KeyPattern.literalBytes(match), request: request)
        }

        let nodes = try await session.nodes(role: .primary)
        if session.isCluster || nodes.count > 1 {
            return try await clusterScan(request, match: match, nodes: nodes, threshold: threshold, state: state)
        }

        guard let node = nodes.first else { throw RedisClientError.notConnected }
        return try await standaloneScan(request, match: match, node: node, threshold: threshold, state: state)
    }

    /// For patterns without glob characters: `TYPE`/`TTL`/`MEMORY USAGE` the exact key instead of scanning.
    /// Returns nil when the key does not exist or its type does not match `type`.
    public func exactKey(_ name: Data, type: KeyType? = nil) async throws -> KeyListItem? {
        let replies = try await session.pipeline([
            ["TYPE", .data(name)], ["TTL", .data(name)], ["MEMORY", "USAGE", .data(name), "SAMPLES", "0"],
        ])
        guard replies.count == 3, let typeText = replies[0].stringValue, let keyType = KeyType(typeReply: typeText) else {
            return nil
        }
        let ttl = replies[1].intValue.map(Int.init)
        if ttl == -2 { return nil }
        if let type, type != keyType { return nil }
        return KeyListItem(name: name, type: keyType, ttl: ttl, size: replies[2].intValue.map(Int.init))
    }

    /// Keys in the current logical database (sum over primaries).
    public func totalKeys() async throws -> Int {
        var total = 0
        for node in try await session.nodes(role: .primary) {
            total += max(try await Self.nodeTotal(node, dbIndex: session.effectiveDB) ?? 0, 0)
        }
        return total
    }

    // MARK: - Standalone

    private func standaloneScan(_ request: ScanRequest, match: String, node: NodeClient, threshold: Int,
                                state previous: KeyScanState?) async throws -> KeyScanState {
        var state = previous ?? KeyScanState()
        if previous != nil, previous?.isComplete == true { return previous ?? state }
        let db = session.effectiveDB
        async let pendingTotal = try? Self.nodeTotal(node, dbIndex: db)
        var cursor: UInt64 = 0
        if let previous, case .standalone(let c) = previous.cursor { cursor = c }

        let count = min(Self.maxStandaloneCount, max(request.count, 1))
        var found: [Data] = []
        var scannedNow = 0
        var done = false
        // A DBSIZE of 0 still scans: some non-standard servers report 0 while holding keys.
        while !done && found.count < request.count && scannedNow < threshold {
            let page = try await Self.scanPage(node, cursor: cursor, match: match, count: count, type: request.type)
            cursor = page.cursor
            scannedNow += count
            found += page.keys
            done = cursor == 0
            if Task.isCancelled { break }
        }

        let total = await pendingTotal
        reportKeyCount(total)

        var shard = state.shards["standalone"] ?? ScanShardState()
        shard.cursor = cursor
        shard.scanned += scannedNow
        var resolvedTotal = total
        if let t = total, t >= 0 {
            if shard.scanned > t || cursor == 0 { shard.scanned = t }
            if t == 0 && (cursor > 0 || !found.isEmpty) { resolvedTotal = nil }
        } else {
            resolvedTotal = nil
        }

        shard.total = resolvedTotal
        state.shards["standalone"] = shard
        state.total = resolvedTotal
        state.scanned = shard.scanned
        state.cursor = .standalone(cursor)
        state.hasStarted = true
        state.lastRefreshTime = Date()
        append(found, type: request.type, to: &state)
        return state
    }

    // MARK: - Cluster

    private func clusterScan(_ request: ScanRequest, match: String, nodes: [NodeClient], threshold: Int,
                             state previous: KeyScanState?) async throws -> KeyScanState {
        var state = previous ?? KeyScanState()
        var cursors: [RedisEndpoint: UInt64] = [:]
        if let previous, case .cluster(let map) = previous.cursor { cursors = map }
        var shards = state.shards
        let db = session.effectiveDB

        let totals = await withTaskGroup(of: (RedisEndpoint, Int?).self) { group in
            for node in nodes {
                group.addTask { (node.endpoint, try? await Self.nodeTotal(node, dbIndex: db)) }
            }

            var out: [RedisEndpoint: Int?] = [:]
            for await (endpoint, total) in group { out[endpoint] = total }
            return out
        }
        reportKeyCount(totals.values.reduce(0) { $0 + max($1 ?? 0, 0) })
        for node in nodes {
            var shard = shards[node.endpoint.description] ?? ScanShardState(endpoint: node.endpoint)
            shard.total = totals[node.endpoint] ?? nil
            if previous == nil { shard.scanned = 0 }
            shard.cursor = cursors[node.endpoint] ?? 0
            shards[node.endpoint.description] = shard
        }

        // An unfinished scan starts a node missing from its cursors (a new primary after a failover) from cursor 0.
        // A DBSIZE of 0 still scans once: some servers report 0 while holding keys.
        let resumable = previous.map { !$0.cursor.isComplete } ?? true
        var pendingFirstPage = Set(nodes.map(\.endpoint).filter { previous == nil || (resumable && cursors[$0] == nil) })

        func isFinished(_ node: NodeClient) -> Bool {
            guard let shard = shards[node.endpoint.description] else { return true }
            return shard.cursor == 0 && !pendingFirstPage.contains(node.endpoint)
        }

        var found: [Data] = []
        var scannedNow: [RedisEndpoint: Int] = [:]
        while true {
            let active = nodes.filter { !isFinished($0) }
            if active.isEmpty { break }
            let sumScanned = scannedNow.values.reduce(0, +)
            let sumTotal = shards.values.reduce(0) { $0 + max($1.total ?? 0, 0) }
            let anyCursor = active.contains { (shards[$0.endpoint.description]?.cursor ?? 0) != 0 }
            if found.count >= request.count { break }
            if !((sumTotal < threshold && anyCursor) || sumScanned < threshold) { break }
            let count = max(request.count, 1)
            let pages = try await withThrowingTaskGroup(of: (RedisEndpoint, ScanPage).self) { group in
                for node in active {
                    let cursor = shards[node.endpoint.description]?.cursor ?? 0
                    group.addTask {
                        (node.endpoint, try await Self.scanPage(node, cursor: cursor, match: match, count: count, type: request.type))
                    }
                }

                var out: [(RedisEndpoint, ScanPage)] = []
                for try await item in group { out.append(item) }
                return out
            }
            for (endpoint, page) in pages {
                pendingFirstPage.remove(endpoint)
                var shard = shards[endpoint.description] ?? ScanShardState(endpoint: endpoint)
                shard.cursor = page.cursor
                shard.scanned += count
                scannedNow[endpoint, default: 0] += count
                if let total = shard.total, total >= 0, shard.scanned > total || page.cursor == 0 {
                    shard.scanned = total
                }

                shards[endpoint.description] = shard
                found += page.keys
            }

            if Task.isCancelled { break }
        }

        var nextCursors: [RedisEndpoint: UInt64] = [:]
        for node in nodes { nextCursors[node.endpoint] = shards[node.endpoint.description]?.cursor ?? 0 }
        state.shards = shards
        let nodeTotals = nodes.map { shards[$0.endpoint.description]?.total ?? nil }
        state.total = nodeTotals.contains { $0 == nil || ($0 ?? 0) < 0 } ? nil : nodeTotals.reduce(0) { $0 + ($1 ?? 0) }
        state.scanned = nodes.reduce(0) { $0 + (shards[$1.endpoint.description]?.scanned ?? 0) }
        state.cursor = .cluster(nextCursors)
        state.hasStarted = true
        state.lastRefreshTime = Date()
        append(found, type: request.type, to: &state)
        return state
    }

    // MARK: - Exact

    private func exactScan(name: Data, request: ScanRequest) async throws -> KeyScanState {
        let item = try await exactKey(name, type: request.type)
        let total = try? await totalKeys()
        var state = KeyScanState(keys: item.map { [$0] } ?? [], total: total, scanned: total ?? 1, cursor: .start,
                                 lastRefreshTime: Date(), hasStarted: true)
        if session.isCluster { state.cursor = .cluster([:]) }
        return state
    }

    // MARK: - Helpers

    /// Live tip: more than a million keys suggests shorter key names.
    nonisolated static let smallerKeysThreshold = 1_000_000

    private func reportKeyCount(_ total: Int?) {
        if let total, total > Self.smallerKeysThreshold { session.liveTips.report(.useSmallerKeys) }
    }

    private func append(_ found: [Data], type: KeyType?, to state: inout KeyScanState) {
        var seen = Set(state.keys.map(\.name))
        for name in found where seen.insert(name).inserted {
            state.keys.append(KeyListItem(name: name, type: type))
        }
    }

    struct ScanPage: Sendable {
        var cursor: UInt64
        var keys: [Data]
    }

    nonisolated static func scanPage(_ node: NodeClient, cursor: UInt64, match: String, count: Int,
                                     type: KeyType?) async throws -> ScanPage {
        var args: [RedisArgument] = ["SCAN", .string(String(cursor)), "MATCH", .data(KeyPattern.matchBytes(match)),
                                     "COUNT", .int(Int64(count))]
        if let type { args += ["TYPE", .string(type.rawValue)] }
        let reply: RESPValue
        do {
            reply = try await node.execute(args)
        } catch let error as RedisClientError {
            if type != nil, let message = error.serverError?.message.lowercased(), message.contains("syntax") {
                throw KeyScanError.typeFilterUnsupported
            }

            throw error
        }

        guard let items = reply.arrayValue, items.count == 2, let next = items[0].stringValue.flatMap({ UInt64($0) }) else {
            throw RedisClientError.protocolError("Unexpected SCAN reply")
        }
        return ScanPage(cursor: next, keys: (items[1].arrayValue ?? []).compactMap(\.dataValue))
    }

    /// `DBSIZE`, falling back to `INFO keyspace` (`db<N>:keys=`; missing -> 0). Nil when both fail.
    nonisolated static func nodeTotal(_ node: NodeClient, dbIndex: Int) async throws -> Int? {
        if let reply = try? await node.execute(["DBSIZE"]), let n = reply.intValue { return Int(n) }
        let info = try await DatabaseInfoService(client: node.client).info(section: "keyspace")
        return info.keyspace[dbIndex]?.keys ?? 0
    }
}
