import Foundation
import Observation
import RedisCore

public struct LiveRecommendation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var read: Bool
    public var disabled: Bool
    public var hide: Bool
    public var params: RecommendationParams?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, read: Bool = false, disabled: Bool = false, hide: Bool = false,
                params: RecommendationParams? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.read = read
        self.disabled = disabled
        self.hide = hide
        self.params = params
        self.createdAt = createdAt
    }
}

public struct LiveTipsState: Codable, Hashable, Sendable {
    public var tips: [LiveRecommendation]

    public init(tips: [LiveRecommendation] = []) { self.tips = tips }

    /// Adds tips whose names are not stored yet; returns true when something was added.
    @discardableResult
    public mutating func merge(_ recommendations: [AnalysisRecommendation], now: Date = Date()) -> Bool {
        let existing = Set(tips.map(\.name))
        var added = false
        for (offset, recommendation) in Self.syncOrder(recommendations).enumerated() where !existing.contains(recommendation.name) {
            tips.append(LiveRecommendation(name: recommendation.name, params: recommendation.params,
                                           createdAt: now.addingTimeInterval(-Double(offset) * 0.001)))
            added = true
        }

        return added
    }

    /// searchJSON, searchIndexes, then by name.
    static func syncOrder(_ recommendations: [AnalysisRecommendation]) -> [AnalysisRecommendation] {
        var seen = Set<String>()
        let unique = recommendations.filter { seen.insert($0.name).inserted }
        return RecommendationRules.sortedForDisplay(unique, known: Set(unique.map(\.name)))
    }
}

/// Live checks that need only server metadata (connect-time triggers).
public enum LiveTipChecks {
    public struct Input: Sendable {
        public var infos: [RedisInfo]
        public var isCluster: Bool
        public var aclUsers: [String]?

        public init(infos: [RedisInfo], isCluster: Bool, aclUsers: [String]? = nil) {
            self.infos = infos
            self.isCluster = isCluster
            self.aclUsers = aclUsers
        }
    }

    public static func evaluate(_ input: Input) -> [AnalysisRecommendation] {
        var out: [AnalysisRecommendation] = []
        if RecommendationRules.needsRedisUpgrade(input.infos.first) {
            out.append(AnalysisRecommendation(.redisVersion))
        }

        if let scripts = input.infos.first?.value("number_of_cached_scripts").flatMap(Int.init),
           scripts > RecommendationRules.luaScriptsThreshold {
            out.append(AnalysisRecommendation(.luaScript))
        }

        let clients = input.infos.compactMap(\.connectedClients).max() ?? 0
        if clients > RecommendationRules.connectedClientsThreshold {
            out.append(AnalysisRecommendation(.bigAmountOfConnectedClients))
        }

        if !input.isCluster, let info = input.infos.first, info.keyspace.values.filter({ $0.keys > 0 }).count > 1 {
            out.append(AnalysisRecommendation(.avoidLogicalDatabases))
        }

        if let users = input.aclUsers, users.contains(where: { $0.split(separator: " ").contains("nopass") }) {
            out.append(AnalysisRecommendation(.setPassword))
        }

        return out
    }
}

/// Per-database live tips (Insights > Tips), shared by the Tips panel and the Database Analysis tips list.
@Observable
@MainActor
public final class LiveTipsModel {
    nonisolated public static let featureKey = "analytics.liveTips"

    public let session: DatabaseSession
    public private(set) var tips: [LiveRecommendation] = []
    public private(set) var showHidden = false
    public private(set) var isChecking = false
    public private(set) var hasLoaded = false
    private var didRunChecks = false
    private var connectChecks: Task<Void, Never>?
    private var isObservingDB = false
    /// `dbIndex` and `effectiveDB` when last observed.
    private var observedDB: (index: Int, effective: Int)?
    let catalog: RecommendationCatalog

    public init(session: DatabaseSession, catalog: RecommendationCatalog = .shared) {
        self.session = session
        self.catalog = catalog
    }

    public static func shared(for session: DatabaseSession) -> LiveTipsModel {
        session.scopedObject(LiveTipsModel.self) { LiveTipsModel(session: session) }
    }

    private var settingsStore: DatabaseSettingsStore { session.services.databaseSettingsStore }

    /// Known, non-deprecated tips, newest first.
    public var allTips: [LiveRecommendation] {
        tips.filter { catalog[$0.name].map { !$0.deprecated } ?? false }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public var visibleTips: [LiveRecommendation] {
        allTips.filter { showHidden || !$0.hide }
    }

    public var hasHiddenTips: Bool { allTips.contains { $0.hide } }
    public var totalUnread: Int { allTips.filter { !$0.read }.count }

    public func isHidden(_ name: String) -> Bool {
        tips.first { $0.name == name }?.hide ?? false
    }

    public func load() async {
        let settings = await settingsStore.settings(for: session.id)
        tips = settings.feature(LiveTipsState.self, key: Self.featureKey)?.tips ?? []
        showHidden = settings.showHiddenRecommendations
        hasLoaded = true
        startLiveTriggers()
    }

    /// Once per window session: runs the connect-time checks (when connected) and starts the DB-change trigger.
    func startLiveTriggers() {
        if connectChecks == nil, session.state.isConnected { startConnectChecks() }
        guard !isObservingDB else { return }
        isObservingDB = true
        observedDB = (session.dbIndex, session.effectiveDB)
        observeEffectiveDB()
        session.liveTips.setHandler { [weak self] signal in
            Task { await self?.add([AnalysisRecommendation(signal.name, key: signal.key)]) }
        }
    }

    private func startConnectChecks() {
        connectChecks = Task { [weak self] in
            guard let self else { return }
            let found = await self.runQuickChecks()
            await self.add(found)
        }
    }

    /// Loads stored tips, then once per window session waits for the connect-time checks and syncs the latest report.
    public func refresh(analysisStore: DatabaseAnalysisStore? = nil) async {
        await load()
        guard !didRunChecks else { return }
        didRunChecks = true
        isChecking = true
        defer { isChecking = false }
        if connectChecks == nil { startConnectChecks() }
        await connectChecks?.value
        let store = analysisStore ?? DatabaseAnalysisStore(paths: session.services.paths)
        if let latest = await store.list(databaseID: session.id).first,
           let report = try? await store.get(latest.id, databaseID: session.id) {
            await add(report.recommendations)
        }
    }

    private func observeEffectiveDB() {
        withObservationTracking {
            _ = session.effectiveDB
        } onChange: { [weak self] in
            Task { @MainActor in await self?.effectiveDBDidChange() }
        }
    }

    /// A change of `effectiveDB` without a change of `dbIndex` comes from server details loading (a Valkey 9 cluster
    /// selecting its configured DB), not from the user switching databases, so it adds no tip.
    func effectiveDBDidChange() async {
        let previous = observedDB
        let current = (index: session.dbIndex, effective: session.effectiveDB)
        observedDB = current
        observeEffectiveDB()
        guard previous?.index != current.index else { return }
        await add(Self.dbIndexChangeTips(previous: previous?.effective, current: current.effective))
    }

    /// `avoidLogicalDatabases` when the window switches to another logical database. Compares effective DBs, so a
    /// cluster without numbered databases never triggers it.
    nonisolated static func dbIndexChangeTips(previous: Int?, current: Int) -> [AnalysisRecommendation] {
        guard let previous, previous != current else { return [] }
        return [AnalysisRecommendation(.avoidLogicalDatabases)]
    }

    func runQuickChecks() async -> [AnalysisRecommendation] {
        do {
            let nodes = try await session.nodes(role: .primary)
            var infos: [RedisInfo] = []
            for node in nodes {
                if let reply = try? await node.execute(["INFO"]), !reply.isError, let text = reply.stringValue {
                    infos.append(ServerInfoParser.parse(text))
                }
            }

            let acl = try? await session.execute(["ACL", "LIST"])
            let users = acl?.arrayValue?.compactMap(\.stringValue)
            return LiveTipChecks.evaluate(.init(infos: infos, isCluster: session.isCluster, aclUsers: users))
        } catch {
            return []
        }
    }

    /// Creates tips for names not stored yet.
    public func add(_ recommendations: [AnalysisRecommendation]) async {
        var state = LiveTipsState(tips: tips)
        guard state.merge(recommendations) else { return }
        await persist(state.tips, reportsErrors: false)
    }

    public func markAllRead() async {
        guard tips.contains(where: { !$0.read }) else { return }
        await persist(tips.map { var t = $0; t.read = true; return t }, reportsErrors: false)
    }

    public func setHidden(_ name: String, hidden: Bool, params: RecommendationParams? = nil) async {
        var updated = tips
        if let index = updated.firstIndex(where: { $0.name == name }) {
            updated[index].hide = hidden
        } else {
            updated.append(LiveRecommendation(name: name, read: true, hide: hidden, params: params))
        }

        await persist(updated)
    }

    public func toggleHidden(_ tip: LiveRecommendation) async {
        await setHidden(tip.name, hidden: !tip.hide)
    }

    /// Snooze = delete; the tip can be found again by a later check or analysis.
    public func snooze(_ tip: LiveRecommendation) async {
        await persist(tips.filter { $0.id != tip.id })
    }

    public func setShowHidden(_ value: Bool) async {
        showHidden = value
        do {
            try await settingsStore.update(session.id) { $0.showHiddenRecommendations = value }
        } catch {
            session.toasts.error(error)
        }
    }

    /// Background writes (live triggers, mark read) fail silently; only user actions report errors.
    private func persist(_ newTips: [LiveRecommendation], reportsErrors: Bool = true) async {
        tips = newTips
        let state = LiveTipsState(tips: newTips)
        do {
            try await settingsStore.update(session.id) { $0.setFeature(state, key: Self.featureKey) }
        } catch {
            if reportsErrors { session.toasts.error(error) }
        }
    }
}
