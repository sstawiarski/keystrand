import Foundation
import RedisUI

/// Database info derived from INFO, MODULE LIST, and CONFIG GET databases.
public struct DatabaseInfoDetails: Hashable, Sendable {
    public struct Row: Hashable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct KeyspaceRow: Hashable, Sendable, Identifiable {
        public var db: Int
        public var keys: Int
        public var expires: Int
        public var avgTTL: Int?
        public var isCurrent: Bool
        public var id: Int { db }

        public init(db: Int, keys: Int, expires: Int, avgTTL: Int?, isCurrent: Bool) {
            self.db = db
            self.keys = keys
            self.expires = expires
            self.avgTTL = avgTTL
            self.isCurrent = isCurrent
        }
    }

    public struct ModuleRow: Hashable, Sendable, Identifiable {
        public var name: String
        public var version: String?
        public var id: String { name }

        public init(name: String, version: String?) {
            self.name = name
            self.version = version
        }

        /// `Redis Search v. 2.10.12`.
        public var text: String { version.map { "\(name) v. \($0)" } ?? name }
    }

    public var name: String
    public var hostPort: String
    public var connectionType: String
    public var version: String?
    public var serverFlavor: ServerFlavor
    public var user: String
    public var databaseCount: Int
    public var currentDb: Int
    public var server: [Row]
    public var memory: [Row]
    public var keyspace: [KeyspaceRow]
    public var modules: [ModuleRow]

    public var showsLogicalDatabasesHint: Bool { databaseCount > 1 }

    public var serverProduct: String { serverFlavor.displayName }
    public var versionLabel: String { "\(serverProduct) Version" }

    public static let logicalDatabasesHint = "Pick the logical database that Browser, Workbench, and Database Analysis use."

    public init(name: String, hostPort: String, connectionType: String, version: String?,
                serverFlavor: ServerFlavor = .redis, user: String, databaseCount: Int, currentDb: Int, server: [Row],
                memory: [Row], keyspace: [KeyspaceRow], modules: [ModuleRow]) {
        self.name = name
        self.hostPort = hostPort
        self.connectionType = connectionType
        self.version = version
        self.serverFlavor = serverFlavor
        self.user = user
        self.databaseCount = databaseCount
        self.currentDb = currentDb
        self.server = server
        self.memory = memory
        self.keyspace = keyspace
        self.modules = modules
    }

    public static func connectionTypeText(_ kind: ConnectionKind) -> String {
        switch kind {
        case .standalone: return "Standalone"
        case .cluster: return "Cluster"
        case .sentinel: return "Sentinel"
        }
    }

    public static func make(name: String, hostPort: String, connectionKind: ConnectionKind, username: String?,
                            info: RedisInfo?, modules: [RedisModuleInfo], databaseCount: Int, currentDb: Int,
                            provider: HostingProvider? = nil) -> DatabaseInfoDetails {
        let server = info?["server"] ?? [:]
        var serverRows: [Row] = []

        func add(_ rows: inout [Row], _ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(Row(label: label, value: value))
        }

        add(&serverRows, "Mode", info?.redisMode.map(capitalized))
        add(&serverRows, "Role", (info?["replication"]?["role"]).map(capitalized))
        add(&serverRows, "Hosting provider", provider.flatMap(providerName))
        add(&serverRows, "OS", server["os"])
        add(&serverRows, "Uptime", info?.uptimeSeconds.map { DurationText.full(seconds: $0) })
        add(&serverRows, "Server", server["server_name"])
        add(&serverRows, "Process ID", server["process_id"])
        add(&serverRows, "Config file", server["config_file"])
        add(&serverRows, "Logical databases", String(max(databaseCount, 1)))

        let memorySection = info?["memory"] ?? [:]
        var memoryRows: [Row] = []
        add(&memoryRows, "Used memory", bytes(memorySection["used_memory"]))
        add(&memoryRows, "Used memory peak", bytes(memorySection["used_memory_peak"]))
        add(&memoryRows, "Total system memory", bytes(memorySection["total_system_memory"]))
        if let max = memorySection["maxmemory"].flatMap(Int.init) {
            add(&memoryRows, "Max memory", max == 0 ? "No limit" : OverviewFormatting.bytes(Double(max), decimals: 2))
        }

        add(&memoryRows, "Eviction policy", memorySection["maxmemory_policy"])
        add(&memoryRows, "Fragmentation ratio", memorySection["mem_fragmentation_ratio"])

        let keyspace = (info?.keyspace ?? [:])
            .map { KeyspaceRow(db: $0.key, keys: $0.value.keys, expires: $0.value.expires, avgTTL: $0.value.avgTTL,
                               isCurrent: $0.key == currentDb) }
            .sorted { $0.db < $1.db }

        let flavor = info?.serverFlavor ?? .redis
        let moduleRows = modules.map { ModuleRow(name: $0.displayName(on: flavor), version: $0.versionText) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let user = username.flatMap { $0.isEmpty ? nil : $0 } ?? "Default"
        return DatabaseInfoDetails(name: name, hostPort: hostPort, connectionType: connectionTypeText(connectionKind),
                                   version: info?.serverVersion, serverFlavor: flavor,
                                   user: user, databaseCount: max(databaseCount, 1),
                                   currentDb: currentDb, server: serverRows, memory: memoryRows, keyspace: keyspace,
                                   modules: moduleRows)
    }

    /// Plain-text summary for the Copy button.
    public var plainText: String {
        var lines = ["\(name)", hostPort, "Connection: \(connectionType)"]
        if let version { lines.append("\(serverProduct) version: \(version)") }
        lines.append("User: \(user)")
        lines += (server + memory).map { "\($0.label): \($0.value)" }
        if !keyspace.isEmpty {
            lines.append("Keyspace:")
            lines += keyspace.map { "  db\($0.db): keys=\($0.keys), expires=\($0.expires)" }
        }

        if !modules.isEmpty {
            lines.append("Database modules:")
            lines += modules.map { "  \($0.text)" }
        }

        return lines.joined(separator: "\n")
    }

    /// Display name of a detected hosting provider; nil for `.unknown`.
    public static func providerName(_ provider: HostingProvider) -> String? {
        switch provider {
        case .localhost: return "Localhost"
        case .redisCloud: return "Redis Cloud"
        case .redisSoftware: return "Redis Software"
        case .redisCommunityEdition: return "Redis Community Edition"
        case .redisStack: return "Redis Stack"
        case .awsElastiCache: return "Amazon ElastiCache"
        case .awsMemoryDB: return "Amazon MemoryDB"
        case .azureCache: return "Azure Cache for Redis"
        case .azureCacheRedisEnterprise: return "Azure Cache for Redis Enterprise"
        case .googleMemorystore: return "Google Cloud Memorystore"
        case .upstash: return "Upstash"
        case .keyDB: return "KeyDB"
        case .dragonfly: return "Dragonfly"
        case .valkey: return "Valkey"
        case .unknown: return nil
        }
    }

    private static func bytes(_ text: String?) -> String? {
        guard let value = text.flatMap(Double.init) else { return nil }
        return OverviewFormatting.bytes(value, decimals: 2)
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
