import Foundation
import Observation
import RedisCore

/// One database of a Redis Software (Enterprise) cluster (`GET /v1/bdbs`).
public struct SoftwareDatabase: Identifiable, Hashable, Sendable {
    public enum Option: String, CaseIterable, Hashable, Sendable {
        case activeActive = "Active-Active"
        case backup = "Backup"
        case clustering = "Clustering"
        case persistence = "Persistence"
        case flash = "Flash"
        case replication = "Replication"
        case replicaDestination = "Replica Destination"
        case replicaSource = "Replica Source"

        public var systemImage: String {
            switch self {
            case .activeActive: return "arrow.triangle.2.circlepath"
            case .backup: return "externaldrive"
            case .clustering: return "square.grid.3x3"
            case .persistence: return "internaldrive"
            case .flash: return "bolt"
            case .replication: return "doc.on.doc"
            case .replicaDestination: return "arrow.down.doc"
            case .replicaSource: return "arrow.up.doc"
            }
        }
    }

    public var uid: Int
    public var name: String
    public var dnsName: String
    public var address: String
    public var port: Int
    public var status: String
    public var tls: Bool
    public var password: String?
    public var modules: [RedisModuleInfo]
    public var tags: [DatabaseTag]
    public var options: [Option]
    public var persistencePolicy: String?

    public var id: Int { uid }
    public var endpoint: String { "\(dnsName):\(port)" }

    public func tooltip(for option: Option) -> String {
        option == .persistence ? (persistencePolicy ?? option.rawValue) : option.rawValue
    }
}

public enum SoftwareDiscoveryError: Error, LocalizedError, Sendable {
    case unauthorized(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let endpoint): return "\(endpoint) rejected the username or password."
        case .unavailable(let endpoint): return "Couldn't reach \(endpoint). Check the host, port, and network."
        }
    }
}

/// Redis Software REST discovery (self-signed certificates accepted).
public enum SoftwareAPI {
    static let moduleNames: [String: String] = [
        "ai": "ai", "graph": "graph", "gears": "rg", "rg": "rg", "bf": "bf", "rejson": "ReJSON", "search": "search",
        "timeseries": "timeseries", "searchlight": "search", "ft": "search",
    ]

    public static func fetch(host: String, port: Int, username: String, password: String) async throws
        -> [SoftwareDatabase] {
        let endpoint = "\(host):\(port)"
        guard let url = URL(string: "https://\(endpoint)/v1/bdbs") else { throw SoftwareDiscoveryError.unavailable(endpoint) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: TrustAllDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SoftwareDiscoveryError.unavailable(endpoint)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw SoftwareDiscoveryError.unauthorized(endpoint) }
        guard (200..<300).contains(status) else { throw SoftwareDiscoveryError.unavailable(endpoint) }
        return parse(data)
    }

    /// Databases with an external endpoint, sorted by name.
    public static func parse(_ data: Data) -> [SoftwareDatabase] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let replicaSourceURIs = array.flatMap { bdb -> [String] in
            ((bdb["replica_sources"] as? [[String: Any]]) ?? []).compactMap { $0["uri"] as? String }
        }
        return array.compactMap { bdb -> SoftwareDatabase? in
            let endpoints = (bdb["endpoints"] as? [[String: Any]]) ?? []
            guard let external = endpoints.first(where: { ($0["addr_type"] as? String) == "external" }),
                  let uid = bdb["uid"] as? Int else { return nil }
            let dnsName = external["dns_name"] as? String ?? ""
            let address = (external["addr"] as? [String])?.first ?? ""
            let port = external["port"] as? Int ?? 0
            var name = bdb["name"] as? String ?? "db-\(uid)"
            let crdt = bdb["crdt"] as? Bool ?? false
            if crdt, let replica = bdb["crdt_replica_id"] { name += "-\(replica)" }
            let modules = ((bdb["module_list"] as? [[String: Any]]) ?? []).compactMap { module -> RedisModuleInfo? in
                guard let raw = module["module_name"] as? String else { return nil }
                return RedisModuleInfo(name: moduleNames[raw.lowercased()] ?? raw,
                                       semanticVersion: module["semantic_version"] as? String)
            }
            let tags = ((bdb["tags"] as? [[String: Any]]) ?? []).compactMap { tag -> DatabaseTag? in
                guard let key = tag["key"] as? String, let value = tag["value"] as? String else { return nil }
                return DatabaseTag(key: key, value: value)
            }
            var options: [SoftwareDatabase.Option] = []
            if crdt { options.append(.activeActive) }
            if bdb["backup"] as? Bool ?? false { options.append(.backup) }
            if (bdb["shards_count"] as? Int ?? 1) > 1 { options.append(.clustering) }
            let persistence = bdb["data_persistence"] as? String ?? "disabled"
            if persistence != "disabled" { options.append(.persistence) }
            if bdb["bigstore"] as? Bool ?? false { options.append(.flash) }
            if bdb["replication"] as? Bool ?? false { options.append(.replication) }
            if !((bdb["replica_sources"] as? [Any]) ?? []).isEmpty { options.append(.replicaDestination) }
            if replicaSourceURIs.contains(where: { $0.contains("\(dnsName):\(port)") }) { options.append(.replicaSource) }
            return SoftwareDatabase(
                uid: uid, name: name, dnsName: dnsName, address: address, port: port,
                status: bdb["status"] as? String ?? "", tls: (bdb["tls_mode"] as? String) == "enabled",
                password: bdb["authentication_redis_pass"] as? String, modules: modules, tags: tags,
                options: options, persistencePolicy: persistencePolicy(bdb))
        }.sorted { $0.name < $1.name }
    }

    static func persistencePolicy(_ bdb: [String: Any]) -> String? {
        switch bdb["data_persistence"] as? String {
        case "aof":
            return (bdb["aof_policy"] as? String) == "appendfsync-every-sec"
                ? "AOF, fsync every second" : "AOF, fsync on every write"
        case "snapshot":
            let secs = ((bdb["snapshot_policy"] as? [[String: Any]]) ?? []).last?["secs"] as? Int
            switch secs {
            case 3600: return "RDB snapshot every hour"
            case 21_600: return "RDB snapshot every 6 hours"
            case 43_200: return "RDB snapshot every 12 hours"
            default: return "RDB snapshots"
            }
        default:
            return nil
        }
    }
}

private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Discovers Redis Software databases and reports results.
@MainActor
@Observable
public final class SoftwareDiscoveryModel {
    public enum Stage: Sendable, Equatable { case form, discovery, results }

    public struct ResultRow: Identifiable, Sendable, Equatable {
        public var database: SoftwareDatabase
        public var added: Bool
        public var message: String
        public var id: Int { database.uid }
    }

    public var stage: Stage = .form
    public var host = "" { didSet { let v = InputRules.compact(host, 200); if v != host { host = v } } }
    public var port = "9443"
    public var username = ""
    public var password = ""
    public var databases: [SoftwareDatabase] = []
    public var selected: Set<Int> = []
    public var searchText = ""
    public var results: [ResultRow] = []
    public private(set) var isWorking = false
    public var error: String?

    @ObservationIgnored private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var missingFields: [String] {
        var missing: [String] = []
        if host.isEmpty { missing.append("Cluster Host") }
        if Int(port) == nil { missing.append("Cluster Port") }
        if username.isEmpty { missing.append("Admin Username") }
        if password.isEmpty { missing.append("Admin Password") }
        return missing
    }

    @discardableResult
    public func hostChanged(from old: String, to new: String) -> Bool {
        guard new.count - old.count > 1, let parsed = ConnectionURLParser.parse(new) else { return false }
        host = parsed.host
        port = String(parsed.port ?? 9443)
        if !parsed.username.isEmpty { username = parsed.username }
        if !parsed.password.isEmpty { password = parsed.password }
        return true
    }

    public var filtered: [SoftwareDatabase] {
        let needle = searchText.lowercased()
        guard !needle.isEmpty else { return databases }
        return databases.filter {
            $0.name.lowercased().contains(needle) || $0.dnsName.lowercased().contains(needle)
                || String($0.port).contains(needle)
        }
    }

    public var addDisabledReason: String? {
        selected.isEmpty ? "Select at least one database\nNo databases selected." : nil
    }

    public func discover() async {
        guard missingFields.isEmpty, !isWorking, let portValue = Int(port) else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            databases = try await SoftwareAPI.fetch(host: host, port: portValue, username: username, password: password)
            selected = []
            stage = .discovery
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func addSelected() async {
        guard addDisabledReason == nil, !isWorking, let portValue = Int(port) else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        let current: [SoftwareDatabase]
        do {
            current = try await SoftwareAPI.fetch(host: host, port: portValue, username: username, password: password)
        } catch {
            self.error = error.localizedDescription
            return
        }

        let factory = DatabaseFactory(clientFactory: services.clientFactory)
        var rows: [ResultRow] = []
        for uid in selected.sorted() {
            guard let database = current.first(where: { $0.uid == uid }) ?? databases.first(where: { $0.uid == uid }),
                  current.contains(where: { $0.uid == uid }) else {
                if let known = databases.first(where: { $0.uid == uid }) {
                    rows.append(ResultRow(database: known, added: false, message: "Not Found"))
                }

                continue
            }
            let config = DatabaseConfig(
                name: database.name, host: host == "localhost" ? "localhost" : database.dnsName, port: database.port,
                password: database.password, connectionType: .standalone, nameFromProvider: database.name,
                provider: .redisSoftware, isNew: true, modules: database.modules,
                tls: TLSSettings(enabled: database.tls), tags: database.tags)
            do {
                var detected = try await factory.createDetected(config)
                detected.isNew = true
                try await services.saveDatabase(detected)
                rows.append(ResultRow(database: database, added: true, message: "Added"))
            } catch {
                rows.append(ResultRow(database: database, added: false,
                                      message: ConnectionError.classify(error, endpoint: config.endpoint).message))
            }
        }

        results = rows
        stage = .results
    }

    /// "Added 2 databases. 1 failed."
    public var summaryText: String {
        SentinelFlowModel.summary(added: addedCount, failed: failedCount, noun: "database")
    }

    public var addedCount: Int { results.filter(\.added).count }
    public var failedCount: Int { results.count - addedCount }
}
