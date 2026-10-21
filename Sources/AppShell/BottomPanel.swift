import CLIFeature
import MonitoringFeature
import Observation
import RedisUI
import SwiftUI

/// Bottom panel height, stored in `settings.ui.bottomPanelSizes` as `[main, bottom]` percentages.
enum BottomPanelSplit {
    static let defaultSizes: [Double] = [60, 40]
    static let defaultBottomFraction = 0.4
    static let minBottomFraction = 0.1
    static let maxBottomFraction = 0.8

    static func clamp(_ bottomFraction: Double) -> Double {
        guard bottomFraction.isFinite else { return defaultBottomFraction }
        return min(max(bottomFraction, minBottomFraction), maxBottomFraction)
    }

    static func bottomFraction(from sizes: [Double]) -> Double {
        guard sizes.count == 2, sizes.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return defaultBottomFraction }
        let total = sizes[0] + sizes[1]
        guard total > 0 else { return defaultBottomFraction }
        return clamp(sizes[1] / total)
    }

    static func sizes(forBottomFraction fraction: Double) -> [Double] {
        let bottom = clamp(fraction) * 100
        return [(100 - bottom).rounded(.down), bottom.rounded(.up)]
    }

    static func sizes(bottomHeight: CGFloat, totalHeight: CGFloat) -> [Double]? {
        guard totalHeight > 0, bottomHeight > 0 else { return nil }
        return sizes(forBottomFraction: Double(bottomHeight / totalHeight))
    }
}

/// CLI and Profiler state for one database window. Hidden tools keep running; closing a tool ends it.
@MainActor
@Observable
final class BottomPanelModel {
    static let tools: [BottomPanelTool] = [.cli, .profiler]

    private(set) var isVisible = false
    private(set) var hasOpenedCLI = false
    /// Hidden tools keep running.
    private(set) var hiddenTools: Set<BottomPanelTool> = []
    @ObservationIgnored private var lastSeen: Set<BottomPanelTool> = []

    static func shared(for session: DatabaseSession) -> BottomPanelModel {
        session.scopedObject(BottomPanelModel.self) { BottomPanelModel() }
    }

    func openTools(_ navigator: DatabaseNavigator) -> [BottomPanelTool] {
        Self.tools.filter { navigator.openBottomTools.contains($0) }
    }

    func displayedTools(_ navigator: DatabaseNavigator) -> [BottomPanelTool] {
        openTools(navigator).filter { !hiddenTools.contains($0) }
    }

    func isShown(_ navigator: DatabaseNavigator) -> Bool {
        isVisible && !displayedTools(navigator).isEmpty
    }

    func isToolShown(_ tool: BottomPanelTool, navigator: DatabaseNavigator) -> Bool {
        isShown(navigator) && displayedTools(navigator).contains(tool)
    }

    /// Showing the panel shows every open tool, or opens the CLI when none is open.
    func setVisible(_ visible: Bool, navigator: DatabaseNavigator) {
        if visible {
            hiddenTools.removeAll()
            if openTools(navigator).isEmpty { navigator.openBottomTools.insert(.cli) }
        }

        isVisible = visible
        sync(navigator)
    }

    func toggleVisible(navigator: DatabaseNavigator) {
        setVisible(!isShown(navigator), navigator: navigator)
    }

    func open(_ tool: BottomPanelTool, navigator: DatabaseNavigator) {
        hiddenTools.remove(tool)
        navigator.openBottomTools.insert(tool)
        isVisible = true
        sync(navigator)
    }

    /// Hides a visible tool without stopping it, or shows a hidden or closed tool.
    func toggleShown(_ tool: BottomPanelTool, navigator: DatabaseNavigator) {
        guard isToolShown(tool, navigator: navigator) else {
            open(tool, navigator: navigator)
            return
        }
        hiddenTools.insert(tool)
        if displayedTools(navigator).isEmpty { isVisible = false }
    }

    /// Shows a hidden or closed tool. Returns a visible tool after closing it so its connection can be ended.
    @discardableResult
    func toggle(_ tool: BottomPanelTool, navigator: DatabaseNavigator) -> BottomPanelTool? {
        if isToolShown(tool, navigator: navigator) {
            navigator.openBottomTools.remove(tool)
            sync(navigator)
            return tool
        }

        open(tool, navigator: navigator)
        return nil
    }

    /// Shows the panel when tools open elsewhere; hides it when no tools remain visible.
    func sync(_ navigator: DatabaseNavigator) {
        let current = navigator.openBottomTools.intersection(Self.tools)
        let added = current.subtracting(lastSeen)
        lastSeen = current
        hiddenTools.formIntersection(current)
        hiddenTools.subtract(added)
        if current.contains(.cli) { hasOpenedCLI = true }
        if !added.isEmpty { isVisible = true }
        if displayedTools(navigator).isEmpty { isVisible = false }
    }

    func stop(_ tool: BottomPanelTool, session: DatabaseSession) async {
        switch tool {
        case .cli:
            if hasOpenedCLI { await CLIViewModel.shared(for: session).closeCLI() }
        case .profiler:
            if ProfilerView.isRunning(session: session) { await ProfilerView.close(session: session) }
        case .commandHelper:
            break
        }
    }

    static func title(_ tool: BottomPanelTool) -> String {
        tool.title
    }

    static func systemImage(_ tool: BottomPanelTool) -> String {
        switch tool {
        case .cli: return "terminal"
        case .commandHelper: return "book"
        case .profiler: return "waveform.path.ecg"
        }
    }
}

struct BottomPanelView: View {
    let session: DatabaseSession

    var body: some View {
        let model = BottomPanelModel.shared(for: session)
        let navigator = session.navigator
        VStack(spacing: 0) {
            HStack {
                ForEach(BottomPanelModel.tools) { tool in
                    let isDisplayed = model.displayedTools(navigator).contains(tool)
                    Toggle(isOn: Binding(get: { isDisplayed }, set: { _ in toggle(tool) })) {
                        Label(BottomPanelModel.title(tool), systemImage: BottomPanelModel.systemImage(tool))
                    }
                    .toggleStyle(.button)
                    .help(isDisplayed ? "Close \(tool.title)" : "Show \(tool.title)")
                }
                Spacer()
                Button {
                    model.setVisible(false, navigator: navigator)
                } label: {
                    Label("Hide Bottom Panel", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide Bottom Panel (⇧⌘Y)")
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .frame(height: 28)
            Divider()
            HSplitView {
                ForEach(model.displayedTools(navigator)) { tool in
                    toolView(tool)
                        .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func toggle(_ tool: BottomPanelTool) {
        let model = BottomPanelModel.shared(for: session)
        if tool == .profiler, model.isToolShown(.profiler, navigator: session.navigator) {
            ProfilerView.requestClose(session: session)
            return
        }

        if let closed = model.toggle(tool, navigator: session.navigator) {
            Task { await model.stop(closed, session: session) }
        }
    }

    @ViewBuilder
    private func toolView(_ tool: BottomPanelTool) -> some View {
        switch tool {
        case .cli:
            CLIView(session: session)
        case .profiler:
            ProfilerView(session: session) {
                session.navigator.openBottomTools.remove(.profiler)
                BottomPanelModel.shared(for: session).sync(session.navigator)
            }
        case .commandHelper:
            EmptyView()
        }
    }
}
