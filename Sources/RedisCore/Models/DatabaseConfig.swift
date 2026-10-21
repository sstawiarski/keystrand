import Foundation

/// Stable UUID string identifying a saved database.
public struct DatabaseID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public var description: String { rawValue }
}

public enum ConnectionType: String, Codable, Sendable, Hashable, CaseIterable {
    case standalone = "STANDALONE"
    case cluster = "CLUSTER"
    case sentinel = "SENTINEL"
    case notConnected = "NOT CONNECTED"

    public var displayName: String {
        switch self {
        case .standalone: return "Standalone"
        case .cluster: return "OSS Cluster"
        case .sentinel: return "Sentinel"
        case .notConnected: return "Not connected"
        }
    }
}

public enum KeyNameFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case unicode = "Unicode"
    case hex = "HEX"
}

public enum DatabaseEnvironment: String, Codable, Sendable, Hashable, CaseIterable {
    case unspecified
    case production
    case development
}

public enum ConnectionFamily: String, Codable, Sendable, Hashable, CaseIterable {
    case auto
    case ipv4
    case ipv6

    public var ipFamily: IPFamily {
        switch self {
        case .auto: return .auto
        case .ipv4: return .ipv4
        case .ipv6: return .ipv6
        }
    }
}

/// Hosting provider detected from host name / INFO (display only).
public enum HostingProvider: String, Codable, Sendable, Hashable, CaseIterable {
    case localhost = "LOCALHOST"
    case redisCloud = "RE_CLOUD"
    case redisSoftware = "RE_CLUSTER"
    case redisCommunityEdition = "REDIS_COMMUNITY_EDITION"
    case redisStack = "REDIS_STACK"
    case awsElastiCache = "AWS_ELASTICACHE"
    case awsMemoryDB = "AWS_MEMORYDB"
    case azureCache = "AZURE_CACHE"
    case azureCacheRedisEnterprise = "AZURE_CACHE_REDIS_ENTERPRISE"
    case googleMemorystore = "GOOGLE_MEMORYSTORE"
    case upstash = "UPSTASH"
    case keyDB = "KEYDB"
    case dragonfly = "DRAGONFLY"
    case valkey = "VALKEY"
    case unknown = "UNKNOWN"
}

public struct RedisModuleInfo: Hashable, Codable, Sendable {
    public var name: String
    /// Numeric version from MODULE LIST (`20612` = 2.6.12).
    public var version: Int?
    public var semanticVersion: String?

    public init(name: String, version: Int? = nil, semanticVersion: String? = nil) {
        self.name = name
        self.version = version
        self.semanticVersion = semanticVersion
    }

    /// "Redis Search", "JSON", ... (module badge mapping), else the raw name.
    public var displayName: String { displayName(on: .redis) }

    /// `displayName`, with valkey-search shown as "Valkey Search" on Valkey.
    public func displayName(on flavor: ServerFlavor) -> String {
        let lowered = name.lowercased()
        if ModuleNames.search.contains(lowered) { return flavor == .valkey ? "Valkey Search" : "Redis Search" }
        if ModuleNames.json.contains(lowered) { return "JSON" }
        switch lowered {
        case "timeseries": return "Time Series"
        case "bf": return "Probabilistic"
        case "graph": return "Graph"
        case "ai": return "AI"
        case "rg", "redisgears", "redisgears_2": return "Gears"
        case "vectorset": return "Vector Set"
        case "pb": return "redis-protobuf"
        default: return String(name.prefix(50))
        }
    }

    /// `semanticVersion`, or `version` decoded as `major.minor.patch`.
    public var versionText: String? {
        if let semanticVersion { return semanticVersion }
        guard let version else { return nil }
        return "\(version / 10_000).\((version / 100) % 100).\(version % 100)"
    }
}

public struct DatabaseTag: Hashable, Codable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct SentinelMasterConfig: Hashable, Codable, Sendable {
    public var name: String
    public var username: String?
    /// Secret: stored in Keychain, never in databases.json.
    public var password: String?

    public init(name: String, username: String? = nil, password: String? = nil) {
        self.name = name
        self.username = username
        self.password = password
    }
}

public enum SSHAuth: Hashable, Codable, Sendable {
    /// Secret: password in Keychain.
    case password(String?)
    /// Secrets: key and passphrase in Keychain.
    case privateKey(pem: String?, passphrase: String?)
}

public struct SSHOptions: Hashable, Codable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: SSHAuth

    public init(host: String, port: Int = 22, username: String, auth: SSHAuth = .password(nil)) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
    }
}

public struct CACertificate: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// PEM.
    public var certificate: String

    public init(id: String = UUID().uuidString.lowercased(), name: String, certificate: String) {
        self.id = id
        self.name = name
        self.certificate = certificate
    }
}

public struct ClientCertificate: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// PEM.
    public var certificate: String
    /// PEM private key. Secret: Keychain only.
    public var key: String?

    public init(id: String = UUID().uuidString.lowercased(), name: String, certificate: String, key: String? = nil) {
        self.id = id
        self.name = name
        self.certificate = certificate
        self.key = key
    }
}

public struct TLSSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    /// SNI.
    public var servername: String?
    public var verifyServerCert: Bool
    public var caCertID: String?
    public var clientCertID: String?

    public init(enabled: Bool = false, servername: String? = nil, verifyServerCert: Bool = false,
                caCertID: String? = nil, clientCertID: String? = nil) {
        self.enabled = enabled
        self.servername = servername
        self.verifyServerCert = verifyServerCert
        self.caCertID = caCertID
        self.clientCertID = clientCertID
    }
}

/// A saved database connection (persisted in databases.json; secrets live in the Keychain).
public struct DatabaseConfig: Identifiable, Hashable, Codable, Sendable {
    public var id: DatabaseID
    /// Alias shown in the UI (≤ 500 chars). Defaults to `host:port`.
    public var name: String
    public var host: String
    public var port: Int
    /// Logical database; `nil` = 0.
    public var db: Int?
    public var username: String?
    /// Secret.
    public var password: String?
    public var timeoutMs: Int
    public var connectionType: ConnectionType
    public var nameFromProvider: String?
    public var provider: HostingProvider?
    /// The server flavor the saved provider implies, for when INFO has not been read.
    public var providerFlavor: ServerFlavor { provider == .valkey ? .valkey : .redis }
    public var lastConnection: Date?
    public var createdAt: Date
    /// "New" badge until first opened.
    public var isNew: Bool
    public var sentinelMaster: SentinelMasterConfig?
    /// Cluster seed nodes, or the other sentinels.
    public var nodes: [RedisEndpoint]?
    public var modules: [RedisModuleInfo]
    /// The real server version from the last connection (`valkey_version` on Valkey).
    public var version: String?
    public var tls: TLSSettings
    /// `nil` = SSH tunnel off.
    public var ssh: SSHOptions?
    public var compressor: Compressor
    public var keyNameFormat: KeyNameFormat
    public var forceStandalone: Bool
    public var tags: [DatabaseTag]
    public var environment: DatabaseEnvironment
    public var connectionFamily: ConnectionFamily
    public var preConnectScript: String?
    /// Runs once the app has closed every connection it opened to this database.
    public var postDisconnectScript: String?

    public init(id: DatabaseID = DatabaseID(), name: String? = nil, host: String = "127.0.0.1", port: Int = 6379,
                db: Int? = nil, username: String? = nil, password: String? = nil, timeoutMs: Int = 30_000,
                connectionType: ConnectionType = .notConnected, nameFromProvider: String? = nil,
                provider: HostingProvider? = nil, lastConnection: Date? = nil, createdAt: Date = Date(),
                isNew: Bool = true, sentinelMaster: SentinelMasterConfig? = nil, nodes: [RedisEndpoint]? = nil,
                modules: [RedisModuleInfo] = [], version: String? = nil, tls: TLSSettings = TLSSettings(),
                ssh: SSHOptions? = nil, compressor: Compressor = .none, keyNameFormat: KeyNameFormat = .unicode,
                forceStandalone: Bool = false, tags: [DatabaseTag] = [], environment: DatabaseEnvironment = .unspecified,
                connectionFamily: ConnectionFamily = .auto, preConnectScript: String? = nil,
                postDisconnectScript: String? = nil) {
        self.id = id
        self.name = name ?? "\(host):\(port)"
        self.host = host
        self.port = port
        self.db = db
        self.username = username
        self.password = password
        self.timeoutMs = timeoutMs
        self.connectionType = connectionType
        self.nameFromProvider = nameFromProvider
        self.provider = provider
        self.lastConnection = lastConnection
        self.createdAt = createdAt
        self.isNew = isNew
        self.sentinelMaster = sentinelMaster
        self.nodes = nodes
        self.modules = modules
        self.version = version
        self.tls = tls
        self.ssh = ssh
        self.compressor = compressor
        self.keyNameFormat = keyNameFormat
        self.forceStandalone = forceStandalone
        self.tags = tags
        self.environment = environment
        self.connectionFamily = connectionFamily
        self.preConnectScript = preConnectScript
        self.postDisconnectScript = postDisconnectScript
    }

    public var endpoint: RedisEndpoint { RedisEndpoint(host: host, port: port) }
    public var hostPort: String { endpoint.description }
    public var dbIndex: Int { db ?? 0 }
    public var decompressionEnabled: Bool { compressor != .none }

    /// Returns a copy without secrets for persistence and display.
    public func withoutSecrets() -> DatabaseConfig {
        var copy = self
        copy.password = nil
        copy.sentinelMaster?.password = nil
        if var ssh = copy.ssh {
            switch ssh.auth {
            case .password: ssh.auth = .password(nil)
            case .privateKey: ssh.auth = .privateKey(pem: nil, passphrase: nil)
            }

            copy.ssh = ssh
        }

        return copy
    }

    /// Builds the client recipe. Pass the certificates referenced by `tls` (with the client key loaded).
    public func clientDescriptor(caCertificate: CACertificate? = nil, clientCertificate: ClientCertificate? = nil,
                                 clientName: String? = nil, dbOverride: Int? = nil) -> RedisClientDescriptor {
        var tlsConfig: TLSConfig?
        if tls.enabled {
            tlsConfig = TLSConfig(caCertificatePEM: caCertificate?.certificate,
                                  clientCertificatePEM: clientCertificate?.certificate,
                                  clientKeyPEM: clientCertificate?.key,
                                  verifyServerCertificate: tls.verifyServerCert,
                                  serverName: tls.servername)
        }

        let connection = RedisConnectionConfig(
            host: host, port: port, family: connectionFamily.ipFamily, username: username, password: password,
            dbIndex: dbOverride ?? dbIndex, tls: tlsConfig, connectTimeout: TimeInterval(timeoutMs) / 1000,
            clientName: clientName)
        let topology: RedisTopology
        switch connectionType {
        case .cluster where !forceStandalone:
            topology = .cluster(seeds: [endpoint] + (nodes ?? []).filter { $0 != endpoint })
        case .sentinel:
            topology = .sentinel(masterName: sentinelMaster?.name ?? "", sentinels: [endpoint] + (nodes ?? []),
                                 sentinelUsername: username, sentinelPassword: password)
        default:
            topology = .standalone(endpoint)
        }

        var descriptorConnection = connection
        if case .sentinel = topology {
            descriptorConnection.username = sentinelMaster?.username
            descriptorConnection.password = sentinelMaster?.password
        }

        var sshOptions: SSHTunnelOptions?
        if let ssh {
            let auth: SSHTunnelAuth
            switch ssh.auth {
            case .password(let p): auth = .password(p ?? "")
            case .privateKey(let pem, let passphrase): auth = .privateKey(pem: pem ?? "", passphrase: passphrase)
            }

            sshOptions = SSHTunnelOptions(sshHost: ssh.host, sshPort: ssh.port, username: ssh.username, auth: auth,
                                          remoteHost: host, remotePort: port,
                                          connectTimeout: TimeInterval(timeoutMs) / 1000)
        }

        return RedisClientDescriptor(topology: topology, connection: descriptorConnection, ssh: sshOptions,
                                     preConnectScript: preConnectScript, forceStandalone: forceStandalone)
    }
}

/// Who a pooled client is for; sent as part of `CLIENT SETNAME keystrand-<context>-<first 8 characters of the id>`.
public enum ClientContext: String, Codable, Sendable, Hashable, CaseIterable {
    case common
    case browser
    case cli
    case workbench
    case profiler
    case events
    /// Long-running work (Database Analysis, Bulk Delete, overview polling) kept off the interactive `.common` client.
    case background
}

// Malformed edits, unknown enum values and missing fields fall back to defaults so databases.json stays readable.
// Only `id` and nested `host`/`name` identifiers are required.

extension DatabaseConfig {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(DatabaseID.self, forKey: .id),
                  name: c.optionalValue(.name), host: c.value(.host, default: "127.0.0.1"),
                  port: c.value(.port, default: 6379), db: c.optionalValue(.db), username: c.optionalValue(.username),
                  password: c.optionalValue(.password), timeoutMs: c.value(.timeoutMs, default: 30_000),
                  connectionType: c.value(.connectionType, default: .notConnected),
                  nameFromProvider: c.optionalValue(.nameFromProvider), provider: c.optionalValue(.provider),
                  lastConnection: c.optionalValue(.lastConnection), createdAt: c.value(.createdAt, default: Date()),
                  isNew: c.value(.isNew, default: false), sentinelMaster: c.optionalValue(.sentinelMaster),
                  nodes: c.lossyArray(.nodes), modules: c.lossyArray(.modules) ?? [],
                  version: c.optionalValue(.version), tls: c.value(.tls, default: TLSSettings()),
                  ssh: c.optionalValue(.ssh), compressor: c.value(.compressor, default: .none),
                  keyNameFormat: c.value(.keyNameFormat, default: .unicode),
                  forceStandalone: c.value(.forceStandalone, default: false), tags: c.lossyArray(.tags) ?? [],
                  environment: c.value(.environment, default: .unspecified),
                  connectionFamily: c.value(.connectionFamily, default: .auto),
                  preConnectScript: c.optionalValue(.preConnectScript),
                  postDisconnectScript: c.optionalValue(.postDisconnectScript))
    }
}

extension TLSSettings {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: c.value(.enabled, default: false), servername: c.optionalValue(.servername),
                  verifyServerCert: c.value(.verifyServerCert, default: false),
                  caCertID: c.optionalValue(.caCertID), clientCertID: c.optionalValue(.clientCertID))
    }
}

extension SSHOptions {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(host: try c.decode(String.self, forKey: .host), port: c.value(.port, default: 22),
                  username: c.value(.username, default: ""), auth: c.value(.auth, default: .password(nil)))
    }
}

extension SentinelMasterConfig {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), username: c.optionalValue(.username),
                  password: c.optionalValue(.password))
    }
}

extension RedisModuleInfo {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), version: c.optionalValue(.version),
                  semanticVersion: c.optionalValue(.semanticVersion))
    }
}
