import Foundation

/// Which server implementation answered INFO.
public enum ServerFlavor: String, Hashable, Sendable, Codable {
    case redis
    case valkey

    /// "Redis" or "Valkey".
    public var displayName: String { self == .valkey ? "Valkey" : "Redis" }
}

/// Parsed `INFO` fields grouped by lowercased section name.
public struct RedisInfo: Hashable, Sendable {
    public var sections: [String: [String: String]]

    public init(sections: [String: [String: String]] = [:]) {
        self.sections = sections
    }

    public subscript(section: String) -> [String: String]? { sections[section.lowercased()] }

    /// First value for `key` in any section.
    public func value(_ key: String) -> String? {
        for (_, fields) in sections { if let v = fields[key] { return v } }
        return nil
    }

    /// Compatibility version. Valkey always reports `7.2.4` here; use `serverVersion` for the real one.
    public var redisVersion: String? { value("redis_version") }
    /// `server_name`, absent on Redis.
    public var serverName: String? { value("server_name") }
    /// `valkey_version`, absent on Redis.
    public var valkeyVersion: String? { value("valkey_version") }

    public var serverFlavor: ServerFlavor {
        serverName?.lowercased() == "valkey" || valkeyVersion != nil ? .valkey : .redis
    }

    /// The real version of the server: `valkey_version` on Valkey, else `redis_version`.
    public var serverVersion: String? { valkeyVersion ?? redisVersion }
    public var usedMemory: Int? { value("used_memory").flatMap(Int.init) }
    public var connectedClients: Int? { value("connected_clients").flatMap(Int.init) }
    public var opsPerSecond: Int? { value("instantaneous_ops_per_sec").flatMap(Int.init) }
    public var uptimeSeconds: Int? { value("uptime_in_seconds").flatMap(Int.init) }
    public var role: String? { value("role") }
    /// `redis_mode`, or `server_mode` on Valkey.
    public var redisMode: String? { value("redis_mode") ?? value("server_mode") }

    public struct Keyspace: Hashable, Sendable {
        public var keys: Int
        public var expires: Int
        public var avgTTL: Int?

        public init(keys: Int, expires: Int, avgTTL: Int? = nil) {
            self.keys = keys
            self.expires = expires
            self.avgTTL = avgTTL
        }
    }

    /// `db0:keys=1,expires=0,avg_ttl=0` -> `[0: Keyspace(keys: 1, ...)]`.
    public var keyspace: [Int: Keyspace] {
        var out: [Int: Keyspace] = [:]
        for (key, value) in self["keyspace"] ?? [:] {
            guard key.hasPrefix("db"), let index = Int(key.dropFirst(2)) else { continue }
            var fields: [String: Int] = [:]
            for pair in value.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let n = Int(kv[1]) { fields[String(kv[0])] = n }
            }

            out[index] = Keyspace(keys: fields["keys"] ?? 0, expires: fields["expires"] ?? 0, avgTTL: fields["avg_ttl"])
        }

        return out
    }
}

public enum ServerInfoParser {
    /// Parses INFO text (`# Section` headers, `key:value` lines; `\r\n` or `\n`).
    public static func parse(_ text: String) -> RedisInfo {
        var sections: [String: [String: String]] = [:]
        var current = "default"
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                current = line.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            sections[current, default: [:]][String(line[..<colon])] = String(line[line.index(after: colon)...])
        }

        return RedisInfo(sections: sections)
    }
}

/// Dotted version comparison (`7.2.4`, `8.0.3`).
public struct RedisVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var components: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap { $0 }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: RedisVersion, rhs: RedisVersion) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        for i in 0..<n {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }

        return false
    }

    /// `version >= "8.0.3"`.
    public func isAtLeast(_ other: String) -> Bool {
        guard let o = RedisVersion(other) else { return false }
        return self >= o
    }
}

/// Which search module implementation is loaded.
public enum SearchFlavor: Hashable, Sendable {
    case rediSearch
    case valkeySearch
}

/// What the connected server supports (modules + version gates).
public struct DatabaseCapabilities: Hashable, Sendable {
    /// Compatibility version (`redis_version`). Valkey always reports `7.2.4` here.
    public var redisVersion: String?
    public var serverFlavor: ServerFlavor
    /// `RedisInfo.serverVersion`; on Redis it defaults to `redisVersion`.
    public var serverVersion: String?
    public var modules: [RedisModuleInfo]
    /// Set by the session from `COMMAND INFO ARGET` when available.
    public var hasArrayCommands: Bool?

    public init(redisVersion: String? = nil, serverFlavor: ServerFlavor = .redis, serverVersion: String? = nil,
                modules: [RedisModuleInfo] = [], hasArrayCommands: Bool? = nil) {
        self.redisVersion = redisVersion
        self.serverFlavor = serverFlavor
        self.serverVersion = serverVersion ?? (serverFlavor == .redis ? redisVersion : nil)
        self.modules = modules
        self.hasArrayCommands = hasArrayCommands
    }

    private var moduleNames: Set<String> { Set(modules.map { $0.name.lowercased() }) }
    private var version: RedisVersion? { redisVersion.flatMap(RedisVersion.init) }
    private var realVersion: RedisVersion? { serverVersion.flatMap(RedisVersion.init) }

    /// "Valkey 9.1.2", "Redis 8.0.3", or "Redis" / "Valkey" when the version is unknown.
    public var serverDisplayName: String { Self.displayName(flavor: serverFlavor, version: serverVersion) }

    public static func displayName(flavor: ServerFlavor, version: String?) -> String {
        guard let version = version?.trimmingCharacters(in: .whitespaces), !version.isEmpty else {
            return flavor.displayName
        }
        return "\(flavor.displayName) \(version)"
    }

    /// Real-version check that is false on Valkey.
    public func isRedis(atLeast minimum: String) -> Bool {
        serverFlavor == .redis && (realVersion?.isAtLeast(minimum) ?? false)
    }

    /// Real-version check that is false on Redis.
    public func isValkey(atLeast minimum: String) -> Bool {
        serverFlavor == .valkey && (realVersion?.isAtLeast(minimum) ?? false)
    }

    /// Compares the compatibility `redisVersion`, so on Valkey it answers for Redis 7.2.4.
    /// Use it only for features Redis had by 7.2.4; use `isRedis(atLeast:)` / `isValkey(atLeast:)` above that.
    public func isVersion(atLeast minimum: String) -> Bool { version?.isAtLeast(minimum) ?? false }

    /// One of `names` (lowercased `MODULE LIST` names, such as a `ModuleNames` set) is loaded.
    public func hasModule(_ names: Set<String>) -> Bool { !moduleNames.isDisjoint(with: names) }

    /// Lowercased module names for command requirements, not display. On Valkey, `bf` supports only `BF.*`
    /// and maps to `CommandModuleRequirement.bloomFilterOnlyModule`.
    var effectiveModuleNames: [String] {
        modules.map { module in
            let name = module.name.lowercased()
            return serverFlavor == .valkey && name == "bf" ? CommandModuleRequirement.bloomFilterOnlyModule : name
        }
    }

    /// The module panel to show for `commandLine` when the server lacks its module.
    public func missingModule(for commandLine: String) -> CommandModuleRequirement? {
        CommandModuleRequirement.missing(for: commandLine, loadedModules: effectiveModuleNames)
    }

    /// Commands to offer in completion lists. Until the server is known: every command. Then: module commands of
    /// loaded modules, no vector set commands on a server without them (Valkey, Redis before 8), no Valkey-only
    /// core commands on Redis, and no `FT.EXPLAIN`/`FT.PROFILE` on valkey-search.
    public var commandAvailability: CommandAvailability {
        let names = effectiveModuleNames
        let isKnown = redisVersion != nil
        return CommandAvailability(modules: names.isEmpty ? nil : names,
                                   includesVectorSets: !isKnown || supportsVectorSets,
                                   includesValkeyOnly: !isKnown || serverFlavor == .valkey,
                                   includesSearchExplain: supportsSearchExplain)
    }

    public var hasSearch: Bool { hasModule(ModuleNames.search) }
    public var hasJSON: Bool { hasModule(ModuleNames.json) }
    public var hasTimeSeries: Bool { hasModule(ModuleNames.timeSeries) }
    public var hasBloom: Bool { hasModule(ModuleNames.bloom) }
    public var hasGraph: Bool { hasModule(ModuleNames.graph) }

    /// Major version of the JSON module (RedisJSON or valkey-json).
    public var jsonMajorVersion: Int? {
        modules.first { ModuleNames.json.contains($0.name.lowercased()) }?.version.map { $0 / 10_000 }
    }

    /// JSONPath (`$…`): valkey-json always, RedisJSON from 2. Legacy `.` paths when the module version is unknown,
    /// because every JSON module accepts them.
    public var supportsJSONPath: Bool {
        hasModule(["json"]) || (modules.first { $0.name.lowercased() == "rejson" }?.version ?? 0) >= 20_000
    }

    public var searchFlavor: SearchFlavor? {
        guard hasSearch else { return nil }
        return serverFlavor == .valkey ? .valkeySearch : .rediSearch
    }

    /// Search module version as MMmmpp, e.g. 21012 = 2.10.12.
    public var searchVersion: Int? {
        guard let search = modules.first(where: { ModuleNames.search.contains($0.name.lowercased()) }),
              let raw = search.version else { return nil }
        return Self.decodedVersion(raw, moduleName: search.name, flavor: serverFlavor)
    }

    /// A MODULE LIST version as MMmmpp. valkey-search encodes its version as hex `0xMMmmpp`, which is decoded
    /// (66049 = 0x010201 -> 10201); every other module already reports MMmmpp.
    public nonisolated static func decodedVersion(_ raw: Int, moduleName: String, flavor: ServerFlavor) -> Int {
        guard flavor == .valkey, ModuleNames.search.contains(moduleName.lowercased()) else { return raw }
        return (raw >> 16) * 10_000 + ((raw >> 8) & 0xFF) * 100 + (raw & 0xFF)
    }

    /// RediSearch older than `minimum` (MMmmpp). valkey-search versions have their own numbering and never count as
    /// too old; an unknown (absent or 0) RediSearch version does not either.
    public func isRediSearch(below minimum: Int) -> Bool {
        guard searchFlavor == .rediSearch, let version = searchVersion, version > 0 else { return false }
        return version < minimum
    }

    public var supportsFloat16Vectors: Bool { searchFlavor == .rediSearch && (searchVersion ?? 0) >= 21_000 }
    /// `FT.SEARCH idx *`. Without a detected search module the server is assumed to be RediSearch, as are the
    /// two flags below.
    public var supportsSearchMatchAll: Bool { searchFlavor != .valkeySearch }
    /// `FT.EXPLAIN` and `FT.PROFILE`.
    public var supportsSearchExplain: Bool { searchFlavor != .valkeySearch }
    public var searchIndexesRequireDB0: Bool { searchFlavor != .valkeySearch }

    public var supportsVectorSets: Bool { isRedis(atLeast: "8.0.0") }
    public var supportsVsimWithAttribs: Bool { isRedis(atLeast: "8.0.3") }
    public var supportsArray: Bool { hasArrayCommands ?? isRedis(atLeast: "8.8.0") }
    public var supportsHashFieldTTL: Bool { isRedis(atLeast: "7.4.0") || isValkey(atLeast: "9.0.0") }
    /// `HSETEX ... KEEPTTL`.
    public var supportsHashFieldKeepTTL: Bool { isRedis(atLeast: "8.0.0") || isValkey(atLeast: "9.0.0") }
    /// Numbered databases in cluster mode.
    public var supportsClusterDatabases: Bool { isValkey(atLeast: "9.0.0") }
}

/// Database info popover / general info.
public struct GeneralInfo: Hashable, Sendable {
    /// `RedisInfo.serverVersion`.
    public var version: String?
    public var serverFlavor: ServerFlavor
    public var databases: Int
    public var usedMemory: Int?
    public var totalKeys: Int?
    public var connectedClients: Int?
    public var uptimeSeconds: Int?
    public var hitRatio: Double?
    public var role: String?
    public var server: [String: String]

    public init(version: String? = nil, serverFlavor: ServerFlavor = .redis, databases: Int = 1,
                usedMemory: Int? = nil, totalKeys: Int? = nil, connectedClients: Int? = nil,
                uptimeSeconds: Int? = nil, hitRatio: Double? = nil, role: String? = nil,
                server: [String: String] = [:]) {
        self.version = version
        self.serverFlavor = serverFlavor
        self.databases = databases
        self.usedMemory = usedMemory
        self.totalKeys = totalKeys
        self.connectedClients = connectedClients
        self.uptimeSeconds = uptimeSeconds
        self.hitRatio = hitRatio
        self.role = role
        self.server = server
    }
}

/// Header overview metrics.
public struct DatabaseOverview: Hashable, Sendable {
    /// `RedisInfo.serverVersion`.
    public var version: String?
    public var totalKeys: Int?
    /// Per logical db when it differs from `totalKeys` ("db0": 12).
    public var totalKeysPerDb: [String: Int]?
    public var usedMemory: Int?
    /// May be fractional (median across cluster nodes).
    public var connectedClients: Double?
    public var opsPerSecond: Int?
    public var networkInKbps: Double?
    public var networkOutKbps: Double?
    /// `.some(nil)` = calculating (first sample), `nil` = unavailable.
    public var cpuUsagePercentage: Double??
    public var maxCpuUsagePercentage: Int?

    public init(version: String? = nil, totalKeys: Int? = nil, totalKeysPerDb: [String: Int]? = nil, usedMemory: Int? = nil,
                connectedClients: Double? = nil,
                opsPerSecond: Int? = nil, networkInKbps: Double? = nil, networkOutKbps: Double? = nil,
                cpuUsagePercentage: Double?? = nil, maxCpuUsagePercentage: Int? = nil) {
        self.version = version
        self.totalKeys = totalKeys
        self.totalKeysPerDb = totalKeysPerDb
        self.usedMemory = usedMemory
        self.connectedClients = connectedClients
        self.opsPerSecond = opsPerSecond
        self.networkInKbps = networkInKbps
        self.networkOutKbps = networkOutKbps
        self.cpuUsagePercentage = cpuUsagePercentage
        self.maxCpuUsagePercentage = maxCpuUsagePercentage
    }
}
