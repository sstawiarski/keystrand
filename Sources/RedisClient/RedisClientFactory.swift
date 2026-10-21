import Foundation
import RESP

public enum RedisTopology: Hashable, Sendable {
    case standalone(RedisEndpoint)
    case cluster(seeds: [RedisEndpoint])
    case sentinel(masterName: String, sentinels: [RedisEndpoint], sentinelUsername: String?, sentinelPassword: String?)
}

/// Resolved database connection settings, including secrets.
public struct RedisClientDescriptor: Hashable, Sendable {
    public var topology: RedisTopology
    /// Auth, TLS, db index, timeouts, client name. Host/port are replaced per node.
    public var connection: RedisConnectionConfig
    /// When set, every node connection goes through its own `SSHTunnel` (remote = node address).
    public var ssh: SSHTunnelOptions?
    /// Shell script run before connecting.
    public var preConnectScript: String?
    /// Skip cluster detection/routing even if the server is a cluster.
    public var forceStandalone: Bool
    /// Enables `connection.dbIndex` on cluster nodes only for servers supporting numbered databases, such as Valkey 9 `cluster-databases`.
    public var clusterDatabases: Bool

    public init(topology: RedisTopology, connection: RedisConnectionConfig, ssh: SSHTunnelOptions? = nil,
                preConnectScript: String? = nil, forceStandalone: Bool = false, clusterDatabases: Bool = false) {
        self.topology = topology
        self.connection = connection
        self.ssh = ssh
        self.preConnectScript = preConnectScript
        self.forceStandalone = forceStandalone
        self.clusterDatabases = clusterDatabases
    }
}

/// Creates a connected standalone connection, resolved Sentinel master connection or cluster client.
/// Closing the returned client stops its SSH tunnels.
public struct RedisClientFactory: Sendable {
    public var scriptRunner: ConnectionScriptRunner

    public init(scriptRunner: ConnectionScriptRunner = ConnectionScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    public func makeClient(_ descriptor: RedisClientDescriptor) async throws -> any RedisClient {
        try await runPreConnectScript(descriptor)
        switch descriptor.topology {
        case .standalone(let endpoint):
            return try await standalone(descriptor, endpoint: endpoint)
        case .cluster(let seeds):
            if descriptor.forceStandalone {
                return try await standalone(descriptor, endpoint: seeds.first ?? descriptor.connection.endpoint)
            }

            return try await cluster(descriptor, seeds: seeds.isEmpty ? [descriptor.connection.endpoint] : seeds)
        case .sentinel(let name, let sentinels, let username, let password):
            return try await sentinelMaster(descriptor, name: name, sentinels: sentinels, username: username, password: password)
        }
    }

    /// Creates an unpooled connection for Pub/Sub, MONITOR or CLI.
    /// `node` selects a cluster node; nil selects the standalone/Sentinel master or first cluster seed.
    public func makeDedicatedConnection(_ descriptor: RedisClientDescriptor,
                                        node: RedisEndpoint? = nil) async throws -> RedisConnection {
        try await runPreConnectScript(descriptor)
        switch descriptor.topology {
        case .standalone(let endpoint):
            return try await standalone(descriptor, endpoint: node ?? endpoint)
        case .cluster(let seeds):
            var config = descriptor
            if !descriptor.forceStandalone && !descriptor.clusterDatabases { config.connection.dbIndex = 0 }
            return try await standalone(config, endpoint: node ?? seeds.first ?? descriptor.connection.endpoint)
        case .sentinel(let name, let sentinels, let username, let password):
            if let node { return try await standalone(descriptor, endpoint: node) }
            return try await sentinelMaster(descriptor, name: name, sentinels: sentinels, username: username, password: password)
        }
    }

    /// Runs a database's post-disconnect script. Call it only after every connection opened for that work is closed.
    public func runPostDisconnectScript(_ script: String?) async throws {
        guard let script = ConnectionScriptRunner.runnable(script) else { return }
        try await scriptRunner.runOrThrow(script, kind: .postDisconnect)
    }

    // MARK: - Strategies

    private func runPreConnectScript(_ descriptor: RedisClientDescriptor) async throws {
        guard let script = ConnectionScriptRunner.runnable(descriptor.preConnectScript) else { return }
        try await scriptRunner.runOrThrow(script, kind: .preConnect)
    }

    /// Config for connecting through a local tunnel: SNI and certificate verification keep pointing at the real host.
    static func tunneledConfig(_ config: RedisConnectionConfig, local: RedisEndpoint) -> RedisConnectionConfig {
        var copy = config.with(endpoint: local)
        if var tls = copy.tls, tls.serverName?.isEmpty ?? true {
            if TLSOptionsBuilder.isDNSName(config.host) {
                tls.serverName = config.host
            } else if tls.verificationHost?.isEmpty ?? true {
                tls.verificationHost = config.host
            }

            copy.tls = tls
        }

        return copy
    }

    private func standalone(_ descriptor: RedisClientDescriptor, endpoint: RedisEndpoint) async throws -> RedisConnection {
        let config = descriptor.connection.with(endpoint: endpoint)
        guard let ssh = descriptor.ssh else {
            let connection = try await RedisConnection.connect(config: config)
            if ConnectionScriptRunner.runnable(descriptor.preConnectScript) != nil {
                await connection.setReconnectProvider { [self] in
                    try await runPreConnectScript(descriptor)
                    return config
                }
            }

            return connection
        }
        let tunnel = SSHTunnel(options: ssh.with(remote: endpoint))
        do {
            let port = try await tunnel.start()
            let connection = RedisConnection(config: Self.tunneledConfig(config, local: RedisEndpoint(host: "127.0.0.1", port: port)))
            await connection.attach(tunnels: [tunnel])
            try await connection.connectOwned()
            await connection.setReconnectProvider { [self] in
                try await runPreConnectScript(descriptor)
                let port = try await Self.restartIfNeeded(tunnel)
                return Self.tunneledConfig(config, local: RedisEndpoint(host: "127.0.0.1", port: port))
            }
            return connection
        } catch {
            await tunnel.stop()
            throw error
        }
    }

    static func restartIfNeeded(_ tunnel: SSHTunnel) async throws -> Int {
        if await !tunnel.isRunning { await tunnel.stop() }
        return try await tunnel.start()
    }

    private func cluster(_ descriptor: RedisClientDescriptor, seeds: [RedisEndpoint]) async throws -> ClusterClient {
        var nodeConfig = descriptor.connection
        if !descriptor.clusterDatabases { nodeConfig.dbIndex = 0 }
        let client: ClusterClient
        if let ssh = descriptor.ssh {
            // Every node, including one announced after connect, is reached through its own tunnel, opened on first use.
            let tunnels = ClusterSSHTunnels(options: ssh)
            client = ClusterClient(seeds: seeds, nodeConfig: nodeConfig, nodeClientFactory: { config in
                try await Self.tunneledNodeConnection(config, tunnels: tunnels)
            })
            await client.attach(tunnels: tunnels)
        } else {
            client = ClusterClient(seeds: seeds, nodeConfig: nodeConfig)
        }

        do {
            try await withTaskCancellationHandler {
                try await client.connect()
            } onCancel: {
                Task { await client.close() }
            }
            if Task.isCancelled { throw RedisClientError.cancelled }
        } catch {
            await client.close()
            throw error
        }

        return client
    }

    /// A cluster node connection through the node's tunnel; a reconnect restarts the tunnel when ssh has exited.
    static func tunneledNodeConnection(_ config: RedisConnectionConfig, tunnels: ClusterSSHTunnels) async throws -> RedisConnection {
        let announced = config.endpoint
        let local = try await tunnels.localEndpoint(for: announced)
        let connection = RedisConnection(config: tunneledConfig(config, local: local))
        try await connection.connectOwned()
        await connection.setReconnectProvider {
            tunneledConfig(config, local: try await tunnels.localEndpoint(for: announced))
        }
        return connection
    }

    private func sentinelMaster(_ descriptor: RedisClientDescriptor, name: String, sentinels: [RedisEndpoint],
                                username: String?, password: String?) async throws -> RedisConnection {
        guard !name.isEmpty else {
            throw RedisClientError.invalidConfiguration("SENTINEL_PARAMS_REQUIRED: Enter the name of the Sentinel primary group.")
        }
        var sentinelConfig = descriptor.connection
        sentinelConfig.username = username
        sentinelConfig.password = password
        sentinelConfig.endpoint = sentinels.first ?? descriptor.connection.endpoint
        let resolver = SentinelResolver(sentinelConfig: sentinelConfig)
        let masterConfig = descriptor.connection
        let connection = try await resolver.connectToMaster(name: name, sentinels: sentinels, masterConfig: masterConfig)
        // After a failover the old master is a replica or gone: ask the sentinels again on every reconnect.
        await connection.setReconnectProvider { [self] in
            try await runPreConnectScript(descriptor)
            let master = try await resolver.resolveVerifiedMaster(name: name, sentinels: sentinels, masterConfig: masterConfig)
            return masterConfig.with(endpoint: master)
        }
        return connection
    }
}

/// Starts one tunnel per announced node on first use; restarts it if ssh exits. `stopAll()` is terminal.
actor ClusterSSHTunnels {
    private let options: SSHTunnelOptions
    private var tunnels: [RedisEndpoint: SSHTunnel] = [:]
    private var starting: [RedisEndpoint: Task<Int, Error>] = [:]
    private var isStopped = false

    init(options: SSHTunnelOptions) {
        self.options = options
    }

    func localEndpoint(for remote: RedisEndpoint) async throws -> RedisEndpoint {
        if isStopped { throw RedisClientError.notConnected }
        let task: Task<Int, Error>
        if let existing = starting[remote] {
            task = existing
        } else {
            let tunnel = tunnels[remote] ?? SSHTunnel(options: options.with(remote: remote))
            tunnels[remote] = tunnel
            task = Task { try await RedisClientFactory.restartIfNeeded(tunnel) }
            starting[remote] = task
        }

        let port: Int
        do {
            port = try await task.value
        } catch {
            if starting[remote] == task { starting[remote] = nil }
            throw error
        }

        if starting[remote] == task { starting[remote] = nil }
        if isStopped { throw RedisClientError.notConnected }
        return RedisEndpoint(host: "127.0.0.1", port: port)
    }

    func stopAll() async {
        isStopped = true
        let all = Array(tunnels.values)
        tunnels.removeAll()
        for task in starting.values { _ = try? await task.value }
        starting.removeAll()
        for tunnel in all { await tunnel.stop() }
    }
}
