import AppKit
import ConnectionsFeature
import Foundation
import RedisUI
import SettingsFeature

/// Launch arguments for smoke tests and screenshots.
/// `--open host:port[/db]` upserts and opens a database named “host:port”; `--open-id <id>` opens a saved database.
/// The remaining flags navigate the first window.
struct LaunchOptions: Equatable {
    enum Target: Equatable {
        case endpoint(host: String, port: Int, db: Int?)
        case id(DatabaseID)
    }

    var target: Target?
    var home = false
    var addDatabase = false
    var section: DatabaseSidebarItem?
    var tools: [BottomPanelTool] = []
    var inspector: InspectorPane?
    var key: String?
    /// `""` opens Settings on its current page.
    var settingsPage: String?
    var shortcuts = false
    var appearance: ThemeMode?
    var sheet: String?
    var windowSize: CGSize?
    /// Launch flags disable restoration of saved window state.
    var isActive = false

    static let current = LaunchOptions(QALaunchOptions.current)

    init(arguments: [String]) {
        self.init(QALaunchOptions(arguments: arguments))
    }

    /// Maps the parsed flags to AppShell's types; unknown values are ignored.
    init(_ options: QALaunchOptions) {
        if let id = options.openID {
            target = .id(DatabaseID(rawValue: id))
        } else {
            target = options.open.flatMap(Self.parseEndpoint)
        }

        home = options.home
        addDatabase = options.addDatabase
        section = options.section.flatMap(DatabaseSidebarItem.init(flag:))
        tools = options.tools.compactMap { tool in
            switch tool {
            case "cli": return .cli
            case "profiler": return .profiler
            case "helper": return .commandHelper
            default: return nil
            }
        }
        inspector = options.inspector.flatMap(InspectorPane.init(flag:))
        key = options.key
        settingsPage = options.settingsPage
        shortcuts = options.shortcuts
        appearance = options.appearance
        sheet = options.sheet
        windowSize = options.windowSize
        isActive = options.isActive
    }

    /// Home stays closed at launch when a database window opens instead (unless `--home` asks for it).
    var suppressesHome: Bool { target != nil && !home }

    /// Parses `host:port` or `host:port/db`.
    static func parseEndpoint(_ text: String) -> Target? {
        var hostPort = Substring(text)
        var db: Int?
        if let slash = text.lastIndex(of: "/") {
            guard let parsed = Int(text[text.index(after: slash)...]), parsed >= 0 else { return nil }
            db = parsed
            hostPort = text[..<slash]
        }

        guard let colon = hostPort.lastIndex(of: ":") else { return nil }
        let host = String(hostPort[..<colon])
        guard !host.isEmpty, let port = Int(hostPort[hostPort.index(after: colon)...]), (1...65_535).contains(port) else {
            return nil
        }
        return .endpoint(host: host, port: port, db: db)
    }
}

@MainActor
enum LaunchOpener {
    private static var handled = false

    static var hasPendingTarget: Bool { !handled && LaunchOptions.current.target != nil }

    /// Resolves the launch target once per process and returns the database to open.
    static func resolveOnce(_ options: LaunchOptions = .current, services: AppServices) async -> DatabaseID? {
        guard !handled, let target = options.target else { return nil }
        handled = true
        switch target {
        case .id(let id):
            return id
        case .endpoint(let host, let port, let db):
            do {
                return try await upsert(host: host, port: port, db: db, services: services)
            } catch {
                services.toasts.error(error, title: "Unable to Open Database")
                return nil
            }
        }
    }

    static func upsert(host: String, port: Int, db: Int?, services: AppServices) async throws -> DatabaseID {
        let name = "\(host):\(port)"
        let existing = try await services.databaseStore.list().first { $0.name == name && $0.host == host && $0.port == port }
        if let existing {
            if existing.db != db {
                var full = try await services.databaseStore.get(existing.id)
                full.db = db
                try await services.saveDatabase(full)
            }

            return existing.id
        }

        let config = DatabaseConfig(name: name, host: host, port: port, db: db)
        try await services.saveDatabase(config)
        return config.id
    }
}

/// One-shot QA navigation from the launch flags, applied by the first window that can act on it.
@MainActor
enum LaunchActions {
    private static var didApplyHome = false
    private static var didApplyDatabase = false
    private static var didSizeWindow = false

    /// `--add-database`, `--settings`, `--shortcuts` after the Home window appears.
    static func applyHome(options: LaunchOptions = .current, openWindow: (String) -> Void, openSettings: () -> Void) {
        guard !didApplyHome else { return }
        didApplyHome = true
        if options.addDatabase { HomeCommandCenter.shared.send(.addDatabase) }
        if let page = options.settingsPage {
            if let tab = SettingsTab(rawValue: page) { SettingsTab.preselect(tab) }
            openSettings()
            NSApp.activate()
        }

        if options.shortcuts {
            openWindow(AppWindowID.shortcuts)
            NSApp.activate()
            Task {
                // Home finishes its first layout after this call and would otherwise stay in front.
                try? await Task.sleep(for: .milliseconds(400))
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(AppWindowID.shortcuts) == true }?
                    .makeKeyAndOrderFront(nil)
            }
        }
    }

    /// `--section`, `--tool`, `--inspector`, `--key` once the launch database window is connected.
    static func applyDatabase(options: LaunchOptions = .current, session: DatabaseSession) {
        guard !didApplyDatabase, options.target != nil else { return }
        didApplyDatabase = true
        let navigator = session.navigator
        if let section = options.section {
            section.resolved(isCluster: session.isCluster).apply(to: navigator)
        }

        let bottom = BottomPanelModel.shared(for: session)
        let inspector = InspectorState.shared(for: session)
        for tool in options.tools {
            if tool == .commandHelper {
                inspector.show(.commandHelper)
            } else {
                bottom.open(tool, navigator: navigator)
            }
        }

        if let pane = options.inspector { inspector.show(pane) }
        if let key = options.key {
            navigator.navigate(.browser(BrowserNavigationRequest(selectedKey: Data(key.utf8))))
        }

        switch options.sheet {
        case "edit-database": navigator.navigate(.editDatabase(focusEnvironment: false))
        case "tags": DatabaseWindowChrome.shared(for: session).tagsSheetDatabase = session.config
        default: break
        }
    }

    /// Resizes the first app window to `--window-size WxH`.
    static func sizeFirstWindow(_ window: NSWindow, options: LaunchOptions = .current) {
        guard !didSizeWindow, let size = options.windowSize else { return }
        didSizeWindow = true
        window.setContentSize(size)
        window.center()
    }
}
