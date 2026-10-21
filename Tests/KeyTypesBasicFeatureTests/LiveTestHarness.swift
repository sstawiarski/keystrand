import Foundation
@testable import KeyTypesBasicFeature
import RedisCore
import TestSupport

/// Live session (Redis or Valkey) on DB 5 with a unique key prefix and recorded key-details callbacks.
@MainActor
final class LiveHarness {
    let session: DatabaseSession
    let connection: RedisConnection
    let prefix: String
    var renamedTo: [Data] = []
    var deletedCount = 0
    var changedCount = 0
    var closedCount = 0

    private init(session: DatabaseSession, connection: RedisConnection, prefix: String) {
        self.session = session
        self.connection = connection
        self.prefix = prefix
    }

    static func make(_ area: String, valkey: Bool = false) async throws -> LiveHarness {
        let db = RedisTestServer.DB.keyTypesBasic
        let endpoint = valkey ? RedisTestServer.valkey : RedisTestServer.endpoint
        let session = try await RedisTestServer.liveSession(db: db, endpoint: endpoint)
        let connection = try await RedisTestServer.makeConnection(db: db, endpoint: endpoint)
        return LiveHarness(session: session, connection: connection, prefix: RedisTestServer.uniquePrefix(area))
    }

    func key(_ suffix: String) -> Data { Data((prefix + suffix).utf8) }

    func context(_ key: Data, type: KeyType, state: KeyDetailsState? = nil) -> KeyDetailsContext {
        KeyDetailsContext(session: session, key: key, type: type, state: state ?? KeyDetailsState(key: key),
                          onKeyRenamed: { [weak self] name in self?.renamedTo.append(name) },
                          onKeyDeleted: { [weak self] in self?.deletedCount += 1 },
                          onKeyChanged: { [weak self] in self?.changedCount += 1 },
                          onClose: { [weak self] in self?.closedCount += 1 })
    }

    @discardableResult
    func run(_ args: [RedisArgument]) async throws -> RESPValue {
        try await connection.execute(args)
    }

    func pipeline(_ commands: [[RedisArgument]]) async throws {
        _ = try await connection.pipeline(commands)
    }

    var toastTitles: [String] { session.toasts.toasts.map(\.title) }

    func cleanup() async {
        try? await RedisTestServer.deleteKeys(connection, prefix: prefix)
        await connection.close()
        await session.close()
    }
}
