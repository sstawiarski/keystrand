import Foundation
@testable import MonitoringFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct PubSubViewModelTests {
    private func makeModel(_ factory: FakePubSubFactory, client: MockRedisClient = MockRedisClient())
        -> (PubSubViewModel, DatabaseSession) {
        let session = RedisTestServer.mockSession(client)
        let model = PubSubViewModel(session: session) { try factory.connect() }
        return (model, session)
    }

    @Test func subscribeUsesPatternsAndConfirms() async throws {
        let factory = FakePubSubFactory()
        let (model, _) = makeModel(factory)
        #expect(model.isEmptyState)
        model.patternInput = "news.* alerts news.*"
        await model.subscribe()
        let transport = try #require(factory.latest)
        #expect(await transport.patterns == [Data("news.*".utf8), Data("alerts".utf8)])
        #expect(await waitUntil { model.status == .subscribed })
        #expect(model.headerPatternsText == "Patterns: 2")
        #expect(model.patternsTooltip == "news.*\nalerts")
        #expect(!model.isEmptyState)
    }

    @Test func emptyPatternSubscribesToEverything() async throws {
        let factory = FakePubSubFactory()
        let (model, _) = makeModel(factory)
        model.patternInput = "   "
        await model.subscribe()
        #expect(model.patternInput == "*")
        #expect(await factory.latest?.patterns == [Data("*".utf8)])
        #expect(model.headerPatternsText == "Patterns: All")
    }

    @Test func messagesArriveInBatchesNewestFirst() async throws {
        let factory = FakePubSubFactory()
        let (model, _) = makeModel(factory)
        await model.subscribe()
        let transport = try #require(factory.latest)
        for i in 0..<25 { await transport.deliver(channel: "ch\(i % 3)", message: "m\(i)") }
        #expect(await waitUntil { model.messages.count == 25 })
        #expect(model.totalReceived == 25)
        #expect(model.canClear)
        #expect(model.rows.count == 25)
        #expect(model.rows.first?.messagePreview == "m24")
        #expect(await waitUntil { model.status == .subscribed })
        #expect(model.statusText == "Subscribed to all channels · 25 messages")
        model.sortDescending = false
        #expect(model.rows.first?.messagePreview == "m0")
        #expect(model.rows.last?.messagePreview == "m24")
    }

    @Test func statusTextBeforeSubscribing() {
        let (model, _) = makeModel(FakePubSubFactory())
        #expect(model.statusText == "Not subscribed")
    }

    @Test func keepsAtMostFiveThousandMessages() async throws {
        let factory = FakePubSubFactory()
        let (model, _) = makeModel(factory)
        await model.subscribe()
        let transport = try #require(factory.latest)
        for i in 0..<6_000 { await transport.deliver(channel: "c", message: "\(i)") }
        #expect(await waitUntil(timeout: .seconds(10)) { model.totalReceived == 6_000 })
        #expect(model.messages.count == PubSubViewModel.messageLimit)
        #expect(model.messages.first?.messagePreview == "1000")
        #expect(model.messages.last?.messagePreview == "5999")
    }

    @Test func clearResetsMessagesAndCount() async throws {
        let factory = FakePubSubFactory()
        let (model, _) = makeModel(factory)
        await model.subscribe()
        let transport = try #require(factory.latest)
        await transport.deliver(channel: "c", message: "x")
        #expect(await waitUntil { model.messages.count == 1 })
        model.clearMessages()
        #expect(model.messages.isEmpty)
        #expect(model.totalReceived == 0)
        #expect(!model.canClear)
        #expect(model.status == .subscribed)
    }

    @Test func binaryPayloadsStayBinarySafe() async throws {
        let factory = FakePubSubFactory()
        let (model, _) = makeModel(factory)
        await model.subscribe()
        let transport = try #require(factory.latest)
        let payload = Data([0x00, 0xFF, 0x41])
        await transport.deliver(channel: "bin", message: payload)
        #expect(await waitUntil { model.messages.count == 1 })
        let entry = try #require(model.messages.first)
        #expect(entry.message == payload)
        #expect(entry.messagePreview == " \\xffA")
        #expect(entry.messageFullText == "\u{0}\\xffA")
    }

    @Test func unsubscribeClosesTheConnectionAndKeepsMessages() async throws {
        let factory = FakePubSubFactory()
        let (model, _) = makeModel(factory)
        await model.subscribe()
        let transport = try #require(factory.latest)
        await transport.deliver(channel: "c", message: "kept")
        #expect(await waitUntil { model.messages.count == 1 })
        await model.unsubscribe()
        #expect(model.status == .unsubscribed)
        #expect(await transport.isClosed)
        #expect(model.messages.count == 1)
        #expect(!model.isEmptyState)
        #expect(model.connectionError == nil)
    }

    @Test func connectionDropUnsubscribesAndOffersResubscribe() async throws {
        let factory = FakePubSubFactory()
        let (model, session) = makeModel(factory)
        await model.subscribe()
        #expect(await waitUntil { model.status == .subscribed })
        let first = try #require(factory.latest)
        await first.fail(RedisClientError.connectionClosed)
        #expect(await waitUntil { model.status == .unsubscribed })
        #expect(model.connectionError == "Couldn't open a connection to the database.")
        #expect(model.statusText == "Connection lost")
        #expect(await first.isClosed)
        #expect(session.toasts.toasts.map(\.title) == ["Couldn't open a connection to the database."])

        await model.resubscribe()
        #expect(factory.made.count == 2)
        #expect(await waitUntil { model.status == .subscribed })
        #expect(model.connectionError == nil)
    }

    @Test func serverRejectionBeforeConfirmationShowsTheReason() async throws {
        let factory = FakePubSubFactory()
        factory.confirms = false
        let (model, _) = makeModel(factory)
        await model.subscribe()
        let transport = try #require(factory.latest)
        await transport.fail(RedisClientError.server(RESPError("NOPERM no permissions to access channel")))
        #expect(await waitUntil { model.status == .unsubscribed })
        #expect(model.connectionError == "NOPERM no permissions to access channel")
    }

    @Test func connectFailureShowsErrorAndToast() async throws {
        let factory = FakePubSubFactory()
        factory.failNext = RedisClientError.connectionFailed("refused")
        let (model, session) = makeModel(factory)
        await model.subscribe()
        #expect(model.status == .unsubscribed)
        #expect(model.connectionError == "Couldn't open a connection to the database.")
        #expect(model.statusText == "Could not subscribe")
        let toast = try #require(session.toasts.toasts.first)
        #expect(session.toasts.toasts.count == 1)
        #expect(toast.title == "Couldn't open a connection to the database.")
        #expect(toast.message?.contains("refused") == true)
    }

    @Test func sessionResetWhileSubscribedRaisesNoError() async throws {
        let factory = FakePubSubFactory()
        let session = RedisTestServer.mockSession(MockRedisClient())
        let model = session.scopedObject(PubSubViewModel.self) {
            PubSubViewModel(session: session) { try factory.connect() }
        }
        await model.subscribe()
        #expect(await waitUntil { model.status == .subscribed })
        let transport = try #require(factory.latest)
        await session.disconnect()
        #expect(await transport.isClosed)
        model.flushPending()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.status == .unsubscribed)
        #expect(model.connectionError == nil)
        #expect(model.statusText == "Not subscribed")
        #expect(session.toasts.toasts.isEmpty)
    }

    @Test func sessionCloseStopsTheSubscription() async throws {
        let factory = FakePubSubFactory()
        let (model, _) = makeModel(factory)
        await model.subscribe()
        let transport = try #require(factory.latest)
        await model.sessionWillClose()
        #expect(model.status == .unsubscribed)
        #expect(await transport.isClosed)
    }

    @Test func scopedObjectSurvivesViewRecreation() {
        let session = RedisTestServer.mockSession()
        let a = session.scopedObject(PubSubViewModel.self) { PubSubViewModel(session: session) }
        a.channelInput = "kept"
        let b = session.scopedObject(PubSubViewModel.self) { PubSubViewModel(session: session) }
        #expect(a === b)
        #expect(b.channelInput == "kept")
    }

    @Test func publishShowsReceiversAndClearsMessage() async throws {
        let client = MockRedisClient(responses: ["PUBLISH": .integer(3)])
        let (model, _) = makeModel(FakePubSubFactory(), client: client)
        model.channelInput = "news"
        model.messageInput = "hello"
        await model.publish()
        #expect(model.messageInput.isEmpty)
        #expect(model.channelInput == "news")
        #expect(model.publishResult?.receivers == 3)
        #expect(model.publishResult?.statusText == "Published to 3 clients")
        #expect(await client.executedCommandStrings.last == "PUBLISH news hello")
    }

    @Test func publishErrorKeepsInputAndToasts() async {
        let client = MockRedisClient(responses: ["PUBLISH": .error(RESPError("NOPERM no permission"))])
        let (model, session) = makeModel(FakePubSubFactory(), client: client)
        model.channelInput = "news"
        model.messageInput = "hello"
        await model.publish()
        #expect(model.messageInput == "hello")
        #expect(model.publishResult == nil)
        #expect(session.toasts.toasts.count == 1)
        #expect(session.toasts.toasts.first?.message?.contains("NOPERM") == true)
    }

    @Test func patternFieldBlurRestoresDefault() {
        let (model, _) = makeModel(FakePubSubFactory())
        model.patternInput = ""
        model.patternFieldDidLoseFocus()
        #expect(model.patternInput == "*")
    }
}

@MainActor
@Suite(.serialized)
struct PubSubLiveTests {
    @Test(.tags(.live), RedisTestServer.live(.redis))
    func subscribePublishRoundTrip() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.monitoring)
        defer { Task { await session.close() } }
        let model = PubSubViewModel(session: session)
        let channel = RedisTestServer.uniquePrefix("pubsub") + "news"
        model.patternInput = channel.replacingOccurrences(of: "news", with: "*")
        await model.subscribe()
        #expect(await waitUntil { model.status == .subscribed })

        model.channelInput = channel
        model.messageInput = "hello world"
        await model.publish()
        #expect((model.publishResult?.receivers ?? 0) >= 1)
        #expect(await waitUntil { model.messages.contains { $0.messagePreview == "hello world" } })
        let entry = try #require(model.messages.first { $0.messagePreview == "hello world" })
        #expect(entry.channelText == channel)

        let other = try await RedisTestServer.makeConnection(db: RedisTestServer.DB.monitoring)
        _ = try await other.execute(["PUBLISH", .string("unrelated-\(UUID().uuidString)"), "nope"])
        _ = try await other.execute(["PUBLISH", .data(Data(channel.utf8)), .data(Data([0xC3, 0x28, 0x00]))])
        #expect(await waitUntil { model.messages.count == 2 })
        #expect(model.messages.last?.message == Data([0xC3, 0x28, 0x00]))
        #expect(model.messages.allSatisfy { !$0.channelText.hasPrefix("unrelated") })
        await other.close()

        await model.unsubscribe()
        #expect(model.status == .unsubscribed)
        model.channelInput = channel
        model.messageInput = "after"
        await model.publish()
        #expect(model.publishResult != nil)
        #expect(model.messageInput.isEmpty)
    }

    @Test(.tags(.live), RedisTestServer.live(.redis))
    func serverSideKillIsReportedAsConnectionLoss() async throws {
        let session = try await RedisTestServer.liveSession(db: RedisTestServer.DB.monitoring)
        defer { Task { await session.close() } }
        let marker = "rgtest-pubsub-\(UUID().uuidString.prefix(8))"
        let model = PubSubViewModel(session: session) {
            let connection = try await session.makeDedicatedConnection()
            _ = try await connection.execute(["CLIENT", "SETNAME", .string(marker)])
            return connection
        }
        await model.subscribe()
        #expect(await waitUntil { model.status == .subscribed })
        let admin = try await RedisTestServer.makeConnection(db: RedisTestServer.DB.monitoring)
        let list = try await admin.execute(["CLIENT", "LIST"]).stringValue ?? ""
        let id = list.split(separator: "\n").first { $0.contains("name=\(marker)") }?
            .split(separator: " ").first { $0.hasPrefix("id=") }?.dropFirst(3)
        let clientID = try #require(id.map(String.init))
        _ = try await admin.execute(["CLIENT", "KILL", "ID", .string(clientID)])
        await admin.close()
        #expect(await waitUntil { model.status == .unsubscribed })
        #expect(model.connectionError == "Couldn't open a connection to the database.")
    }
}
