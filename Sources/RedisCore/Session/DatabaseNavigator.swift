import Foundation
import Observation

/// Window-level navigation state for one database window (rail section, analytics tab, bottom panel,
/// insights) plus a one-shot pending request that the destination feature consumes.
@MainActor
@Observable
public final class DatabaseNavigator {
    public struct Pending: Identifiable, Sendable {
        public let id: UUID
        public let request: DatabaseNavigationRequest
    }

    public var section: DatabaseSection = .browser
    public var analyticsTab: AnalyticsTab = .databaseAnalysis
    public var openBottomTools: Set<BottomPanelTool> = []
    /// The latest `.bottomPanel(tool)` request; AppShell shows that tool even when it is already open but hidden.
    public private(set) var bottomToolRequest: Pending?
    public var isInsightsOpen = false
    public var insightsTab: InsightsTab = .tutorials
    public private(set) var pending: Pending?
    /// Incremented by View > Refresh (⌘R); the visible section reloads when it changes.
    public private(set) var refreshGeneration = 0

    /// Brings the Home window forward.
    @ObservationIgnored public var onOpenHome: (@MainActor () -> Void)?
    /// Opens the edit-database sheet; `focusEnvironment` selects the Environment field.
    @ObservationIgnored public var onEditDatabase: (@MainActor (_ focusEnvironment: Bool) -> Void)?

    public init() {}

    public func navigate(_ request: DatabaseNavigationRequest) {
        switch request {
        case .section(let s):
            section = s
        case .analytics(let tab):
            analyticsTab = tab
            section = .analytics
        case .bottomPanel(let tool):
            openBottomTools.insert(tool)
            bottomToolRequest = Pending(id: UUID(), request: request)
        case .tutorial:
            isInsightsOpen = true
            insightsTab = .tutorials
            pending = Pending(id: UUID(), request: request)
        case .home:
            onOpenHome?()
        case .editDatabase(let focus):
            onEditDatabase?(focus)
        default:
            if let s = request.section { section = s }
            pending = Pending(id: UUID(), request: request)
        }
    }

    /// Returns and clears the pending request if `matches` accepts it.
    public func consume(where matches: (DatabaseNavigationRequest) -> Bool) -> DatabaseNavigationRequest? {
        guard let pending, matches(pending.request) else { return nil }
        self.pending = nil
        return pending.request
    }

    public func toggle(_ tool: BottomPanelTool) {
        if openBottomTools.contains(tool) { openBottomTools.remove(tool) } else { openBottomTools.insert(tool) }
    }

    public var isBottomPanelOpen: Bool { !openBottomTools.isEmpty }

    public func requestRefresh() {
        refreshGeneration += 1
    }
}
