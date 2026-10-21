import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import TestSupport
import Testing

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct LiveZSetTests {
    @Test func pagesSortsAndCounts() async throws {
        let h = try await LiveHarness.make("zpage")
        defer { Task { await h.cleanup() } }
        let key = h.key("z")
        var args: [RedisArgument] = ["ZADD", .data(key)]
        for i in 0..<1_200 { args += [.string(String(i)), .string("m\(i)")] }
        try await h.run(args)

        let model = ZSetViewModel(context: h.context(key, type: .zset))
        await model.load()
        #expect(model.total == 1_200)
        #expect(model.rows.count == 500)
        #expect(model.rows.first?.member.score == "0")
        #expect(model.canLoadMore)

        await model.loadNextPage()
        #expect(model.rows.count == 1_000)
        await model.loadNextPage()
        #expect(model.rows.count == 1_200)
        #expect(!model.canLoadMore)

        await model.toggleSort()
        #expect(model.sortOrder == .desc)
        #expect(model.rows.first?.member.score == "1199")
        #expect(model.rows.count == 500)
    }

    @Test func exactAndPatternSearch() async throws {
        let h = try await LiveHarness.make("zsearch")
        defer { Task { await h.cleanup() } }
        let key = h.key("z")
        try await h.run(["ZADD", .data(key), "1", "apple", "2", "apricot", "3", "banana", "4", "a*b"])
        let model = ZSetViewModel(context: h.context(key, type: .zset))
        await model.load()

        model.searchText = "apple"
        await model.applySearch()
        #expect(model.rows.map(\.member.score) == ["1"])

        model.searchText = "ap*"
        await model.applySearch()
        #expect(Set(model.rows.map { String(decoding: $0.member.name, as: UTF8.self) }) == ["apple", "apricot"])

        model.searchText = "a\\*b"
        await model.applySearch()
        #expect(model.rows.map { String(decoding: $0.member.name, as: UTF8.self) } == ["a*b"])

        model.searchText = "missing"
        await model.applySearch()
        #expect(model.rows.isEmpty)

        await model.closeSearch()
        #expect(model.rows.count == 4)
    }

    @Test func editAddAndRemoveMembers() async throws {
        let h = try await LiveHarness.make("zedit")
        defer { Task { await h.cleanup() } }
        let key = h.key("z")
        try await h.run(["ZADD", .data(key), "1", "a", "2", "b"])
        let model = ZSetViewModel(context: h.context(key, type: .zset))
        await model.load()

        await model.updateScore(member: Data("a".utf8), score: "10.5")
        #expect(try await h.run(["ZSCORE", .data(key), "a"]).doubleValue == 10.5)
        await model.updateScore(member: Data("a".utf8), score: "10.5")
        #expect(!h.toastTitles.contains("Error"))

        model.openAddPanel()
        model.draftRows = [ZSetDraftRow(member: "c", score: "3"), ZSetDraftRow(member: "d", score: "-1.25")]
        #expect(model.isAddValid)
        await model.saveDrafts()
        #expect(!model.isAddPanelOpen)
        #expect(model.total == 4)
        #expect(try await h.run(["ZSCORE", .data(key), "d"]).doubleValue == -1.25)

        await model.remove(Data("b".utf8))
        #expect(model.total == 3)
        await model.remove(Data("a".utf8))
        await model.remove(Data("c".utf8))
        #expect(model.lastItemWarning() != nil)
        await model.remove(Data("d".utf8))
        #expect(h.deletedCount == 1)
        #expect(try await h.exists(key) == false)
    }

    @Test func missingKeyReportsDeleted() async throws {
        let h = try await LiveHarness.make("zgone")
        defer { Task { await h.cleanup() } }
        let model = ZSetViewModel(context: h.context(h.key("nope"), type: .zset))
        await model.load()
        #expect(h.deletedCount == 1)
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct LiveStreamTests {
    @Test func entriesPagingAndRange() async throws {
        let h = try await LiveHarness.make("xpage")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        var commands: [[RedisArgument]] = []
        for i in 1...1_100 { commands.append(["XADD", .data(key), .string("\(i)-0"), "n", .string(String(i))]) }
        try await h.pipeline(commands)

        let model = StreamViewModel(context: h.context(key, type: .stream))
        await model.load()
        #expect(model.info?.length == 1_100)
        #expect(model.rows.count == 500)
        #expect(model.rows.first?.id == "1100-0")
        #expect(model.bounds == 1...1_100)
        await model.loadNextPage()
        await model.loadNextPage()
        #expect(model.rows.count == 1_100)
        #expect(model.rows.last?.id == "1-0")
        #expect(!model.canLoadMore)

        model.range = 10...20
        await model.reloadEntries()
        #expect(model.rows.count == 11)
        #expect(model.isRangeFiltered)

        await model.toggleSort()
        #expect(model.rows.first?.id == "10-0")
        model.resetRange()
        #expect(!model.isRangeFiltered)
    }

    @Test func addAndDeleteEntries() async throws {
        let h = try await LiveHarness.make("xadd")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        try await h.run(["XADD", .data(key), "5-1", "f", "v"])
        let model = StreamViewModel(context: h.context(key, type: .stream))
        await model.load()

        model.openAddEntry()
        model.draftId = "5-1"
        #expect(model.draftIdError == "Must be greater than the last ID")
        model.draftId = "6-0"
        model.draftFields = [StreamFieldInput(name: "a", value: "1"), StreamFieldInput(name: "a", value: "2")]
        #expect(model.isDraftValid)
        await model.saveEntry()
        #expect(model.info?.length == 2)
        #expect(model.columns.count == 3)

        await model.deleteEntry("5-1")
        await model.deleteEntry("6-0")
        #expect(model.isStreamEmpty)
        #expect(try await h.exists(key))
        #expect(h.deletedCount == 0)
        #expect(model.rows.isEmpty)
    }

    @Test func consumerGroupsFlow() async throws {
        let h = try await LiveHarness.make("xgroup")
        defer { Task { await h.cleanup() } }
        let key = h.key("s")
        try await h.pipeline([
            ["XADD", .data(key), "1-0", "f", "a"],
            ["XADD", .data(key), "2-0", "f", "b"],
            ["XADD", .data(key), "3-0", "f", "c"],
        ])
        let model = StreamViewModel(context: h.context(key, type: .stream))
        await model.load()
        await model.showGroups()
        #expect(model.groups.isEmpty)

        model.openAddGroup()
        model.draftGroupName = "g1"
        model.draftGroupId = "0"
        await model.saveGroup()
        #expect(model.groups.map(\.displayName) == ["g1"])
        await model.saveGroup()
        #expect(h.toastTitles.contains("Error"))

        try await h.run(["XREADGROUP", "GROUP", "g1", "c1", "COUNT", "2", "STREAMS", .data(key), ">"])
        try await h.run(["XREADGROUP", "GROUP", "g1", "c2", "COUNT", "1", "STREAMS", .data(key), ">"])
        await model.loadGroups()
        let group = try #require(model.groups.first)
        #expect(group.pending == 3)
        #expect(group.smallestPendingId == "1-0")
        #expect(group.greatestPendingId == "3-0")

        #expect(await model.setGroupId(group, id: "2-0"))
        #expect(model.groups.first?.lastDeliveredId == "2-0")

        await model.openGroup(try #require(model.groups.first))
        #expect(model.viewType == .consumers)
        #expect(model.consumers.count == 2)
        let c1 = try #require(model.consumers.first { $0.displayName == "c1" })
        await model.openConsumer(c1)
        #expect(model.viewType == .messages)
        #expect(model.pending.map(\.id) == ["1-0", "2-0"])
        #expect(model.otherConsumers.map(\.displayName) == ["c2"])

        await model.ack(try #require(model.pending.first))
        #expect(model.pending.map(\.id) == ["2-0"])

        #expect(await model.claim(try #require(model.pending.first),
                                  options: ClaimOptions(consumer: Data("c2".utf8), minIdleMs: 0)))
        #expect(model.pending.isEmpty)

        #expect(await model.claim(PendingEntry(id: "3-0", consumer: Data("c2".utf8), idleMs: 0, delivered: 1),
                                  options: ClaimOptions(consumer: Data("c1".utf8), minIdleMs: 3_600_000)) == false)

        let outcome = try #require(await model.autoClaim(to: Data("c1".utf8), minIdleMs: 0, start: "0-0", count: 10))
        #expect(outcome.claimedCount >= 1)
        #expect(outcome.isComplete)
        #expect(model.pending.map(\.id).contains("3-0"))

        let c2 = try #require(model.consumers.first { $0.displayName == "c2" })
        await model.deleteConsumer(c2)
        #expect(model.consumers.map(\.displayName) == ["c1"])

        await model.deleteGroup(try #require(model.groups.first))
        #expect(model.groups.isEmpty)
    }
}
