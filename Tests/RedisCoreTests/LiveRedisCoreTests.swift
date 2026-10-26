import Foundation
import RedisCore
import TestSupport
import Testing

/// Tests share and clear DB 3, so they run serially.
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct LiveRedisCoreTests {
    static let db = RedisTestServer.DB.redisCore

    func freshSession() async throws -> DatabaseSession {
        try await RedisTestServer.flush(db: Self.db)
        return try await RedisTestServer.liveSession(db: Self.db)
    }

    @Test(RedisTestServer.needs(.search, .json, .timeSeries, .vectorSet)) func connectLoadsServerDetails() async throws {
        let session = try await freshSession()
        #expect(session.state == .connected)
        #expect(session.info?.redisVersion != nil)
        #expect(session.capabilities.hasSearch)
        #expect(session.capabilities.hasJSON)
        #expect(session.capabilities.hasTimeSeries)
        #expect(session.capabilities.supportsVectorSets)
        #expect(session.databaseCount >= 16)
        #expect(session.dangerousCommands.contains("flushall"))
        #expect(session.connectionKind == .standalone)
        let stored = try await session.services.databaseStore.get(session.id)
        #expect(stored.lastConnection != nil)
        #expect(stored.isNew == false)
        #expect(stored.modules.contains { $0.name == "search" })
        #expect(stored.version == session.serverVersion)
        #expect(stored.provider != nil && stored.provider != .unknown)
        await session.close()
    }

    @Test func selectAndOverview() async throws {
        let session = try await freshSession()
        try await RedisTestServer.seedStrings(session.client(), prefix: "ov:", count: 5)
        await session.refreshOverview()
        #expect(session.overviewError == nil)
        let overview = try #require(session.overview)
        #expect(overview.version == session.serverVersion)
        #expect((overview.totalKeysPerDb?["db\(Self.db)"] ?? overview.totalKeys) == 5)
        #expect(overview.cpuUsagePercentage == .some(nil))
        #expect((overview.maxCpuUsagePercentage ?? 0) >= 100)
        try await Task.sleep(for: .milliseconds(1100))
        await session.refreshOverview()
        #expect(session.overview?.cpuUsagePercentage != nil)

        let generation = session.dbGeneration
        #expect(await session.canSelect(db: 4))
        #expect(!(await session.canSelect(db: 10_000)))
        try await session.select(db: RedisTestServer.DB.redisCore)
        #expect(session.dbGeneration == generation)
        await #expect(throws: RedisClientError.self) { try await session.select(db: 9_999) }
        #expect(session.dbIndex == Self.db)

        session.overviewRefreshInterval = 0.2
        session.windowDidAppear()
        session.windowDidDisappear()
        await session.close()
    }

    @Test(RedisTestServer.needs(.json, .vectorSet)) func infoServiceAgainstServer() async throws {
        let session = try await freshSession()
        let service = DatabaseInfoService(client: try await session.client())
        let modules = try await service.modules(flavor: .redis)
        #expect(modules.contains { $0.name == "ReJSON" && $0.semanticVersion != nil })
        #expect(modules.contains { $0.name == "vectorset" })
        #expect(try await service.databaseCount() == 16)
        let general = try await service.generalInfo()
        #expect(general.version != nil)
        #expect(general.role == "master")
        await session.close()
    }

    @Test(RedisTestServer.needs(.json, .timeSeries, .vectorSet)) func scanStandaloneWithContinuationAndFilters() async throws {
        let session = try await freshSession()
        let client = try await session.client()
        try await RedisTestServer.seedStrings(client, prefix: "scan:", count: 1_500)
        try await RedisTestServer.seedAllTypes(client, prefix: "typed:")
        let scanner = KeyScanner(session: session)
        #expect(try await scanner.totalKeys() == 1_509)

        var state = try await scanner.scan(ScanRequest(match: "scan:*", count: 500))
        #expect(state.keys.count >= 500)
        #expect(state.total == 1_509)
        while !state.isComplete {
            state = try await scanner.scan(ScanRequest(match: "scan:*", count: 500), continuing: state)
        }

        #expect(state.keys.count == 1_500)
        #expect(Set(state.keys.map(\.name)).count == 1_500)
        #expect(state.scanned == 1_509)

        let hashes = try await scanner.scan(ScanRequest(match: "*", type: .hash, count: 10_000))
        #expect(hashes.keys.map(\.name) == [Data("typed:hash".utf8)])
        #expect(hashes.keys.first?.type == .hash)
        #expect(hashes.isComplete)

        let exact = try await scanner.scan(ScanRequest(match: "typed:zset"))
        #expect(exact.keys.count == 1)
        #expect(exact.keys.first?.type == .zset)
        #expect(exact.isComplete)
        let missing = try await scanner.scan(ScanRequest(match: "typed:missing"))
        #expect(missing.keys.isEmpty)
        let wrongType = try await scanner.exactKey(Data("typed:zset".utf8), type: .hash)
        #expect(wrongType == nil)
        await session.close()
    }

    @Test func emptyDatabaseScanCompletes() async throws {
        let session = try await freshSession()
        let state = try await KeyScanner(session: session).scan(ScanRequest(match: "*", count: 500))
        #expect(state.keys.isEmpty)
        #expect(state.total == 0)
        #expect(state.isComplete)
        await session.close()
    }

    @Test(RedisTestServer.needs(.json, .timeSeries, .vectorSet)) func metadataAndKeyInfoForEveryType() async throws {
        let session = try await freshSession()
        let seeded = try await RedisTestServer.seedAllTypes(try await session.client(), prefix: "meta:")
        let service = KeyMetadataService(session: session)
        let names = KeyType.allKnown.compactMap { seeded.keys[$0] }
        let rows = try await service.metadata(for: names, includeSize: true, includeTTL: true)
        #expect(rows.count == names.count)
        #expect(rows.allSatisfy { $0.type != nil && $0.ttl == -1 && ($0.size ?? 0) > 0 })

        let expectations: [(KeyType, Int)] = [(.string, 5), (.hash, 3), (.list, 3), (.set, 3), (.zset, 3), (.stream, 2),
                                              (.json, 3), (.timeSeries, 3), (.vectorSet, 2)]
        for (type, length) in expectations {
            let info = try await service.keyInfo(seeded.name(type))
            #expect(info.type == type, "type for \(type)")
            #expect(info.length == length, "length for \(type)")
            #expect(info.ttl == -1)
            #expect((info.size ?? 0) > 0, "size for \(type)")
        }

        let vset = try await service.keyInfo(seeded.name(.vectorSet), includeSize: false)
        #expect(vset.vectorDim == 3)
        #expect(vset.quantType != nil)
        await #expect(throws: KeyOperationError.keyNotFound) { try await service.keyInfo(Data("nope".utf8)) }
        await session.close()
    }

    @Test(RedisTestServer.needs(.json, .timeSeries, .vectorSet)) func keyOperationsCreateEveryType() async throws {
        let session = try await freshSession()
        let ops = KeyOperations(session: session)
        let metadata = KeyMetadataService(session: session)
        func name(_ s: String) -> Data { Data("ops:\(s)".utf8) }
        let drafts: [NewKeyDraft] = [
            NewKeyDraft(name: name("string"), ttl: 100, value: .string(Data("v".utf8))),
            NewKeyDraft(name: name("hash"), value: .hash([HashField(field: Data("f".utf8), value: Data("v".utf8), expire: 50)])),
            NewKeyDraft(name: name("list"), value: .list(.head, [Data("a".utf8), Data("b".utf8)])),
            NewKeyDraft(name: name("set"), value: .set([Data("a".utf8)])),
            NewKeyDraft(name: name("zset"), value: .zset([ZSetMemberDraft(member: Data("m".utf8), score: 1.5),
                                                          ZSetMemberDraft(member: Data("inf".utf8), score: .infinity)])),
            NewKeyDraft(name: name("json"), ttl: 60, value: .json(#"{"a":1}"#)),
            NewKeyDraft(name: name("stream"), value: .stream(id: "*", fields: [StreamFieldDraft(name: Data("f".utf8), value: Data("v".utf8))])),
            NewKeyDraft(name: name("vset"), value: .vectorSet([VectorElementDraft(name: Data("e".utf8), vector: [0.1, 0.2],
                                                                                  attributes: #"{"k":"v"}"#)])),
            NewKeyDraft(name: name("ts"), value: .timeSeries(TimeSeriesDraft(retentionMs: 0, labels: [.init(name: "l", value: "1")],
                                                                             samples: [.init(timestamp: "1000", value: 1)]))),
        ]
        for draft in drafts {
            try await ops.create(draft)
            let info = try await metadata.keyInfo(draft.name)
            #expect(info.type == draft.type, "created \(draft.type)")
        }

        #expect(try await metadata.keyInfo(name("string")).ttl > 0)
        #expect(try await metadata.keyInfo(name("json")).ttl > 0)
        let hashTTL = try await session.execute(["HTTL", .data(name("hash")), "FIELDS", "1", "f"])
        #expect((hashTTL.arrayValue?.first?.intValue ?? -1) > 0)
        let listHead = try await session.execute(["LRANGE", .data(name("list")), "0", "-1"])
        #expect(listHead.arrayValue?.compactMap(\.stringValue) == ["b", "a"])
        await #expect(throws: KeyOperationError.keyAlreadyExists) {
            try await ops.create(NewKeyDraft(name: name("set"), value: .set([Data("x".utf8)])))
        }
        await #expect(throws: KeyOperationError.self) {
            try await ops.create(NewKeyDraft(name: name("empty"), value: .hash([])))
        }

        try await ops.rename(name("set"), to: name("set2"))
        #expect(!(try await ops.exists(name("set"))))
        await #expect(throws: KeyOperationError.newNameInUse) { try await ops.rename(name("set2"), to: name("list")) }
        try await ops.rename(name("set2"), to: name("list"), overwrite: true)
        #expect(try await metadata.keyInfo(name("list")).type == .set)
        await #expect(throws: KeyOperationError.keyNotFound) { try await ops.rename(name("nope"), to: name("x")) }

        try await ops.setTTL(name("hash"), seconds: 500)
        #expect(try await metadata.keyInfo(name("hash")).ttl > 400)
        try await ops.setTTL(name("hash"), seconds: nil)
        #expect(try await metadata.keyInfo(name("hash")).ttl == -1)
        try await ops.setTTL(name("hash"), seconds: 0)
        #expect(!(try await ops.exists(name("hash"))))
        await #expect(throws: KeyOperationError.keyNotFound) { try await ops.setTTL(name("hash"), seconds: 5) }

        #expect(try await ops.delete([name("zset"), name("stream"), name("missing")]) == 2)
        try await ops.delete([name("vset")])
        await #expect(throws: KeyOperationError.keyNotFound) { try await ops.delete([name("vset")]) }
        await session.close()
    }

    @Test(RedisTestServer.needs(.json, .timeSeries, .vectorSet)) func bulkDeleteReportsProgress() async throws {
        let session = try await freshSession()
        let client = try await session.client()
        try await RedisTestServer.seedStrings(client, prefix: "bulk:", count: 2_500)
        try await RedisTestServer.seedStrings(client, prefix: "keep:", count: 10)
        var overviews: [BulkActionOverview] = []
        for await overview in KeyOperations(session: session).bulkDelete(BulkActionFilter(match: "bulk:*", count: 1_000)) {
            overviews.append(overview)
        }

        let last = try #require(overviews.last)
        #expect(last.status == .completed)
        #expect(last.succeeded == 2_500)
        #expect(last.processed == 2_500)
        #expect(last.failed == 0)
        #expect(last.total == 2_510)
        #expect(last.scanned == 2_510)
        #expect(overviews.contains { $0.status == .running })
        #expect(try await KeyScanner(session: session).totalKeys() == 10)

        try await RedisTestServer.seedAllTypes(client, prefix: "t:")
        var typed: BulkActionOverview?
        for await overview in KeyOperations(session: session).bulkDelete(BulkActionFilter(match: "*", type: .hash)) {
            typed = overview
        }

        #expect(typed?.succeeded == 1)
        #expect(!(try await KeyOperations(session: session).exists(Data("t:hash".utf8))))
        await session.close()
    }

    @Test func bulkDeleteCanBeCancelled() async throws {
        let session = try await freshSession()
        try await RedisTestServer.seedStrings(try await session.client(), prefix: "c:", count: 20_000)
        let ops = KeyOperations(session: session)
        let task = Task { @MainActor () -> BulkActionOverview? in
            var last: BulkActionOverview?
            for await overview in ops.bulkDelete(BulkActionFilter(match: "c:*", count: 100)) {
                last = overview
                if overview.status == .running { break }
            }

            return last
        }
        let last = await task.value
        #expect(last?.status == .running)
        try await Task.sleep(for: .milliseconds(200))
        let remaining = try await KeyScanner(session: session).totalKeys()
        #expect(remaining > 0)
        await session.close()
    }

    @Test func bulkUploadCommandsFile() async throws {
        let session = try await freshSession()
        let file = """
        SET up:a 1
        HSET up:h f "hello world"

        RPUSH up:l a b c
        NOTACOMMAND x
        SET "unterminated
        SET up:b 2\r
        """
        var summaries: [BulkImportSummary] = []
        for await summary in KeyOperations(session: session).bulkUpload(Data(file.utf8)) { summaries.append(summary) }
        let final = try #require(summaries.last)
        #expect(final.isFinished)
        #expect(final.processed == 6)
        #expect(final.succeeded == 4)
        #expect(final.failed == 2)
        #expect(final.errors.count == 2)
        let value = try await session.execute(["HGET", "up:h", "f"])
        #expect(value.stringValue == "hello world")
        #expect(try await session.execute(["GET", "up:b"]).stringValue == "2")
        let summary = await CommandFileImporter(session: session).importAll(Data("SET up:c 3\n".utf8))
        #expect(summary.succeeded == 1)
        await session.close()
    }

    @Test func workbenchExecutorOnLiveServer() async throws {
        let session = try await freshSession()
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore)
        let script = """
        SET wb:key "café"
        GET wb:key
        2 INCR wb:counter
        INFO server
        """
        let commands = try WorkbenchScriptParser.parse(script)
        let ascii = try await executor.run(commands, params: ExecuteParams(), settings: AppSettings())
        #expect(ascii.count == 5)
        #expect(ascii[1].result?.first?.response == .reply(.string("caf\\xc3\\xa9")))
        #expect(ascii[3].result?.first?.response == .reply(.integer("2")))
        guard case .reply(.string(let infoText))? = ascii[4].result?.first?.response else {
            Issue.record("INFO should be a string")
            return
        }
        #expect(infoText.contains("redis_version"))
        #expect(ascii.allSatisfy { $0.db == Self.db && ($0.executionTime ?? 0) > 0 })
        let raw = try await executor.run(["GET wb:key"], params: ExecuteParams(mode: .raw), settings: AppSettings())
        #expect(raw.first?.result?.first?.response == .reply(.string("café")))
        let history = await session.services.commandHistoryStore.list(databaseID: session.id, type: .workbench)
        #expect(history.count == 6)
        await session.close()
    }

    @Test(RedisTestServer.needs(.search)) func databaseFactoryDetectsStandalone() async throws {
        let factory = DatabaseFactory()
        let draft = RedisTestServer.databaseConfig(db: Self.db)
        var unknown = draft
        unknown.connectionType = .notConnected
        unknown.provider = nil
        let detected = try await factory.createDetected(unknown)
        #expect(detected.connectionType == .standalone)
        #expect(detected.modules.contains { $0.name == "search" })
        #expect(detected.version != nil)
        #expect(detected.provider != nil && detected.provider != .unknown)
        #expect(detected.lastConnection != nil)
        try await factory.test(draft)

        var wrongPort = draft
        wrongPort.port = 6391
        wrongPort.timeoutMs = 2_000
        do {
            try await factory.test(wrongPort)
            Issue.record("expected a connection error")
        } catch let error as DatabaseFactoryError {
            guard case .connection(let connection) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(connection.code == .unavailable)
        }

        await #expect(throws: DatabaseFactoryError.self) { _ = try await factory.sentinelMasters(draft) }
    }

    @Test func notConnectedDatabaseIsDetectedOnConnect() async throws {
        try await RedisTestServer.flush(db: Self.db)
        let session = try await RedisTestServer.liveSession(db: Self.db) { $0.connectionType = .notConnected }
        #expect(session.state == .connected)
        #expect(session.config.connectionType == .standalone)
        let stored = try await session.services.databaseStore.get(session.id)
        #expect(stored.connectionType == .standalone)
        await session.close()
    }

    @Test func connectFailureSurfacesError() async throws {
        let services = RedisTestServer.makeServices()
        var config = RedisTestServer.databaseConfig(db: Self.db)
        config.port = 6391
        config.timeoutMs = 2_000
        try await services.databaseStore.create(config)
        let session = try await services.sessions.session(for: config.id)
        await session.connect()
        guard case .failed(let error) = session.state else {
            Issue.record("expected failure, got \(session.state)")
            return
        }
        #expect(error.code == .unavailable)
    }

    // MARK: - Atomic Add Key

    private static func collectionDrafts(_ name: (String) -> Data, ttl: Int?) -> [NewKeyDraft] {
        [
            NewKeyDraft(name: name("hash"), ttl: ttl, value: .hash([HashField(field: Data("f".utf8), value: Data("v".utf8), expire: 50)])),
            NewKeyDraft(name: name("list"), ttl: ttl, value: .list(.head, [Data("a".utf8), Data("b".utf8)])),
            NewKeyDraft(name: name("set"), ttl: ttl, value: .set([Data("a".utf8)])),
            NewKeyDraft(name: name("zset"), ttl: ttl, value: .zset([ZSetMemberDraft(member: Data("m".utf8), score: 1.5)])),
            NewKeyDraft(name: name("json"), ttl: ttl, value: .json(#"{"a":1}"#)),
            NewKeyDraft(name: name("stream"), ttl: ttl, value: .stream(id: "*", fields: [StreamFieldDraft(name: Data("f".utf8), value: Data("v".utf8))])),
            NewKeyDraft(name: name("vset"), ttl: ttl, value: .vectorSet([VectorElementDraft(name: Data("e".utf8), vector: [0.1, 0.2])])),
            NewKeyDraft(name: name("ts"), ttl: ttl, value: .timeSeries(TimeSeriesDraft(samples: [.init(timestamp: "1000", value: 1)]))),
        ]
    }

    @Test(RedisTestServer.needs(.json, .timeSeries, .vectorSet), RedisTestServer.needs(.hashFieldTTL))
    func atomicCreateOfEveryCollectionTypeAppliesTheTTL() async throws {
        let session = try await freshSession()
        let ops = KeyOperations(session: session)
        let metadata = KeyMetadataService(session: session)
        for draft in Self.collectionDrafts({ Data("atomic:\($0)".utf8) }, ttl: 300) {
            try await ops.create(draft)
            #expect(try await metadata.keyInfo(draft.name).type == draft.type, "created \(draft.type)")
            let ttl = try await session.execute(["TTL", .data(draft.name)]).intValue ?? -1
            #expect(ttl > 0 && ttl <= 300, "\(draft.type) TTL \(ttl)")
        }

        let fieldTTL = try await session.execute(["HTTL", "atomic:hash", "FIELDS", "1", "f"])
        #expect((fieldTTL.arrayValue?.first?.intValue ?? -1) > 0)
        #expect(try await session.execute(["LRANGE", "atomic:list", "0", "-1"]).arrayValue?.compactMap(\.stringValue) == ["b", "a"])
        await session.close()
    }

    @Test func createRefusesAnExistingKeyWithoutTouchingIt() async throws {
        let session = try await freshSession()
        let ops = KeyOperations(session: session)
        _ = try await session.execute(["SET", "taken", "keep", "EX", "1000"])
        _ = try await session.execute(["HSET", "taken:hash", "old", "1"])
        _ = try await session.execute(["EXPIRE", "taken:hash", "1000"])
        var drafts = Self.collectionDrafts({ _ in Data("taken".utf8) }, ttl: 50)
        drafts.append(NewKeyDraft(name: Data("taken".utf8), ttl: 50, value: .string(Data("new".utf8))))
        for draft in drafts {
            await #expect(throws: KeyOperationError.keyAlreadyExists, "\(draft.type)") { try await ops.create(draft) }
        }

        #expect(try await session.execute(["GET", "taken"]).stringValue == "keep")
        #expect((try await session.execute(["TTL", "taken"]).intValue ?? 0) > 900)
        let hash = NewKeyDraft(name: Data("taken:hash".utf8), ttl: 50,
                               value: .hash([HashField(field: Data("new".utf8), value: Data("2".utf8), expire: 5)]))
        await #expect(throws: KeyOperationError.keyAlreadyExists) { try await ops.create(hash) }
        #expect(try await session.execute(["HKEYS", "taken:hash"]).arrayValue?.compactMap(\.stringValue) == ["old"])
        #expect((try await session.execute(["TTL", "taken:hash"]).intValue ?? 0) > 900)
        await session.close()
    }

    @Test func largeCreateIsSplitIntoScriptSizedCommands() async throws {
        let session = try await freshSession()
        let ops = KeyOperations(session: session)
        let count = 20_000
        try await ops.create(NewKeyDraft(name: Data("big:set".utf8), ttl: 300, value: .set((0..<count).map { Data("m\($0)".utf8) })))
        try await ops.create(NewKeyDraft(name: Data("big:list".utf8), ttl: 300,
                                         value: .list(.head, (0..<count).map { Data("e\($0)".utf8) })))
        try await ops.create(NewKeyDraft(name: Data("big:hash".utf8), ttl: 300, value: .hash((0..<count).map {
            HashField(field: Data("f\($0)".utf8), value: Data("v".utf8))
        })))
        try await ops.create(NewKeyDraft(name: Data("big:zset".utf8), ttl: 300, value: .zset((0..<count).map {
            ZSetMemberDraft(member: Data("m\($0)".utf8), score: Double($0))
        })))
        #expect(try await session.execute(["SCARD", "big:set"]).intValue == Int64(count))
        #expect(try await session.execute(["LLEN", "big:list"]).intValue == Int64(count))
        #expect(try await session.execute(["LINDEX", "big:list", "0"]).stringValue == "e\(count - 1)")
        #expect(try await session.execute(["HLEN", "big:hash"]).intValue == Int64(count))
        #expect(try await session.execute(["ZCARD", "big:zset"]).intValue == Int64(count))
        for name in ["big:set", "big:list", "big:hash", "big:zset"] {
            #expect((try await session.execute(["TTL", .string(name)]).intValue ?? -1) > 0, "\(name)")
        }

        await session.close()
    }

    /// Runs `body` with a session authenticated as a new ACL user (`+@all` plus `rules`), then deletes the user.
    private func withACLUser(_ rules: [String], _ body: (DatabaseSession) async throws -> Void) async throws {
        try await RedisTestServer.flush(db: Self.db)
        let admin = try await RedisTestServer.makeConnection(db: Self.db)
        let user = "rgtest-addkey-" + UUID().uuidString.prefix(8).lowercased()
        let setUser: [RedisArgument] = ["ACL", "SETUSER", .string(user), "on", ">pw", "~*", "&*", "+@all"]
        _ = try await admin.execute(setUser + rules.map { .string($0) })
        var config = RedisTestServer.connectionConfig(db: Self.db)
        config.username = user
        config.password = "pw"
        var failure: Error?
        do {
            let connection = try await RedisConnection.connect(config: config)
            let session = DatabaseSession(config: RedisTestServer.databaseConfig(db: Self.db),
                                          services: RedisTestServer.makeServices(), client: connection)
            do { try await body(session) } catch { failure = error }
            await connection.close()
        } catch {
            failure = error
        }

        _ = try? await admin.execute(["ACL", "DELUSER", .string(user)])
        await admin.close()
        if let failure { throw failure }
    }

    @Test(RedisTestServer.needs(.json)) func deniedExpireReportsAKeyCreatedWithoutTTL() async throws {
        try await withACLUser(["-expire"]) { session in
            let ops = KeyOperations(session: session)
            for draft in [
                NewKeyDraft(name: Data("nottl:hash".utf8), ttl: 60, value: .hash([HashField(field: Data("f".utf8), value: Data("v".utf8))])),
                NewKeyDraft(name: Data("nottl:json".utf8), ttl: 60, value: .json(#"{"a":1}"#)),
            ] {
                do {
                    try await ops.create(draft)
                    Issue.record("\(draft.type): expected createdWithoutTTL")
                } catch KeyOperationError.createdWithoutTTL(let reason) {
                    #expect(reason.contains("no permissions to run the 'expire' command"), "\(reason)")
                }

                #expect(try await ops.exists(draft.name))
                #expect(try await session.execute(["TTL", .data(draft.name)]).intValue == -1)
            }
        }
    }

    @Test func deniedScriptingFallsBackAndStillCreates() async throws {
        try await withACLUser(["-@scripting"]) { session in
            let ops = KeyOperations(session: session)
            try await ops.create(NewKeyDraft(name: Data("noscript:set".utf8), ttl: 60, value: .set([Data("a".utf8)])))
            #expect((try await session.execute(["TTL", "noscript:set"]).intValue ?? -1) > 0)
            await #expect(throws: KeyOperationError.keyAlreadyExists) {
                try await ops.create(NewKeyDraft(name: Data("noscript:set".utf8), ttl: 5, value: .list(.tail, [Data("a".utf8)])))
            }
        }
        try await withACLUser(["-@scripting", "-expire"]) { session in
            let ops = KeyOperations(session: session)
            do {
                try await ops.create(NewKeyDraft(name: Data("noscript:list".utf8), ttl: 60, value: .list(.tail, [Data("a".utf8)])))
                Issue.record("expected createdWithoutTTL")
            } catch KeyOperationError.createdWithoutTTL(let reason) {
                #expect(reason.contains("no permissions to run the 'expire' command"), "\(reason)")
            }

            #expect(try await session.execute(["LLEN", "noscript:list"]).intValue == 1)
            #expect(try await session.execute(["TTL", "noscript:list"]).intValue == -1)
        }
    }

    @Test(RedisTestServer.needs(.timeSeries)) func failedCreationCommandLeavesNoKey() async throws {
        let draft = NewKeyDraft(name: Data("partial:ts".utf8), ttl: 60, value: .timeSeries(TimeSeriesDraft(
            duplicatePolicy: "BLOCK", samples: [.init(timestamp: "1000", value: 1), .init(timestamp: "1000", value: 2)])))

        func check(_ session: DatabaseSession) async throws {
            let ops = KeyOperations(session: session)
            do {
                try await ops.create(draft)
                Issue.record("expected the duplicate sample to fail")
            } catch let error as RedisClientError {
                #expect(error.serverError?.message.contains("DUPLICATE_POLICY") == true, "\(error)")
            }

            #expect(try await ops.exists(draft.name) == false)
        }

        let session = try await freshSession()
        try await check(session)
        await session.close()
        try await withACLUser(["-@scripting"], check)
    }

    @Test func removingTheTTLPersistsTheKey() async throws {
        let session = try await freshSession()
        let ops = KeyOperations(session: session)
        _ = try await session.execute(["SET", "persist", "v", "PX", "400"])
        try await ops.setTTL(Data("persist".utf8), seconds: nil)
        #expect(try await session.execute(["TTL", "persist"]).intValue == -1)
        await session.close()
    }
}

/// RediSearch helpers in DB 0 with a unique prefix and index name.
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis, modules: .search))
struct LiveSearchIndexTests {
    @Test func listInfoCoverageSearchAndDrop() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.search)
        let client = try await session.client()
        let prefix = RedisTestServer.uniquePrefix("core")
        let index = "idx:\(prefix)"
        _ = try await session.execute(["FT.CREATE", .string(index), "ON", "HASH", "PREFIX", "1", .string(prefix),
                                       "SCHEMA", "name", "TEXT", "SORTABLE", "price", "NUMERIC"])
        do {
            for i in 0..<5 {
                _ = try await session.execute(["HSET", .string("\(prefix)\(i)"), "name", .string("bike \(i)"), "price", .int(Int64(i))])
            }

            let service = SearchIndexService(session: session)
            let indexes = try await service.listIndexes()
            #expect(indexes.contains(Data(index.utf8)))
            let info = try await service.info(Data(index.utf8))
            #expect(info.keyType == .hash)
            #expect(info.prefixes == [prefix])
            #expect(info.attributes.map(\.attribute) == ["name", "price"])
            #expect(info.attributes[0].flags.contains("SORTABLE"))

            let covering = try await service.indexes(coveringKey: Data("\(prefix)0".utf8), type: .hash)
            #expect(covering.contains { $0.name == Data(index.utf8) })
            #expect(try await service.indexes(coveringKey: Data("other:0".utf8), type: .hash).allSatisfy { $0.name != Data(index.utf8) })
            #expect(try await service.indexes(coveringKey: Data("\(prefix)0".utf8), type: .set).isEmpty)

            var page = SearchKeysPage(total: 0, keys: [], nextOffset: nil)
            for _ in 0..<20 {
                page = try await service.searchKeys(index: Data(index.utf8), query: "*", offset: 0, limit: 3)
                if page.total == 5 { break }
                try await Task.sleep(for: .milliseconds(50))
            }

            #expect(page.total == 5)
            #expect(page.keys.count == 3)
            #expect(page.nextOffset == 3)
            #expect(page.keyType == .hash)
            let rest = try await service.searchKeys(index: Data(index.utf8), query: "*", offset: 3, limit: 3)
            #expect(rest.keys.count == 2)
            #expect(rest.nextOffset == nil)
            _ = try await service.maxSearchResults()

            try await session.services.queryLibraryStore.create(
                QueryLibraryItem(databaseId: session.id, indexName: index, name: "q", query: "FT.SEARCH \(index) *"))
            try await service.drop(Data(index.utf8))
            #expect(!(try await service.listIndexes()).contains(Data(index.utf8)))
            #expect(await session.services.queryLibraryStore.list(databaseID: session.id, indexName: index).isEmpty)
            await #expect(throws: SearchIndexError.indexNotFound) { try await service.info(Data(index.utf8)) }
        } catch {
            _ = try? await session.execute(["FT.DROPINDEX", .string(index)])
            try? await RedisTestServer.deleteKeys(client, prefix: prefix)
            throw error
        }

        try await RedisTestServer.deleteKeys(client, prefix: prefix)
        await session.close()
    }
}
