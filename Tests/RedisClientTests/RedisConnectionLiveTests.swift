import Foundation
import RedisClient
import RESP
import TestSupport
import Testing

private let db = RedisTestServer.DB.redisClient

private func config(_ mutate: (inout RedisConnectionConfig) -> Void = { _ in }) -> RedisConnectionConfig {
    var config = RedisTestServer.connectionConfig(db: db)
    mutate(&config)
    return config
}

private func key(_ name: String) -> RedisArgument {
    .string("rgtest:client:\(UUID().uuidString.prefix(8)):\(name)")
}

/// Waits for the first element of `stream` that satisfies `predicate`, failing after `seconds`.
private func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>, within seconds: Double,
                                where predicate: @escaping @Sendable (T) -> Bool) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            for try await item in stream where predicate(item) { return item }
            return nil
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = try await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct RedisConnectionLiveTests {
    @Test func pingAndSelectedDatabase() async throws {
        let connection = try await RedisTestServer.freshConnection(db: db)
        defer { Task { await connection.close() } }
        #expect(try await connection.execute(["PING"]) == .simpleString("PONG"))
        #expect(try await connection.ping())
        #expect(await connection.isConnected)
        #expect(await connection.selectedDB == db)
        let info = try await connection.execute(["CLIENT", "INFO"]).stringValue ?? ""
        #expect(info.contains("db=\(db)"))
        #expect(info.contains("name=keystrand-tests"))
    }

    @Test func binarySafeKeysAndValues() async throws {
        let connection = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await connection.close() } }
        let binaryKey = Data([0x72, 0x67, 0x00, 0xFF, 0x0D, 0x0A, 0xC3, 0x28]) + Data(UUID().uuidString.utf8)
        let value = Data((0...255).map(UInt8.init))
        _ = try await connection.execute(["SET", .data(binaryKey), .data(value)])
        #expect(try await connection.execute(["GET", .data(binaryKey)]) == .bulkString(value))
        #expect(try await connection.execute([Data("STRLEN".utf8), binaryKey]) == .integer(256))
        _ = try await connection.execute(["DEL", .data(binaryKey)])
    }

    @Test func pipelinesThousandCommandsInOrder() async throws {
        let connection = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await connection.close() } }
        let counter = key("counter")
        let replies = try await connection.pipeline((0..<1000).map { _ in ["INCR", counter] })
        #expect(replies.count == 1000)
        #expect(replies == (1...1000).map { .integer(Int64($0)) })

        let echoes = try await connection.pipeline((0..<1000).map { ["ECHO", .string("v\($0)")] })
        #expect(echoes.map(\.stringValue) == (0..<1000).map { "v\($0)" })
        _ = try await connection.execute(["DEL", counter])
    }

    @Test func concurrentCallersGetTheirOwnReplies() async throws {
        let connection = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await connection.close() } }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<200 {
                group.addTask {
                    let reply = try await connection.execute(["ECHO", .string("message-\(i)")])
                    return reply.stringValue == "message-\(i)"
                }
            }

            for try await ok in group { #expect(ok) }
        }
    }

    @Test func largeValueRoundTrip() async throws {
        let connection = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await connection.close() } }
        let big = Data((0..<(5 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let k = key("big")
        _ = try await connection.execute(["SET", k, .data(big)])
        let reply = try await connection.execute(["GET", k])
        #expect(reply.dataValue?.count == big.count)
        #expect(reply == .bulkString(big))
        _ = try await connection.execute(["DEL", k])
    }

    @Test func errorReplies() async throws {
        let connection = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await connection.close() } }
        let k = key("list")
        _ = try await connection.execute(["RPUSH", k, "a"])
        do {
            _ = try await connection.execute(["GET", k])
            Issue.record("expected WRONGTYPE")
        } catch let error as RedisClientError {
            #expect(error.serverError?.code == "WRONGTYPE")
        }

        let replies = try await connection.pipeline([["GET", k], ["LLEN", k], ["NOSUCHCOMMAND"]])
        #expect(replies[0].errorValue?.code == "WRONGTYPE")
        #expect(replies[1] == .integer(1))
        #expect(replies[2].isError)
        let sent = try await connection.send(["NOSUCHCOMMAND", "x"])
        #expect(sent.errorValue?.message.contains("unknown command") == true)
        #expect(try await connection.execute(["PING"]) == .simpleString("PONG"))
        _ = try await connection.execute(["DEL", k])
    }

    @Test func commandTimeoutKeepsRepliesAligned() async throws {
        let connection = try await RedisConnection.connect(config: config { $0.commandTimeout = 0.3 })
        defer { Task { await connection.close() } }
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: RedisClientError.self) {
            _ = try await connection.execute(["BLPOP", key("never"), "1"])
        }
        #expect(clock.now - start < .seconds(1))
        // The late BLPOP reply must be discarded, not handed to the next caller.
        let reply = try await connection.execute(["ECHO", "after-timeout"], timeout: 5)
        #expect(reply.stringValue == "after-timeout")
    }

    @Test func connectTimeoutAndRefusal() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: RedisClientError.self) {
            _ = try await RedisConnection.connect(config: RedisConnectionConfig(
                host: "10.255.255.1", port: 6390, connectTimeout: 0.5, retry: .none))
        }
        #expect(clock.now - start < .seconds(3))

        do {
            _ = try await RedisConnection.connect(config: RedisConnectionConfig(host: "127.0.0.1", port: 1, retry: .none))
            Issue.record("expected connection refused")
        } catch let error as RedisClientError {
            guard case .connectionFailed(let detail) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(detail.contains("ECONNREFUSED"))
        }
    }

    @Test func authenticationWithACLUser() async throws {
        let admin = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await admin.close() } }
        let user = "rgtest-\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await admin.execute(["ACL", "SETUSER", .string(user), "on", ">s3cret", "~*", "&*", "+@all"])
        defer { Task { _ = try? await admin.execute(["ACL", "DELUSER", .string(user)]) } }

        let good = try await RedisConnection.connect(config: config { $0.username = user; $0.password = "s3cret" })
        #expect(try await good.execute(["ACL", "WHOAMI"]).stringValue == user)
        await good.close()

        do {
            _ = try await RedisConnection.connect(config: config { $0.username = user; $0.password = "wrong"; $0.retry = .none })
            Issue.record("expected auth failure")
        } catch let error as RedisClientError {
            guard case .authenticationFailed = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }

        // Password-only AUTH against a server without a default password is tolerated.
        let passwordOnly = try await RedisConnection.connect(config: config { $0.password = "unused" })
        #expect(try await passwordOnly.ping())
        await passwordOnly.close()
    }

    @Test func selectOutOfRangeFails() async throws {
        await #expect(throws: RedisClientError.self) {
            _ = try await RedisConnection.connect(config: config { $0.dbIndex = 10_000; $0.retry = .none })
        }
        let connection = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await connection.close() } }
        try await connection.select(db: 3)
        #expect(await connection.selectedDB == 3)
        _ = try await connection.execute(["SELECT", .string("\(db)")])
        #expect(await connection.selectedDB == db)
    }

    @Test func reconnectsOnDemandAfterServerKill() async throws {
        let connection = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await connection.close() } }
        try await connection.select(db: db)
        let id = try await connection.execute(["CLIENT", "ID"])
        let killer = try await RedisTestServer.makeConnection(db: db)
        _ = try await killer.execute(["CLIENT", "KILL", "ID", .data(id.dataValue ?? Data())])
        await killer.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await connection.isConnected == false)
        #expect(try await connection.ping())
        let newID = try await connection.execute(["CLIENT", "ID"])
        #expect(newID != id)
        let info = try await connection.execute(["CLIENT", "INFO"]).stringValue ?? ""
        #expect(info.contains("db=\(db)"))
    }

    @Test func closeIsTerminal() async throws {
        let connection = try await RedisTestServer.makeConnection(db: db)
        await connection.close()
        await connection.close()
        await #expect(throws: RedisClientError.self) { _ = try await connection.execute(["PING"]) }
        try await connection.connect()
        #expect(try await connection.ping())
        await connection.close()
    }

    @Test func resp3Negotiation() async throws {
        let connection = try await RedisConnection.connect(config: config { $0.protocolVersion = .resp3 })
        defer { Task { await connection.close() } }
        #expect(await connection.negotiatedProtocol == .resp3)
        let k = key("hash")
        _ = try await connection.execute(["HSET", k, "f", "v"])
        let reply = try await connection.execute(["HGETALL", k])
        guard case .map(let pairs) = reply else {
            Issue.record("expected map, got \(reply)")
            return
        }
        #expect(pairs.count == 1)
        #expect(reply.stringKeyedMap?["f"] == .bulk("v"))
        _ = try await connection.execute(["DEL", k])
    }

    // MARK: Pub/Sub

    @Test(arguments: [RESPProtocolVersion.resp2, .resp3])
    func pubSubRoundTrip(protocolVersion: RESPProtocolVersion) async throws {
        let subscriber = try await RedisConnection.connect(config: config { $0.protocolVersion = protocolVersion })
        defer { Task { await subscriber.close() } }
        let publisher = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await publisher.close() } }
        let suffix = UUID().uuidString.prefix(8)
        let channel = Data("rgtest:ch:\(suffix)".utf8)
        let pattern = Data("rgtest:pat:\(suffix):*".utf8)

        let stream = await subscriber.subscribe(channels: [channel], patterns: [pattern])
        let box = MessageBox()
        let collector = Task {
            for try await message in stream { await box.append(message) }
        }
        var subscribed = false
        for _ in 0..<50 {
            let numsub = try await publisher.execute(["PUBSUB", "NUMSUB", .data(channel)]).arrayValue?.last?.intValue
            let numpat = try await publisher.execute(["PUBSUB", "NUMPAT"]).intValue ?? 0
            if numsub == 1 && numpat >= 1 { subscribed = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(subscribed)
        let payload = Data([0x00, 0xFF]) + Data("hello".utf8)
        #expect(try await publisher.execute(["PUBLISH", .data(channel), .data(payload)]) == .integer(1))
        _ = try await publisher.execute(["PUBLISH", .data(Data("rgtest:pat:\(suffix):x".utf8)), "p-msg"])

        var messages: [PubSubMessage] = []
        for _ in 0..<100 {
            messages = await box.messages
            if messages.filter({ !PubSubFrameParser.isConfirmation($0.kind) }).count >= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        collector.cancel()
        let delivered = messages.filter { !PubSubFrameParser.isConfirmation($0.kind) }
        #expect(messages.contains { $0.kind == .subscribe && $0.channel == channel })
        #expect(messages.contains { $0.kind == .psubscribe && $0.pattern == pattern })
        #expect(delivered.first?.kind == .message)
        #expect(delivered.first?.channel == channel)
        #expect(delivered.first?.message == payload)
        #expect(delivered.last?.kind == .pmessage)
        #expect(delivered.last?.pattern == pattern)
        #expect(delivered.last?.message == Data("p-msg".utf8))

        // After consumer cancellation, wait for the connection to unsubscribe.
        var released = false
        for _ in 0..<50 {
            let numsub = try await publisher.execute(["PUBSUB", "NUMSUB", .data(channel)]).arrayValue?.last?.intValue
            if numsub == 0 { released = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(released)
        #expect(try await subscriber.ping())
    }

    @Test func explicitUnsubscribeFinishesStream() async throws {
        let subscriber = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await subscriber.close() } }
        let pattern = Data("rgtest:unsub:\(UUID().uuidString.prefix(8)):*".utf8)
        let stream = await subscriber.psubscribe([pattern])
        let collector = Task { () -> [PubSubMessageKind] in
            var kinds: [PubSubMessageKind] = []
            for try await message in stream {
                kinds.append(message.kind)
                if message.kind == .psubscribe { try await subscriber.punsubscribe() }
            }

            return kinds
        }
        let kinds = try await collector.value
        #expect(kinds == [.psubscribe, .punsubscribe])
        #expect(try await subscriber.ping())
    }

    @Test func connectionDropFailsSubscription() async throws {
        let subscriber = try await RedisTestServer.makeConnection(db: db)
        let id = try await subscriber.execute(["CLIENT", "ID"])
        let stream = await subscriber.subscribe(channels: [Data("rgtest:drop:\(UUID().uuidString)".utf8)])
        let collector = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let killer = try await RedisTestServer.makeConnection(db: db)
        _ = try await killer.execute(["CLIENT", "KILL", "ID", .data(id.dataValue ?? Data())])
        await killer.close()
        let error = await collector.value
        #expect(error is RedisClientError)
        await subscriber.close()
    }

    // MARK: MONITOR

    @Test func monitorCapturesCommands() async throws {
        let monitor = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await monitor.close() } }
        let worker = try await RedisTestServer.makeConnection(db: db)
        defer { Task { await worker.close() } }
        let marker = "rgtest:monitor:\(UUID().uuidString.prefix(8))"
        let stream = await monitor.monitor()
        let found = Task {
            try await first(stream, within: 5) { line in
                line.args.count >= 2 && String(decoding: line.args[1], as: UTF8.self) == marker
            }
        }
        // MONITOR has no "ready" signal; keep issuing the command until it is seen.
        for _ in 0..<20 {
            _ = try await worker.execute(["SET", .string(marker), "a \"quoted\"\nvalue"])
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let line = try await found.value
        #expect(line != nil)
        #expect(line?.database == db)
        #expect(line?.source.contains("127.0.0.1") == true || line?.source.contains(":") == true)
        #expect(line.map { String(decoding: $0.args[0], as: UTF8.self).uppercased() } == "SET")
        #expect(line?.args.last == Data("a \"quoted\"\nvalue".utf8))
        #expect(Double(line?.time ?? "") != nil)
        _ = try await worker.execute(["DEL", .string(marker)])
    }

    @Test func monitorStreamEndsWhenConnectionCloses() async throws {
        let monitor = try await RedisTestServer.makeConnection(db: db)
        let stream = await monitor.monitor()
        let collector = Task { () -> Bool in
            do {
                for try await _ in stream {}
            } catch {}

            return true
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        await monitor.close()
        #expect(await collector.value)
    }

    // MARK: Factory

    @Test func factoryStandaloneAndDedicated() async throws {
        let descriptor = RedisClientDescriptor(
            topology: .standalone(RedisEndpoint(host: RedisTestServer.host, port: RedisTestServer.port)),
            connection: config())
        let factory = RedisClientFactory()
        let client = try await factory.makeClient(descriptor)
        #expect(client is RedisConnection)
        #expect(try await client.execute(["PING"]) == .simpleString("PONG"))
        await client.close()
        let dedicated = try await factory.makeDedicatedConnection(descriptor)
        #expect(await dedicated.selectedDB == db)
        await dedicated.close()
    }

    @Test func factoryRunsPreConnectScript() async throws {
        var descriptor = RedisClientDescriptor(
            topology: .standalone(RedisEndpoint(host: RedisTestServer.host, port: RedisTestServer.port)),
            connection: config(), preConnectScript: "exit 7")
        let factory = RedisClientFactory(scriptRunner: ConnectionScriptRunner(timeout: 10, shell: "/bin/sh"))
        do {
            _ = try await factory.makeClient(descriptor)
            Issue.record("expected script failure")
        } catch let error as RedisClientError {
            guard case .scriptFailed(.preConnect, let message) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(message.hasPrefix("The pre-connection script failed with exit code 7."))
        }

        descriptor.preConnectScript = "true"
        let client = try await factory.makeClient(descriptor)
        await client.close()
    }

    @Test func clusterClientAgainstStandaloneFails() async throws {
        let client = ClusterClient(seeds: [RedisEndpoint(host: RedisTestServer.host, port: RedisTestServer.port)],
                                   nodeConfig: config())
        await #expect(throws: RedisClientError.self) { try await client.connect() }
        await client.close()
    }
}

private actor MessageBox {
    var messages: [PubSubMessage] = []
    func append(_ message: PubSubMessage) { messages.append(message) }
}

extension RedisConnectionLiveTests {
    @Test func expiredRequestKeepsItsReplySlot() async throws {
        let connection = try await RedisTestServer.freshConnection(db: db)
        defer { Task { await connection.close() } }
        do {
            _ = try await connection.execute(["BLPOP", key("blocked"), "1"], timeout: 0.2)
            Issue.record("expected a timeout")
        } catch RedisClientError.timeout {
        }

        #expect(try await connection.execute(["ECHO", "first"]).stringValue == "first")
        #expect(try await connection.execute(["ECHO", "second"]).stringValue == "second")
    }

    @Test func closeReturnsOnceTheSocketIsCancelled() async throws {
        let connection = try await RedisTestServer.freshConnection(db: db)
        let clock = ContinuousClock()
        let start = clock.now
        await connection.close()
        #expect(clock.now - start < .seconds(1.5))
        #expect(await !connection.isConnected)
        do {
            _ = try await connection.execute(["PING"])
            Issue.record("expected a closed connection")
        } catch RedisClientError.notConnected {
        }
    }
}
