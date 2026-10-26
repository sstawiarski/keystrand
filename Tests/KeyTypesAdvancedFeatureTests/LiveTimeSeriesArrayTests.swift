import Foundation
@testable import KeyTypesAdvancedFeature
import RedisCore
import TestSupport
import Testing

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis, modules: .timeSeries))
struct LiveTimeSeriesTests {
    @Test func infoRangePagingAndAggregation() async throws {
        let h = try await LiveHarness.make("ts")
        defer { Task { await h.cleanup() } }
        let key = h.key("t")
        try await h.run(["TS.CREATE", .data(key), "LABELS", "sensor", "a1", "room", "lab"])
        var add: [RedisArgument] = ["TS.MADD"]
        for i in 1...1_200 { add += [.data(key), .string(String(i * 1_000)), .string(String(Double(i) / 2))] }
        try await h.run(add)

        let model = TimeSeriesViewModel(context: h.context(key, type: .timeSeries))
        await model.load()
        let info = try #require(model.info)
        #expect(info.totalSamples == 1_200)
        #expect(info.labels.map(\.name).sorted() == ["room", "sensor"])
        #expect(info.firstTimestamp == 1_000)
        #expect(model.samples.count == 500)
        #expect(model.samples.first?.timestamp == 1_200_000)
        #expect(model.canLoadMore)
        #expect(!model.chartSamples.isEmpty)

        await model.loadNextPage()
        await model.loadNextPage()
        #expect(model.samples.count == 1_200)
        #expect(!model.canLoadMore)

        model.order = .asc
        model.fromText = "10000"
        model.toText = "20000"
        await model.apply()
        #expect(model.samples.map(\.timestamp).first == 10_000)
        #expect(model.samples.count == 11)

        model.isAggregating = true
        model.aggregation = .sum
        model.bucketText = "5000"
        await model.apply()
        #expect(model.samples.first?.timestamp == 10_000)
        #expect(model.samples.first?.value == 5 + 5.5 + 6 + 6.5 + 7)

        model.minValueText = "3"
        #expect(model.queryError != nil)
        model.maxValueText = "x"
        #expect(model.queryError == "Value filter must be numeric")
        await model.resetQuery()
        #expect(model.queryError == nil)
        #expect(model.samples.count == 500)
    }

    @Test func addDeleteAndAlter() async throws {
        let h = try await LiveHarness.make("tsw")
        defer { Task { await h.cleanup() } }
        let key = h.key("t")
        try await h.run(["TS.CREATE", .data(key)])
        let model = TimeSeriesViewModel(context: h.context(key, type: .timeSeries))
        await model.load()
        #expect(model.samples.isEmpty)

        model.openAddPanel()
        model.draftTimestamp = "5000"
        model.draftValue = "abc"
        #expect(!model.isAddValid)
        model.draftValue = "4.25"
        #expect(model.isAddValid)
        await model.saveSample()
        #expect(model.info?.totalSamples == 1)
        #expect(model.samples.first?.valueText == "4.25")

        model.draftTimestamp = "*"
        model.draftValue = "1"
        await model.saveSample()
        #expect(model.info?.totalSamples == 2)

        await model.deleteSamples(from: 0, to: 5000)
        #expect(model.info?.totalSamples == 1)

        model.beginEditingSettings()
        model.draftRetention = "60000"
        model.draftDuplicatePolicy = .last
        model.draftLabels = [TimeSeriesLabel(name: "k", value: "v")]
        await model.saveSettings()
        #expect(!model.isEditingSettings)
        #expect(model.info?.retentionMs == 60_000)
        #expect(model.info?.duplicatePolicy?.lowercased() == "last")
        #expect(model.info?.labels.map(\.name) == ["k"])
    }
}

@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis), RedisTestServer.needs(.array))
struct LiveArrayTests {
    @Test func viewSearchAndAggregate() async throws {
        let h = try await LiveHarness.make("arr")
        defer { Task { await h.cleanup() } }
        #expect(h.session.capabilities.supportsArray)
        let key = h.key("a")
        try await h.run(["ARSET", .data(key), "0", "1", "2", "3", "x"])
        try await h.run(["ARSET", .data(key), "10", "7"])
        let model = ArrayViewModel(context: h.context(key, type: .array))
        await model.load()
        #expect(model.rows.count == 10)
        #expect(model.rows[3].element.value == Data("x".utf8))
        #expect(model.rows[5].element.value == nil)

        model.showEmpty = false
        model.endText = "20"
        await model.runView()
        #expect(model.rows.map(\.id) == ["0", "1", "2", "3", "10"])

        model.startText = "0"
        model.endText = "2000000"
        model.showEmpty = true
        #expect(model.viewValidationError == ArrayError.rangeTooLarge.localizedDescription)
        model.endText = "007"
        #expect(model.viewValidationError == ArrayIndex.indexError)
        await model.resetView()
        #expect(model.endText == "9")

        model.predicates = [ArrayGrepPredicate(criteria: .exact, pattern: "x"), ArrayGrepPredicate(criteria: .match, pattern: "7")]
        model.withValues = true
        await model.runSearch()
        #expect(model.searchRows.map(\.id) == ["3", "10"])
        model.contextEnabled = true
        model.contextSize = 1
        await model.toggleContext(for: try #require(model.searchRows.first))
        #expect(model.contextBand?.rows.map(\.id) == ["2", "3", "4"])

        model.aggStartText = "0"
        model.aggEndText = "20"
        model.aggOp = .sum
        await model.runAggregate()
        #expect(model.aggResult == "13")
        model.aggOp = .match
        model.aggValue = "x"
        await model.runAggregate()
        #expect(model.aggResult == "1")
        model.aggOp = .max
        model.aggStartText = "3"
        model.aggEndText = "3"
        await model.runAggregate()
        #expect(model.aggResultIsNil)
    }

    @Test func editAddAndDelete() async throws {
        let h = try await LiveHarness.make("arrw")
        defer { Task { await h.cleanup() } }
        let key = h.key("a")
        try await h.run(["ARSET", .data(key), "0", "a", "b", "c"])
        let model = ArrayViewModel(context: h.context(key, type: .array))
        await model.load()

        #expect(await model.save(index: "1", text: "B"))
        #expect(try await h.run(["ARGET", .data(key), "1"]).stringValue == "B")
        #expect(model.rows[1].element.value == Data("B".utf8))

        model.openAddPanel()
        model.addValue = "appended"
        await model.saveAdd()
        #expect(try await h.run(["ARGET", .data(key), "3"]).stringValue == "appended")

        model.openAddPanel()
        model.addIndexText = "007"
        #expect(!model.isAddValid)
        model.addIndexText = "500"
        model.addValue = "far"
        model.moveToAdded = true
        await model.saveAdd()
        #expect(model.startText == "491")
        #expect(model.endText == "500")
        #expect(model.rows.last?.element.value == Data("far".utf8))

        await model.resetView()
        await model.delete(indexes: ["0"])
        #expect(model.rows.first?.element.value == nil)

        model.startText = "0"
        model.endText = "600"
        await model.deleteViewRange()
        #expect(h.deletedCount == 1)
        #expect(try await h.exists(key) == false)
    }
}

@MainActor
struct KeyTypesAdvancedFeatureSmokeTests {
    @Test func publicViewsConstruct() {
        let session = RedisTestServer.mockSession()
        let key = Data("k".utf8)
        let context = KeyDetailsContext(session: session, key: key, type: .unknown("MBbloom--"), state: KeyDetailsState(key: key))
        _ = ZSetKeyView(context: context)
        _ = StreamKeyView(context: context)
        _ = JSONKeyView(context: context)
        _ = VectorSetKeyView(context: context)
        _ = TimeSeriesKeyView(context: context)
        _ = ArrayKeyView(context: context)
        _ = UnsupportedKeyView(context: context)
        _ = UnsupportedKeyView(context: context, note: "note")
        _ = VectorSetAddKeyForm(context: AddKeyFormContext(session: session, keyName: { key }, ttl: { nil },
                                                           onKeyAdded: { _ in }, onCancel: {}))
    }
}
