import Foundation

/// Header metrics from INFO on every node. Keeps the previous CPU sample per database to compute CPU %.
public actor DatabaseOverviewService {
    struct CPUSample: Sendable {
        var cpu: Double
        var uptime: Double
    }

    private var previousCPU: [DatabaseID: [RedisEndpoint: CPUSample]] = [:]

    public init() {}

    /// `nodes` = every node of the database (standalone: one). Keys are counted for logical db `dbIndex`.
    public func overview(databaseID: DatabaseID, nodes: [NodeClient], dbIndex: Int) async throws -> DatabaseOverview {
        guard !nodes.isEmpty else { throw RedisClientError.notConnected }
        let isCluster = nodes.count > 1 || nodes.contains { $0.role == .replica }
        let samples = try await withThrowingTaskGroup(of: NodeSample.self) { group in
            for node in nodes {
                group.addTask { try await Self.sample(node, isCluster: isCluster, dbIndex: dbIndex) }
            }

            var out: [NodeSample] = []
            for try await sample in group { out.append(sample) }
            return out
        }
        var overview = Self.aggregate(samples, isCluster: isCluster, dbIndex: dbIndex)
        overview.cpuUsagePercentage = cpuUsage(databaseID: databaseID, samples: samples)
        return overview
    }

    public func reset(_ databaseID: DatabaseID) {
        previousCPU[databaseID] = nil
    }

    // MARK: - Sampling

    struct NodeSample: Sendable {
        var endpoint: RedisEndpoint
        var role: NodeRole
        var info: RedisInfo
        var dbSize: Int?
        var ioThreads: Int
    }

    static func sample(_ node: NodeClient, isCluster: Bool, dbIndex: Int) async throws -> NodeSample {
        var commands: [[RedisArgument]] = [["INFO"], ["CONFIG", "GET", "io-threads"]]
        if isCluster && node.role == .primary { commands.append(["DBSIZE"]) }
        let replies = try await node.pipeline(commands)
        guard let infoReply = replies.first, !infoReply.isError else {
            let info = try await DatabaseInfoService(client: node.client).info()
            return NodeSample(endpoint: node.endpoint, role: node.role, info: info, dbSize: nil, ioThreads: 1)
        }
        let info = ServerInfoParser.parse(DatabaseInfoService.text(infoReply))
        let ioThreads = replies.count > 1 ? DatabaseInfoService.configValue(replies[1]).flatMap(Int.init) ?? 1 : 1
        let dbSize = replies.count > 2 ? replies[2].intValue.map(Int.init) : nil
        return NodeSample(endpoint: node.endpoint, role: node.role, info: info, dbSize: dbSize, ioThreads: max(ioThreads, 1))
    }

    static func aggregate(_ samples: [NodeSample], isCluster: Bool, dbIndex: Int) -> DatabaseOverview {
        var overview = DatabaseOverview()
        let ordered = samples.sorted { $0.endpoint.description < $1.endpoint.description }
        let first = ordered.first { $0.role == .primary } ?? ordered.first
        overview.version = first?.info.serverVersion

        func sum(_ key: String, over nodes: [NodeSample]) -> Double? {
            var total = 0.0
            for node in nodes {
                guard let value = node.info.value(key).flatMap(Double.init) else { return nil }
                total += value
            }

            return total
        }

        let masters = samples.filter { sample in
            guard samples.count > 1 else { return true }
            let role = sample.info["replication"]?["role"]
            return role == nil || role == "master"
        }
        overview.usedMemory = sum("used_memory", over: masters).map { Int($0) }
        overview.opsPerSecond = sum("instantaneous_ops_per_sec", over: samples).map { Int($0) }
        overview.networkInKbps = sum("instantaneous_input_kbps", over: samples)
        overview.networkOutKbps = sum("instantaneous_output_kbps", over: samples)

        let clients = samples.compactMap { $0.info.value("connected_clients").flatMap(Double.init) }.sorted()
        if clients.count == samples.count, !clients.isEmpty {
            let mid = clients.count / 2
            overview.connectedClients = clients.count % 2 == 0 ? (clients[mid - 1] + clients[mid]) / 2 : clients[mid]
        }

        let primaries = samples.filter { $0.role == .primary }
        overview.maxCpuUsagePercentage = primaries.reduce(0) { $0 + $1.ioThreads } * 100

        if isCluster {
            var total = 0
            var known = true
            for node in primaries {
                if let size = node.dbSize { total += size } else if let keys = node.info.keyspace[dbIndex]?.keys {
                    total += keys
                } else if node.info["keyspace"] != nil {
                    continue
                } else {
                    known = false
                }
            }

            overview.totalKeys = known ? total : nil
        } else if let node = samples.first {
            let keyspace = node.info.keyspace
            let total = keyspace.values.reduce(0) { $0 + $1.keys }
            overview.totalKeys = total
            let current = keyspace[dbIndex]?.keys ?? 0
            if current != total { overview.totalKeysPerDb = ["db\(dbIndex)": current] }
        }

        return overview
    }

    /// `.some(nil)` on the first sample, nil when the server does not report CPU.
    private func cpuUsage(databaseID: DatabaseID, samples: [NodeSample]) -> Double?? {
        var current: [RedisEndpoint: CPUSample] = [:]
        for sample in samples {
            guard let sys = sample.info.value("used_cpu_sys").flatMap(Double.init),
                  let user = sample.info.value("used_cpu_user").flatMap(Double.init),
                  let uptime = sample.info.value("uptime_in_seconds").flatMap(Double.init) else {
                previousCPU[databaseID] = nil
                return nil
            }
            if sys == 0 {
                previousCPU[databaseID] = nil
                return nil
            }

            current[sample.endpoint] = CPUSample(cpu: sys + user, uptime: uptime)
        }

        defer { previousCPU[databaseID] = current }
        guard let previous = previousCPU[databaseID] else { return .some(nil) }
        var total = 0.0
        for (endpoint, now) in current {
            guard let before = previous[endpoint], now.uptime > before.uptime else { continue }
            let usage = (now.cpu - before.cpu) / (now.uptime - before.uptime) * 100
            if usage > 0 { total += usage }
        }

        return .some(total)
    }
}

/// `ACL CAT dangerous`, cached per database (lowercased names). NOPERM / unknown command -> cached empty set;
/// transient errors -> empty set, not cached.
public actor DangerousCommandsProvider {
    private var cache: [DatabaseID: Set<String>] = [:]

    public init() {}

    public func commands(for id: DatabaseID, client: any RedisClient) async -> Set<String> {
        if let cached = cache[id] { return cached }
        do {
            let reply = try await client.execute(["ACL", "CAT", "dangerous"])
            let names = Set((reply.arrayValue ?? []).compactMap { $0.stringValue?.lowercased() })
            cache[id] = names
            return names
        } catch let error as RedisClientError {
            if let server = error.serverError {
                let message = server.message.lowercased()
                if message.hasPrefix("noperm") || message.contains("unknown command") || message.contains("unknown subcommand") {
                    cache[id] = []
                }
            }

            return []
        } catch {
            return []
        }
    }

    public func invalidate(_ id: DatabaseID) {
        cache[id] = nil
    }
}
