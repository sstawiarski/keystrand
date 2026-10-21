import Foundation

public enum DatabaseStoreError: Error, LocalizedError, Sendable, Equatable {
    case notFound(DatabaseID)
    case importFailed(String)
    case alreadyExists(DatabaseID)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Invalid database instance id."
        case .importFailed(let message): return message
        case .alreadyExists: return "A database with this id already exists."
        }
    }
}

/// Result of importing a RedisInsight-compatible JSON export.
public struct DatabaseImportResult: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public enum Status: String, Sendable { case success, partial, fail }
        public var index: Int
        public var status: Status
        public var host: String?
        public var port: Int?
        public var errors: [String]
        /// The saved database (success and partial items).
        public var databaseID: DatabaseID?
        /// Shell scripts the file carried, removed from the saved database until the user keeps them.
        public var strippedScripts: ConnectionScripts?

        public init(index: Int, status: Status, host: String? = nil, port: Int? = nil, errors: [String] = [],
                    databaseID: DatabaseID? = nil, strippedScripts: ConnectionScripts? = nil) {
            self.index = index
            self.status = status
            self.host = host
            self.port = port
            self.errors = errors
            self.databaseID = databaseID
            self.strippedScripts = strippedScripts
        }
    }

    /// Pre-connect and post-disconnect shell scripts of one database.
    public struct ConnectionScripts: Hashable, Sendable {
        public var preConnect: String?
        public var postDisconnect: String?

        public init(preConnect: String?, postDisconnect: String?) {
            self.preConnect = preConnect
            self.postDisconnect = postDisconnect
        }

        /// The scripts of `config`, or nil when it has none.
        public init?(of config: DatabaseConfig) {
            let pre = config.preConnectScript.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let post = config.postDisconnectScript.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            guard pre != nil || post != nil else { return nil }
            self.init(preConnect: pre, postDisconnect: post)
        }
    }

    public var total: Int
    public var items: [Item]

    public init(total: Int, items: [Item]) {
        self.total = total
        self.items = items
    }

    public var success: [Item] { items.filter { $0.status == .success } }
    public var partial: [Item] { items.filter { $0.status == .partial } }
    public var fail: [Item] { items.filter { $0.status == .fail } }
}

/// Saved databases: non-secret fields in `databases.json`, secrets in the `SecretStore`.
public actor DatabaseStore {
    private let paths: AppPaths
    private let secrets: any SecretStore
    /// Resolves and creates TLS certificates for export / import.
    private let certificates: CertificateStore?
    private var cache: [DatabaseConfig]?
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Maximum import file size (10 MB).
    public static let maxImportBytes = 10 * 1024 * 1024

    public init(paths: AppPaths, secrets: any SecretStore, certificates: CertificateStore? = nil) {
        self.paths = paths
        self.secrets = secrets
        self.certificates = certificates
    }

    /// All databases, secrets not loaded.
    public func list() throws -> [DatabaseConfig] {
        try loadAll()
    }

    /// Whether `id` is saved (reads `databases.json` only, never the secret store).
    public func contains(_ id: DatabaseID) throws -> Bool {
        try loadAll().contains { $0.id == id }
    }

    /// One database with secrets filled in from the secret store.
    public func get(_ id: DatabaseID) throws -> DatabaseConfig {
        guard var config = try loadAll().first(where: { $0.id == id }) else { throw DatabaseStoreError.notFound(id) }
        config.password = try secrets.secret(for: SecretAccount.password(id))
        if config.sentinelMaster != nil {
            config.sentinelMaster?.password = try secrets.secret(for: SecretAccount.sentinelPassword(id))
        }

        if var ssh = config.ssh {
            switch ssh.auth {
            case .password:
                ssh.auth = .password(try secrets.secret(for: SecretAccount.sshPassword(id)))
            case .privateKey:
                ssh.auth = .privateKey(pem: try secrets.secret(for: SecretAccount.sshPrivateKey(id)),
                                       passphrase: try secrets.secret(for: SecretAccount.sshPassphrase(id)))
            }

            config.ssh = ssh
        }

        return config
    }

    @discardableResult
    public func create(_ config: DatabaseConfig) throws -> DatabaseConfig {
        var all = try loadAll()
        guard !all.contains(where: { $0.id == config.id }) else { throw DatabaseStoreError.alreadyExists(config.id) }
        all.append(config.withoutSecrets())
        try writeSecrets(of: config)
        try persist(all)
        return config.withoutSecrets()
    }

    /// Replaces the stored database (secrets included: `nil` secrets are deleted).
    public func update(_ config: DatabaseConfig) throws {
        var all = try loadAll()
        guard let index = all.firstIndex(where: { $0.id == config.id }) else { throw DatabaseStoreError.notFound(config.id) }
        all[index] = config.withoutSecrets()
        try writeSecrets(of: config)
        try persist(all)
    }

    /// Mutates non-secret fields only (lastConnection, modules, version, isNew, ...).
    @discardableResult
    public func modify(_ id: DatabaseID, _ change: @Sendable (inout DatabaseConfig) -> Void) throws -> DatabaseConfig {
        var all = try loadAll()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw DatabaseStoreError.notFound(id) }
        change(&all[index])
        all[index] = all[index].withoutSecrets()
        try persist(all)
        return all[index]
    }

    public func delete(_ ids: [DatabaseID]) throws {
        let set = Set(ids)
        let all = try loadAll().filter { !set.contains($0.id) }
        for id in ids {
            for account in SecretAccount.all(for: id) { try? secrets.setSecret(nil, for: account) }
        }

        try persist(all)
    }

    /// Distinct tags across all databases.
    public func allTags() throws -> [DatabaseTag] {
        var seen = Set<DatabaseTag>()
        var out: [DatabaseTag] = []
        for tag in try loadAll().flatMap(\.tags) where seen.insert(tag).inserted { out.append(tag) }
        return out
    }

    /// RedisInsight-compatible export (JSON array). Missing ids are skipped.
    public func export(ids: [DatabaseID], includeSecrets: Bool) async throws -> Data {
        var items: [[String: Any]] = []
        for id in ids {
            guard let config = try? get(id) else { continue }
            var ca: CACertificate?
            var client: ClientCertificate?
            if let certificates {
                if let caID = config.tls.caCertID { ca = try? await certificates.caCertificate(caID) }
                if let clientID = config.tls.clientCertID { client = try? await certificates.clientCertificate(clientID) }
            }

            items.append(DatabaseExportFormat.object(for: config, ca: ca, client: client, includeSecrets: includeSecrets))
        }

        return try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
    }

    /// Imports database exports from RedisInsight, redis-commander and other tools.
    /// Unless `keepScripts` is true, removes connection scripts and reports them in each result item for review.
    public func importDatabases(from data: Data, filename: String,
                                keepScripts: Bool = false) async throws -> DatabaseImportResult {
        guard !data.isEmpty else { throw DatabaseStoreError.importFailed("No file was chosen to import.") }
        guard data.count <= Self.maxImportBytes else {
            throw DatabaseStoreError.importFailed("The file is larger than the 10 MB import limit.")
        }
        let shortName = filename.count > 50 ? String(filename.prefix(50)) + "..." : filename
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let array = parsed as? [Any], !array.isEmpty else {
            throw DatabaseStoreError.importFailed("Unable to parse \(shortName)")
        }
        var items: [DatabaseImportResult.Item] = []
        for (index, element) in array.enumerated() {
            guard let object = element as? [String: Any] else {
                items.append(.init(index: index, status: .fail, errors: ["Invalid database data"]))
                continue
            }
            var mapped = DatabaseExportFormat.mapImport(object)
            var errors = mapped.errors
            let scripts = keepScripts ? nil : DatabaseImportResult.ConnectionScripts(of: mapped.config)
            if !keepScripts {
                mapped.config.preConnectScript = nil
                mapped.config.postDisconnectScript = nil
            }

            do {
                try await attachCertificates(&mapped, errors: &errors)
                try DatabaseExportFormat.validate(mapped.config)
                try create(mapped.config)
                items.append(.init(index: index, status: errors.isEmpty ? .success : .partial,
                                   host: mapped.config.host, port: mapped.config.port, errors: errors,
                                   databaseID: mapped.config.id, strippedScripts: scripts))
            } catch {
                items.append(.init(index: index, status: .fail, host: mapped.config.host.isEmpty ? nil : mapped.config.host,
                                   port: mapped.config.port, errors: errors + [error.localizedDescription]))
            }
        }

        return DatabaseImportResult(total: array.count, items: items)
    }

    /// Saves (or, with nil, removes) the scripts of an imported database after the user reviewed them.
    public func restoreScripts(_ scripts: DatabaseImportResult.ConnectionScripts?, for id: DatabaseID) throws {
        try modify(id) { config in
            config.preConnectScript = scripts?.preConnect
            config.postDisconnectScript = scripts?.postDisconnect
        }
    }

    /// Creates (or reuses identical) CA / client certificates for an imported item.
    private func attachCertificates(_ mapped: inout DatabaseExportFormat.Mapped, errors: inout [String]) async throws {
        if let ca = mapped.caCertificate {
            if let certificates {
                let existing = try await certificates.listCA()
                if let same = existing.first(where: { $0.certificate == ca.certificate }) {
                    mapped.config.tls.caCertID = same.id
                } else {
                    let name = Self.uniqueName(ca.name, taken: Set(existing.map(\.name)))
                    let created = try await certificates.addCA(CACertificate(name: name, certificate: ca.certificate))
                    mapped.config.tls.caCertID = created.id
                }
            } else {
                errors.append("Certificates are not supported by this store")
            }
        }

        if let client = mapped.clientCertificate {
            if let certificates {
                let existing = try await certificates.listClient()
                var reused: ClientCertificate?
                for candidate in existing where candidate.certificate == client.certificate {
                    if let full = try await certificates.clientCertificate(candidate.id), full.key == client.key {
                        reused = full
                        break
                    }
                }

                if let reused {
                    mapped.config.tls.clientCertID = reused.id
                } else {
                    let name = Self.uniqueName(client.name, taken: Set(existing.map(\.name)))
                    let created = try await certificates.addClient(
                        ClientCertificate(name: name, certificate: client.certificate, key: client.key))
                    mapped.config.tls.clientCertID = created.id
                }
            } else {
                errors.append("Certificates are not supported by this store")
            }
        }
    }

    /// `name`, or `"<n>_<name>"` with the first free n.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var n = 1
        while taken.contains("\(n)_\(name)") { n += 1 }
        return "\(n)_\(name)"
    }

    /// Emits after every successful write. Each call returns an independent stream.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    // MARK: - Private

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func loadAll() throws -> [DatabaseConfig] {
        if let cache { return cache }
        let loaded = DatabaseFile.load(from: paths.databasesFile)
        cache = loaded
        return loaded
    }

    private func persist(_ all: [DatabaseConfig]) throws {
        try JSONFile.save(DatabaseFile(databases: all), to: paths.databasesFile)
        cache = all
        for continuation in subscribers.values { continuation.yield() }
    }

    private func writeSecrets(of config: DatabaseConfig) throws {
        let id = config.id
        try secrets.setSecret(config.password, for: SecretAccount.password(id))
        try secrets.setSecret(config.sentinelMaster?.password, for: SecretAccount.sentinelPassword(id))
        var sshPassword: String?
        var sshKey: String?
        var sshPassphrase: String?
        if let ssh = config.ssh {
            switch ssh.auth {
            case .password(let p): sshPassword = p
            case .privateKey(let pem, let passphrase): sshKey = pem; sshPassphrase = passphrase
            }
        }

        try secrets.setSecret(sshPassword, for: SecretAccount.sshPassword(id))
        try secrets.setSecret(sshKey, for: SecretAccount.sshPrivateKey(id))
        try secrets.setSecret(sshPassphrase, for: SecretAccount.sshPassphrase(id))
    }
}

/// The `databases.json` layout: `{"schemaVersion": n, "databases": [...]}`. A bare array is the unversioned layout.
struct DatabaseFile: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var databases: [DatabaseConfig]
    /// Records that failed to decode and were left out of `databases`.
    private(set) var droppedCount = 0

    init(databases: [DatabaseConfig]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.databases = databases
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, default: Self.currentSchemaVersion)
        guard let elements = try c.decodeIfPresent([LossyElement<DatabaseConfig>].self, forKey: .databases) else {
            throw DecodingError.keyNotFound(CodingKeys.databases, .init(codingPath: [], debugDescription: "No databases"))
        }
        databases = elements.compactMap(\.value)
        droppedCount = elements.count - databases.count
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, databases
    }

    /// Loads decodable records; returns [] if the file is missing.
    /// Backs up the original beside it if the file is unreadable, drops records or comes from a newer version.
    static func load(from url: URL) -> [DatabaseConfig] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONFile.makeDecoder()
        guard let data = try? Data(contentsOf: url) else {
            DataFileBackup.preserve(url, label: "damaged")
            return []
        }
        if let file = try? decoder.decode(DatabaseFile.self, from: data) {
            if file.schemaVersion > currentSchemaVersion {
                DataFileBackup.preserve(url, label: "v\(file.schemaVersion)")
            } else if file.droppedCount > 0 {
                DataFileBackup.preserve(url, label: "damaged")
            }

            return file.databases
        }

        if let elements = try? decoder.decode([LossyElement<DatabaseConfig>].self, from: data) {
            let databases = elements.compactMap(\.value)
            if databases.count != elements.count { DataFileBackup.preserve(url, label: "damaged") }
            return databases
        }

        DataFileBackup.preserve(url, label: "damaged")
        return []
    }
}
