import RedisUI
import SwiftUI

/// Shows General, Workbench, and Advanced settings from the environment store.
public struct SettingsView: View {
    @Environment(SettingsStore.self) private var store

    public init() {}

    public var body: some View {
        SettingsTabsView(store: store)
    }
}

struct SettingsTabsView: View {
    static let width: CGFloat = 520

    @State private var model: SettingsViewModel
    @AppStorage(SettingsTab.selectionDefaultsKey) private var selectedTab: String = SettingsTab.general.rawValue

    init(store: SettingsStore) {
        _model = State(initialValue: SettingsViewModel(store: store))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .frame(width: Self.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab.rawValue)
            }
        }
        .onAppear {
            if SettingsTab(rawValue: selectedTab) == nil { selectedTab = SettingsTab.general.rawValue }
        }
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsPage(model: model)
        case .workbench: WorkbenchSettingsPage(model: model)
        case .advanced: AdvancedSettingsPage(model: model)
        }
    }
}
