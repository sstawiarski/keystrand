import Foundation
@testable import WorkbenchFeature
import RedisCore
import TestSupport
import Testing

struct ModuleMissingTests {
    @Test func emptyModuleListCountsAsMissing() {
        #expect(CommandModuleRequirement.missing(for: "FT.SEARCH idx *", loadedModules: []) == .search)
        #expect(CommandModuleRequirement.missing(for: "json.get k", loadedModules: []) == .json)
        #expect(CommandModuleRequirement.missing(for: "TS.RANGE k - +", loadedModules: ["ReJSON"]) == .timeSeries)
        #expect(CommandModuleRequirement.missing(for: "CF.ADD k v", loadedModules: []) == .probabilistic)
    }

    @Test func loadedModuleOrCoreCommandIsNotMissing() {
        #expect(CommandModuleRequirement.missing(for: "FT.SEARCH idx *", loadedModules: ["search"]) == nil)
        #expect(CommandModuleRequirement.missing(for: "JSON.GET k", loadedModules: ["ReJSON"]) == nil)
        #expect(CommandModuleRequirement.missing(for: "GET k", loadedModules: []) == nil)
    }

    @MainActor
    @Test func tutorialRunOnDatabaseWithoutModulesOpensModulePopover() throws {
        let model = TutorialsViewModel(session: RedisTestServer.mockSession())
        let plain = try #require(TutorialFence.parse(info: "redis Search"))
        #expect(model.check(code: "HSET a f v\nFT.SEARCH idx *", fence: plain) == .moduleMissing(.search))
        #expect(model.check(code: "GET a", fence: plain) == .ready)
    }
}

struct DangerousSkipTests {
    @Test func multiVerbActionIDSkipsEveryVerb() {
        #expect(WorkbenchCommandText.dangerousActionID(verbs: ["KEYS"]) == "dangerous:KEYS")
        #expect(WorkbenchCommandText.dangerousActionID(verbs: ["KEYS", "FLUSHDB"]) == "dangerous:KEYS,FLUSHDB")
        let skipped = WorkbenchCommandText.skippedDangerousVerbs(["dangerous:KEYS,FLUSHDB", "dangerous:config", "other"])
        #expect(skipped == ["KEYS", "FLUSHDB", "CONFIG"])
    }

    @MainActor
    @Test func confirmingCombinedRunWithSkipSkipsSingleVerbLater() async throws {
        var config = DatabaseConfig(name: "Prod")
        config.environment = .production
        let session = RedisTestServer.mockSession(MockRedisClient(), config: config)
        session.confirmations.isProduction = true
        let model = WorkbenchViewModel(session: session)
        let verbs = WorkbenchCommandText.dangerousVerbs(in: ["KEYS *", "DEBUG SLEEP 0"],
                                                         serverList: session.dangerousCommands)
        try #require(verbs.count == 2)
        let run = Task { await model.confirmDangerous(["KEYS *", "DEBUG SLEEP 0"]) }
        for _ in 0..<100 where session.confirmations.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.confirmations.pending?.actionID == WorkbenchCommandText.dangerousActionID(verbs: verbs))
        session.confirmations.resolve(confirmed: true, skipForSession: true)
        #expect(await run.value)
        #expect(await model.confirmDangerous(["KEYS foo*"]))
        #expect(session.confirmations.pending == nil)
    }
}

@MainActor
struct WorkbenchRunFailureTests {
    @Test func historyWriteFailureIsNotReportedAsCommandFailure() {
        let failure = WorkbenchViewModel.runFailure(CocoaError(.fileWriteOutOfSpace), skippedLaterCommands: true)
        #expect(failure.cardText.hasPrefix("The command was sent to Redis"))
        #expect(failure.toastTitle == "Results could not be saved")
        #expect(failure.toastText.contains("The remaining commands were not run."))
        let last = WorkbenchViewModel.runFailure(CocoaError(.fileWriteNoPermission), skippedLaterCommands: false)
        #expect(!last.toastText.contains("remaining"))
    }

    @Test func otherErrorsKeepTheirMessage() {
        let failure = WorkbenchViewModel.runFailure(WorkbenchError.busy, skippedLaterCommands: true)
        #expect(failure.cardText == WorkbenchError.busy.localizedDescription)
        #expect(failure.toastTitle == "Run Failed")
    }

    @Test func escapeLeavesFullscreen() {
        let model = WorkbenchViewModel(session: RedisTestServer.mockSession())
        #expect(model.exitFullscreen() == false)
        model.fullscreenCardID = UUID()
        #expect(model.exitFullscreen())
        #expect(model.fullscreenCardID == nil)
    }

    @Test func commandCatalogLoadsOffTheMainActor() async {
        let model = WorkbenchViewModel(session: RedisTestServer.mockSession())
        await model.loadCommandCatalog()
        #expect(model.isCommandCatalogLoaded)
        #expect(WorkbenchViewModel(session: RedisTestServer.mockSession()).isCommandCatalogLoaded)
    }

    @Test func headerMessageIsTruncatedAtTheLimit() {
        #expect(WorkbenchResultFormatter.headerMessage(matched: "42") == "Matched:42")
        #expect(WorkbenchResultFormatter.truncatedHeaderMessage("Matched:42") == "Matched:42")
        #expect(WorkbenchResultFormatter.truncatedHeaderMessage("Matched:12345") == "Matched:12345…")
        #expect(WorkbenchResultFormatter.truncatedHeaderMessage("Matched:1234567") == "Matched:12345…")
    }
}

@MainActor
struct TutorialScrollTests {
    @Test func scrollOffsetIsKeptForTheOpenPageOnly() async throws {
        let model = TutorialsViewModel(session: RedisTestServer.mockSession())
        await model.load()
        await model.open(id: "sq-intro")
        let page = try #require(model.page)
        model.recordScrollOffset(240, for: page.id)
        #expect(model.scrollOffset(for: page.id) == 240)
        model.recordScrollOffset(99, for: "other-page")
        #expect(model.scrollOffset(for: "other-page") == 0)
        await model.open(id: page.id)
        #expect(model.scrollOffset(for: page.id) == 240)
        let next = try #require(page.next)
        await model.open(id: next.id)
        #expect(model.scrollOffset(for: next.id) == 0)
        #expect(model.scrollOffset(for: page.id) == 0)
        model.recordScrollOffset(50, for: next.id)
        model.closePage()
        #expect(model.scrollOffset(for: next.id) == 0)
    }
}

struct TimeSeriesSamplerTests {
    private func series(_ count: Int, key: String = "k", descending: Bool = false) -> TimeSeriesSeries {
        var points = (0..<count).map { TimeSeriesPoint(timestamp: Double($0) * 1000, value: sin(Double($0) / 50)) }
        if descending { points.reverse() }
        return TimeSeriesSeries(key: key, labels: [:], points: points)
    }

    @Test func plotDataSortsDescendingReplies() {
        let data = TimeSeriesPlotData([series(10, descending: true)])
        #expect(data.series[0].timestamps == (0..<10).map { Double($0) * 1000 })
        #expect(data.minTimestamp == 0)
        #expect(data.maxTimestamp == 9000)
    }

    @Test func largeSeriesAreDownsampledWithinBudget() {
        let data = TimeSeriesPlotData([series(500_000), series(200_000, key: "b")])
        let plotted = TimeSeriesSampler.plot(data, low: nil, high: nil, isMilliseconds: true)
        let perSeries = TimeSeriesSampler.pointsPerSeries(seriesCount: 2)
        #expect(plotted.allSatisfy { $0.samples.count <= perSeries + 2 })
        #expect(plotted[0].samples.first?.date == Date(timeIntervalSince1970: 0))
        #expect(plotted[0].samples.last?.date == Date(timeIntervalSince1970: 499_999))
        let values = plotted[0].samples.map(\.value)
        #expect(values.max() ?? 0 > 0.99)
        #expect(values.min() ?? 0 < -0.99)
    }

    @Test func zoomPlotsOnlyTheVisibleRange() {
        let data = TimeSeriesPlotData([series(1_000)])
        let plotted = TimeSeriesSampler.plot(data, low: 100_000, high: 200_000, isMilliseconds: true)
        let dates = plotted[0].samples.map { $0.date.timeIntervalSince1970 }
        #expect(dates.first == 99)
        #expect(dates.last == 201)
        #expect(dates.count == 103)
    }

    @Test func smallSeriesAreUntouched() {
        #expect(TimeSeriesSampler.downsample(values: [1, 2, 3], range: 0..<3, maxPoints: 100) == [0, 1, 2])
    }

    @Test func nearestIndexUsesBinarySearch() {
        let timestamps: [Double] = [0, 10, 20, 30]
        #expect(TimeSeriesSampler.nearestIndex(timestamps, to: -5) == 0)
        #expect(TimeSeriesSampler.nearestIndex(timestamps, to: 14) == 1)
        #expect(TimeSeriesSampler.nearestIndex(timestamps, to: 16) == 2)
        #expect(TimeSeriesSampler.nearestIndex(timestamps, to: 99) == 3)
        #expect(TimeSeriesSampler.nearestIndex([], to: 1) == nil)
    }
}

struct TimeSeriesAxisScaleTests {
    @Test func linearScaleUsesNiceTicks() {
        let scale = TimeSeriesAxisScale(values: [3, 47, 12], isLog: false)
        #expect(scale.lower == 0)
        #expect(scale.upper == 50)
        #expect(scale.ticks.map(\.label) == ["0", "10", "20", "30", "40", "50"])
        #expect(scale.unit(25) == 0.5)
    }

    @Test func logScaleUsesPowersOfTen() {
        let scale = TimeSeriesAxisScale(values: [5, 2_000, -1], isLog: true)
        #expect(scale.ticks.map(\.label) == ["1", "10", "100", "1000", "10000"])
        #expect(scale.unit(100) == 0.5)
        #expect(scale.unit(0) == nil)
        #expect(scale.unit(-3) == nil)
    }

    @Test func flatAndEmptySeriesStillHaveARange() {
        let flat = TimeSeriesAxisScale(values: [7, 7], isLog: false)
        #expect(flat.lower < 7 && flat.upper > 7)
        let empty = TimeSeriesAxisScale(values: [], isLog: false)
        #expect(empty.upper > empty.lower)
        #expect(TimeSeriesAxisScale(values: [0.1, 0.35], isLog: false).ticks.first?.label == "0.10")
    }

    @Test func extremeMagnitudesKeepFiniteBoundsAndTicks() {
        let inputs: [[Double]] = [
            [1.7e308], [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude],
            [-1e308, 1e308], [-Double.greatestFiniteMagnitude], [.infinity, .nan]
        ]
        for values in inputs {
            let scale = TimeSeriesAxisScale(values: values, isLog: false)
            #expect(scale.lower.isFinite && scale.upper.isFinite && scale.upper > scale.lower)
            #expect(scale.step.isFinite && scale.step > 0)
            #expect(!scale.ticks.isEmpty)
            #expect(scale.ticks.allSatisfy { $0.label.count < 24 })
            if let value = values.first(where: \.isFinite), let unit = scale.unit(value) {
                #expect((0...1).contains(unit))
            }
        }
    }
}

struct GeoDetailsTests {
    @Test func registryMatchesEveryGeoCommand() {
        #expect(VisualizationRegistry.defaultView(for: "GEOADD k 13.36 38.11 Palermo") == .geoTable)
        #expect(VisualizationRegistry.defaultView(for: "GEODIST k a b km") == .geoTable)
        #expect(VisualizationRegistry.defaultView(for: "GEOHASH k a") == .geoTable)
        #expect(VisualizationRegistry.defaultView(for: "GEOSEARCHSTORE d k FROMLONLAT 1 2 BYRADIUS 1 km") == .geoTable)
        #expect(VisualizationRegistry.defaultView(for: "GEOPOS k a") == .geoMap)
        #expect(VisualizationRegistry.options(for: "GEORADIUS k 15 37 200 km WITHCOORD")
                == [.text, .geoMap, .geoHeatmap, .geoTable])
        #expect(VisualizationRegistry.options(for: "GEOADD k 1 2 m") == [.text, .geoTable])
    }

    @Test func geoaddAndStoreRepliesAreCounts() throws {
        let add = try #require(GeoParser.parse(.integer("2"), command: "GEOADD Sicily 13.36 38.11 Palermo 15.08 37.50 Catania"))
        #expect(add.metric == GeoMetric(label: "items added", value: "2"))
        #expect(add.summary.map(\.value) == ["GEOADD", "Sicily", "-", "unknown"])
        let store = try #require(GeoParser.parse(.integer("3"),
                                                 command: "GEOSEARCHSTORE dest Sicily FROMLONLAT 15 37 BYBOX 400 400 km"))
        #expect(store.metric == GeoMetric(label: "items stored", value: "3"))
        #expect(store.summary.map(\.value) == ["GEOSEARCHSTORE", "Sicily", "dest", "box"])
        let radiusStore = try #require(GeoParser.parse(.integer("1"),
                                                       command: "GEORADIUS Sicily 15 37 200 km STORE out"))
        #expect(radiusStore.metric?.label == "items stored")
        #expect(radiusStore.summary.map(\.value) == ["GEORADIUS", "Sicily", "out", "radius"])
    }

    @Test func geodistShowsDistanceOrNotFound() throws {
        let found = try #require(GeoParser.parse(.string("166.2742"), command: "GEODIST Sicily Palermo Catania km"))
        #expect(found.metric == GeoMetric(label: "Distance", value: "166.2742 km"))
        let meters = try #require(GeoParser.parse(.string("166274"), command: "GEODIST Sicily Palermo Catania"))
        #expect(meters.metric?.value == "166274 m")
        let missing = try #require(GeoParser.parse(.null, command: "GEODIST Sicily Palermo Nowhere"))
        #expect(missing.metric?.value == "Not found")
    }

    @Test func rowRepliesKeepTheirSummary() throws {
        let reply = ReplyNode.array([.string("Palermo"), .string("Catania")])
        let geo = try #require(GeoParser.parse(reply, command: "GEOSEARCH Sicily FROMLONLAT 15 37 BYRADIUS 200 km"))
        #expect(geo.metric == nil)
        #expect(geo.rows.map(\.member) == ["Palermo", "Catania"])
        #expect(geo.summary.last?.value == "radius")
    }

    @Test func heatRadiusFollowsSpread() {
        let near = GeoModel(rows: [GeoRow(id: 0, member: "a", longitude: 13.0, latitude: 38.0)], hasCoordinates: true)
        #expect(near.heatRadiusMeters == 50)
        let far = GeoModel(rows: [GeoRow(id: 0, member: "a", longitude: 13.0, latitude: 38.0),
                                  GeoRow(id: 1, member: "b", longitude: 15.0, latitude: 37.0)], hasCoordinates: true)
        #expect(far.heatRadiusMeters > 5_000)
    }
}
