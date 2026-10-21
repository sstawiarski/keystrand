import AnalyticsFeature
import AppKit
import BrowserFeature
import ConnectionsFeature
import MonitoringFeature
import RedisUI
import SettingsFeature
import SwiftUI
import WorkbenchFeature

struct DatabaseSessionFocusedKey: FocusedValueKey {
    typealias Value = DatabaseSession
}

extension FocusedValues {
    var databaseSession: DatabaseSession? {
        get { self[DatabaseSessionFocusedKey.self] }
        set { self[DatabaseSessionFocusedKey.self] = newValue }
    }
}

/// A menu key equivalent.
struct MenuShortcut: Equatable, Sendable {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }

    /// Menu notation in the system modifier order, for example `⇧⌘N` or `⌘↩`.
    var notation: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .return: text += "↩"
        case .delete: text += "⌫"
        case .space: text += "Space"
        default: text += String(key.character).uppercased()
        }

        return text
    }

    static func == (lhs: MenuShortcut, rhs: MenuShortcut) -> Bool {
        lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
    }

    static let addDatabase = MenuShortcut("n")
    static let importConnections = MenuShortcut("i", [.command, .shift])
    static let exportConnections = MenuShortcut("e", [.command, .shift])
    static let showHome = MenuShortcut("0")
    static let keyboardShortcuts = MenuShortcut("/")
    static let copyKeyName = MenuShortcut("c", [.command, .option])
    static let find = MenuShortcut("f")
    static let findNext = MenuShortcut("g")
    static let findPrevious = MenuShortcut("g", [.command, .shift])
    static let useSelectionForFind = MenuShortcut("e")
    static let asList = MenuShortcut("1", [.command, .control])
    static let asTree = MenuShortcut("2", [.command, .control])
    static let viewOptions = MenuShortcut("j")
    static let bottomPanel = MenuShortcut("y", [.command, .shift])
    static let cli = MenuShortcut("`", .control)
    static let profiler = MenuShortcut("p", [.command, .shift])
    static let inspector = MenuShortcut("i", [.command, .option])
    static let commandHelper = MenuShortcut("h", [.command, .shift])
    static let refresh = MenuShortcut("r")
    static let reconnect = MenuShortcut("r", [.command, .shift])
    static let switchDatabase = MenuShortcut("o")
    static let editDatabase = MenuShortcut("e", [.command, .option])
    static let newKey = MenuShortcut("n", [.command, .shift])
    static let runCommands = MenuShortcut(.return)
    static let stopCommands = MenuShortcut(".")

    static func section(_ item: DatabaseSidebarItem) -> MenuShortcut {
        MenuShortcut(item.shortcutKey)
    }
}

extension View {
    func keyboardShortcut(_ shortcut: MenuShortcut) -> some View {
        keyboardShortcut(shortcut.keyboardShortcut)
    }
}

/// Sends an `NSTextFinder` action to the first responder (the focused text view's find bar).
@MainActor
enum TextFinderCommand {
    static func send(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }
}

/// Routes menu actions through the focused window’s session and feature commands.
struct AppCommands: Commands {
    @FocusedValue(\.databaseSession) private var session
    @FocusedValue(\.homeCommands) private var homeCommands
    @FocusedValue(\.browserCommands) private var browserCommands
    @FocusedValue(\.workbenchCommands) private var workbenchCommands
    @FocusedValue(\.editorRunAction) private var editorRunAction
    @FocusedValue(\.analyticsCommands) private var analyticsCommands
    @FocusedValue(\.profilerCommands) private var profilerCommands
    @Environment(\.openWindow) private var openWindow

    static let commandReferenceURL = "https://redis.io/docs/latest/commands/"

    var body: some Commands {
        let _ = AppWindowOpener.remember(openWindow)
        fileCommands
        editCommands
        viewCommands
        databaseMenu
        helpCommands
    }

    // MARK: File

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Database…") { sendHomeCommand(.addDatabase) }
                .keyboardShortcut(MenuShortcut.addDatabase)
            Menu("Open Recent") {
                ForEach(RecentDatabases.shared.items) { config in
                    Button(RecentDatabases.title(config)) { openWindow(value: config.id) }
                }
                Divider()
                Button("Clear Menu") { RecentDatabases.shared.clear() }
                    .disabled(RecentDatabases.shared.items.isEmpty)
            }
            Divider()
            Button("Import Connections…") { sendHomeCommand(.importConnections) }
                .keyboardShortcut(MenuShortcut.importConnections)
            Button("Export Connections…") { homeCommands?.exportSelection() }
                .keyboardShortcut(MenuShortcut.exportConnections)
                .disabled(homeCommands?.canExport != true)
        }
    }

    // MARK: Edit

    @CommandsBuilder
    private var editCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Key Name") { browserCommands?.copyKeyName() }
                .keyboardShortcut(MenuShortcut.copyKeyName)
                .disabled(browserCommands?.hasSelectedKey != true)
        }
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { find() }
                    .keyboardShortcut(MenuShortcut.find)
                Button("Find Next") { TextFinderCommand.send(.nextMatch) }
                    .keyboardShortcut(MenuShortcut.findNext)
                Button("Find Previous") { TextFinderCommand.send(.previousMatch) }
                    .keyboardShortcut(MenuShortcut.findPrevious)
                Button("Use Selection for Find") { TextFinderCommand.send(.setSearchString) }
                    .keyboardShortcut(MenuShortcut.useSelectionForFind)
            }
        }
    }

    /// Focuses Home or Browser search if available; otherwise opens the focused text view’s find bar.
    private func find() {
        if let browserCommands {
            browserCommands.focusSearch()
        } else if session == nil, let homeCommands {
            homeCommands.focusSearch()
        } else {
            TextFinderCommand.send(.showFindInterface)
        }
    }

    // MARK: View

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(DatabaseSidebarItem.allCases) { item in
                Toggle(item.title, isOn: Binding(
                    get: { session.map { DatabaseSidebarItem.current($0.navigator) == item } ?? false },
                    set: { _ in select(item) }
                ))
                .keyboardShortcut(MenuShortcut.section(item))
                .disabled(session == nil || (item == .clusterDetails && session?.isCluster != true))
            }
            Divider()
            Toggle("as List", isOn: viewTypeBinding(.list))
                .keyboardShortcut(MenuShortcut.asList)
                .disabled(browserCommands == nil)
            Toggle("as Tree", isOn: viewTypeBinding(.tree))
                .keyboardShortcut(MenuShortcut.asTree)
                .disabled(browserCommands?.isTreeAvailable != true)
            Button("Show View Options") { browserCommands?.showViewOptions() }
                .keyboardShortcut(MenuShortcut.viewOptions)
                .disabled(browserCommands == nil)
            Button(browserCommands?.isListHidden == true ? "Show Key List" : "Hide Key List") {
                browserCommands?.toggleListHidden()
            }
            .disabled(browserCommands?.canHideList != true)
            Divider()
            Button(isBottomPanelShown ? "Hide Bottom Panel" : "Show Bottom Panel") {
                guard let session else { return }
                BottomPanelModel.shared(for: session).toggleVisible(navigator: session.navigator)
            }
            .keyboardShortcut(MenuShortcut.bottomPanel)
            .disabled(!isConnected)
            Button(isToolShown(.cli) ? "Hide CLI" : "Show CLI") { toggleTool(.cli) }
                .keyboardShortcut(MenuShortcut.cli)
                .disabled(!isConnected)
            Button(isToolShown(.profiler) ? "Hide Profiler" : "Show Profiler") { toggleTool(.profiler) }
                .keyboardShortcut(MenuShortcut.profiler)
                .disabled(!isConnected)
            Divider()
            Button(isInspectorShown ? "Hide Inspector" : "Show Inspector") {
                guard let session else { return }
                InspectorState.shared(for: session).toggle()
            }
            .keyboardShortcut(MenuShortcut.inspector)
            .disabled(session == nil)
            ForEach(InspectorPane.allCases) { pane in
                Toggle(pane.menuTitle, isOn: Binding(
                    get: { isInspectorPaneShown(pane) },
                    set: { _ in
                        guard let session else { return }
                        InspectorState.shared(for: session).toggle(pane)
                    }
                ))
                .keyboardShortcut(pane == .commandHelper ? MenuShortcut.commandHelper.keyboardShortcut : nil)
                .disabled(session == nil)
            }
            Divider()
            Button("Refresh") {
                if let session {
                    session.navigator.requestRefresh()
                } else {
                    homeCommands?.reload()
                }
            }
            .keyboardShortcut(MenuShortcut.refresh)
            .disabled(session == nil ? homeCommands == nil : !isConnected)
            Divider()
        }
    }

    // MARK: Database

    @CommandsBuilder
    private var databaseMenu: some Commands {
        CommandMenu("Database") {
            Button("Connect") {
                if let session { Task { await WindowConnectionModel.shared(for: session).connect() } }
            }
            .disabled(!canConnect)
            Button("Disconnect") {
                if let session { Task { await WindowConnectionModel.shared(for: session).disconnect() } }
            }
            .disabled(!isConnected)
            Button("Reconnect") {
                if let session { Task { await WindowConnectionModel.shared(for: session).reconnect() } }
            }
            .keyboardShortcut(MenuShortcut.reconnect)
            .disabled(!isConnected)
            Divider()
            Button("Switch Database…") {
                guard let session else { return }
                DatabaseWindowChrome.shared(for: session).isSwitcherPresented = true
            }
            .keyboardShortcut(MenuShortcut.switchDatabase)
            .disabled(session == nil)
            logicalDatabaseMenu
            Button("Edit Database…") {
                if let session {
                    session.navigator.navigate(.editDatabase(focusEnvironment: false))
                } else {
                    homeCommands?.editSelection()
                }
            }
            .keyboardShortcut(MenuShortcut.editDatabase)
            .disabled(session == nil && homeCommands?.canEdit != true)
            Divider()
            Button("New Key…") { browserCommands?.newKey() }
                .keyboardShortcut(MenuShortcut.newKey)
                .disabled(browserCommands == nil || !isConnected)
            Button("Rename Key…") { browserCommands?.renameKey() }
                .disabled(browserCommands?.hasSelectedKey != true)
            Button("Set TTL…") { browserCommands?.setTTL() }
                .disabled(browserCommands?.hasSelectedKey != true)
            Button("Delete Key…") { browserCommands?.deleteKey() }
                .disabled(browserCommands?.hasSelectedKey != true)
            Button("Delete Keys Matching Filter…") { browserCommands?.deleteKeysMatchingFilter() }
                .disabled(browserCommands == nil)
            Button("Upload Commands from File…") { browserCommands?.uploadCommands() }
                .disabled(browserCommands == nil)
            Divider()
            Button("Run Commands") { editorRunAction?.run() }
                .keyboardShortcut(MenuShortcut.runCommands)
                .disabled(editorRunAction?.canRun != true)
            Button("Stop") { workbenchCommands?.stop() }
                .keyboardShortcut(MenuShortcut.stopCommands)
                .disabled(workbenchCommands?.canStop != true)
            Button("Clear Results…") { workbenchCommands?.clearResults() }
                .disabled(workbenchCommands?.hasResults != true)
            Divider()
            Button("New Analysis Report") { analyticsCommands?.newReport() }
                .disabled(analyticsCommands?.canCreateReport != true)
            Button("Clear Slow Log…") { analyticsCommands?.clearSlowLog() }
                .disabled(analyticsCommands?.canClearSlowLog != true)
            Button(profilerCommands?.title ?? "Start Profiler") { profilerCommands?.toggle() }
                .disabled(profilerCommands?.isEnabled != true)
        }
    }

    @ViewBuilder
    private var logicalDatabaseMenu: some View {
        let count = session?.databaseCount ?? 1
        Menu("Logical Database") {
            if let session {
                ForEach(0..<min(count, 16), id: \.self) { index in
                    Toggle("db\(index)", isOn: Binding(
                        get: { session.effectiveDB == index },
                        set: { _ in LogicalDatabaseSwitch.select(index, session: session) }
                    ))
                }
                if count > 16 {
                    Divider()
                    Button("Other…") { DatabaseWindowChrome.shared(for: session).isOtherDatabasePromptPresented = true }
                }
            }
        }
        .disabled(session == nil || count <= 1 || session.map(LogicalDatabaseSwitch.isBlocked(session:)) == true)
    }

    // MARK: Help

    @CommandsBuilder
    private var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: AppWindowID.shortcuts) }
                .keyboardShortcut(MenuShortcut.keyboardShortcuts)
            Button("Redis Command Reference") {
                if let url = URL(string: Self.commandReferenceURL) { NSWorkspace.shared.open(url) }
            }
            Button("Acknowledgements") { openWindow(id: AppWindowID.acknowledgements) }
            Divider()
            Button("Copy System Info") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AppVersionInfo.current().diagnostics, forType: .string)
            }
            Button("Reset Onboarding") { AppServices.shared.settings.ui.resetOnboarding() }
        }
    }

    // MARK: State

    private var isConnected: Bool {
        guard let session else { return false }
        return WindowConnectionModel.shared(for: session).phase.showsBottomPanel
    }

    private var canConnect: Bool {
        guard let session else { return false }
        switch WindowConnectionModel.shared(for: session).phase {
        case .disconnected, .failed: return true
        case .connecting, .content: return false
        }
    }

    private var isBottomPanelShown: Bool {
        guard let session else { return false }
        return BottomPanelModel.shared(for: session).isShown(session.navigator)
    }

    private var isInspectorShown: Bool {
        guard let session else { return false }
        return InspectorState.shared(for: session).isShown
    }

    private func isInspectorPaneShown(_ pane: InspectorPane) -> Bool {
        guard let session else { return false }
        let inspector = InspectorState.shared(for: session)
        return inspector.isShown && inspector.pane == pane
    }

    private func isToolShown(_ tool: BottomPanelTool) -> Bool {
        guard let session else { return false }
        return BottomPanelModel.shared(for: session).isToolShown(tool, navigator: session.navigator)
    }

    /// Hiding a tool keeps its CLI connection or Profiler running.
    private func toggleTool(_ tool: BottomPanelTool) {
        guard let session else { return }
        BottomPanelModel.shared(for: session).toggleShown(tool, navigator: session.navigator)
    }

    private func select(_ item: DatabaseSidebarItem) {
        guard let session else { return }
        item.resolved(isCluster: session.isCluster).apply(to: session.navigator)
    }

    private func viewTypeBinding(_ type: KeyViewType) -> Binding<Bool> {
        Binding(
            get: { browserCommands?.viewType == type },
            set: { _ in browserCommands?.setViewType(type) }
        )
    }

    private func sendHomeCommand(_ request: HomeCommandCenter.Request) {
        HomeWindowActivator.show(openWindow)
        HomeCommandCenter.shared.send(request)
    }
}
