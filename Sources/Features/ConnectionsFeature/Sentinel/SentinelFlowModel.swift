import Foundation
import Observation
import RedisCore

/// Discovers Sentinel primary groups, adds selected groups, and reports results.
@MainActor
@Observable
public final class SentinelFlowModel {
    public enum Stage: Sendable, Equatable { case form, discovery, results }

    public enum RowResult: Sendable, Equatable {
        case added(DatabaseID)
        case failed(ConnectionError)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public struct Row: Identifiable, Sendable, Equatable {
        public let id: String
        public var master: SentinelMasterInfo
        public var alias: String
        public var username = ""
        public var password = ""
        public var db = ""
        public var isSelected = false
        public var isAdding = false
        public var result: RowResult?

        public init(id: String, master: SentinelMasterInfo) {
            self.id = id
            self.master = master
            self.alias = master.name
        }

        public var dbValue: Int? {
            let text = db.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return Int(text).flatMap { $0 >= 0 ? $0 : nil }
        }

        /// Failures caused by auth, bad input or encryption can be fixed inline and retried.
        public var isRetryable: Bool {
            guard case .failed(let error) = result else { return false }
            return [.unauthorized, .failed, .incorrectCertificate, .defaultUserDisabled, .sentinelMasterRequired]
                .contains(error.code)
        }
    }

    public var stage: Stage = .form

    public var host = "127.0.0.1" { didSet { let v = InputRules.compact(host, 200); if v != host { host = v } } }
    public var port = "26379"
    public var connectionFamily: ConnectionFamily = .auto
    public var username = ""
    public var password = ""
    public let tls: TLSFormModel
    public let certificates: CertificateCatalog

    public var rows: [Row] = []
    public var searchText = ""

    public private(set) var isWorking = false
    public var error: ConnectionError?

    @ObservationIgnored public let services: AppServices
    @ObservationIgnored private let factory: DatabaseFactory

    public init(services: AppServices, certificates: CertificateCatalog? = nil, tls: TLSFormModel? = nil,
                prefill: DatabaseConfig? = nil) {
        self.services = services
        self.certificates = certificates ?? CertificateCatalog(services: services)
        self.tls = tls ?? TLSFormModel()
        self.factory = DatabaseFactory(clientFactory: services.clientFactory)
        if let prefill {
            host = prefill.host
            port = String(prefill.port)
            connectionFamily = prefill.connectionFamily
            username = prefill.username == "default" ? "" : (prefill.username ?? "")
            password = prefill.password ?? ""
            if tls == nil {
                self.tls.enabled = prefill.tls.enabled
                self.tls.verifyServerCert = prefill.tls.verifyServerCert
            }
        }

        self.tls.sniDefault = { [weak self] in self?.host ?? "" }
    }

    // MARK: - Form

    public var portValue: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (0...65_535).contains(value) else { return nil }
        return value
    }

    public var missingFields: [String] {
        var missing: [String] = []
        if host.isEmpty { missing.append("Host") }
        if portValue == nil { missing.append("Port") }
        return missing + tls.missingFields
    }

    /// Autofills host / port / credentials / TLS from a pasted URL (port defaults to 26379).
    @discardableResult
    public func hostChanged(from old: String, to new: String) -> Bool {
        guard new.count - old.count > 1, new.contains(":") else { return false }
        let pasted = new.hasPrefix(old) ? String(new.dropFirst(old.count)) : new
        guard let parsed = ConnectionURLParser.parse(pasted) ?? ConnectionURLParser.parse(new) else { return false }
        host = parsed.host
        port = String(parsed.port ?? 26379)
        username = parsed.username
        password = parsed.password
        tls.enabled = parsed.tls
        return true
    }

    /// Sentinel endpoint and credentials as a standalone draft.
    public func sentinelDraft() -> DatabaseConfig {
        DatabaseConfig(name: "\(host):\(portValue ?? 26379)", host: host, port: portValue ?? 26379,
                       username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password,
                       connectionType: .standalone, tls: tls.settings, connectionFamily: connectionFamily)
    }

    // MARK: - Discovery

    /// `SENTINEL MASTERS` on the sentinel; switches to the discovery stage on success.
    public func discover() async {
        guard missingFields.isEmpty, !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        let draft = sentinelDraft()
        do {
            let certs = try await tls.resolveCertificates(services, catalog: certificates)
            let masters = try await Self.fetchMasters(draft, ca: certs.ca, client: certs.client,
                                                      factory: services.clientFactory)
            rows = masters.enumerated().map { Row(id: String($0.offset + 1), master: $0.element) }
            searchText = ""
            stage = .discovery
        } catch {
            self.error = DatabaseFormModel.connectionError(error, endpoint: draft.endpoint)
        }
    }

    static func fetchMasters(_ draft: DatabaseConfig, ca: CACertificate?, client: ClientCertificate?,
                             factory: RedisClientFactory) async throws -> [SentinelMasterInfo] {
        var descriptor = draft.clientDescriptor(caCertificate: ca, clientCertificate: client,
                                                clientName: "keystrand-sentinel-discovery", dbOverride: 0)
        descriptor.connection.readyCheck = false
        descriptor.connection.retry = .none
        descriptor.ssh = nil
        let connection = try await factory.makeDedicatedConnection(descriptor)
        do {
            let reply = try await connection.execute(["SENTINEL", "MASTERS"])
            await connection.close()
            return SentinelResolver.parseMasters(reply).sorted { $0.name < $1.name }
        } catch {
            await connection.close()
            throw mapDiscoveryError(error, endpoint: draft.endpoint)
        }
    }

    static func mapDiscoveryError(_ error: Error, endpoint: RedisEndpoint) -> Error {
        guard let server = (error as? RedisClientError)?.serverError else { return error }
        let message = server.message
        if message.lowercased().contains("unknown command") {
            return ConnectionError(code: .failed, title: "Not a Sentinel",
                                   message: "This endpoint didn't answer as a Redis Sentinel. Add it as a regular database with its host and port instead.")
        }

        if message.uppercased().hasPrefix("NOPERM") {
            return ConnectionError(code: .failed, title: "Permission denied", message: message)
        }

        return ConnectionError.classify(error, endpoint: endpoint)
    }

    public var filteredRows: [Row] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            [row.master.name, row.master.host, row.alias, row.username, String(row.master.port),
             String(row.master.numberOfSlaves)].contains { $0.lowercased().contains(needle) }
        }
    }

    public var selectedRows: [Row] { rows.filter(\.isSelected) }

    public var allSelected: Bool { !rows.isEmpty && rows.allSatisfy(\.isSelected) }

    public func setAllSelected(_ selected: Bool) {
        for index in rows.indices { rows[index].isSelected = selected }
    }

    public func binding(for id: String) -> Int? { rows.firstIndex { $0.id == id } }

    /// Why "Add Primary Group" is disabled, or nil.
    public var addDisabledReason: String? {
        let selected = selectedRows
        if selected.isEmpty { return "Choose at least one primary group." }
        let missing = selected.filter { $0.alias.trimmingCharacters(in: .whitespaces).isEmpty }
        if !missing.isEmpty { return "Fill in the required fields (\(missing.count)):\nDatabase Alias" }
        if selected.contains(where: { !$0.db.isEmpty && $0.dbValue == nil }) { return "Database index must be a number ≥ 0" }
        return nil
    }

    // MARK: - Adding

    /// Adds every selected primary group (in parallel) and switches to the results stage. When the shared
    /// certificate step fails nothing is added and the discovery stage stays with the error shown.
    public func addSelected() async {
        guard addDisabledReason == nil, !isWorking else { return }
        guard await add(ids: selectedRows.map(\.id)) else { return }
        rows = rows.filter(\.isSelected)
        stage = .results
    }

    /// Retries one failed row with its edited values.
    public func retry(_ id: String) async {
        guard !isWorking else { return }
        await add(ids: [id])
    }

    /// Returns false when nothing was attempted because the certificates could not be prepared.
    @discardableResult
    private func add(ids: [String]) async -> Bool {
        isWorking = true
        error = nil
        defer { isWorking = false }
        let draft = sentinelDraft()
        let tlsSettings: TLSSettings
        let certs: (ca: CACertificate?, client: ClientCertificate?)
        do {
            certs = try await tls.resolveCertificates(services, catalog: certificates)
            tlsSettings = try await tls.persistNewCertificates(services, ca: certs.ca, client: certs.client)
            await certificates.load()
        } catch {
            self.error = DatabaseFormModel.connectionError(error, endpoint: draft.endpoint)
            return false
        }

        var configs: [(String, DatabaseConfig)] = []
        for id in ids {
            guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
            rows[index].isAdding = true
            configs.append((id, Self.databaseConfig(for: rows[index], sentinel: draft, tls: tlsSettings)))
        }

        let factory = self.factory
        let results = await withTaskGroup(of: (String, Result<DatabaseConfig, Error>).self) { group in
            for (id, config) in configs {
                group.addTask {
                    do {
                        var detected = try await factory.createDetected(config, caCertificate: certs.ca,
                                                                        clientCertificate: certs.client)
                        detected.isNew = true
                        return (id, .success(detected))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            var collected: [(String, Result<DatabaseConfig, Error>)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        for (id, result) in results {
            guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
            rows[index].isAdding = false
            switch result {
            case .success(let config):
                do {
                    try await services.saveDatabase(config)
                    rows[index].result = .added(config.id)
                } catch {
                    rows[index].result = .failed(DatabaseFormModel.connectionError(error, endpoint: draft.endpoint))
                }
            case .failure(let error):
                rows[index].result = .failed(DatabaseFormModel.connectionError(error, endpoint: draft.endpoint))
            }
        }
        return true
    }

    /// One saved database per primary group: sentinel endpoint + credentials, master auth, logical db.
    static func databaseConfig(for row: Row, sentinel: DatabaseConfig, tls: TLSSettings) -> DatabaseConfig {
        DatabaseConfig(
            name: row.alias.trimmingCharacters(in: .whitespaces), host: sentinel.host, port: sentinel.port,
            db: row.dbValue, username: sentinel.username, password: sentinel.password,
            connectionType: .sentinel, isNew: true,
            sentinelMaster: SentinelMasterConfig(name: row.master.name,
                                                 username: row.username.isEmpty ? nil : row.username,
                                                 password: row.password.isEmpty ? nil : row.password),
            tls: tls, connectionFamily: sentinel.connectionFamily)
    }

    // MARK: - Results

    /// Failures first, then by primary group name.
    public var resultRows: [Row] {
        rows.sorted { lhs, rhs in
            let l = lhs.result?.isFailure ?? false
            let r = rhs.result?.isFailure ?? false
            return l == r ? lhs.master.name < rhs.master.name : l
        }
    }

    public var addedCount: Int { rows.filter { if case .added = $0.result { return true } else { return false } }.count }
    public var failedCount: Int { rows.filter { $0.result?.isFailure ?? false }.count }

    /// "Added 3 primary groups. 1 failed."
    public var summaryText: String {
        Self.summary(added: addedCount, failed: failedCount, noun: "primary group")
    }

    nonisolated static func summary(added: Int, failed: Int, noun: String) -> String {
        let addedText = "Added \(added) \(noun)\(added == 1 ? "" : "s")."
        return failed > 0 ? "\(addedText) \(failed) failed." : addedText
    }

    /// Why "Add Primary Groups" is disabled, as a footer warning; nil when adding is allowed.
    public var addDisabledMessage: String? {
        let selected = selectedRows
        if selected.isEmpty { return "Choose at least one primary group." }
        if selected.contains(where: { $0.alias.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Enter an alias for every selected group."
        }

        if selected.contains(where: { !$0.db.isEmpty && $0.dbValue == nil }) {
            return "Enter a database index of 0 or more for every selected group."
        }

        return nil
    }

    /// The discovery page has selections or edits that cancelling would discard.
    public var hasUnsavedChanges: Bool {
        rows.contains { row in
            row.isSelected || row.alias != row.master.name || !row.username.isEmpty || !row.password.isEmpty
                || !row.db.isEmpty
        }
    }
}
