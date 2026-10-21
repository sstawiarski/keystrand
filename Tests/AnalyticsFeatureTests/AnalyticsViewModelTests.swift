import Foundation
@testable import AnalyticsFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct AnalysisHistoryTests {
    static func report(_ databaseId: DatabaseID, minutesAgo: Double, recommendations: [String] = []) -> DatabaseAnalysisReport {
        DatabaseAnalysisReport(databaseId: databaseId, createdAt: Date().addingTimeInterval(-minutesAgo * 60), db: 0,
                               progress: AnalysisProgress(total: 10, scanned: 10_000, processed: 10),
                               totalKeys: SimpleSummary(total: 10, types: [SimpleTypeSummary(type: "string", total: 10)]),
                               recommendations: recommendations.map { AnalysisRecommendation(name: $0) })
    }

    @Test func storeKeepsNewestFiveAndDeletes() async throws {
        let services = RedisTestServer.makeServices()
        let store = DatabaseAnalysisStore(paths: services.paths)
        let id = DatabaseID()
        let reports = (0..<6).map { Self.report(id, minutesAgo: Double($0)) }
        for report in reports.reversed() { try await store.save(report) }
        let listed = await store.list(databaseID: id)
        #expect(listed.map(\.id) == reports.prefix(5).map(\.id))
        await #expect(throws: AnalysisError.notFound) { try await store.get(reports[5].id, databaseID: id) }
        #expect(try await store.get(reports[0].id, databaseID: id).totalKeys.total == 10)
        await store.delete(reports[0].id, databaseID: id)
        #expect(await store.list(databaseID: id).first?.id == reports[1].id)
    }

    @Test func modelSelectsNewestAndHandlesCorruptReports() async throws {
        let session = RedisTestServer.mockSession()
        let store = DatabaseAnalysisStore(paths: session.services.paths)
        let good = Self.report(session.id, minutesAgo: 10)
        try await store.save(good)
        let corruptID = UUID()
        let directory = session.services.paths.analysisDirectory(for: session.id)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("\(corruptID.uuidString).json"))

        let model = DatabaseAnalysisViewModel(session: session, store: store)
        await model.loadIfNeeded()
        #expect(model.reports.count == 2)
        #expect(model.selectedReportID == corruptID)
        #expect(model.reportError == .undecodable)
        #expect(model.report == nil)

        await model.select(good.id)
        #expect(model.report?.id == good.id)
        #expect(model.reportError == nil)
        #expect(model.historyLabel(good.short).isEmpty == false)

        await model.deleteReport(good.id)
        #expect(model.reports.map(\.id) == [corruptID])
        #expect(model.selectedReportID == corruptID)
    }

    @Test func derivedSectionsAndNavigation() async throws {
        let session = RedisTestServer.mockSession()
        let store = DatabaseAnalysisStore(paths: session.services.paths)
        var report = Self.report(session.id, minutesAgo: 1)
        report.delimiter = "*"
        report.totalMemory = SimpleSummary(total: 500, types: [SimpleTypeSummary(type: "string", total: 500)])
        report.expirationGroups = AnalysisAggregator.expirationGroups([AnalyzedKey(name: Data("k".utf8), type: "string", memory: 500, ttl: -1)])
        report.progress = AnalysisProgress(total: 30, scanned: 10_000, processed: 10)
        let nsp = NspSummary(nsp: Data("user?".utf8), memory: 500, keys: 10, types: [NspTypeSummary(type: "hash", memory: 500, keys: 10)])
        report.topMemoryNsp = [nsp]
        report.topKeysNsp = [nsp]
        report.topKeysMemory = (0..<15).map { (i: Int) in AnalyzedKey(name: Data("k\(i)".utf8), type: "string", memory: i) }
        try await store.save(report)

        let model = DatabaseAnalysisViewModel(session: session, store: store)
        await model.loadIfNeeded()
        #expect(model.extrapolationFactor == 3)
        #expect(model.canExtrapolate)
        #expect(model.showsSummarySection)
        #expect(model.showsTTLSection)
        #expect(model.showsNamespacesSection)
        #expect(model.topKeysTitle == "Top 15 Keys")
        #expect(model.expirationBars.map(\.label).contains("No Expiry") == false)
        model.showNoExpiry = true
        #expect(model.expirationBars.last?.label == "No Expiry")

        #expect(model.namespacePattern(nsp.nsp) == "user?**")
        #expect(model.namespaceSearchPattern(nsp.nsp) == "user\\?\\**")
        model.openNamespace(nsp)
        guard case .browser(let request)? = session.navigator.pending?.request else {
            Issue.record("expected a browser navigation request")
            return
        }
        #expect(request.pattern == "user\\?\\**")
        #expect(request.typeFilter == .hash)
        #expect(request.treeDelimiter == "*")

        model.openKey(AnalyzedKey(name: Data("a[1]".utf8), type: "string"))
        guard case .browser(let keyRequest)? = session.navigator.pending?.request else {
            Issue.record("expected a browser navigation request")
            return
        }
        #expect(keyRequest.pattern == "a\\[1\\]")
        #expect(keyRequest.selectedKey == Data("a[1]".utf8))
        #expect(keyRequest.typeFilter == nil)
    }

    @Test func hiddenTipsArePersistedPerDatabase() async throws {
        let session = RedisTestServer.mockSession()
        let store = DatabaseAnalysisStore(paths: session.services.paths)
        try await store.save(Self.report(session.id, minutesAgo: 1, recommendations: ["bigSets", "searchJSON", "notATip"]))
        let model = DatabaseAnalysisViewModel(session: session, store: store)
        await model.loadIfNeeded()
        #expect(model.recommendations.map(\.name) == ["searchJSON", "bigSets"])
        #expect(model.tipsTitle == "Tips (2)")

        let bigSets = try #require(model.recommendations.last)
        await model.setTipHidden(bigSets, hidden: true)
        #expect(model.recommendations.map(\.name) == ["searchJSON"])
        #expect(model.tipsTitle == "Tips (1)")
        await model.tips.setShowHidden(true)
        #expect(model.recommendations.count == 2)

        let reloaded = LiveTipsModel(session: session)
        await reloaded.load()
        #expect(reloaded.isHidden("bigSets"))
        #expect(reloaded.showHidden)
        let settings = await session.services.databaseSettingsStore.settings(for: session.id)
        #expect(settings.showHiddenRecommendations)
    }

    @Test func liveTipsReadHideAndSnooze() async throws {
        let session = RedisTestServer.mockSession()
        let tips = LiveTipsModel(session: session)
        await tips.load()
        #expect(tips.allTips.isEmpty)
        await tips.add([AnalysisRecommendation(name: "bigSets"), AnalysisRecommendation(name: "luaScript"),
                        AnalysisRecommendation(name: "unknownTip")])
        #expect(tips.allTips.count == 2)
        #expect(tips.totalUnread == 2)
        await tips.markAllRead()
        #expect(tips.totalUnread == 0)
        let first = try #require(tips.allTips.first)
        await tips.toggleHidden(first)
        #expect(tips.hasHiddenTips)
        #expect(tips.visibleTips.count == 1)
        await tips.snooze(first)
        #expect(tips.allTips.count == 1)
        #expect(!tips.hasHiddenTips)

        let reloaded = LiveTipsModel(session: session)
        await reloaded.load()
        #expect(reloaded.allTips.map(\.name) == tips.allTips.map(\.name))
        #expect(reloaded.totalUnread == 0)
    }
}

/// Tests share DB 9 and the server slowlog configuration, so they run serially.
@MainActor
@Suite(.serialized, .tags(.live), RedisTestServer.live(.redis))
struct AnalyticsLiveTests {
    static let db = RedisTestServer.DB.analytics

    @Test(RedisTestServer.needs(.json, .timeSeries, .vectorSet)) func analysisOfSeededDatabase() async throws {
        let connection = try await RedisTestServer.freshConnection(db: Self.db)
        let seeded = try await RedisTestServer.seedAllTypes(connection, prefix: "seed:")
        try await RedisTestServer.seedStrings(connection, prefix: "small:", count: 12)
        let bigList: [RedisArgument] = ["RPUSH", "big:list"] + (0..<1_500).map { RedisArgument.string("\($0)") }
        _ = try await connection.execute(bigList)
        _ = try await connection.execute(["SET", "ttl:key", "value", "EX", "100"])
        let binaryKey = Data([0xFF, 0x3A, 0x01])
        _ = try await connection.execute(["SET", .data(binaryKey), "bin"])
        await connection.close()

        let session = try await RedisTestServer.liveSession(db: Self.db)
        let model = DatabaseAnalysisViewModel(session: session)
        await model.loadIfNeeded()
        #expect(model.reports.isEmpty)

        let report = try #require(await model.runAnalysis())
        #expect(!model.isAnalyzing)
        #expect(model.lastError == nil)
        #expect(report.totalKeys.total == 24)
        #expect(report.progress.processed == 24)
        #expect(report.progress.total == 24)
        #expect(report.db == Self.db)
        #expect(report.delimiter == ":")
        #expect(model.reports.map(\.id) == [report.id])
        #expect(model.report?.id == report.id)

        #expect(report.topKeysNsp.first?.nsp == Data("small".utf8))
        #expect(report.topKeysNsp.first?.keys == 12)
        #expect(report.topKeysNsp.contains { $0.nsp == Data([0xFF]) })
        #expect(report.topKeysLength.first?.name == Data("big:list".utf8))
        #expect(report.topKeysLength.first?.length == 1_500)
        #expect(report.totalMemory.total > 0)
        #expect((report.expirationGroups.first { $0.label == "<1 hr" }?.total ?? 0) > 0)
        let names = Set(report.recommendations.map(\.name))
        #expect(names.isSuperset(of: ["combineSmallStringsToHashes", "compressionForList"]))

        let tips = LiveTipsModel.shared(for: session)
        #expect(Set(tips.allTips.map(\.name)).isSuperset(of: ["combineSmallStringsToHashes", "compressionForList"]))

        let node = try #require(try await session.nodes(role: .primary).first)
        let order: [KeyType] = [.string, .hash, .list, .set, .zset, .stream, .json, .timeSeries, .vectorSet]
        let keys = try await DatabaseAnalyzer.collectMetadata(node, names: order.map(seeded.name))
        #expect(keys.map(\.length) == [5, 3, 3, 3, 3, 2, 3, 3, nil])
        #expect(keys[6].type == "ReJSON-RL")
        #expect(keys[7].type == "TSDB-TYPE")
        #expect(keys.allSatisfy { $0.ttl == -1 && ($0.memory ?? 0) > 0 })

        let secondModel = DatabaseAnalysisViewModel(session: session)
        await secondModel.loadIfNeeded()
        #expect(secondModel.report?.totalKeys.total == 24)
        await session.close()
    }

    @Test func cancelledAnalysisSavesNothing() async throws {
        let connection = try await RedisTestServer.freshConnection(db: Self.db)
        try await RedisTestServer.seedStrings(connection, prefix: "c:", count: 50)
        await connection.close()
        let session = try await RedisTestServer.liveSession(db: Self.db)
        let model = DatabaseAnalysisViewModel(session: session)
        await model.loadIfNeeded()
        let task = Task { await model.runAnalysis() }
        task.cancel()
        #expect(await task.value == nil)
        #expect(!model.isAnalyzing)
        #expect(model.reports.isEmpty)
        #expect(model.lastError == nil)
        await session.close()
    }

    @Test func emptyDatabaseReport() async throws {
        let connection = try await RedisTestServer.freshConnection(db: Self.db)
        await connection.close()
        let session = try await RedisTestServer.liveSession(db: Self.db)
        let model = DatabaseAnalysisViewModel(session: session)
        let report = try #require(await model.runAnalysis())
        #expect(report.totalKeys.total == 0)
        #expect(AnalyticsFormat.progressText(report.progress).percentage == "Scanned 100%")
        #expect(!model.showsNamespacesSection)
        #expect(!model.showsTopKeysSection)
        #expect(!model.showsTTLSection)
        await session.close()
    }

    @Test func liveTipsQuickChecks() async throws {
        let session = try await RedisTestServer.liveSession(db: Self.db)
        let acl = try? await session.execute(["ACL", "LIST"])
        let noPassword = acl?.arrayValue?.compactMap(\.stringValue).contains { $0.split(separator: " ").contains("nopass") } ?? false
        let tips = LiveTipsModel(session: session)
        await tips.refresh()
        #expect(tips.hasLoaded)
        #expect(!tips.isChecking)
        #expect(tips.allTips.contains { $0.name == "setPassword" } == noPassword)
        #expect(!tips.allTips.contains { $0.name == "redisVersion" })
        await session.close()
    }

    @Test func slowLogLoadConfigureAndClear() async throws {
        let session = try await RedisTestServer.liveSession(db: Self.db)
        let service = SlowLogService(session: session)
        let original = try await service.config()
        var failure: Error?
        do {
            let model = SlowLogViewModel(session: session)
            await model.load()
            #expect(model.hasLoaded)
            #expect(model.config == original)
            #expect(model.durationUnit == .milliseconds)
            #expect(model.statusText.contains("Logging commands slower than"))
            #expect(model.countHelp == "Number of entries to show")

            let saved = await model.saveConfig(SlowLogConfigForm(slowerThan: "0", unit: .microseconds, maxLen: "200"))
            #expect(saved)
            #expect(try await service.config() == SlowLogConfig(slowlogMaxLen: 200, slowlogLogSlowerThan: 0))
            #expect(model.durationUnit == .microseconds)
            #expect(model.durationHeader == "Duration (µs)")
            let settings = await session.services.databaseSettingsStore.settings(for: session.id)
            #expect(settings.slowLogDurationUnit == .microseconds)

            for i in 0..<15 { _ = try await session.execute(["SET", .string("slow:\(i)"), "v"]) }
            await model.refresh()
            #expect(model.entries.count >= 10)
            #expect(model.errorMessage == nil)
            #expect(model.lastRefresh != nil)
            #expect(model.statusText.contains("entries since"))

            model.count = .ten
            await model.refresh()
            #expect(model.entries.count == 10)
            #expect(model.entries.allSatisfy { $0.node == nil })

            #expect(await model.clear())
            #expect(model.entries.isEmpty)
            #expect(!(model.emptyText.isEmpty))
        } catch {
            failure = error
        }

        try await service.setConfig(slowerThanUs: original.slowlogLogSlowerThan, maxLen: original.slowlogMaxLen)
        #expect(try await service.config() == original)
        await session.close()
        if let failure { throw failure }
    }

    @Test func clusterDetailsOnStandalone() async throws {
        let session = try await RedisTestServer.liveSession(db: Self.db)
        let model = ClusterDetailsViewModel(session: session)
        await model.refresh(manual: true)
        #expect(model.details == nil)
        #expect(model.errorMessage == nil)
        await #expect(throws: ClusterDetailsError.notCluster) { try await ClusterDetailsService(session: session).fetch() }
        await session.close()
    }
}
