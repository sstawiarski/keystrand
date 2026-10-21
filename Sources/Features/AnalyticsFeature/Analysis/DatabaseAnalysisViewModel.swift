import Foundation
import Observation
import RedisCore

public enum AnalysisSubTab: String, Hashable, Sendable, CaseIterable {
    case summary
    case tips
}

public enum NamespaceRanking: String, Hashable, Sendable {
    case memory
    case keys
}

public enum TopKeysRanking: String, Hashable, Sendable {
    case memory
    case length
}

/// Database Analysis state for one database window (survives section switches via `session.scopedObject`).
@Observable
@MainActor
public final class DatabaseAnalysisViewModel {
    public let session: DatabaseSession
    public let store: DatabaseAnalysisStore
    let catalog: RecommendationCatalog

    public private(set) var reports: [ShortDatabaseAnalysis] = []
    public private(set) var selectedReportID: UUID?
    public private(set) var report: DatabaseAnalysisReport?
    public private(set) var reportError: AnalysisError?
    public private(set) var isLoadingReport = false
    public private(set) var isAnalyzing = false
    public private(set) var liveProgress: AnalysisProgress?
    public private(set) var hasLoaded = false
    public private(set) var lastError: String?

    public var subTab: AnalysisSubTab = .summary
    public var extrapolateSummary = true
    public var extrapolateTTL = true
    public var extrapolateNamespaces = true
    public var showNoExpiry = false
    public var namespaceRanking: NamespaceRanking = .memory
    public var topKeysRanking: TopKeysRanking = .memory

    private var analysisTask: Task<Void, Never>?

    public init(session: DatabaseSession, store: DatabaseAnalysisStore? = nil, catalog: RecommendationCatalog = .shared) {
        self.session = session
        self.store = store ?? DatabaseAnalysisStore(paths: session.services.paths)
        self.catalog = catalog
    }

    public static func shared(for session: DatabaseSession) -> DatabaseAnalysisViewModel {
        session.scopedObject(DatabaseAnalysisViewModel.self) { DatabaseAnalysisViewModel(session: session) }
    }

    var tips: LiveTipsModel { LiveTipsModel.shared(for: session) }

    // MARK: - Loading

    /// Loads the history once and selects the newest report.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reloadHistory(selectNewest: true)
        if !tips.hasLoaded { await tips.load() }
    }

    public func reloadHistory(selectNewest: Bool = false) async {
        reports = await store.list(databaseID: session.id)
        hasLoaded = true
        if selectNewest || selectedReportID.map({ id in !reports.contains { $0.id == id } }) ?? true {
            if let newest = reports.first {
                await select(newest.id)
            } else {
                selectedReportID = nil
                report = nil
                reportError = nil
            }
        }
    }

    public func select(_ id: UUID) async {
        selectedReportID = id
        isLoadingReport = true
        defer { isLoadingReport = false }
        do {
            let loaded = try await store.get(id, databaseID: session.id)
            guard selectedReportID == id else { return }
            report = loaded
            reportError = nil
        } catch let error as AnalysisError {
            guard selectedReportID == id else { return }
            report = nil
            reportError = error
        } catch {
            report = nil
            reportError = .undecodable
        }
    }

    public func deleteReport(_ id: UUID) async {
        await store.delete(id, databaseID: session.id)
        let wasSelected = selectedReportID == id
        await reloadHistory(selectNewest: wasSelected)
    }

    // MARK: - Analysis

    public func delimiter() async -> String {
        let settings = await session.services.databaseSettingsStore.settings(for: session.id)
        return settings.treeViewDelimiters.first.flatMap { $0.isEmpty ? nil : $0 } ?? ":"
    }

    /// Starts a new analysis in the background (no-op while one is running).
    public func startAnalysis() {
        guard !isAnalyzing else { return }
        analysisTask = Task { await self.runAnalysis() }
    }

    public func cancelAnalysis() {
        analysisTask?.cancel()
    }

    /// Runs one analysis, saves it, refreshes the history and selects the new report.
    @discardableResult
    public func runAnalysis(filter: AnalysisFilter = AnalysisFilter()) async -> DatabaseAnalysisReport? {
        guard !isAnalyzing else { return nil }
        isAnalyzing = true
        lastError = nil
        liveProgress = AnalysisProgress()
        defer {
            isAnalyzing = false
            liveProgress = nil
            analysisTask = nil
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalysisProgress.self, bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task { @MainActor [weak self] in
            for await progress in stream { self?.liveProgress = progress }
        }
        defer { progressTask.cancel() }
        do {
            let delimiter = await delimiter()
            let report = try await DatabaseAnalyzer(session: session)
                .analyze(delimiter: delimiter, filter: filter) { continuation.yield($0) }
            continuation.finish()
            try Task.checkCancellation()
            try await store.save(report)
            await reloadHistory()
            await select(report.id)
            await tips.add(report.recommendations)
            return report
        } catch {
            continuation.finish()
            if !Self.isCancellation(error) {
                lastError = error.localizedDescription
                session.toasts.error(error)
            }
        }

        return nil
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case RedisClientError.cancelled? = error as? RedisClientError { return true }
        return false
    }

    // MARK: - Derived data

    public var extrapolationFactor: Double { report?.extrapolationFactor ?? 1 }
    public var canExtrapolate: Bool { extrapolationFactor != 1 }

    public var displayedProgress: AnalysisProgress? { liveProgress ?? report?.progress }

    /// Every recommendation of the selected report in display order, hidden ones included.
    public var allRecommendations: [AnalysisRecommendation] {
        guard let report else { return [] }
        return RecommendationRules.sortedForDisplay(report.recommendations, known: catalog.knownNames)
    }

    public var recommendations: [AnalysisRecommendation] {
        allRecommendations.filter { tips.showHidden || !tips.isHidden($0.name) }
    }

    public var hasHiddenRecommendations: Bool {
        allRecommendations.contains { tips.isHidden($0.name) }
    }

    public var tipsTitle: String {
        let count = recommendations.count
        return count > 0 ? "Tips (\(count))" : "Tips"
    }

    public var namespaces: [NspSummary] {
        guard let report else { return [] }
        return namespaceRanking == .memory ? report.topMemoryNsp : report.topKeysNsp
    }

    public var topKeys: [AnalyzedKey] {
        guard let report else { return [] }
        return topKeysRanking == .memory ? report.topKeysMemory : report.topKeysLength
    }

    public var topKeysTitle: String {
        guard let report else { return "Top Keys" }
        let full = report.topKeysMemory.count == AnalysisAggregator.topLimit || report.topKeysLength.count == AnalysisAggregator.topLimit
        return full ? "Top \(AnalysisAggregator.topLimit) Keys" : "Top Keys"
    }

    /// TTL bars in display order: buckets except "No Expiry", which goes last when `showNoExpiry` is on.
    public var expirationBars: [SumGroup] {
        guard let report else { return [] }
        let groups = report.expirationGroups
        let regular = groups.filter { $0.label != AnalysisAggregator.noExpiryLabel }
        let noExpiry = groups.filter { $0.label == AnalysisAggregator.noExpiryLabel }
        return showNoExpiry ? regular + noExpiry : regular
    }

    /// Label of the bar that gets a divider before it: "No Expiry" when it is shown after other buckets.
    public var expirationSeparatorLabel: String? {
        let bars = expirationBars
        guard bars.count > 1, bars.last?.label == AnalysisAggregator.noExpiryLabel else { return nil }
        return AnalysisAggregator.noExpiryLabel
    }

    public var showsSummarySection: Bool {
        guard let report else { return false }
        return !report.totalKeys.types.isEmpty || !report.totalMemory.types.isEmpty
    }

    public var showsTTLSection: Bool {
        guard let report else { return false }
        return !report.expirationGroups.isEmpty && report.totalMemory.total > 0 && report.totalKeys.total > 0
    }

    public var showsNamespacesSection: Bool { (report?.totalKeys.total ?? 0) > 0 }

    public var showsTopKeysSection: Bool {
        guard let report else { return false }
        return !report.topKeysMemory.isEmpty || !report.topKeysLength.isEmpty
    }

    public func historyLabel(_ item: ShortDatabaseAnalysis) -> String {
        AnalyticsFormat.dbPrefix(item.db) + AnalyticsFormat.date(item.createdAt, settings: session.services.settings)
    }

    // MARK: - Navigation

    /// `<nsp><delimiter>*` as shown in the table.
    public func namespacePattern(_ nsp: Data) -> String {
        AnalyticsFormat.keyName(nsp) + (report?.delimiter ?? ":") + "*"
    }

    /// Browser SCAN pattern for a namespace: glob characters in the namespace and delimiter are escaped.
    public func namespaceSearchPattern(_ nsp: Data) -> String {
        Self.literalPattern(nsp) + KeyPattern.escape(report?.delimiter ?? ":") + "*"
    }

    /// Glob that matches `name` literally. Names that are not printable UTF-8 cannot be sent as a text pattern,
    /// so every byte outside printable ASCII becomes `?` (one byte in Redis globs) and the rest is escaped.
    nonisolated static func literalPattern(_ name: Data) -> String {
        if RedisKeyName(name).isPrintable { return KeyPattern.escape(String(decoding: name, as: UTF8.self)) }
        var out = ""
        for byte in name {
            if byte >= 0x20 && byte < 0x7F {
                out += KeyPattern.escape(String(UnicodeScalar(byte)))
            } else {
                out += "?"
            }
        }

        return out
    }

    public func openNamespace(_ nsp: NspSummary, type: String? = nil) {
        let typeFilter = type ?? (nsp.types.count == 1 ? nsp.types.first?.type : nil)
        session.navigator.navigate(.browser(BrowserNavigationRequest(
            pattern: namespaceSearchPattern(nsp.nsp), typeFilter: typeFilter.map(KeyType.init(rawValue:)),
            treeDelimiter: report?.delimiter)))
    }

    public func openKey(_ key: AnalyzedKey) {
        session.navigator.navigate(.browser(BrowserNavigationRequest(
            pattern: Self.literalPattern(key.name), selectedKey: key.name,
            treeDelimiter: report?.delimiter)))
    }

    public func openTreeView() {
        session.navigator.navigate(.browser(BrowserNavigationRequest(treeDelimiter: report?.delimiter, switchToTreeView: true)))
    }

    public func openWorkbench() {
        session.navigator.navigate(.workbench(script: nil))
    }

    public func setTipHidden(_ recommendation: AnalysisRecommendation, hidden: Bool) async {
        await tips.setHidden(recommendation.name, hidden: hidden, params: recommendation.params)
    }
}
