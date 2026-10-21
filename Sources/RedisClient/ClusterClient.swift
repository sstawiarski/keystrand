import Foundation
import RESP

/// CRC16-based hash-slot computation, honoring `{hash tags}`.
public enum ClusterSlot {
    public static let count = 16_384

    public static func slot(for key: Data) -> Int {
        key.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var hashed = bytes[...]
            if let open = bytes.firstIndex(of: UInt8(ascii: "{")),
               let close = bytes[(open + 1)...].firstIndex(of: UInt8(ascii: "}")),
               close > open + 1 {
                hashed = bytes[(open + 1)..<close]
            }

            return Int(crc16(hashed) % UInt16(count))
        }
    }

    public static func slot(for key: String) -> Int { slot(for: Data(key.utf8)) }

    static func crc16<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }

        return crc
    }
}

/// Where the first key of a command is, for slot routing.
public enum ClusterKeyLocator {
    private static let keyless: Set<String> = [
        "PING", "ECHO", "INFO", "DBSIZE", "KEYS", "SCAN", "RANDOMKEY", "FLUSHDB", "FLUSHALL", "CONFIG", "CLIENT",
        "CLUSTER", "COMMAND", "TIME", "LASTSAVE", "SAVE", "BGSAVE", "BGREWRITEAOF", "SLOWLOG", "LATENCY", "MODULE",
        "ACL", "AUTH", "HELLO", "SELECT", "SCRIPT", "FUNCTION", "PUBLISH", "PUBSUB", "MONITOR", "SUBSCRIBE",
        "PSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE", "MULTI", "EXEC", "DISCARD", "UNWATCH", "WAIT", "WAITAOF",
        "READONLY", "READWRITE", "ROLE", "SWAPDB", "LOLWUT", "RESET", "QUIT", "SHUTDOWN", "REPLICAOF", "SLAVEOF",
        "DEBUG", "FAILOVER", "MEMORY", "OBJECT", "XINFO", "XGROUP",
    ]
    private static let numkeysAtOne: Set<String> = [
        "ZUNION", "ZINTER", "ZDIFF", "SINTERCARD", "ZINTERCARD", "LMPOP", "ZMPOP",
    ]
    private static let numkeysAtTwo: Set<String> = [
        "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO", "BLMPOP", "BZMPOP",
        "ZUNIONSTORE", "ZINTERSTORE", "ZDIFFSTORE",
    ]

    /// Index of the first key argument, or nil for keyless commands.
    public static func keyIndex(_ args: [Data]) -> Int? {
        guard let first = args.first else { return nil }
        let name = String(decoding: first, as: UTF8.self).uppercased()
        func upper(_ i: Int) -> String? { i < args.count ? String(decoding: args[i], as: UTF8.self).uppercased() : nil }

        switch name {
        case "BITOP", "PFDEBUG":
            return args.count > 2 ? 2 : nil
        case "MIGRATE":
            return args.count > 3 && !args[3].isEmpty ? 3 : nil
        case "XREAD", "XREADGROUP":
            guard let streams = (1..<args.count).first(where: { upper($0) == "STREAMS" }) else { return nil }
            return streams + 1 < args.count ? streams + 1 : nil
        case "MEMORY":
            return upper(1) == "USAGE" && args.count > 2 ? 2 : nil
        case "OBJECT", "XINFO", "XGROUP":
            guard args.count > 2, let sub = upper(1), sub != "HELP" else { return nil }
            if name == "XGROUP" && sub == "HELP" { return nil }
            return 2
        case "SPUBLISH", "SSUBSCRIBE", "SUNSUBSCRIBE":
            return args.count > 1 ? 1 : nil
        default:
            break
        }

        if name.hasPrefix("FT.") || name.hasPrefix("_FT.") { return nil }
        if keyless.contains(name) { return nil }
        if numkeysAtOne.contains(name) {
            guard let n = upper(1).flatMap(Int.init), n > 0, args.count > 2 else { return nil }
            return 2
        }

        if numkeysAtTwo.contains(name) {
            if ["ZUNIONSTORE", "ZINTERSTORE", "ZDIFFSTORE"].contains(name) { return args.count > 1 ? 1 : nil }
            guard let n = upper(2).flatMap(Int.init), n > 0, args.count > 3 else { return nil }
            return 3
        }

        return args.count > 1 ? 1 : nil
    }
}

/// A `MOVED`/`ASK` redirect parsed from an error reply.
public enum ClusterRedirect: Hashable, Sendable {
    case moved(slot: Int, endpoint: RedisEndpoint)
    case ask(slot: Int, endpoint: RedisEndpoint)

    /// `defaultHost` replaces an empty host (`MOVED 3999 :6381`).
    public init?(_ error: RESPError, defaultHost: String) {
        let parts = error.message.split(separator: " ")
        guard parts.count >= 3, let slot = Int(parts[1]), (0..<ClusterSlot.count).contains(slot) else { return nil }
        let address = String(parts[2])
        guard let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { return nil }
        var host = String(address[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.isEmpty { host = defaultHost }
        let endpoint = RedisEndpoint(host: host, port: port)
        switch parts[0] {
        case "MOVED": self = .moved(slot: slot, endpoint: endpoint)
        case "ASK": self = .ask(slot: slot, endpoint: endpoint)
        default: return nil
        }
    }

    public var endpoint: RedisEndpoint {
        switch self {
        case .moved(_, let e), .ask(_, let e): return e
        }
    }
}

/// Parses `CLUSTER SLOTS` / `CLUSTER SHARDS` replies into nodes.
public enum ClusterTopologyParser {
    private static func slotRange(_ start: Int, _ end: Int) -> ClosedRange<Int>? {
        let lo = max(0, start), hi = min(ClusterSlot.count - 1, end)
        return lo <= hi ? lo...hi : nil
    }

    public static func parseSlots(_ reply: RESPValue, seedHost: String) -> [ClusterNode] {
        var order: [String] = []
        var nodes: [String: ClusterNode] = [:]
        for range in reply.arrayValue ?? [] {
            guard let items = range.arrayValue, items.count >= 3,
                  let start = items[0].intValue, let end = items[1].intValue,
                  let slots = slotRange(Int(start), Int(end)) else { continue }
            var primaryID: String?
            for (index, entry) in items[2...].enumerated() {
                guard let fields = entry.arrayValue, fields.count >= 2, let port = fields[1].intValue else { continue }
                var host = fields[0].stringValue ?? ""
                if host == "?" { continue }
                if host.isEmpty { host = seedHost }
                let endpoint = RedisEndpoint(host: host, port: Int(port))
                let id = fields.count > 2 ? (fields[2].stringValue ?? endpoint.description) : endpoint.description
                let isPrimary = index == 0
                if isPrimary { primaryID = id }
                if var existing = nodes[id] {
                    if isPrimary { existing.slots.append(slots) }
                    nodes[id] = existing
                } else {
                    order.append(id)
                    nodes[id] = ClusterNode(id: id, endpoint: endpoint, role: isPrimary ? .primary : .replica,
                                            primaryID: isPrimary ? nil : primaryID,
                                            slots: isPrimary ? [slots] : [],
                                            flags: [isPrimary ? "master" : "slave"])
                }
            }
        }

        return order.compactMap { nodes[$0] }.map { node in
            var sorted = node
            sorted.slots.sort { $0.lowerBound < $1.lowerBound }
            return sorted
        }
    }

    /// `tls` picks `tls-port` over `port` when a node advertises both; the other one is the fallback.
    public static func parseShards(_ reply: RESPValue, seedHost: String, tls: Bool) -> [ClusterNode] {
        var out: [ClusterNode] = []
        for shard in reply.arrayValue ?? [] {
            guard let fields = shard.stringKeyedMap else { continue }
            let bounds = (fields["slots"]?.arrayValue ?? []).compactMap { $0.intValue.map(Int.init) }
            var ranges: [ClosedRange<Int>] = []
            var i = 0
            while i + 1 < bounds.count {
                if let range = slotRange(bounds[i], bounds[i + 1]) { ranges.append(range) }
                i += 2
            }

            var shardNodes: [ClusterNode] = []
            for entry in fields["nodes"]?.arrayValue ?? [] {
                guard let node = entry.stringKeyedMap else { continue }
                let id = node["id"]?.stringValue ?? ""
                var host = node["endpoint"]?.stringValue ?? ""
                if host.isEmpty || host == "?" { host = node["ip"]?.stringValue ?? "" }
                if host.isEmpty || host == "?" { host = seedHost }
                let plainPort = validPort(node["port"]), tlsPort = validPort(node["tls-port"])
                guard let port = tls ? (tlsPort ?? plainPort) : (plainPort ?? tlsPort) else { continue }
                let role: NodeRole = node["role"]?.stringValue == "master" ? .primary : .replica
                let health = node["health"]?.stringValue ?? "online"
                shardNodes.append(ClusterNode(id: id.isEmpty ? "\(host):\(port)" : id,
                                              endpoint: RedisEndpoint(host: host, port: port), role: role,
                                              slots: role == .primary ? ranges : [],
                                              flags: [role == .primary ? "master" : "slave", health]))
            }

            let primaryID = shardNodes.first { $0.role == .primary }?.id
            for var node in shardNodes {
                if node.role == .replica { node.primaryID = primaryID }
                out.append(node)
            }
        }

        return out
    }

    /// Redis reports a port it does not listen on as 0.
    private static func validPort(_ value: RESPValue?) -> Int? {
        guard let port = value?.intValue, (1...65_535).contains(port) else { return nil }
        return Int(port)
    }
}

/// Opens one node client for a cluster (connected, on `config.dbIndex`).
public typealias ClusterNodeClientFactory = @Sendable (RedisConnectionConfig) async throws -> any RedisClient

/// Discovers CLUSTER SLOTS/SHARDS topology and routes single-key commands through one connection per node.
/// Follows MOVED/ASK up to `maxRedirections` and refreshes slots every `slotsRefreshInterval`.
/// `natMap` rewrites announced addresses; nodes absent from a nonempty map are unavailable.
/// Every node handshake, including after MOVED/ASK, selects `nodeConfig.dbIndex`.
/// Only Valkey 9 clusters with `cluster-databases` above 1 accept a database other than 0.
public actor ClusterClient: RedisClient {
    public let seeds: [RedisEndpoint]
    public let nodeConfig: RedisConnectionConfig
    public let natMap: [RedisEndpoint: RedisEndpoint]
    public let maxRedirections: Int
    public let slotsRefreshInterval: TimeInterval
    /// Overrides the built-in key position table (e.g. from command specs). Return nil to fall back.
    public let keyLocator: (@Sendable ([Data]) -> Int?)?

    private let makeNodeClient: ClusterNodeClientFactory
    private var topology: [ClusterNode] = []
    private var slotOwners: [RedisEndpoint?] = Array(repeating: nil, count: ClusterSlot.count)
    private var clients: [RedisEndpoint: any RedisClient] = [:]
    /// Keeps replaced clients open until the cluster closes because running scans may still hold them.
    private var retired: [WeakClient] = []
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Error>?
    private var tunnels: ClusterSSHTunnels?
    private var isClosed = false

    public init(seeds: [RedisEndpoint], nodeConfig: RedisConnectionConfig,
                natMap: [RedisEndpoint: RedisEndpoint] = [:], maxRedirections: Int = 3,
                slotsRefreshInterval: TimeInterval = 5, keyLocator: (@Sendable ([Data]) -> Int?)? = nil) {
        self.init(seeds: seeds, nodeConfig: nodeConfig, natMap: natMap, maxRedirections: maxRedirections,
                  slotsRefreshInterval: slotsRefreshInterval, keyLocator: keyLocator,
                  nodeClientFactory: { config in try await RedisConnection.connect(config: config) })
    }

    /// Creates a cluster client with an injected node client factory.
    public init(seeds: [RedisEndpoint], nodeConfig: RedisConnectionConfig,
                natMap: [RedisEndpoint: RedisEndpoint] = [:], maxRedirections: Int = 3,
                slotsRefreshInterval: TimeInterval = 5, keyLocator: (@Sendable ([Data]) -> Int?)? = nil,
                nodeClientFactory: @escaping ClusterNodeClientFactory) {
        self.seeds = seeds
        self.nodeConfig = nodeConfig
        self.natMap = natMap
        self.maxRedirections = maxRedirections
        self.slotsRefreshInterval = slotsRefreshInterval
        self.keyLocator = keyLocator
        self.makeNodeClient = nodeClientFactory
    }

    public func connect() async throws {
        try await refreshTopology()
    }

    func attach(tunnels: ClusterSSHTunnels) {
        self.tunnels = tunnels
    }

    // MARK: - RedisClient

    /// Routes by the first key argument (`args[1]` unless the command spec says otherwise);
    /// keyless commands go to any primary.
    public func execute(_ args: [RedisArgument]) async throws -> RESPValue {
        let reply = try await send(args.map(\.data))
        if case .error(let e) = reply { throw RedisClientError.server(e) }
        return reply
    }

    /// Groups commands by slot owner, runs one pipeline per node, and returns replies in input order.
    /// Commands answered with `MOVED` are regrouped by their new owner after one topology refresh.
    public func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        try await ensureTopology()
        let raw = commands.map { $0.map(\.data) }
        var replies = [RESPValue](repeating: .null, count: raw.count)
        let allFailed = try await runGrouped(Array(raw.indices), commands: commands, raw: raw, into: &replies)
        if allFailed.failed, let error = allFailed.error { throw error }

        var moved: [Int] = []
        for index in raw.indices {
            guard case .error(let e) = replies[index], e.code == "MOVED", let asked = try? route(raw[index]),
                  case .moved(let slot, let endpoint)? = ClusterRedirect(e, defaultHost: asked.host) else { continue }
            learnOwner(slot: slot, endpoint: endpoint)
            moved.append(index)
        }

        if !moved.isEmpty {
            try? await refreshTopology()
            _ = try await runGrouped(moved, commands: commands, raw: raw, into: &replies)
        }

        // Retries only redirects, TRYAGAIN and CLUSTERDOWN because the server did not execute those commands.
        for index in raw.indices {
            if case .error(let e) = replies[index], Self.isRetryableServerError(e) {
                replies[index] = try await send(raw[index])
            }
        }

        return replies
    }

    /// Pipelines `indices` by slot owner and writes replies in place.
    /// Drops nodes whose batches fail and fills their replies with errors; `failed` is true if every node fails.
    private func runGrouped(_ indices: [Int], commands: [[RedisArgument]], raw: [[Data]],
                            into replies: inout [RESPValue]) async throws -> (failed: Bool, error: Error?) {
        var groups: [RedisEndpoint: [Int]] = [:]
        for index in indices {
            groups[try route(raw[index]), default: []].append(index)
        }

        var targets: [(RedisEndpoint, any RedisClient, [Int])] = []
        for (endpoint, group) in groups {
            targets.append((endpoint, try await client(for: endpoint), group))
        }

        var failedEndpoints: [RedisEndpoint] = []
        var firstFailure: Error?
        await withTaskGroup(of: (RedisEndpoint, [Int], Result<[RESPValue], Error>).self) { group in
            for (endpoint, client, batchIndices) in targets {
                let batch = batchIndices.map { commands[$0] }
                group.addTask {
                    do {
                        return (endpoint, batchIndices, .success(try await client.pipeline(batch)))
                    } catch {
                        return (endpoint, batchIndices, .failure(error))
                    }
                }
            }

            for await (endpoint, batchIndices, result) in group {
                switch result {
                case .success(let values):
                    for (offset, index) in batchIndices.enumerated() where offset < values.count { replies[index] = values[offset] }
                case .failure(let error):
                    // Never resends a failed batch because the node may have executed commands before the socket dropped.
                    failedEndpoints.append(endpoint)
                    if firstFailure == nil { firstFailure = error }
                    let reply = RESPValue.error(RESPError("ERR " + error.localizedDescription))
                    for index in batchIndices { replies[index] = reply }
                }
            }
        }
        if !failedEndpoints.isEmpty {
            for endpoint in failedEndpoints { dropClient(endpoint) }
            try? await refreshTopology()
        }
        return (!failedEndpoints.isEmpty && failedEndpoints.count == targets.count, firstFailure)
    }

    public func close() async {
        isClosed = true
        refreshTask?.cancel()
        let all = Array(clients.values) + retired.compactMap(\.client)
        clients.removeAll()
        retired.removeAll()
        for client in all { await client.close() }
        let ownTunnels = tunnels
        tunnels = nil
        await ownTunnels?.stopAll()
    }

    // MARK: - Nodes

    /// Current topology; `role == nil` returns every node.
    public func nodes(role: NodeRole? = nil) async throws -> [ClusterNode] {
        try await ensureTopology()
        guard let role else { return topology }
        return topology.filter { $0.role == role }
    }

    /// The pooled connection for one node (announced address; NAT mapping applied internally).
    public func connection(for node: RedisEndpoint) async throws -> RedisConnection {
        guard let connection = try await client(for: node) as? RedisConnection else {
            throw RedisClientError.invalidConfiguration("Node \(node) is not backed by a RedisConnection.")
        }
        return connection
    }

    /// Returns the pooled node client, including injected clients.
    public func client(for node: RedisEndpoint) async throws -> any RedisClient {
        if isClosed { throw RedisClientError.notConnected }
        if let existing = clients[node] { return existing }
        let physical = try physicalEndpoint(node)
        let client = try await makeNodeClient(nodeConfig.with(endpoint: physical))
        if isClosed {
            await client.close()
            throw RedisClientError.notConnected
        }

        if let raced = clients[node] {
            await client.close()
            return raced
        }

        clients[node] = client
        return client
    }

    /// Runs one command on a specific node (no redirects). Error replies come back in place.
    public func send(_ args: [RedisArgument], to node: RedisEndpoint) async throws -> RESPValue {
        let client = try await client(for: node)
        return try await client.pipeline([args]).first ?? .null
    }

    /// Runs `body` on every primary concurrently and returns results keyed by node.
    public func forEachPrimary<T: Sendable>(
        _ body: @escaping @Sendable (RedisConnection) async throws -> T
    ) async throws -> [RedisEndpoint: T] {
        var connections: [(RedisEndpoint, RedisConnection)] = []
        for node in try await nodes(role: .primary) {
            connections.append((node.endpoint, try await connection(for: node.endpoint)))
        }
        return try await withThrowingTaskGroup(of: (RedisEndpoint, T).self) { group in
            for (endpoint, connection) in connections {
                group.addTask { (endpoint, try await body(connection)) }
            }

            var out: [RedisEndpoint: T] = [:]
            for try await (endpoint, value) in group { out[endpoint] = value }
            return out
        }
    }

    /// Full `SCAN` of every primary (`MATCH`/`COUNT`/`TYPE`), keys keyed by node. Stops a node at `limitPerNode`.
    public func scanAllMasters(match: Data? = nil, count: Int = 1000, type: String? = nil,
                               limitPerNode: Int = .max) async throws -> [RedisEndpoint: [Data]] {
        var out: [RedisEndpoint: [Data]] = [:]
        for node in try await nodes(role: .primary) {
            let client = try await client(for: node.endpoint)
            var cursor = Data("0".utf8)
            var keys: [Data] = []
            repeat {
                var args: [RedisArgument] = ["SCAN", .data(cursor)]
                if let match { args += ["MATCH", .data(match)] }
                args += ["COUNT", .int(Int64(count))]
                if let type { args += ["TYPE", .string(type)] }
                let reply = try await client.execute(args)
                guard let items = reply.arrayValue, items.count == 2, let next = items[0].dataValue else {
                    throw RedisClientError.protocolError("Unexpected SCAN reply")
                }
                keys += (items[1].arrayValue ?? []).compactMap(\.dataValue)
                cursor = next
            } while cursor != Data("0".utf8) && keys.count < limitPerNode

            out[node.endpoint] = keys
        }
        return out
    }

    /// Slot owner for `key` according to the current topology.
    public func owner(ofKey key: Data) async throws -> RedisEndpoint? {
        try await ensureTopology()
        return slotOwners[ClusterSlot.slot(for: key)]
    }

    // MARK: - Topology

    private func ensureTopology() async throws {
        if topology.isEmpty { try await refreshTopology() }
    }

    /// Reloads the topology from any reachable node (known primaries first, then seeds).
    public func refreshTopology() async throws {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.loadTopology() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func loadTopology() async throws {
        var candidates: [RedisEndpoint] = topology.filter { $0.role == .primary }.map(\.endpoint)
        for seed in seeds where !candidates.contains(seed) { candidates.append(seed) }
        guard !candidates.isEmpty else { throw RedisClientError.invalidConfiguration("No cluster seed nodes.") }
        var lastError: Error = RedisClientError.clusterNodeUnavailable(candidates[0])
        for candidate in candidates {
            do {
                let client = try await client(for: candidate)
                var nodes: [ClusterNode] = []
                let slots = try await client.pipeline([["CLUSTER", "SLOTS"]])[0]
                if case .error(let e) = slots {
                    let shards = try await client.pipeline([["CLUSTER", "SHARDS"]])[0]
                    if case .error(let shardsError) = shards {
                        // Without CLUSTER permission, routes every slot to the seed and learns owners from MOVED replies.
                        guard e.code == "NOPERM" || shardsError.code == "NOPERM" else { throw RedisClientError.server(e) }
                    } else {
                        nodes = ClusterTopologyParser.parseShards(shards, seedHost: candidate.host, tls: nodeConfig.tls != nil)
                    }
                } else {
                    nodes = ClusterTopologyParser.parseSlots(slots, seedHost: candidate.host)
                }

                if nodes.isEmpty {
                    nodes = [ClusterNode(id: candidate.description, endpoint: candidate, role: .primary,
                                         slots: [0...(ClusterSlot.count - 1)], flags: ["master"])]
                }

                apply(nodes)
                return
            } catch let error as RedisClientError {
                lastError = error
                if case .server = error { throw error }
                dropClient(candidate)
            } catch {
                lastError = error
                dropClient(candidate)
            }
        }

        throw lastError
    }

    private func apply(_ nodes: [ClusterNode]) {
        topology = nodes
        var owners = [RedisEndpoint?](repeating: nil, count: ClusterSlot.count)
        for node in nodes where node.role == .primary {
            for range in node.slots {
                let lo = max(0, range.lowerBound), hi = min(ClusterSlot.count - 1, range.upperBound)
                guard lo <= hi else { continue }
                for slot in lo...hi {
                    owners[slot] = node.endpoint
                }
            }
        }

        slotOwners = owners
        lastRefresh = Date()
    }

    /// Applies a `MOVED` redirect to the slot table before the next topology refresh.
    private func learnOwner(slot: Int, endpoint: RedisEndpoint) {
        slotOwners[slot] = endpoint
        if !topology.contains(where: { $0.endpoint == endpoint }) {
            topology.append(ClusterNode(id: endpoint.description, endpoint: endpoint, role: .primary,
                                        slots: [slot...slot], flags: ["master"]))
        }
    }

    private func scheduleRefreshIfStale() {
        guard refreshTask == nil else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < slotsRefreshInterval { return }
        Task { try? await self.refreshTopology() }
    }

    private func physicalEndpoint(_ announced: RedisEndpoint) throws -> RedisEndpoint {
        if natMap.isEmpty { return announced }
        if let mapped = natMap[announced] { return mapped }
        if natMap.values.contains(announced) { return announced }
        throw RedisClientError.clusterNodeUnavailable(announced)
    }

    /// Removes the client so the next command opens a fresh one.
    /// Keeps it open for existing holders, whose next command reconnects the already-dropped socket.
    private func dropClient(_ endpoint: RedisEndpoint) {
        guard let client = clients.removeValue(forKey: endpoint) else { return }
        retired.removeAll { $0.client == nil }
        retired.append(WeakClient(client: client))
    }

    // MARK: - Routing

    private func keyIndex(_ args: [Data]) -> Int? {
        if let keyLocator, let index = keyLocator(args) { return index < args.count ? index : nil }
        return ClusterKeyLocator.keyIndex(args)
    }

    private func anyPrimary() throws -> RedisEndpoint {
        if let primary = topology.first(where: { $0.role == .primary && !$0.slots.isEmpty }) ?? topology.first {
            return primary.endpoint
        }

        guard let seed = seeds.first else { throw RedisClientError.notConnected }
        return seed
    }

    private func route(_ args: [Data]) throws -> RedisEndpoint {
        if let index = keyIndex(args), let owner = slotOwners[ClusterSlot.slot(for: args[index])] { return owner }
        return try anyPrimary()
    }

    private static func isRetryableServerError(_ e: RESPError) -> Bool {
        switch e.code {
        case "MOVED", "ASK", "TRYAGAIN", "CLUSTERDOWN": return true
        default: return false
        }
    }

    /// Reconnects a dropped pooled node connection before sending.
    private func readyClient(for node: RedisEndpoint) async throws -> any RedisClient {
        let client = try await client(for: node)
        if let connection = client as? RedisConnection { try await connection.ensureConnected() }
        return client
    }

    /// Sends one command following redirects; error replies that are not redirects are returned in place.
    /// A transport failure before the command was written is retried once on a refreshed topology.
    private func send(_ args: [Data]) async throws -> RESPValue {
        try await ensureTopology()
        var target = try route(args)
        var asking = false
        var reconnected = false
        var attempts = 0
        while attempts <= maxRedirections {
            let reply: RESPValue
            var sendStarted = false
            do {
                let client = try await readyClient(for: target)
                sendStarted = true
                if asking {
                    let replies = try await client.pipeline([["ASKING"], args.redisArguments])
                    reply = replies.count > 1 ? replies[1] : .null
                } else {
                    reply = try await client.pipeline([args.redisArguments]).first ?? .null
                }
            } catch let error as RedisClientError {
                switch error {
                case .server:
                    throw error
                case .notConnected:
                    break
                default:
                    if sendStarted {
                        // Never resends because the node may have executed the command before the reply was lost.
                        dropClient(target)
                        try? await refreshTopology()
                        throw error
                    }
                }

                guard !reconnected else { throw error }
                reconnected = true
                dropClient(target)
                try await refreshTopology()
                target = try route(args)
                asking = false
                continue
            }

            guard case .error(let e) = reply, Self.isRetryableServerError(e) else { return reply }
            attempts += 1
            if let redirect = ClusterRedirect(e, defaultHost: target.host) {
                switch redirect {
                case .moved(let slot, let endpoint):
                    learnOwner(slot: slot, endpoint: endpoint)
                    scheduleRefreshIfStale()
                    target = endpoint
                    asking = false
                case .ask(_, let endpoint):
                    target = endpoint
                    asking = true
                }
            } else {
                if attempts > maxRedirections { return reply }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        throw RedisClientError.tooManyRedirections
    }
}

private struct WeakClient {
    weak var client: (any RedisClient)?
}
