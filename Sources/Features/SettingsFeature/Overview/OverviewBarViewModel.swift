import Foundation
import Observation
import RedisUI

/// Formats session overview data and drives refreshes from the bar.
@MainActor
@Observable
public final class OverviewBarViewModel {
    public static let refreshPostfix = "overview"
    /// Session polling interval while the bar's own auto-refresh control is in charge.
    static let dormantPollingInterval: TimeInterval = 86_400
    /// Delays the bar refresh until the session sample arrives so two CPU samples do not share a second.
    static let initialRefreshDelay: Duration = .milliseconds(1200)

    public let session: DatabaseSession
    public private(set) var lastRefresh: Date?
    public private(set) var isRefreshing = false
    @ObservationIgnored private(set) var missedTickWhileHidden = false

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var metrics: [OverviewMetric] {
        guard let overview = session.overview else { return [] }
        return OverviewMetricsBuilder.metrics(from: overview, dbIndex: session.effectiveDB)
    }

    /// The last overview refresh error, or the connection failure when the session could not connect.
    public var errorMessage: String? {
        if let error = session.overviewError { return error }
        if case .failed(let error) = session.state { return error.message }
        return nil
    }

    public var hasData: Bool { session.overview != nil }

    /// Spinner while the first sample is on its way (only while connecting or connected).
    public var isWaitingForFirstSample: Bool {
        guard session.overview == nil, session.overviewError == nil else { return false }
        return session.state == .connecting || session.state == .connected
    }

    public var version: String? { session.overview?.version ?? session.serverVersion }

    public var modules: [RedisModuleInfo] { session.modules }

    public var connectionTypeText: String {
        switch session.connectionKind {
        case .standalone: return "Standalone"
        case .cluster: return "Cluster"
        case .sentinel: return "Sentinel"
        }
    }

    public var connectionTypeImage: String {
        switch session.connectionKind {
        case .standalone: return "server.rack"
        case .cluster: return "square.grid.3x3"
        case .sentinel: return "eye"
        }
    }

    public var isRefreshDisabled: Bool { !session.state.isConnected }

    /// Runs one overview refresh; concurrent calls collapse into the running one.
    public func refresh() async {
        guard !isRefreshing, session.state.isConnected else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await session.refreshOverview()
        lastRefresh = Date()
    }

    /// Skips ticks while the window is minimized, hidden, or occluded and catches up when it becomes visible.
    public func autoRefresh(isWindowVisible: Bool) async {
        guard isWindowVisible else {
            missedTickWhileHidden = true
            return
        }
        missedTickWhileHidden = false
        await refresh()
    }

    /// Refreshes once when the window comes back after at least one tick was skipped while it was hidden.
    public func windowBecameVisible() async {
        guard missedTickWhileHidden else { return }
        missedTickWhileHidden = false
        await refresh()
    }

    /// Records a refresh performed by the session's own polling loop.
    public func noteExternalRefresh() {
        if !isRefreshing { lastRefresh = Date() }
    }

    /// Uses the bar auto-refresh rate while visible and restores the session polling interval to 5 s afterwards.
    public func barDidAppear() {
        session.overviewRefreshInterval = Self.dormantPollingInterval
        if session.overview != nil, lastRefresh == nil { lastRefresh = Date() }
    }

    public func barDidDisappear() {
        session.overviewRefreshInterval = UIPreferences.defaultAutoRefreshRate
    }
}
