import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import TestSupport

/// Live session (Redis or Valkey) on DB 6 with a unique key prefix and recorded key-details callbacks.
@MainActor
final class LiveHarness {
    let session: DatabaseSession
    let connection: RedisConnection
    let prefix: String
    var deletedCount = 0
    var changedCount = 0
    var addedKeys: [Data] = []

    private init(session: DatabaseSession, connection: RedisConnection, prefix: String) {
        self.session = session
        self.connection = connection
        self.prefix = prefix
    }

    static func make(_ area: String, valkey: Bool = false) async throws -> LiveHarness {
        let db = RedisTestServer.DB.keyTypesAdvanced
        let endpoint = valkey ? RedisTestServer.valkey : RedisTestServer.endpoint
        let session = try await RedisTestServer.liveSession(db: db, endpoint: endpoint)
        let connection = try await RedisTestServer.makeConnection(db: db, endpoint: endpoint)
        return LiveHarness(session: session, connection: connection, prefix: RedisTestServer.uniquePrefix(area))
    }

    func key(_ suffix: String) -> Data { Data((prefix + suffix).utf8) }

    func context(_ key: Data, type: KeyType) -> KeyDetailsContext {
        KeyDetailsContext(session: session, key: key, type: type, state: KeyDetailsState(key: key),
                          onKeyDeleted: { [weak self] in self?.deletedCount += 1 },
                          onKeyChanged: { [weak self] in self?.changedCount += 1 })
    }

    func addKeyContext(name: Data, ttl: Int? = nil) -> AddKeyFormContext {
        AddKeyFormContext(session: session, keyName: { name }, ttl: { ttl },
                          onKeyAdded: { [weak self] name in self?.addedKeys.append(name) }, onCancel: {})
    }

    @discardableResult
    func run(_ args: [RedisArgument]) async throws -> RESPValue {
        try await connection.execute(args)
    }

    func pipeline(_ commands: [[RedisArgument]]) async throws {
        let replies = try await connection.pipeline(commands)
        if let error = replies.compactMap(\.errorValue).first { throw RedisClientError.server(error) }
    }

    func exists(_ key: Data) async throws -> Bool {
        (try await run(["EXISTS", .data(key)]).intValue ?? 0) > 0
    }

    var toastTitles: [String] { session.toasts.toasts.map(\.title) }

    func cleanup() async {
        try? await RedisTestServer.deleteKeys(connection, prefix: prefix)
        await connection.close()
        await session.close()
    }
}
