import Foundation
import RedisCore

public enum ClusterNodeHealth: String, Hashable, Sendable {
    case online, offline, loading
}

public struct ClusterInfoSummary: Hashable, Sendable {
    public var state: String = "-"
    public var slotsAssigned = 0
    public var slotsOk = 0
    public var slotsPFail = 0
    public var slotsFail = 0
    public var slotsUnassigned = ClusterSlot.count
    public var statsMessagesSent = 0
    public var statsMessagesReceived = 0
    public var currentEpoch = 0
    public var myEpoch = 0
    public var size = 0
    public var knownNodes = 0

    public init() {}
}

/// One node from CLUSTER NODES / CLUSTER SHARDS.
public struct ClusterTopologyNode: Hashable, Sendable {
    public var id: String
    public var host: String
    public var port: Int
    public var role: NodeRole
    public var primaryID: String?
    public var health: ClusterNodeHealth
    public var slots: [String]

    public init(id: String, host: String, port: Int, role: NodeRole, primaryID: String? = nil,
                health: ClusterNodeHealth = .online, slots: [String] = []) {
        self.id = id
        self.host = host
        self.port = port
        self.role = role
        self.primaryID = primaryID
        self.health = health
        self.slots = slots
    }

    public var endpoint: String { "\(host):\(port)" }
}

public struct ClusterNodeMetrics: Hashable, Sendable {
    public var totalKeys = 0
    public var usedMemory = 0
    public var opsPerSecond = 0
    public var connectionsReceived = 0
    public var connectedClients = 0
    public var commandsProcessed = 0
    public var networkInKbps = 0.0
    public var networkOutKbps = 0.0
    public var cacheHitRatio: Double?
    public var replicationOffset = 0
    public var replicaOffset: Int?
    public var uptimeSec = 0
    /// `RedisInfo.serverVersion`.
    public var version: String?
    public var serverFlavor: ServerFlavor = .redis
    public var mode: String?

    public init() {}
}

public struct ClusterNodeDetails: Hashable, Sendable, Identifiable {
    public var node: ClusterTopologyNode
    public var metrics: ClusterNodeMetrics
    public var replicationLag: Int?
    public var replicas: [ClusterNodeDetails]?
    public var letter: String = ""
    public var index: Int = 0

    public var id: String { node.id.isEmpty ? node.endpoint : node.id }
    public var host: String { node.host }
    public var port: Int { node.port }
    public var endpoint: String { node.endpoint }
    public var isPrimary: Bool { node.role == .primary }
}

public struct ClusterDetails: Hashable, Sendable {
    public var version: String?
    public var serverFlavor: ServerFlavor = .redis
    public var mode: String?
    public var user: String?
    public var uptimeSec: Int
    public var info: ClusterInfoSummary
    /// Primaries (sorted by host, lettered A, B, ...) with their replicas.
    public var primaries: [ClusterNodeDetails]

    /// "Valkey 9.1.2" or "Redis 8.0.3"; nil when no node reported a version.
    public var versionText: String? { version.map { DatabaseCapabilities.displayName(flavor: serverFlavor, version: $0) } }
}

public enum ClusterDetailsError: Error, LocalizedError, Equatable {
    case notCluster

    public var errorDescription: String? {
        switch self {
        case .notCluster: return "This database isn't running in cluster mode."
        }
    }
}

public enum ClusterDetailsParser {
    /// `CLUSTER INFO` (`key:value` lines).
    public static func parseClusterInfo(_ text: String) -> ClusterInfoSummary {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        func int(_ key: String) -> Int { fields[key].flatMap { Int($0) } ?? 0 }
        var out = ClusterInfoSummary()
        out.state = fields["cluster_state"] ?? "-"
        out.slotsAssigned = int("cluster_slots_assigned")
        out.slotsOk = int("cluster_slots_ok")
        out.slotsPFail = int("cluster_slots_pfail")
        out.slotsFail = int("cluster_slots_fail")
        out.slotsUnassigned = ClusterSlot.count - out.slotsAssigned
        out.statsMessagesSent = int("cluster_stats_messages_sent")
        out.statsMessagesReceived = int("cluster_stats_messages_received")
        out.currentEpoch = int("cluster_current_epoch")
        out.myEpoch = int("cluster_my_epoch")
        out.size = int("cluster_size")
        out.knownNodes = int("cluster_known_nodes")
        return out
    }

    /// `CLUSTER NODES`: `id host:port@cport[,hostname] flags primaryId ping pong epoch link slots...`.
    public static func parseClusterNodes(_ text: String, seedHost: String) -> [ClusterTopologyNode] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 8 else { return nil }
            let address = parts[1].split(separator: "@").first.map(String.init) ?? parts[1]
            guard let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { return nil }
            var host = String(address[..<colon])
            if host.isEmpty { host = seedHost }
            let flags = parts[2].split(separator: ",").map(String.init)
            let primaryID = parts[3] == "-" ? nil : parts[3]
            let health: ClusterNodeHealth
            if flags.contains("fail") && !flags.contains("fail?") {
                health = .offline
            } else if flags.contains("master") || flags.contains("slave") {
                health = .online
            } else {
                health = .loading
            }

            let slots = parts.count > 8 ? parts[8...].filter { !$0.hasPrefix("[") } : []
            return ClusterTopologyNode(id: parts[0], host: host, port: port, role: primaryID == nil ? .primary : .replica,
                                       primaryID: primaryID, health: health, slots: Array(slots))
        }
    }

    /// `CLUSTER SHARDS`: `[["slots", [s, e, ...], "nodes", [[field, value, ...], ...]], ...]`.
    public static func parseClusterShards(_ reply: RESPValue, seedHost: String) -> [ClusterTopologyNode] {
        var out: [ClusterTopologyNode] = []
        for shard in reply.arrayValue ?? [] {
            guard let fields = shard.stringKeyedMap else { continue }
            let bounds = (fields["slots"]?.arrayValue ?? []).compactMap { $0.intValue.map(Int.init) }
            var slots: [String] = []
            var i = 0
            while i + 1 < bounds.count {
                slots.append(bounds[i] == bounds[i + 1] ? "\(bounds[i])" : "\(bounds[i])-\(bounds[i + 1])")
                i += 2
            }

            let nodes = (fields["nodes"]?.arrayValue ?? []).compactMap(\.stringKeyedMap)
            let primaryID = nodes.first { $0["role"]?.stringValue == "master" }?["id"]?.stringValue
            for node in nodes {
                let id = node["id"]?.stringValue ?? ""
                let endpoint = node["endpoint"]?.stringValue ?? ""
                let ip = node["ip"]?.stringValue ?? ""
                let host = (!endpoint.isEmpty && endpoint != "?") ? endpoint : (!ip.isEmpty ? ip : seedHost)
                let port = node["port"]?.intValue ?? node["tls-port"]?.intValue ?? 0
                let isPrimary = node["role"]?.stringValue == "master"
                let healthText = node["health"]?.stringValue ?? "online"
                out.append(ClusterTopologyNode(
                    id: id, host: host, port: Int(port), role: isPrimary ? .primary : .replica,
                    primaryID: isPrimary ? nil : primaryID, health: ClusterNodeHealth(rawValue: healthText) ?? .loading,
                    slots: isPrimary ? slots : []))
            }
        }

        return out
    }

    /// Per-node numbers from `INFO` (all sections).
    public static func metrics(from info: RedisInfo) -> ClusterNodeMetrics {
        func int(_ key: String) -> Int { info.value(key).flatMap { Int($0) } ?? 0 }
        func double(_ key: String) -> Double { info.value(key).flatMap { Double($0) } ?? 0 }
        var out = ClusterNodeMetrics()
        out.totalKeys = info.keyspace.values.reduce(0) { $0 + $1.keys }
        out.usedMemory = int("used_memory")
        out.opsPerSecond = int("instantaneous_ops_per_sec")
        out.connectionsReceived = int("total_connections_received")
        out.connectedClients = int("connected_clients")
        out.commandsProcessed = int("total_commands_processed")
        out.networkInKbps = double("instantaneous_input_kbps")
        out.networkOutKbps = double("instantaneous_output_kbps")
        let hits = double("keyspace_hits"), misses = double("keyspace_misses")
        out.cacheHitRatio = hits + misses > 0 ? hits / (hits + misses) : nil
        out.replicationOffset = int("master_repl_offset")
        out.replicaOffset = info.value("slave_repl_offset").flatMap { Int($0) }
        out.uptimeSec = int("uptime_in_seconds")
        out.version = info.serverVersion
        out.serverFlavor = info.serverFlavor
        out.mode = info.redisMode
        return out
    }

    /// `A`...`Z`, `AA`, `AB`, ...
    public static func letter(for index: Int) -> String {
        var n = index
        var out = ""
        repeat {
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            n = n / 26 - 1
        } while n >= 0

        return out
    }

    /// Joins topology with per-node metrics: primaries sorted by host:port, lettered, replicas nested.
    public static func assemble(topology: [ClusterTopologyNode], metrics: [String: ClusterNodeMetrics],
                                info: ClusterInfoSummary, user: String?) -> ClusterDetails {
        let primaries = topology.filter { $0.role == .primary }
            .sorted { ($0.host, $0.port) < ($1.host, $1.port) }
        var details: [ClusterNodeDetails] = []
        for (index, primary) in primaries.enumerated() {
            guard let primaryMetrics = metrics[primary.endpoint] else { continue }
            let replicas = topology
                .filter { $0.role == .replica && $0.primaryID == primary.id }
                .sorted { ($0.host, $0.port) < ($1.host, $1.port) }
                .compactMap { replica -> ClusterNodeDetails? in
                    guard let m = metrics[replica.endpoint] else { return nil }
                    let lag = m.replicaOffset.map { max(primaryMetrics.replicationOffset - $0, 0) }
                    return ClusterNodeDetails(node: replica, metrics: m, replicationLag: lag, replicas: nil,
                                              letter: "", index: index)
                }
            details.append(ClusterNodeDetails(node: primary, metrics: primaryMetrics, replicationLag: nil,
                                              replicas: replicas.isEmpty ? nil : replicas, letter: "", index: 0))
        }

        for i in details.indices {
            details[i].letter = letter(for: i)
            details[i].index = i
            if let replicas = details[i].replicas {
                details[i].replicas = replicas.map { var r = $0; r.letter = details[i].letter; r.index = i; return r }
            }
        }

        let first = details.first?.metrics
        return ClusterDetails(version: first?.version, serverFlavor: first?.serverFlavor ?? .redis, mode: first?.mode,
                              user: user, uptimeSec: details.map(\.metrics.uptimeSec).max() ?? 0, info: info,
                              primaries: details)
    }

    /// Index of the unique maximum (nil when empty or tied).
    public static func uniqueMaxIndex<T: Comparable>(_ values: [T]) -> Int? {
        guard let maxValue = values.max() else { return nil }
        let indices = values.indices.filter { values[$0] == maxValue }
        return indices.count == 1 ? indices.first : nil
    }
}

@MainActor
public struct ClusterDetailsService {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public func fetch() async throws -> ClusterDetails {
        guard session.isCluster else { throw ClusterDetailsError.notCluster }
        let seedHost = session.config.host
        let user = session.username
        let serverInfo = try await session.execute(["INFO", "server"])
        let version = ServerInfoParser.parse(serverInfo.stringValue ?? "").redisVersion ?? session.serverVersion ?? "0"
        let useShards = (RedisVersion(version)?.components.first ?? 0) >= 7
        let clusterInfoText = try await session.execute(["CLUSTER", "INFO"]).stringValue ?? ""
        var topology: [ClusterTopologyNode]
        if useShards, let shards = try? await session.execute(["CLUSTER", "SHARDS"]), !shards.isError {
            topology = ClusterDetailsParser.parseClusterShards(shards, seedHost: seedHost)
        } else {
            topology = []
        }

        if topology.isEmpty {
            let nodesText = try await session.execute(["CLUSTER", "NODES"]).stringValue ?? ""
            topology = ClusterDetailsParser.parseClusterNodes(nodesText, seedHost: seedHost)
        }

        let clients = try await session.nodes()
        let metrics = await Self.collectMetrics(topology: topology, clients: clients)
        return ClusterDetailsParser.assemble(topology: topology, metrics: metrics,
                                             info: ClusterDetailsParser.parseClusterInfo(clusterInfoText), user: user)
    }

    /// INFO for every topology node that has a matching connection (by host:port, else by unique port).
    nonisolated static func collectMetrics(topology: [ClusterTopologyNode], clients: [NodeClient]) async -> [String: ClusterNodeMetrics] {
        var out: [String: ClusterNodeMetrics] = [:]
        await withTaskGroup(of: (String, ClusterNodeMetrics?).self) { group in
            for node in topology {
                guard let client = match(node, clients: clients) else { continue }
                group.addTask {
                    guard let reply = try? await client.execute(["INFO"]), let text = reply.stringValue else { return (node.endpoint, nil) }
                    return (node.endpoint, ClusterDetailsParser.metrics(from: ServerInfoParser.parse(text)))
                }
            }

            for await (endpoint, metrics) in group {
                if let metrics { out[endpoint] = metrics }
            }
        }
        return out
    }

    nonisolated static func match(_ node: ClusterTopologyNode, clients: [NodeClient]) -> NodeClient? {
        if let exact = clients.first(where: { $0.endpoint.host == node.host && $0.endpoint.port == node.port }) { return exact }
        let byPort = clients.filter { $0.endpoint.port == node.port }
        return byPort.count == 1 ? byPort.first : nil
    }
}
