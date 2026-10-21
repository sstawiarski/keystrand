import Foundation
import RedisCore
import TestSupport
import Testing

@MainActor
struct MockSessionTests {
    @Test func executorDefaultModeChunksAndFormats() async throws {
        let client = MockRedisClient(responses: ["GET a": .bulk("1"), "GET b": .bulkString(Data([0xE5, 0x90])),
                                                 "BAD": .error(RESPError("ERR unknown command 'BAD'"))])
        let session = RedisTestServer.mockSession(client)
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore)
        var chunks = 0
        let results = try await executor.run(["GET a", "GET b", "BAD", "BLPOP l 0", "0 GET a"],
                                             params: ExecuteParams(batchSize: 2), settings: AppSettings(),
                                             onChunk: { _ in chunks += 1 })
        #expect(results.count == 5)
        #expect(chunks == 3)
        #expect(await client.batchCount == 2)
        #expect(results[0].result?.first?.response == .reply(.string("1")))
        #expect(results[1].result?.first?.response == .reply(.string("\\xe5\\x90")))
        #expect(results[2].result?.first?.status == .fail)
        #expect(results[3].result?.first?.response ==
                .reply(.error("BLPOP can't be run from Workbench.")))
        #expect(results[4].result?.first?.response == .reply(.error("The repeat count before the command isn't valid.")))
        #expect(results.allSatisfy { $0.db == 0 && $0.type == .workbench })
        let history = await session.services.commandHistoryStore.list(databaseID: session.id, type: .workbench)
        #expect(history.map(\.command) == ["0 GET a", "BAD", "BLPOP l 0", "GET a", "GET b"])
    }

    @Test func executorGroupAndSilentModes() async throws {
        let client = MockRedisClient(responses: ["PING": .simpleString("PONG"), "NOPE": .error(RESPError("ERR nope"))])
        let session = RedisTestServer.mockSession(client)
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore, type: .search)
        let group = try await executor.run(["PING", "NOPE"], params: ExecuteParams(resultsMode: .group), settings: AppSettings())
        #expect(group.count == 1)
        #expect(group[0].command == "PING\r\nNOPE")
        #expect(group[0].summary == ResultsSummary(total: 2, success: 1, fail: 1))
        guard case .group(let items)? = group[0].result?.first?.response else {
            Issue.record("expected group response")
            return
        }
        #expect(items.map(\.status) == [.success, .fail])
        let silent = try await executor.run(["PING", "NOPE"], params: ExecuteParams(resultsMode: .silent), settings: AppSettings())
        guard case .group(let failed)? = silent[0].result?.first?.response else {
            Issue.record("expected group response")
            return
        }
        #expect(failed.map(\.command) == ["NOPE"])
        #expect(await session.services.commandHistoryStore.list(databaseID: session.id, type: .search).count == 2)
    }

    @Test func executorTransportFailureStopsChunks() async throws {
        let client = MockRedisClient()
        await client.setTransportError(.connectionClosed)
        let session = RedisTestServer.mockSession(client)
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore)
        let results = try await executor.run(["GET a", "GET b", "GET c"], params: ExecuteParams(batchSize: 1),
                                             settings: AppSettings())
        #expect(results.count == 1)
        #expect(results[0].result?.first?.status == .fail)
    }

    @Test func keyOperationsAgainstMock() async throws {
        let client = MockRedisClient(responses: ["EXISTS": .integer(1), "RENAMENX": .integer(0), "DEL": .integer(0),
                                                 "TTL": .integer(100), "PERSIST": .integer(1)])
        let session = RedisTestServer.mockSession(client)
        let ops = KeyOperations(session: session)
        await #expect(throws: KeyOperationError.newNameInUse) { try await ops.rename(Data("a".utf8), to: Data("b".utf8)) }
        await #expect(throws: KeyOperationError.keyNotFound) { try await ops.delete([Data("a".utf8)]) }
        await #expect(throws: KeyOperationError.keyAlreadyExists) {
            try await ops.create(NewKeyDraft(name: Data("a".utf8), value: .string(Data("v".utf8))))
        }
        try await ops.setTTL(Data("a".utf8), seconds: -1)
        #expect(await client.executedCommandStrings.contains("PERSIST a"))
    }

    @Test func metadataPipelinesAgainstMock() async throws {
        let client = MockRedisClient(handler: { args in
            let name = String(decoding: args[0], as: UTF8.self)
            switch name {
            case "TYPE": return .simpleString("hash")
            case "TTL": return .integer(-1)
            case "MEMORY": return .integer(72)
            case "HLEN": return .integer(60_000)
            default: return nil
            }
        })
        let session = RedisTestServer.mockSession(client)
        let service = KeyMetadataService(session: session)
        let rows = try await service.metadata(for: [Data("a".utf8), Data("b".utf8)], includeSize: true, includeTTL: true)
        #expect(rows.map(\.type) == [.hash, .hash])
        #expect(rows.map(\.size) == [72, 72])
        #expect(rows.map(\.ttl) == [-1, -1])
        let filtered = try await service.metadata(for: [Data("a".utf8)], includeSize: false, includeTTL: false, knownType: .set)
        #expect(filtered.first?.type == .set)
        let info = try await service.keyInfo(Data("a".utf8), includeSize: false)
        #expect(info.length == 60_000)
        #expect(info.size == -1)
    }

    @Test func keyInfoTypeHintSavesARoundTrip() async throws {
        let client = MockRedisClient(handler: { args in
            switch String(decoding: args[0], as: UTF8.self) {
            case "TYPE": return .simpleString("hash")
            case "TTL": return .integer(30)
            case "HLEN": return .integer(60_000)
            case "MEMORY": return .integer(72)
            default: return nil
            }
        })
        let service = KeyMetadataService(session: RedisTestServer.mockSession(client))
        let key = Data("a".utf8)

        await client.resetRecording()
        let hinted = try await service.keyInfo(key, includeSize: false, typeHint: .hash)
        #expect(await client.batchCount == 1)
        #expect(hinted.length == 60_000 && hinted.ttl == 30 && hinted.size == -1)

        await client.resetRecording()
        let plain = try await service.keyInfo(key, includeSize: false)
        #expect(await client.batchCount == 2)
        #expect(plain.length == hinted.length && plain.ttl == hinted.ttl && plain.size == hinted.size)

        await client.resetRecording()
        let wrongHint = try await service.keyInfo(key, includeSize: true, typeHint: .set)
        #expect(await client.batchCount == 2)
        #expect(wrongHint.type == .hash && wrongHint.length == 60_000 && wrongHint.size == 72)
    }

    @Test func connectionKindFromConfig() {
        let services = RedisTestServer.makeServices()
        let cluster = DatabaseSession(config: DatabaseConfig(connectionType: .cluster), services: services)
        #expect(cluster.isCluster)
        let forced = DatabaseSession(config: DatabaseConfig(connectionType: .cluster, forceStandalone: true), services: services)
        #expect(!forced.isCluster)
        let prod = DatabaseSession(config: DatabaseConfig(name: "", environment: .production), services: services)
        #expect(prod.isProduction)
        #expect(prod.confirmationName == "127.0.0.1:6379")
    }
}
