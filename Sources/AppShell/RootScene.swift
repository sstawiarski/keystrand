import AnalyticsFeature
import BrowserFeature
import CLIFeature
import ConnectionsFeature
import KeyTypesAdvancedFeature
import KeyTypesBasicFeature
import MonitoringFeature
import RedisUI
import SettingsFeature
import SwiftUI
import VectorSearchFeature
import WorkbenchFeature

public enum AppWindowID {
    public static let home = "home"
    public static let shortcuts = "shortcuts"
    public static let acknowledgements = "acknowledgements"
}

/// The whole app: Home library window, one window per database, Settings, the Help windows, menu commands.
public struct RootScene: Scene {
    public init() {}

    public var body: some Scene {
        let services = AppServices.shared
        let options = LaunchOptions.current

        Window("Redis Databases", id: AppWindowID.home) {
            AppRoot(services: services) { HomeWindowView() }
        }
        .defaultSize(width: 1000, height: 640)
        .keyboardShortcut(MenuShortcut.showHome.keyboardShortcut)
        .defaultLaunchBehavior(options.suppressesHome ? .suppressed : .presented)
        .handlesExternalEvents(matching: [DeepLink.scheme])
        .commands {
            SidebarCommands()
            ToolbarCommands()
            AppCommands()
        }

        WindowGroup("Database", for: DatabaseID.self) { $id in
            AppRoot(services: services) { DatabaseWindowContainer(id: $id) }
        }
        .defaultSize(width: 1320, height: 860)
        .defaultLaunchBehavior(options.target != nil ? .presented : .suppressed)
        .handlesExternalEvents(matching: [])

        Window("Keyboard Shortcuts", id: AppWindowID.shortcuts) {
            AppRoot(services: services) {
                KeyboardShortcutsView()
                    .frame(width: 640, height: 600)
            }
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])

        Window("Acknowledgements", id: AppWindowID.acknowledgements) {
            AppRoot(services: services) {
                AcknowledgementsView()
                    .frame(minWidth: 520, minHeight: 400)
            }
        }
        .defaultSize(width: 640, height: 640)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])

        Settings {
            AppRoot(services: services) { SettingsView() }
        }
    }
}

/// Injects services and settings, applies the appearance override, and handles `keystrand://` links in any window.
struct AppRoot<Content: View>: View {
    let services: AppServices
    @ViewBuilder let content: () -> Content
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content()
            .environment(services)
            .environment(services.settings)
            .appAppearance(services.settings.app.theme)
            .onAppear { AppWindowOpener.remember(openWindow) }
            .onHostingWindow { window in LastWindowCloseGuard.install(on: window, services: services) }
            .handlesExternalEvents(preferring: [DeepLink.scheme], allowing: [DeepLink.scheme])
            .onOpenURL { url in
                if let link = DatabaseDeepLink.parse(url) { DeepLinkRedirects.expect(link) }
                HomeWindowActivator.show(openWindow)
                HomeCommandCenter.shared.send(.openURL(url))
            }
    }
}

struct HomeWindowView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HomeView(
            onOpenDatabase: { config in
                DeepLinkRedirects.databaseOpened(config)
                openWindow(value: config.id)
            },
            onDatabasesDeleted: { ids in
                for id in ids { dismissWindow(value: id) }
            },
            onDeepLinkCancelled: { link in DeepLinkRedirects.cancel(link) },
            autoDiscovery: LaunchOptions.current.target == nil ? LocalAutoDiscovery.appDefault : nil
        )
        .frame(minWidth: 760, minHeight: 460)
        .shellStatusAlerts(services.toasts)
        .onHostingWindow { window in LaunchActions.sizeFirstWindow(window) }
        .task {
            RecentDatabases.shared.reload(services: services)
            LaunchActions.applyHome(openWindow: { openWindow(id: $0) }, openSettings: { openSettings() })
        }
    }
}
