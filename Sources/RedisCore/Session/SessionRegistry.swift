import Foundation
import Observation

/// One `DatabaseSession` per database id, shared by every window showing that database.
@MainActor
@Observable
public final class SessionRegistry {
    public private(set) var sessions: [DatabaseID: DatabaseSession] = [:]
    @ObservationIgnored private var closing: [DatabaseID: Closing] = [:]
    @ObservationIgnored private weak var services: AppServices?

    private struct Closing {
        let session: DatabaseSession
        let task: Task<Void, Never>
    }

    init(services: AppServices) {
        self.services = services
    }

    /// Existing session, or a new one created from the stored config (not yet connected).
    public func session(for id: DatabaseID) async throws -> DatabaseSession {
        if let existing = sessions[id] { return existing }
        guard let services else { throw DatabaseStoreError.notFound(id) }
        let config = try await services.databaseStore.get(id)
        if let raced = sessions[id] { return raced }
        let session = DatabaseSession(config: config.withoutSecrets(), services: services)
        sessions[id] = session
        return session
    }

    public func existingSession(for id: DatabaseID) -> DatabaseSession? {
        sessions[id]
    }

    /// Registers an externally created session (tests / previews).
    public func register(_ session: DatabaseSession) {
        sessions[session.id] = session
    }

    /// Open sessions plus sessions whose `close()` has not finished.
    public var sessionsIncludingClosing: [DatabaseSession] {
        Array(sessions.values) + closing.values.map(\.session)
    }

    /// Called when the last window of a database closes, or the database is deleted. Returns only after the session
    /// has closed, also when an earlier call started closing it.
    public func close(_ id: DatabaseID) async {
        if let inProgress = closing[id] { await inProgress.task.value }
        guard let session = sessions.removeValue(forKey: id) else { return }
        let task = Task { await session.close() }
        closing[id] = Closing(session: session, task: task)
        await task.value
        if closing[id]?.task == task { closing[id] = nil }
    }

    /// Closes every open session and waits for the sessions that are already closing.
    public func closeAll() async {
        let ids = Set(sessions.keys).union(closing.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.close(id) }
            }
        }
    }
}
