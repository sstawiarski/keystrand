import Foundation
@testable import RedisCore
import TestSupport
import Testing

@MainActor
struct KeyCreationTests {
    private let key = Data("k".utf8)

    private func strings(_ client: MockRedisClient) async -> [String] {
        await client.executedCommandStrings
    }

    /// Splits the `EVAL` of `createKey` into its key, creation command count, and encoded commands.
    private func decodeScript(_ args: [Data]?) -> (key: String, creating: Int, commands: [[String]])? {
        guard let args else { return nil }
        let text = args.map { String(decoding: $0, as: UTF8.self) }
        guard text.count > 5, text[0] == "EVAL", text[1] == KeyOperations.createScript, text[2] == "1",
              let creating = Int(text[4]) else { return nil }
        var commands: [[String]] = []
        var index = 5
        while index < text.count {
            guard let count = Int(text[index]), count > 0, index + count < text.count else { return nil }
            commands.append(Array(text[(index + 1)...(index + count)]))
            index += count + 1
        }

        return (text[3], creating, commands)
    }

    @Test func createSendsOneScriptWithTheKeyAndEveryCommand() async throws {
        let client = MockRedisClient(responses: ["EVAL": .integer(1)])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        try await ops.create(NewKeyDraft(name: key, ttl: 60, value: .hash([
            HashField(field: Data("f".utf8), value: Data("v".utf8), expire: 30),
            HashField(field: Data("g".utf8), value: Data("w".utf8)),
        ])))
        let executed = await client.executedCommands
        #expect(executed.count == 1)
        let script = try #require(decodeScript(executed.first))
        #expect(script.key == "k")
        #expect(script.creating == 1)
        #expect(script.commands == [
            ["HSET", "k", "f", "v", "g", "w"],
            ["EXPIRE", "k", "60"],
            ["HEXPIRE", "k", "30", "FIELDS", "1", "f"],
        ])
    }

    @Test func jsonCreationRunsInTheScriptWithItsTTL() async throws {
        let client = MockRedisClient(responses: ["EVAL": .integer(1)])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        try await ops.create(NewKeyDraft(name: key, ttl: 5, value: .json(#"{"a":1}"#)))
        let executed = await client.executedCommands
        let script = try #require(decodeScript(executed.first))
        #expect(executed.count == 1)
        #expect(script.commands == [["JSON.SET", "k", ".", #"{"a":1}"#, "NX"], ["EXPIRE", "k", "5"]])
    }

    @Test func stringCreationStaysASingleConditionalSet() async throws {
        let client = MockRedisClient(responses: ["SET": .ok])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        try await ops.create(NewKeyDraft(name: key, ttl: 5, value: .string(Data("v".utf8))))
        #expect(await strings(client) == ["SET k v EX 5 NX"])
    }

    @Test func scriptReportingAnExistingKeyThrowsAlreadyExists() async throws {
        let client = MockRedisClient(responses: ["EVAL": .integer(0)])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        await #expect(throws: KeyOperationError.keyAlreadyExists) {
            try await ops.create(NewKeyDraft(name: key, ttl: 60, value: .set([Data("m".utf8)])))
        }
        #expect(await client.executedCommands.count == 1)
    }

    @Test func failedCreationCommandThrowsItsServerError() async throws {
        let wrongType = "WRONGTYPE Operation against a key holding the wrong kind of value"
        let client = MockRedisClient(responses: ["EVAL": .array([.integer(1), .bulk(wrongType)])])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        do {
            try await ops.create(NewKeyDraft(name: key, ttl: 60, value: .list(.tail, [Data("a".utf8)])))
            Issue.record("expected a server error")
        } catch let error as RedisClientError {
            #expect(error.serverError?.message == wrongType)
        }
    }

    @Test func failedExpireOnlyThrowsCreatedWithoutTTL() async throws {
        let denied = "NOPERM User u has no permissions to run the 'expire' command"
        let client = MockRedisClient(responses: ["EVAL": .array([.integer(2), .bulk(denied)])])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        await #expect(throws: KeyOperationError.createdWithoutTTL(denied)) {
            try await ops.create(NewKeyDraft(name: key, ttl: 60, value: .zset([ZSetMemberDraft(member: Data("m".utf8), score: 1)])))
        }
        let message = KeyOperationError.createdWithoutTTL(denied).localizedDescription
        #expect(message.hasPrefix("The key was created, but its TTL could not be set."))
        #expect(message.contains(denied))
    }

    @Test func failedHashFieldTTLThrowsCreatedWithoutTTL() async throws {
        let invalid = "ERR invalid expire time in 'hexpire' command"
        let client = MockRedisClient(responses: ["EVAL": .array([.integer(2), .bulk(invalid)])])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        await #expect(throws: KeyOperationError.createdWithoutTTL(invalid)) {
            try await ops.create(NewKeyDraft(name: key, value: .hash([
                HashField(field: Data("f".utf8), value: Data("v".utf8), expire: 30),
            ])))
        }
    }

    @Test func deniedScriptingFallsBackToExistsAndPipelines() async throws {
        let client = MockRedisClient(responses: [
            "EVAL": .error(RESPError("NOPERM User u has no permissions to run the 'eval' command")),
            "EXISTS": .integer(0), "SADD": .integer(2), "EXPIRE": .integer(1),
        ])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        try await ops.create(NewKeyDraft(name: key, ttl: 60, value: .set([Data("a".utf8), Data("b".utf8)])))
        let executed = await strings(client)
        #expect(executed.dropFirst() == ["EXISTS k", "SADD k a b", "EXPIRE k 60"])
        #expect(await client.batchCount == 4)
    }

    @Test func fallbackRecognizesUnavailableScripting() {
        let unavailable = ["NOPERM User u has no permissions to run the 'eval' command",
                           "NOPERM this user has no permissions to run the 'eval' command",
                           "ERR unknown command 'EVAL', with args beginning with: ",
                           "ERR command not allowed"]
        for message in unavailable { #expect(KeyOperations.isScriptingUnavailable(RESPError(message)), "\(message)") }
        let other = ["OOM command not allowed when used memory > 'maxmemory'.",
                     "ERR Error running script, user_script:6: too many results to unpack",
                     "READONLY You can't write against a read only replica.",
                     "BUSY Redis is busy running a script."]
        for message in other { #expect(!KeyOperations.isScriptingUnavailable(RESPError(message)), "\(message)") }
    }

    @Test func otherScriptErrorsDoNotFallBack() async throws {
        let client = MockRedisClient(responses: [
            "EVAL": .error(RESPError("OOM command not allowed when used memory > 'maxmemory'.")),
            "EXISTS": .integer(0), "SADD": .integer(1),
        ])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        await #expect(throws: RedisClientError.self) {
            try await ops.create(NewKeyDraft(name: key, value: .set([Data("a".utf8)])))
        }
        #expect(await client.executedCommands.count == 1)
    }

    @Test func fallbackRefusesAnExistingKey() async throws {
        let client = MockRedisClient(responses: [
            "EVAL": .error(RESPError("ERR unknown command 'EVAL'")), "EXISTS": .integer(1),
        ])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        await #expect(throws: KeyOperationError.keyAlreadyExists) {
            try await ops.create(NewKeyDraft(name: key, ttl: 60, value: .set([Data("a".utf8)])))
        }
        #expect(await strings(client).dropFirst() == ["EXISTS k"])
    }

    @Test func fallbackDeletesTheKeyWhenCreationFails() async throws {
        let client = MockRedisClient(responses: [
            "EVAL": .error(RESPError("NOPERM no permissions")), "EXISTS": .integer(0),
            "SADD": .error(RESPError("WRONGTYPE Operation against a key holding the wrong kind of value")),
            "DEL": .integer(1),
        ])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        await #expect(throws: RedisClientError.self) {
            try await ops.create(NewKeyDraft(name: key, ttl: 60, value: .set([Data("a".utf8)])))
        }
        #expect(await strings(client).dropFirst() == ["EXISTS k", "SADD k a", "DEL k"])
    }

    @Test func fallbackReportsAFailedTTLAsCreatedWithoutTTL() async throws {
        let denied = "NOPERM User u has no permissions to run the 'expire' command"
        let client = MockRedisClient(responses: [
            "EVAL": .error(RESPError("NOPERM User u has no permissions to run the 'eval' command")),
            "EXISTS": .integer(0), "RPUSH": .integer(1), "EXPIRE": .error(RESPError(denied)),
        ])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        await #expect(throws: KeyOperationError.createdWithoutTTL(denied)) {
            try await ops.create(NewKeyDraft(name: key, ttl: 60, value: .list(.tail, [Data("a".utf8)])))
        }
    }

    @Test func fallbackTreatsANullJSONSetAsAnExistingKey() async throws {
        let client = MockRedisClient(responses: [
            "EVAL": .error(RESPError("NOPERM no permissions")), "EXISTS": .integer(0), "JSON.SET": .null,
        ])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        await #expect(throws: KeyOperationError.keyAlreadyExists) {
            try await ops.create(NewKeyDraft(name: key, ttl: 60, value: .json("1")))
        }
        #expect(!(await strings(client)).contains { $0.hasPrefix("EXPIRE") })
    }

    @Test func commandTooLongForTheScriptUsesTheFallback() async throws {
        let client = MockRedisClient(responses: ["EXISTS": .integer(0), "XADD": .bulk("1-0")])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        let fields = (0..<KeyOperations.maxScriptCommandArguments).map {
            StreamFieldDraft(name: Data("f\($0)".utf8), value: Data("v".utf8))
        }
        try await ops.create(NewKeyDraft(name: key, value: .stream(id: "*", fields: fields)))
        let executed = await strings(client)
        #expect(executed.first == "EXISTS k")
        #expect(!executed.contains { $0.hasPrefix("EVAL") })
    }

    @Test func variadicCommandsAreSplitForTheScript() {
        let limit = KeyOperations.maxScriptCommandArguments
        let pairs = (0..<10_000).map { [RedisArgument.string("f\($0)"), .string("v\($0)")] }
        let commands = KeyOperations.variadic(["HSET", "k"], pairs)
        #expect(commands.count == 3)
        #expect(commands.allSatisfy { $0.count <= limit && $0.count % 2 == 0 && $0.prefix(2) == ["HSET", "k"] })
        #expect(commands.flatMap { $0.dropFirst(2) } == pairs.flatMap { $0 })
        #expect(KeyOperations.variadic(["SADD", "k"], [["a"], ["b"]]) == [["SADD", "k", "a", "b"]])
    }

    @Test func largeCreateStaysAtomicInOneScript() async throws {
        let client = MockRedisClient(responses: ["EVAL": .integer(1)])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        let members = (0..<20_000).map { Data("m\($0)".utf8) }
        try await ops.create(NewKeyDraft(name: key, ttl: 9, value: .set(members)))
        let executed = await client.executedCommands
        let script = try #require(decodeScript(executed.first))
        #expect(executed.count == 1)
        #expect(script.commands.count == 4)
        #expect(script.creating == 3)
        #expect(script.commands.dropLast().allSatisfy { $0.first == "SADD" && $0.count <= KeyOperations.maxScriptCommandArguments })
        #expect(script.commands.dropLast().reduce(0) { $0 + $1.count - 2 } == 20_000)
        #expect(script.commands.last == ["EXPIRE", "k", "9"])
    }

    // MARK: - setTTL

    @Test func removingTheTTLPersistsWhenTTLRoundsToZero() async throws {
        let client = MockRedisClient(responses: ["TTL": .integer(0), "PERSIST": .integer(1)])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        try await ops.setTTL(key, seconds: nil)
        #expect(await strings(client) == ["TTL k", "PERSIST k"])
    }

    @Test func removingTheTTLOfAMissingKeyThrowsNotFound() async throws {
        let client = MockRedisClient(responses: ["TTL": .integer(-2)])
        let ops = KeyOperations(session: RedisTestServer.mockSession(client))
        await #expect(throws: KeyOperationError.keyNotFound) { try await ops.setTTL(key, seconds: -1) }
        #expect(await strings(client) == ["TTL k"])
    }
}

@MainActor
struct DeferredErrorTests {
    @Test func errorAfterSheetClosesWaitsForTheSheetPresenter() async throws {
        let center = ToastCenter()
        _ = center.presenters.push()
        center.errorAfterSheetCloses(KeyOperationError.createdWithoutTTL("denied"), title: "Unable to Set TTL")
        try await Task.sleep(for: .milliseconds(50))
        #expect(center.toasts.isEmpty)
        center.presenters.pop()
        let deadline = Date().addingTimeInterval(2)
        while center.toasts.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(center.toasts.map(\.title) == ["Unable to Set TTL"])
        #expect(center.toasts.first?.message == KeyOperationError.createdWithoutTTL("denied").localizedDescription)
    }

    @Test func errorAfterSheetClosesShowsAtOnceWithoutASheet() {
        let center = ToastCenter()
        center.errorAfterSheetCloses(KeyOperationError.createdWithoutTTL("denied"))
        #expect(center.toasts.count == 1)
    }
}
