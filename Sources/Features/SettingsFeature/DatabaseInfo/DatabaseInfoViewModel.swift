import Foundation
import Observation
import RedisUI

/// Shows cached server details immediately, then refreshes the database info.
@MainActor
@Observable
public final class DatabaseInfoViewModel {
    public let session: DatabaseSession
    public private(set) var details: DatabaseInfoDetails
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var hasLoaded = false

    public init(session: DatabaseSession) {
        self.session = session
        details = Self.details(session: session, info: session.info, modules: session.modules,
                               databaseCount: session.databaseCount)
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try await session.client()
            let service = DatabaseInfoService(client: client)
            let info = try await service.info()
            let modules = (try? await service.modules(flavor: info.serverFlavor)) ?? session.modules
            let count = session.isCluster
                ? session.databaseCount
                : (try? await service.databaseCount(info: info)) ?? session.databaseCount
            details = Self.details(session: session, info: info, modules: modules, databaseCount: count)
            errorMessage = nil
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Closes the popover (via `dismiss`) and opens the edit-database sheet for this database.
    public func editDatabase(dismiss: () -> Void) {
        dismiss()
        session.navigator.navigate(.editDatabase(focusEnvironment: false))
    }

    static func details(session: DatabaseSession, info: RedisInfo?, modules: [RedisModuleInfo],
                        databaseCount: Int) -> DatabaseInfoDetails {
        DatabaseInfoDetails.make(name: session.config.name.isEmpty ? session.config.hostPort : session.config.name,
                                 hostPort: session.config.hostPort, connectionKind: session.connectionKind,
                                 username: session.username, info: info, modules: modules,
                                 databaseCount: databaseCount, currentDb: session.effectiveDB,
                                 provider: session.config.provider)
    }
}
