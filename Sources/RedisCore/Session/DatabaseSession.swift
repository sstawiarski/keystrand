import Foundation
import Observation

public enum ConnectionKind: String, Sendable, Hashable {
    case standalone
    case cluster
    case sentinel
}

public enum SessionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(ConnectionError)

    public var isConnected: Bool { self == .connected }
}

/// One node of the connected database bound to a client (standalone = the database itself).
public struct NodeClient: Sendable, Identifiable {
    public var endpoint: RedisEndpoint
    public var role: NodeRole
    public var client: any RedisClient

    public init(endpoint: RedisEndpoint, role: NodeRole, client: any RedisClient) {
        self.endpoint = endpoint
        self.role = role
        self.client = client
    }

    public var id: RedisEndpoint { endpoint }

    public func execute(_ args: [RedisArgument]) async throws -> RESPValue { try await client.execute(args) }
    public func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue] { try await client.pipeline(commands) }
}

/// Window-scoped objects (Pub/Sub, Profiler, CLI view models) can clean up when the session closes.
@MainActor
public protocol SessionScopedObject: AnyObject {
    func sessionWillClose() async
    /// The session disconnected, reconnected, or now points at a different server or logical database.
    /// Dedicated connections from `makeDedicatedConnection` are closed right after this returns.
    func sessionConnectionDidReset() async
}

public extension SessionScopedObject {
    func sessionConnectionDidReset() async {}
}

/// The live session for one database, shared by everything in its window.
/// Obtain it from `SessionRegistry.session(for:)`; pass it to views as an init parameter.
@MainActor
@Observable
public final class DatabaseSession: Identifiable {
    public nonisolated let id: DatabaseID
    public private(set) var config: DatabaseConfig
    public private(set) var state: SessionState = .disconnected
    public private(set) var info: RedisInfo?
    public private(set) var modules: [RedisModuleInfo] = []
    public private(set) var capabilities = DatabaseCapabilities()
    public private(set) var connectionKind: ConnectionKind = .standalone
    /// Selected logical database. Commands run on `effectiveDB`, which differs only on clusters.
    public private(set) var dbIndex: Int
    /// Number of logical databases: `CONFIG GET databases` (keyspace fallback), on a cluster `cluster-databases`
    /// when the server supports numbered databases there, else 1.
    public private(set) var databaseCount: Int = 1
    /// `cluster-databases` of a cluster that supports numbered databases (Valkey 9); nil until server details first
    /// load and on every other server. Kept across a reconnect to the same server.
    private var clusterDatabaseCount: Int?
    /// Incremented whenever `dbIndex` changes so features can reload.
    public private(set) var dbGeneration = 0
    public private(set) var overview: DatabaseOverview?
    /// Last overview refresh error (header shows a red info icon).
    public private(set) var overviewError: String?
    /// Lowercased command names from `ACL CAT dangerous`.
    public private(set) var dangerousCommands: Set<String> = []

    public let navigator = DatabaseNavigator()
    public let toasts = ToastCenter()
    public let confirmations = ConfirmationCenter()
    /// Live tip triggers fired by features (Browser scan, key details, CLI); consumed by the Tips panel.
    public let liveTips = LiveTipSignals()

    /// Process-wide stores (history, query library, per-database settings, app settings).
    @ObservationIgnored public let services: AppServices
    @ObservationIgnored private let clientOverride: (any RedisClient)?
    @ObservationIgnored private var cachedDescriptor: RedisClientDescriptor?
    @ObservationIgnored private var scopedObjects: [ObjectIdentifier: AnyObject] = [:]
    @ObservationIgnored private var visibleWindows = 0
    @ObservationIgnored private var overviewTask: Task<Void, Never>?
    @ObservationIgnored private var dedicatedConnections: [WeakConnection] = []
    /// A connection was opened or attempted since the post-disconnect script last ran.
    @ObservationIgnored private var needsPostDisconnect = false
    /// The latest post-disconnect script run. New connections wait for it so setup never overlaps teardown.
    @ObservationIgnored private var postDisconnectRun: Task<Void, Never>?
    /// `FT.CONFIG GET MAXSEARCHRESULTS` cache (`.some(nil)` = unlimited / unavailable).
    @ObservationIgnored var cachedMaxSearchResults: Int??
    /// Seconds between overview refreshes.
    @ObservationIgnored public var overviewRefreshInterval: TimeInterval = 5
    /// Bumped by every `connect()`, `disconnect()` and connection-changing `apply(config:)`; a connect attempt whose
    /// number is no longer current stops before it changes state or persists anything.
    @ObservationIgnored private var connectAttempt = 0
    /// The attempt of the `connect()` call still running, if any.
    @ObservationIgnored private var runningConnect: Int?
    /// A running attempt superseded by a connection-changing edit; it connects again with the edited config.
    @ObservationIgnored private var restartAfterEdit: Int?
    /// A connection succeeded at least once; the next one bumps `dbGeneration` so features reload.
    @ObservationIgnored private var hasConnected = false

    /// `client` injects a fixed client (tests, previews); the session then reports `.connected`.
    public init(config: DatabaseConfig, services: AppServices, client: (any RedisClient)? = nil) {
        self.id = config.id
        self.config = config
        self.services = services
        self.clientOverride = client
        self.dbIndex = config.dbIndex
        self.connectionKind = Self.kind(for: config)
        self.confirmations.isProduction = config.environment == .production
        if client != nil { state = .connected }
    }

    public var environment: DatabaseEnvironment { config.environment }
    public var isProduction: Bool { config.environment == .production }
    public var isCluster: Bool { connectionKind == .cluster }

    /// The logical database commands run on: `dbIndex`, or 0 on a cluster that cannot select it (Redis, Valkey
    /// before 9, a DB at or above `cluster-databases`, or server details not loaded yet).
    public var effectiveDB: Int {
        guard isCluster else { return dbIndex }
        return dbIndex < clusterDBLimit ? dbIndex : 0
    }

    private var clusterDBLimit: Int { clusterDatabaseCount ?? 1 }
    /// `RedisInfo.serverVersion`, or the version saved at the last connection.
    public var serverVersion: String? { info?.serverVersion ?? config.version }
    public var serverFlavor: ServerFlavor { info?.serverFlavor ?? config.providerFlavor }
    public var username: String? { config.username }
    /// "name" for type-to-confirm; host:port when the name is empty.
    public var confirmationName: String { config.name.isEmpty ? config.hostPort : config.name }

    // MARK: - Lifecycle

    /// Connects (pool client), loads INFO / modules / databases count / dangerous commands,
    /// and records `lastConnection`. Failures land in `state = .failed(...)`.
    public func connect() async {
        if clientOverride != nil {
            state = .connected
            if visibleWindows > 0 { startOverviewPolling() }
            return
        }

        connectAttempt += 1
        let attempt = connectAttempt
        runningConnect = attempt
        defer { if runningConnect == attempt { runningConnect = nil } }
        state = .connecting
        do {
            if config.connectionType == .notConnected { try await detectConnectionType(attempt: attempt) }
            let initialDB = effectiveDB
            var client = try await self.client(context: .common)
            try await loadServerDetails(client: client, attempt: attempt)
            var reload = hasConnected
            if effectiveDB != initialDB {
                // A cluster opens on DB 0 before it is known to support numbered databases.
                await services.clientPool.remove(ClientKey(databaseID: id, context: .common, db: initialDB))
                client = try await self.client(context: .common)
                try checkCurrent(attempt)
                reload = true
            }

            if reload { dbGeneration += 1 }
            hasConnected = true
            state = .connected
            if visibleWindows > 0 { startOverviewPolling() }
            let modules = self.modules
            let version = info?.serverVersion
            var discovered: [RedisEndpoint]?
            if let cluster = client as? ClusterClient, let nodes = try? await cluster.nodes() {
                discovered = nodes.map(\.endpoint)
            }
            let clusterNodes = discovered
            let provider = (config.provider == nil || config.provider == .unknown)
                ? DatabaseInfoService.detectProvider(host: config.host, info: info) : config.provider
            // Compare the stored config too because an edit can reach persistence before the session.
            guard attempt == connectAttempt else {
                await connectAgainIfEdited(attempt)
                return
            }
            let connectedTo = ConnectionSignature(config)
            let updated = try? await services.databaseStore.modify(id) { db in
                guard ConnectionSignature(db) == connectedTo else { return }
                db.lastConnection = Date()
                db.isNew = false
                db.modules = modules
                if let version { db.version = version }
                if let clusterNodes, !clusterNodes.isEmpty { db.nodes = clusterNodes }
                db.provider = provider
            }
            if let updated, attempt == connectAttempt, ConnectionSignature(updated) == connectedTo {
                config.lastConnection = updated.lastConnection
                config.isNew = false
                config.modules = updated.modules
                config.version = updated.version
                config.nodes = updated.nodes
                config.provider = updated.provider
            }
        } catch {
            guard attempt == connectAttempt else {
                await connectAgainIfEdited(attempt)
                return
            }
            state = .failed(ConnectionError.classify(error, endpoint: config.endpoint))
        }
    }

    private func checkCurrent(_ attempt: Int) throws {
        if attempt != connectAttempt { throw RedisClientError.cancelled }
    }

    /// An edit superseded `attempt` while no disconnect or newer connect did: connect again with the edited config.
    private func connectAgainIfEdited(_ attempt: Int) async {
        guard restartAfterEdit == attempt, runningConnect == attempt else { return }
        restartAfterEdit = nil
        await connect()
    }

    /// Imported databases start as NOT CONNECTED: detect sentinel / cluster / standalone once and persist it.
    private func detectConnectionType(attempt: Int) async throws {
        await willOpenConnection()
        let full = try await services.databaseStore.get(id)
        var ca: CACertificate?
        var clientCert: ClientCertificate?
        if full.tls.enabled {
            if let caID = full.tls.caCertID { ca = try await services.certificateStore.caCertificate(caID) }
            if let certID = full.tls.clientCertID { clientCert = try await services.certificateStore.clientCertificate(certID) }
        }

        let detected = try await DatabaseFactory(clientFactory: services.clientFactory)
            .createDetectedForSession(full, caCertificate: ca, clientCertificate: clientCert)
        try checkCurrent(attempt)
        let type = detected.connectionType
        let nodes = detected.nodes
        let detectedFor = ConnectionSignature(full)
        _ = try? await services.databaseStore.modify(id) { db in
            guard ConnectionSignature(db) == detectedFor else { return }
            db.connectionType = type
            db.nodes = nodes
        }
        config.connectionType = type
        config.nodes = nodes
        connectionKind = Self.kind(for: config)
        cachedDescriptor = nil
        await services.clientPool.invalidate(databaseID: id)
    }

    /// Stops polling, drops pooled clients, and closes the window's dedicated connections (CLI, MONITOR, Pub/Sub)
    /// after giving scoped objects `sessionConnectionDidReset()`. Returns after the post-disconnect script has run;
    /// cancelling the caller stops the script.
    public func disconnect() async {
        await disconnect(reportingTo: toasts)
    }

    private func disconnect(reportingTo center: ToastCenter) async {
        connectAttempt += 1
        restartAfterEdit = nil
        overviewTask?.cancel()
        overviewTask = nil
        await resetDedicatedConnections()
        await services.clientPool.invalidate(databaseID: id)
        await resetServerCaches()
        state = .disconnected
        startPostDisconnectScript(config.postDisconnectScript, reportingTo: center)
        guard let run = postDisconnectRun else { return }
        await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
    }

    public func reconnect() async {
        await disconnect()
        await connect()
    }

    /// Tears down window-scoped objects and clients when the window closes.
    /// Reports a failing post-disconnect script app-wide because the window is gone.
    public func close() async {
        for object in scopedObjects.values {
            if let scoped = object as? SessionScopedObject { await scoped.sessionWillClose() }
        }

        scopedObjects.removeAll()
        await disconnect(reportingTo: services.toasts)
    }

    /// Applies a config and drops cached clients. If the endpoint, credentials or logical database changes,
    /// resets `dbIndex` to the configured database, increments `dbGeneration` so features reload, and clears
    /// CPU, dangerous-command and MAXSEARCHRESULTS caches. Closes dedicated connections after
    /// `sessionConnectionDidReset()` and runs the previous config's post-disconnect script.
    /// Reconnecting reloads INFO, modules and capabilities.
    public func apply(config newConfig: DatabaseConfig) async {
        let connectionChanged = ConnectionSignature(config) != ConnectionSignature(newConfig)
        let previousPostDisconnectScript = config.postDisconnectScript
        config = newConfig.withoutSecrets()
        cachedDescriptor = nil
        connectionKind = Self.kind(for: newConfig)
        confirmations.isProduction = newConfig.environment == .production
        if connectionChanged {
            connectAttempt += 1
            restartAfterEdit = runningConnect
        }

        await services.clientPool.invalidate(databaseID: id)
        guard connectionChanged else { return }
        await resetDedicatedConnections()
        await resetServerCaches()
        clusterDatabaseCount = nil
        overview = nil
        overviewError = nil
        dbIndex = newConfig.dbIndex
        dbGeneration += 1
        confirmations.resetSkips()
        liveTips.reset()
        startPostDisconnectScript(previousPostDisconnectScript, reportingTo: toasts)
    }

    /// Re-reads INFO, modules, database count.
    public func refreshInfo() async throws {
        try await loadServerDetails(client: client(context: .common))
    }

    // MARK: - Logical database

    /// Opens a temporary connection with `SELECT db` to validate the index.
    public func canSelect(db: Int) async -> Bool {
        (try? await validateSelect(db: db)) != nil
    }

    /// Throws why `db` cannot be selected: out of range, or the error of a temporary connection that selects it.
    private func validateSelect(db: Int) async throws {
        if db < 0 || (isCluster && db >= clusterDBLimit) {
            throw RedisClientError.server(RESPError("ERR DB index is out of range"))
        }

        if clientOverride != nil { return }
        let connection = try await services.clientFactory.makeDedicatedConnection(connectingDescriptor(db: db))
        await connection.close()
    }

    /// Validates and switches the logical database for this window (not persisted).
    public func select(db: Int) async throws {
        guard db != dbIndex else { return }
        try await validateSelect(db: db)
        dbIndex = db
        dbGeneration += 1
        confirmations.resetSkips()
        liveTips.report(.avoidLogicalDatabases)
    }

    // MARK: - Commands

    /// Pooled client for a context, bound to `effectiveDB`. Contexts that never run blocking commands get a command
    /// timeout (`commandTimeout(for:)`).
    public func client(context: ClientContext = .common) async throws -> any RedisClient {
        if let clientOverride { return clientOverride }
        let db = effectiveDB
        let key = ClientKey(databaseID: id, context: context, db: db)
        let timeout = Self.commandTimeout(for: context)
        return try await services.clientPool.client(for: key) { [self] in
            var descriptor = try await connectingDescriptor(db: db, context: context)
            descriptor.connection.commandTimeout = timeout.map { max($0, descriptor.connection.connectTimeout) }
            return descriptor
        }
    }

    /// Seconds a pooled request may stay unanswered before its socket is dropped; nil for contexts that run
    /// user-typed or blocking commands.
    public nonisolated static func commandTimeout(for context: ClientContext) -> TimeInterval? {
        switch context {
        case .common, .browser: RedisConnectionConfig.defaultCommandTimeout
        case .background: RedisConnectionConfig.defaultCommandTimeout * 4
        case .workbench, .cli, .profiler, .events: nil
        }
    }

    /// `PING` on the `.common` client that gives up after `timeout` seconds. A timeout drops the stuck socket.
    public func ping(timeout: TimeInterval) async throws {
        let client = try await client()
        if let connection = client as? RedisConnection {
            _ = try await connection.execute(["PING"], timeout: timeout)
        } else {
            _ = try await withDeadline(seconds: timeout) { try await client.execute(["PING"]) }
        }
    }

    /// Throws `RedisClientError.server` on error replies.
    public func execute(_ args: [RedisArgument], context: ClientContext = .common) async throws -> RESPValue {
        try await client(context: context).execute(args)
    }

    public func execute(_ args: RedisArgument...) async throws -> RESPValue {
        try await execute(args)
    }

    public func execute(_ args: [Data], context: ClientContext = .common) async throws -> RESPValue {
        try await execute(args.redisArguments, context: context)
    }

    /// Error replies come back in place as `.error`.
    public func pipeline(_ commands: [[RedisArgument]], context: ClientContext = .common) async throws -> [RESPValue] {
        try await client(context: context).pipeline(commands)
    }

    public func pipeline(_ commands: [[Data]], context: ClientContext = .common) async throws -> [RESPValue] {
        try await pipeline(commands.map(\.redisArguments), context: context)
    }

    /// Cluster: nodes filtered by role. Standalone/sentinel: the single node as `.primary`.
    public func nodes(role: NodeRole? = nil, context: ClientContext = .common) async throws -> [NodeClient] {
        let client = try await self.client(context: context)
        if let cluster = client as? ClusterClient {
            var out: [NodeClient] = []
            for node in try await cluster.nodes(role: role) {
                out.append(NodeClient(endpoint: node.endpoint, role: node.role,
                                      client: try await cluster.client(for: node.endpoint)))
            }
            return out
        }
        if role == .replica { return [] }

        return [NodeClient(endpoint: config.endpoint, role: .primary, client: client)]
    }

    /// New unpooled client bound to `effectiveDB` (cluster, sentinel and SSH handled like pooled clients).
    /// For work that may change connection state (bulk upload of arbitrary commands). The caller closes it.
    /// With an injected client (tests, previews) this returns a wrapper whose `close()` leaves that client open.
    public func makeDedicatedClient(context: ClientContext = .common) async throws -> any RedisClient {
        if let clientOverride { return UnownedClient(clientOverride) }
        return try await services.clientFactory.makeClient(connectingDescriptor(db: effectiveDB, context: context))
    }

    /// New unpooled connection (Pub/Sub, MONITOR, CLI) with the same auth/TLS/SSH settings, on `effectiveDB`.
    /// `connectTimeout` (seconds) and `retry` override the database's connection settings when set.
    public func makeDedicatedConnection(node: RedisEndpoint? = nil, context: ClientContext = .common,
                                        connectTimeout: TimeInterval? = nil,
                                        retry: RetryPolicy? = nil) async throws -> RedisConnection {
        var descriptor = try await connectingDescriptor(db: effectiveDB, context: context)
        if let connectTimeout { descriptor.connection.connectTimeout = connectTimeout }
        if let retry { descriptor.connection.retry = retry }
        let connection = try await services.clientFactory.makeDedicatedConnection(descriptor, node: node)
        dedicatedConnections.removeAll { $0.connection == nil }
        dedicatedConnections.append(WeakConnection(connection: connection))
        return connection
    }

    /// One dedicated connection per cluster node (or the single node).
    public func makeDedicatedNodeConnections(role: NodeRole? = nil, context: ClientContext = .common) async throws -> [RedisConnection] {
        guard isCluster else { return [try await makeDedicatedConnection(context: context)] }
        var out: [RedisConnection] = []
        for node in try await nodes(role: role, context: context) {
            out.append(try await makeDedicatedConnection(node: node.endpoint, context: context))
        }
        return out
    }

    // MARK: - UI helpers

    /// Type-to-confirm on production databases; true immediately otherwise.
    public func confirm(_ request: ConfirmationRequest) async -> Bool {
        await confirmations.confirm(request, typing: confirmationName)
    }

    /// Window-scoped singleton per type (view models that must survive section switches).
    public func scopedObject<T: AnyObject>(_ type: T.Type = T.self, make: () -> T) -> T {
        let key = ObjectIdentifier(type)
        if let existing = scopedObjects[key] as? T { return existing }
        let created = make()
        scopedObjects[key] = created
        return created
    }

    // MARK: - Overview polling

    public func windowDidAppear() {
        visibleWindows += 1
        startOverviewPolling()
    }

    public func windowDidDisappear() {
        visibleWindows = max(visibleWindows - 1, 0)
        if visibleWindows == 0 {
            overviewTask?.cancel()
            overviewTask = nil
        }
    }

    public func refreshOverview() async {
        do {
            let nodes = try await self.nodes(context: .background)
            overview = try await services.overviewService.overview(databaseID: id, nodes: nodes, dbIndex: effectiveDB)
            overviewError = nil
        } catch {
            overviewError = error.localizedDescription
        }
    }

    private func startOverviewPolling() {
        guard overviewTask == nil else { return }
        overviewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state.isConnected { await self.refreshOverview() }
                try? await Task.sleep(for: .seconds(self.overviewRefreshInterval))
            }
        }
    }

    // MARK: - Private

    private static func kind(for config: DatabaseConfig) -> ConnectionKind {
        switch config.connectionType {
        case .cluster where !config.forceStandalone: return .cluster
        case .sentinel: return .sentinel
        default: return .standalone
        }
    }

    private func resetDedicatedConnections() async {
        for object in Array(scopedObjects.values) {
            if let scoped = object as? SessionScopedObject { await scoped.sessionConnectionDidReset() }
        }

        let open = dedicatedConnections.compactMap(\.connection)
        dedicatedConnections.removeAll()
        for connection in open { await connection.close() }
    }

    private func resetServerCaches() async {
        cachedMaxSearchResults = nil
        await services.overviewService.reset(id)
        await services.dangerousCommands.invalidate(id)
    }

    /// Publishes INFO, modules, capabilities and database counts together unless `attempt` is stale.
    private func loadServerDetails(client: any RedisClient, attempt: Int? = nil) async throws {
        let infoService = DatabaseInfoService(client: client)
        let info = try await infoService.info()
        let modules = (try? await infoService.modules(flavor: info.serverFlavor)) ?? []
        var hasArray: Bool?
        if let reply = try? await client.execute(["COMMAND", "INFO", "ARGET"]), let items = reply.arrayValue {
            hasArray = items.contains { !$0.isNull }
        }

        let capabilities = DatabaseCapabilities(redisVersion: info.redisVersion, serverFlavor: info.serverFlavor,
                                                serverVersion: info.serverVersion, modules: modules,
                                                hasArrayCommands: hasArray)
        var kind = connectionKind
        if let cluster = client as? ClusterClient, (try? await cluster.nodes())?.isEmpty == false {
            kind = .cluster
        }

        let clusterCount: Int?
        let count: Int
        if kind == .cluster {
            clusterCount = capabilities.supportsClusterDatabases ? try? await infoService.clusterDatabaseCount() : nil
            count = clusterCount ?? 1
        } else {
            clusterCount = nil
            count = (try? await infoService.databaseCount(info: info))
                ?? max(info.keyspace.keys.max().map { $0 + 1 } ?? 1, 1)
        }

        let dangerous = await services.dangerousCommands.commands(for: id, client: client)
        if let attempt, attempt != connectAttempt {
            // The cache may now hold the previous server's list.
            await services.dangerousCommands.invalidate(id)
            throw RedisClientError.cancelled
        }

        self.info = info
        self.modules = modules
        self.capabilities = capabilities
        connectionKind = kind
        clusterDatabaseCount = clusterCount
        databaseCount = count
        dangerousCommands = dangerous
    }

    /// The descriptor for a connection about to be opened: waits for a running post-disconnect script first.
    private func connectingDescriptor(db: Int, context: ClientContext = .common) async throws -> RedisClientDescriptor {
        await willOpenConnection()
        return try await descriptor(db: db, context: context)
    }

    /// `db` is `effectiveDB` read before the caller awaited, so a non-zero DB on a cluster means the cluster
    /// supported numbered databases then, even if the count has been cleared since.
    private func descriptor(db: Int, context: ClientContext = .common) async throws -> RedisClientDescriptor {
        let clusterDatabases = clusterDatabaseCount != nil || (isCluster && db != 0)
        var descriptor: RedisClientDescriptor
        if let cachedDescriptor {
            descriptor = cachedDescriptor
        } else {
            let full = try await services.databaseStore.get(id)
            var ca: CACertificate?
            var clientCert: ClientCertificate?
            if full.tls.enabled {
                if let caID = full.tls.caCertID { ca = try await services.certificateStore.caCertificate(caID) }
                if let certID = full.tls.clientCertID {
                    clientCert = try await services.certificateStore.clientCertificate(certID)
                }
            }

            descriptor = full.clientDescriptor(caCertificate: ca, clientCertificate: clientCert,
                                               clientName: Self.clientName(context: context, id: id), dbOverride: db)
            cachedDescriptor = descriptor
        }

        descriptor.connection.dbIndex = db
        descriptor.connection.clientName = Self.clientName(context: context, id: id)
        descriptor.clusterDatabases = clusterDatabases
        return descriptor
    }

    // MARK: - Post-disconnect script

    private func willOpenConnection() async {
        await postDisconnectRun?.value
        needsPostDisconnect = true
    }

    /// Starts `script` when a connection was opened since it last ran. Call it once every connection is closed.
    private func startPostDisconnectScript(_ script: String?, reportingTo center: ToastCenter) {
        guard needsPostDisconnect else { return }
        needsPostDisconnect = false
        guard ConnectionScriptRunner.runnable(script) != nil else { return }
        let factory = services.clientFactory
        let endpoint = config.endpoint
        let previous = postDisconnectRun
        postDisconnectRun = Task {
            await previous?.value
            do {
                try await factory.runPostDisconnectScript(script)
            } catch {
                guard !Task.isCancelled else { return }
                center.error(ConnectionError.classify(error, endpoint: endpoint).message,
                             title: "Post-Disconnect Script Failed")
            }
        }
    }

    private static func clientName(context: ClientContext, id: DatabaseID) -> String {
        "keystrand-\(context.rawValue)-\(id.rawValue.prefix(8))"
    }
}

/// The parts of a database config that decide where and how the session connects.
struct ConnectionSignature: Hashable {
    var host: String
    var port: Int
    var db: Int
    var username: String?
    var timeoutMs: Int
    var tls: TLSSettings
    var ssh: SSHOptions?
    var sentinelMaster: SentinelMasterConfig?
    var connectionType: ConnectionType
    var forceStandalone: Bool
    var connectionFamily: ConnectionFamily
    var preConnectScript: String?

    init(_ config: DatabaseConfig) {
        let config = config.withoutSecrets()
        host = config.host
        port = config.port
        db = config.dbIndex
        username = config.username
        timeoutMs = config.timeoutMs
        tls = config.tls
        ssh = config.ssh
        sentinelMaster = config.sentinelMaster
        connectionType = config.connectionType
        forceStandalone = config.forceStandalone
        connectionFamily = config.connectionFamily
        preConnectScript = config.preConnectScript
    }
}

private struct WeakConnection {
    weak var connection: RedisConnection?
}

/// Forwards to a client owned by someone else; `close()` does nothing.
final class UnownedClient: RedisClient {
    let base: any RedisClient

    init(_ base: any RedisClient) {
        self.base = base
    }

    func execute(_ args: [RedisArgument]) async throws -> RESPValue { try await base.execute(args) }
    func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue] { try await base.pipeline(commands) }
    func close() async {}
}
