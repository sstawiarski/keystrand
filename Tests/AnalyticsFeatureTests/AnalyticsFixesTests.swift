import Foundation
@testable import AnalyticsFeature
import RedisCore
import TestSupport
import Testing

struct SlowLogFormUnitTests {
    @Test func persistedMicrosecondsFormIsNotConvertedTwice() {
        let config = SlowLogConfig(slowlogMaxLen: 128, slowlogLogSlowerThan: 10_000)
        let form = SlowLogConfigForm(config: config, unit: .microseconds)
        #expect(form.slowerThan == "10000")
        #expect(form.unit == .microseconds)
        #expect(form.slowerThanMicroseconds == 10_000)
    }

    @Test func defaultsFromMicrosecondsSendTenMilliseconds() {
        var form = SlowLogConfigForm(slowerThan: "500", unit: .microseconds, maxLen: "64")
        form.applyDefaults()
        #expect(form.slowerThan == "10")
        #expect(form.unit == .milliseconds)
        #expect(form.slowerThanMicroseconds == 10_000)
    }

    @Test func userUnitChangeConvertsValue() {
        var form = SlowLogConfigForm(slowerThan: "10.5", unit: .milliseconds, maxLen: "128")
        form.changeUnit(to: .microseconds)
        #expect(form.slowerThan == "10500")
        #expect(form.slowerThanMicroseconds == 10_500)
        form.changeUnit(to: .microseconds)
        #expect(form.slowerThan == "10500")
        form.changeUnit(to: .milliseconds)
        #expect(form.slowerThan == "10.5")

        var disabled = SlowLogConfigForm(slowerThan: "-1", unit: .milliseconds)
        disabled.changeUnit(to: .microseconds)
        #expect(disabled.slowerThan == "-1")
        #expect(disabled.unit == .microseconds)
    }

    @Test func hugeValuesAreRejectedWithoutTrapping() {
        let huge = SlowLogConfigForm(slowerThan: "9999999999999999", unit: .milliseconds)
        #expect(!huge.isSlowerThanValid)
        #expect(huge.slowerThanMicroseconds == nil)
        #expect(huge.conversionHint == "- µs")
        var switched = huge
        switched.changeUnit(to: .microseconds)
        #expect(switched.slowerThanMicroseconds == nil)

        let atCap = SlowLogConfigForm(slowerThan: "1000000000000", unit: .milliseconds)
        #expect(atCap.isSlowerThanValid)
        #expect(atCap.slowerThanMicroseconds == 1_000_000_000_000_000)
        #expect(!SlowLogConfigForm(slowerThan: "1000000000000001", unit: .microseconds).isSlowerThanValid)

        #expect(SlowLogConfigForm.sanitizeSlowerThan(String(repeating: "9", count: 40), unit: .microseconds).count == 20)
        #expect(SlowLogConfigForm.plain(1e22) == "-")
        #expect(SlowLogConfigForm.plain(12.5) == "12.5")
    }

    @Test func decimalFormattingIsSafeForHugeValues() {
        #expect(AnalyticsFormat.decimal(1e19, maxDecimals: 3) == "-")
        #expect(AnalyticsFormat.decimal(-1e300, maxDecimals: 3) == "-")
        #expect(AnalyticsFormat.decimal(12_345.678, maxDecimals: 3) == "12,345.678")
    }
}

@MainActor
struct AnalyticsRefreshGatingTests {
    @Test func slowLogTickSkippedWhileWindowHidden() async {
        let client = MockRedisClient(responses: ["SLOWLOG": .array([])])
        let session = RedisTestServer.mockSession(client)
        let model = SlowLogViewModel(session: session)
        await model.autoRefresh(isWindowVisible: false)
        #expect(await client.executedCommandStrings.isEmpty)
        #expect(model.lastRefresh == nil)
        await model.autoRefresh(isWindowVisible: true)
        #expect(await client.executedCommandStrings.contains { $0.hasPrefix("SLOWLOG GET") })
    }

    @Test func clusterTickSkippedWhileWindowHidden() async {
        let client = MockRedisClient()
        let model = ClusterDetailsViewModel(session: RedisTestServer.mockSession(client))
        await model.autoRefresh(isWindowVisible: false)
        #expect(await client.executedCommandStrings.isEmpty)
    }

    @Test func windowVisibilityRules() {
        #expect(WindowVisibility.isVisible(nil))
        #expect(WindowVisibility().isVisible)
        #expect(WindowVisibility.isVisible(isOnScreen: true, isMiniaturized: false, isOccluded: false))
        #expect(!WindowVisibility.isVisible(isOnScreen: true, isMiniaturized: true, isOccluded: false))
        #expect(!WindowVisibility.isVisible(isOnScreen: true, isMiniaturized: false, isOccluded: true))
        #expect(!WindowVisibility.isVisible(isOnScreen: false, isMiniaturized: false, isOccluded: false))
    }
}

@MainActor
struct AnalysisFixesTests {
    static func report(_ databaseId: DatabaseID, recommendations: [String] = []) -> DatabaseAnalysisReport {
        DatabaseAnalysisReport(databaseId: databaseId, createdAt: Date(), db: 0,
                               progress: AnalysisProgress(total: 10, scanned: 10_000, processed: 10),
                               totalKeys: SimpleSummary(total: 10, types: [SimpleTypeSummary(type: "string", total: 10)]),
                               recommendations: recommendations.map { AnalysisRecommendation(name: $0) })
    }

    @Test func binaryNamespaceAndKeyPatternsMatchBytes() async throws {
        let session = RedisTestServer.mockSession()
        let store = DatabaseAnalysisStore(paths: session.services.paths)
        try await store.save(Self.report(session.id))
        let model = DatabaseAnalysisViewModel(session: session, store: store)
        await model.loadIfNeeded()

        let binary = Data([0xAC, 0xED, 0x2A, 0x00, 0x61])
        #expect(DatabaseAnalysisViewModel.literalPattern(binary) == "??\\*?a")
        #expect(DatabaseAnalysisViewModel.literalPattern(Data("user?".utf8)) == "user\\?")
        #expect(DatabaseAnalysisViewModel.literalPattern(Data("ключ".utf8)) == "ключ")
        #expect(model.namespaceSearchPattern(Data([0xFF])) == "?:*")

        model.openKey(AnalyzedKey(name: binary, type: "string"))
        guard case .browser(let request)? = session.navigator.pending?.request else {
            Issue.record("expected a browser navigation request")
            return
        }
        #expect(request.pattern == "??\\*?a")
        #expect(request.selectedKey == binary)
    }

    @Test func allHiddenTipsKeepListAndToggle() async throws {
        let session = RedisTestServer.mockSession()
        let store = DatabaseAnalysisStore(paths: session.services.paths)
        try await store.save(Self.report(session.id, recommendations: ["bigSets"]))
        let model = DatabaseAnalysisViewModel(session: session, store: store)
        await model.loadIfNeeded()
        #expect(!model.hasHiddenRecommendations)

        let bigSets = try #require(model.recommendations.first)
        await model.setTipHidden(bigSets, hidden: true)
        #expect(model.recommendations.isEmpty)
        #expect(model.allRecommendations.map(\.name) == ["bigSets"])
        #expect(model.hasHiddenRecommendations)
    }

    @Test func noExpirySeparatorOnlyWhenShownAfterOtherBars() async throws {
        let session = RedisTestServer.mockSession()
        let store = DatabaseAnalysisStore(paths: session.services.paths)
        var report = Self.report(session.id)
        report.expirationGroups = AnalysisAggregator.expirationGroups([
            AnalyzedKey(name: Data("a".utf8), type: "string", memory: 100, ttl: -1),
            AnalyzedKey(name: Data("b".utf8), type: "string", memory: 100, ttl: 60),
        ])
        try await store.save(report)
        let model = DatabaseAnalysisViewModel(session: session, store: store)
        await model.loadIfNeeded()
        #expect(model.expirationSeparatorLabel == nil)
        model.showNoExpiry = true
        #expect(model.expirationSeparatorLabel == AnalysisAggregator.noExpiryLabel)
    }
}

@MainActor
struct LiveTipTriggerTests {
    @Test func dbIndexChangeRule() {
        #expect(LiveTipsModel.dbIndexChangeTips(previous: 0, current: 1).map(\.name) == ["avoidLogicalDatabases"])
        #expect(LiveTipsModel.dbIndexChangeTips(previous: 1, current: 1).isEmpty)
        #expect(LiveTipsModel.dbIndexChangeTips(previous: nil, current: 1).isEmpty)
    }

    @Test func switchingLogicalDatabaseAddsTipOnce() async throws {
        let session = RedisTestServer.mockSession()
        let tips = LiveTipsModel(session: session)
        await tips.load()
        #expect(!tips.allTips.contains { $0.name == "avoidLogicalDatabases" })
        try await session.select(db: 2)
        for _ in 0..<100 where !tips.allTips.contains(where: { $0.name == "avoidLogicalDatabases" }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(tips.allTips.filter { $0.name == "avoidLogicalDatabases" }.count == 1)
        try await session.select(db: 3)
        try await Task.sleep(for: .milliseconds(50))
        #expect(tips.allTips.filter { $0.name == "avoidLogicalDatabases" }.count == 1)
    }

    @Test func graphLengthCommandAndParse() {
        let key = Data("g".utf8)
        #expect(DatabaseAnalyzer.lengthCommand(for: "graphdata", key: key)
            == ["GRAPH.QUERY", .data(key), "MATCH (r) RETURN count(r)", "--compact"])
        let reply = RESPValue.array([.array([.array([.integer(1), .bulk("count(r)")])]),
                                     .array([.array([.array([.integer(3), .integer(42)])])]),
                                     .array([.bulk("Cached execution: 0")])])
        #expect(DatabaseAnalyzer.graphNodeCount(reply) == 42)
        #expect(DatabaseAnalyzer.graphNodeCount(.array([])) == nil)
    }
}
