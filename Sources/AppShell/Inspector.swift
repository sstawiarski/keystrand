import AnalyticsFeature
import CLIFeature
import Observation
import RedisUI
import SwiftUI
import WorkbenchFeature

enum InspectorPane: String, CaseIterable, Identifiable, Sendable {
    case commandHelper
    case tips
    case tutorials

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandHelper: return "Commands"
        case .tips: return "Tips"
        case .tutorials: return "Tutorials"
        }
    }

    var menuTitle: String {
        switch self {
        case .commandHelper: return "Command Helper"
        case .tips: return "Tips"
        case .tutorials: return "Tutorials"
        }
    }

    var systemImage: String {
        switch self {
        case .commandHelper: return "book"
        case .tips: return "lightbulb"
        case .tutorials: return "graduationcap"
        }
    }

    var insightsTab: InsightsTab? {
        switch self {
        case .commandHelper: return nil
        case .tips: return .tips
        case .tutorials: return .tutorials
        }
    }

    init(insightsTab: InsightsTab) {
        self = insightsTab == .tips ? .tips : .tutorials
    }

    /// Values of the `--inspector` launch flag.
    init?(flag: String) {
        switch flag.lowercased() {
        case "helper", "commands", "command-helper": self = .commandHelper
        case "tips": self = .tips
        case "tutorials": self = .tutorials
        default: return nil
        }
    }
}

/// Synchronizes the window’s inspector with Insights state so feature requests can open Tips or Tutorials.
@MainActor
@Observable
final class InspectorState {
    private(set) var isShown = false
    private(set) var pane: InspectorPane = .commandHelper

    static func shared(for session: DatabaseSession) -> InspectorState {
        session.scopedObject(InspectorState.self) { InspectorState() }
    }

    func show(_ pane: InspectorPane) {
        self.pane = pane
        isShown = true
    }

    func setShown(_ shown: Bool) {
        isShown = shown
    }

    func select(_ pane: InspectorPane) {
        self.pane = pane
    }

    func toggle() {
        isShown.toggle()
    }

    /// Shows the selected pane, or hides the inspector if it already shows that pane.
    func toggle(_ pane: InspectorPane) {
        if isShown, self.pane == pane {
            isShown = false
        } else {
            show(pane)
        }
    }

    /// Opens the inspector pane requested through Insights.
    func pull(from navigator: DatabaseNavigator) {
        if navigator.isInsightsOpen {
            let target = InspectorPane(insightsTab: navigator.insightsTab)
            if !isShown || pane != target { show(target) }
        } else if isShown, pane != .commandHelper {
            isShown = false
        }
    }

    func push(to navigator: DatabaseNavigator) {
        let open = isShown && pane != .commandHelper
        if navigator.isInsightsOpen != open { navigator.isInsightsOpen = open }
        if let tab = pane.insightsTab, navigator.insightsTab != tab { navigator.insightsTab = tab }
    }
}

struct InspectorView: View {
    let session: DatabaseSession

    var body: some View {
        let state = InspectorState.shared(for: session)
        VStack(spacing: 0) {
            Picker("Inspector Pane", selection: Binding(get: { state.pane }, set: { state.select($0) })) {
                ForEach(InspectorPane.allCases) { pane in
                    Text(title(pane)).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(12)
            Divider()
            pane(state.pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func title(_ pane: InspectorPane) -> String {
        guard pane == .tips else { return pane.title }
        let unread = LiveTipsModel.shared(for: session).totalUnread
        return unread > 0 ? "Tips (\(unread))" : "Tips"
    }

    @ViewBuilder
    private func pane(_ pane: InspectorPane) -> some View {
        switch pane {
        case .commandHelper: CommandHelperView(session: session)
        case .tips: TipsPanelView(session: session)
        case .tutorials: TutorialsPanelView(session: session)
        }
    }
}
