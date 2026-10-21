import Foundation

/// INFO / MODULE LIST / databases count for one client.
public struct DatabaseInfoService: Sendable {
    public let client: any RedisClient

    /// MODULE LIST names matched case-insensitively, reported in this spelling with a semantic version.
    static let knownModules = ["ai", "graph", "rg", "bf", "ReJSON", "json", "search", "timeseries"]

    /// `COMMAND INFO` probes used when MODULE LIST is not allowed.
    static let moduleProbes: [(name: String, commands: [String])] = [
        ("ai", ["ai.info"]), ("graph", ["graph.delete"]), ("rg", ["rg.pyexecute"]),
        ("bf", ["bf.info", "cf.info", "cms.info", "topk.info"]), ("ReJSON", ["json.get"]),
        ("search", ["ft.info"]), ("timeseries", ["ts.mrange", "ts.info", "ts.range", "ts.revrange"]),
    ]

    public init(client: any RedisClient) {
        self.client = client
    }

    /// `INFO [section]`. Falls back to `HELLO` when INFO is disabled (managed services).
    public func info(section: String? = nil) async throws -> RedisInfo {
        let args: [RedisArgument] = section.map { ["INFO", .string($0)] } ?? ["INFO"]
        do {
            let reply = try await client.execute(args)
            return ServerInfoParser.parse(Self.text(reply))
        } catch let error as RedisClientError where error.serverError != nil {
            guard let hello = try? await client.execute(["HELLO"]), let fields = Self.flatMap(hello) else { throw error }
            var server: [String: String] = [:]
            if let version = fields["version"]?.stringValue { server["redis_version"] = version }
            if let mode = fields["mode"]?.stringValue { server["redis_mode"] = mode }
            if let name = fields["server"]?.stringValue {
                server["server_name"] = name
                if name.lowercased() == "valkey", let version = server["redis_version"] { server["valkey_version"] = version }
            }

            var sections: [String: [String: String]] = ["server": server]
            if let role = fields["role"]?.stringValue { sections["replication"] = ["role": role] }
            return RedisInfo(sections: sections)
        }
    }

    /// `MODULE LIST`, falling back to `COMMAND INFO` probes and then `HELLO`.
    public func modules(flavor: ServerFlavor) async throws -> [RedisModuleInfo] {
        if let reply = try? await client.execute(["MODULE", "LIST"]) {
            return Self.parseModuleList(reply, flavor: flavor)
        }
        var found: [RedisModuleInfo] = []
        for probe in Self.moduleProbes {
            let args: [RedisArgument] = ["COMMAND", "INFO"] + probe.commands.map { .string($0) }
            guard let reply = try? await client.execute(args), let items = reply.arrayValue else { continue }
            if items.contains(where: { !$0.isNull }) { found.append(RedisModuleInfo(name: probe.name)) }
        }
        if !found.isEmpty { return found }
        if let hello = try? await client.execute(["HELLO"]), let fields = Self.flatMap(hello),
           let modules = fields["modules"] {
            return Self.parseModuleList(modules, flavor: flavor)
        }

        return []
    }

    /// `CONFIG GET databases`, falling back to the highest `dbN` in the keyspace + 1.
    public func databaseCount(info: RedisInfo? = nil) async throws -> Int {
        if let reply = try? await client.execute(["CONFIG", "GET", "databases"]), let value = Self.configValue(reply),
           let count = Int(value), count > 0 {
            return count
        }

        var resolved = info
        if resolved == nil { resolved = try? await self.info(section: "keyspace") }
        if let maxIndex = resolved?.keyspace.keys.max() { return maxIndex + 1 }
        return 1
    }

    /// `CONFIG GET cluster-databases` (Valkey 9 cluster mode); 1 when the server does not have the setting.
    public func clusterDatabaseCount() async throws -> Int {
        let reply = try await client.execute(["CONFIG", "GET", "cluster-databases"])
        return Self.configValue(reply).flatMap(Int.init).map { max($0, 1) } ?? 1
    }

    public func generalInfo() async throws -> GeneralInfo {
        let info = try await self.info()
        let databases = (try? await databaseCount(info: info)) ?? 1
        return Self.generalInfo(from: info, databases: databases)
    }

    static func generalInfo(from info: RedisInfo, databases: Int) -> GeneralInfo {
        let keyspace = info.keyspace
        let totalKeys = keyspace.isEmpty ? (info["keyspace"] != nil ? 0 : nil) : keyspace.values.reduce(0) { $0 + $1.keys }
        var hitRatio: Double?
        if let hits = info.value("keyspace_hits").flatMap(Double.init),
           let misses = info.value("keyspace_misses").flatMap(Double.init), hits + misses > 0 {
            hitRatio = hits / (hits + misses)
        }

        return GeneralInfo(version: info.serverVersion, serverFlavor: info.serverFlavor, databases: databases,
                           usedMemory: info.usedMemory,
                           totalKeys: totalKeys, connectedClients: info.connectedClients,
                           uptimeSeconds: info.uptimeSeconds, hitRatio: hitRatio,
                           role: info["replication"]?["role"], server: info["server"] ?? [:])
    }

    /// Hosting provider from host name and INFO (display only).
    public static func detectProvider(host: String, info: RedisInfo?) -> HostingProvider {
        let lower = host.lowercased()
        if lower.hasSuffix(".rlrcp.com") || lower.hasSuffix(".redislabs.com") || lower.hasSuffix(".redis-cloud.com") {
            return .redisCloud
        }

        if lower.hasSuffix("cache.amazonaws.com") { return .awsElastiCache }
        if lower.contains("memorydb") { return .awsMemoryDB }
        if lower.hasSuffix("redisenterprise.cache.azure.net") { return .azureCacheRedisEnterprise }
        if lower.hasSuffix("cache.windows.net") { return .azureCache }
        if lower.contains("upstash.io") { return .upstash }
        if let info {
            let text = info.sections.flatMap { section in section.value.map { "\($0.key):\($0.value)" } }
                .joined(separator: "\n").lowercased()
            if text.contains("elasticache") { return .awsElastiCache }
            if text.contains("memorydb") { return .awsMemoryDB }
            if text.contains("keydb") { return .keyDB }
            if text.contains("valkey") { return .valkey }
            if text.contains("dragonfly_version") { return .dragonfly }
            if text.contains("upstash_version") { return .upstash }
            if let executable = info["server"]?["executable"]?.lowercased(), executable.contains("redis-server") {
                return executable.contains("redis-stack") ? .redisStack : .redisCommunityEdition
            }
        }

        if ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(lower) || isPrivateIPv4(lower) { return .localhost }
        return .unknown
    }

    // MARK: - Parsing

    static func parseModuleList(_ reply: RESPValue, flavor: ServerFlavor) -> [RedisModuleInfo] {
        (reply.arrayValue ?? []).compactMap { entry -> RedisModuleInfo? in
            guard let fields = flatMap(entry), let rawName = fields["name"]?.stringValue else { return nil }
            let version = fields["ver"]?.intValue.map(Int.init) ?? fields["ver"]?.stringValue.flatMap { Int($0) }
            if let known = knownModules.first(where: { $0.lowercased() == rawName.lowercased() }) {
                let decoded = version.map { DatabaseCapabilities.decodedVersion($0, moduleName: known, flavor: flavor) }
                return RedisModuleInfo(name: known, version: version, semanticVersion: decoded.map(semanticVersion))
            }

            return RedisModuleInfo(name: rawName, version: version)
        }
    }

    /// `20811` -> `2.8.11` (pad to 6 digits: `MMmmpp`).
    static func semanticVersion(_ version: Int) -> String {
        let padded = String(format: "%06d", max(version, 0))
        let chars = Array(padded)
        let major = Int(String(chars[0..<(chars.count - 4)])) ?? 0
        let minor = Int(String(chars[(chars.count - 4)..<(chars.count - 2)])) ?? 0
        let patch = Int(String(chars[(chars.count - 2)...])) ?? 0
        return "\(major).\(minor).\(patch)"
    }

    static func flatMap(_ value: RESPValue) -> [String: RESPValue]? {
        value.stringKeyedMap
    }

    /// `CONFIG GET name` value (RESP2 `[name, value]`, RESP3 map).
    static func configValue(_ reply: RESPValue) -> String? {
        if let pairs = reply.mapValue { return pairs.first?.1.stringValue }
        guard let items = reply.arrayValue, items.count >= 2 else { return nil }
        return items[1].stringValue
    }

    static func text(_ reply: RESPValue) -> String {
        if let data = reply.dataValue { return String(decoding: data, as: UTF8.self) }
        return reply.stringValue ?? ""
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
