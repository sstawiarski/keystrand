import Foundation
import Observation

/// Process-wide services injected with `.environment(services)` and read with `@Environment(AppServices.self)`.
/// Tests use temporary paths and an in-memory secret store.
@MainActor
@Observable
public final class AppServices {
    public static let shared = AppServices(paths: .default, secrets: KeychainStore(service: "Keystrand"))

    public let paths: AppPaths
    public let secrets: any SecretStore
    public let databaseStore: DatabaseStore
    public let certificateStore: CertificateStore
    public let databaseSettingsStore: DatabaseSettingsStore
    public let settings: SettingsStore
    public let commandHistoryStore: CommandHistoryStore
    public let queryLibraryStore: QueryLibraryStore
    public let clientFactory: RedisClientFactory
    public let clientPool: ClientPool
    public let overviewService: DatabaseOverviewService
    public let dangerousCommands: DangerousCommandsProvider
    /// App-level toasts (Home window).
    public let toasts = ToastCenter()
    @ObservationIgnored public private(set) var sessions: SessionRegistry!

    public init(paths: AppPaths, secrets: any SecretStore, settingsFileURL: URL? = nil,
                clientFactory: RedisClientFactory = RedisClientFactory()) {
        self.paths = paths
        self.secrets = secrets
        let certificateStore = CertificateStore(paths: paths, secrets: secrets)
        self.certificateStore = certificateStore
        self.databaseStore = DatabaseStore(paths: paths, secrets: secrets, certificates: certificateStore)
        self.databaseSettingsStore = DatabaseSettingsStore(paths: paths)
        self.settings = SettingsStore(fileURL: settingsFileURL ?? paths.settingsFile)
        self.commandHistoryStore = CommandHistoryStore(paths: paths)
        self.queryLibraryStore = QueryLibraryStore(paths: paths)
        self.clientFactory = clientFactory
        self.clientPool = ClientPool(factory: clientFactory)
        self.overviewService = DatabaseOverviewService()
        self.dangerousCommands = DangerousCommandsProvider()
        self.sessions = SessionRegistry(services: self)
    }

    /// In-memory services for SwiftUI previews.
    public static func preview() -> AppServices {
        AppServices(paths: .temporary(), secrets: InMemorySecretStore())
    }

    // MARK: - High-level operations (store + pool + open sessions kept consistent)

    /// Creates or updates a database, drops its cached clients, and updates an open session.
    public func saveDatabase(_ config: DatabaseConfig) async throws {
        let exists = try await databaseStore.contains(config.id)
        if exists { try await databaseStore.update(config) } else { try await databaseStore.create(config) }
        await clientPool.invalidate(databaseID: config.id)
        await sessions.existingSession(for: config.id)?.apply(config: config)
    }

    /// Deletes databases with their secrets, settings, history, query library and analysis reports.
    /// Their windows must close separately.
    public func deleteDatabases(_ ids: [DatabaseID]) async throws {
        try await databaseStore.delete(ids)
        for id in ids {
            await sessions.close(id)
            await clientPool.invalidate(databaseID: id)
            await databaseSettingsStore.delete(id)
            await commandHistoryStore.deleteAll(databaseID: id)
            try? await queryLibraryStore.deleteAll(databaseID: id)
            await dangerousCommands.invalidate(id)
            JSONFile.discard(paths.analysisDirectory(for: id))
        }
    }

    /// Deletes a certificate, detaches it from databases (TLS flag kept), and drops their clients.
    public func deleteCertificate(id: String, isCA: Bool) async throws {
        if isCA { try await certificateStore.deleteCA(id) } else { try await certificateStore.deleteClient(id) }
        for db in try await databaseStore.list() where db.tls.caCertID == id || db.tls.clientCertID == id {
            let updated = try await databaseStore.modify(db.id) { config in
                if config.tls.caCertID == id { config.tls.caCertID = nil }
                if config.tls.clientCertID == id { config.tls.clientCertID = nil }
            }
            await clientPool.invalidate(databaseID: db.id)
            await sessions.existingSession(for: db.id)?.apply(config: updated)
        }
    }
}
