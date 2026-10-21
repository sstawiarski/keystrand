@testable import AppShell
import SettingsFeature
import SwiftUI
import Testing

/// The Keyboard Shortcuts window must match the menu bar key equivalents.
@MainActor
struct MenuShortcutTests {
    /// Includes only menu-backed shortcuts, by group and description.
    /// The system handles Settings (⌘,) and sidebar (⌃⌘S); views handle Return, ⌫, Space, ⌘I, editor and CLI keys.
    static let menuItems: [String: [String: MenuShortcut]] = [
        "Application": [
            "Add database": .addDatabase,
            "Import connections": .importConnections,
            "Show Redis databases": .showHome,
            "Keyboard shortcuts": .keyboardShortcuts,
        ],
        "Database Window": [
            "Browser": .section(.browser),
            "Workbench": .section(.workbench),
            "Vector Search": .section(.vectorSearch),
            "Database Analysis": .section(.databaseAnalysis),
            "Slow Log": .section(.slowLog),
            "Cluster Details": .section(.clusterDetails),
            "Pub/Sub": .section(.pubSub),
            "Show or hide the inspector": .inspector,
            "Command Helper": .commandHelper,
            "Show or hide the bottom panel": .bottomPanel,
            "Show or hide the CLI": .cli,
            "Show or hide the Profiler": .profiler,
            "Refresh": .refresh,
            "Switch database": .switchDatabase,
            "Edit database": .editDatabase,
            "Reconnect": .reconnect,
        ],
        "Browser": [
            "New key": .newKey,
            "View options": .viewOptions,
            "Copy key name": .copyKeyName,
            "Find keys": .find,
        ],
        "Workbench": [
            "Run commands": .runCommands,
            "Stop running commands": .stopCommands,
        ],
    ]

    static let systemOrViewRows: Set<String> = [
        "Settings", "Show or hide the sidebar", "Show as list / as tree", "Rename key", "Delete key", "Preview value",
        "Get index info", "Show completions", "Show command hints", "Previous command from history",
        "Complete command / previous completion", "Clear the screen", "Previous / next command",
    ]

    @Test func catalogMatchesMenuShortcuts() {
        for group in ShortcutCatalog.groups {
            for item in group.items {
                if let shortcut = Self.menuItems[group.title]?[item.description] {
                    #expect(shortcut.notation == item.keys, "\(group.title) › \(item.description)")
                } else {
                    #expect(Self.systemOrViewRows.contains(item.description),
                            "\(group.title) › \(item.description) has no menu item mapping")
                }
            }
        }
    }

    @Test func everyMappedMenuItemIsInTheCatalog() {
        for (group, items) in Self.menuItems {
            let catalog = ShortcutCatalog.groups.first { $0.title == group }
            for description in items.keys {
                #expect(catalog?.items.contains { $0.description == description } == true, "\(group) › \(description)")
            }
        }
    }

    @Test func listAndTreeRowMatchesViewMenu() {
        let row = ShortcutCatalog.groups.flatMap(\.items).first { $0.description == "Show as list / as tree" }
        #expect(row?.keys == "\(MenuShortcut.asList.notation) / \(MenuShortcut.asTree.notation)")
    }

    @Test func notationUsesSystemModifierOrder() {
        #expect(MenuShortcut("k", [.command, .shift, .option, .control]).notation == "⌃⌥⇧⌘K")
        #expect(MenuShortcut.runCommands.notation == "⌘↩")
        #expect(MenuShortcut.cli.notation == "⌃`")
    }

    @Test func menuShortcutsAreUnique() {
        let all: [MenuShortcut] = [
            .addDatabase, .importConnections, .exportConnections, .showHome, .keyboardShortcuts, .copyKeyName, .find,
            .findNext, .findPrevious, .useSelectionForFind, .asList, .asTree, .viewOptions, .bottomPanel, .cli,
            .profiler, .inspector, .commandHelper, .refresh, .reconnect, .switchDatabase, .editDatabase, .newKey,
            .runCommands, .stopCommands,
        ] + DatabaseSidebarItem.allCases.map(MenuShortcut.section)
        #expect(Set(all.map(\.notation)).count == all.count)
    }
}

struct TitleCaseTests {
    @Test func connectionErrorTitles() {
        #expect(TitleCase.make("Connection unavailable") == "Connection Unavailable")
        #expect(TitleCase.make("Authentication not supported") == "Authentication Not Supported")
        #expect(TitleCase.make("SSH connection failed") == "SSH Connection Failed")
        #expect(TitleCase.make("Pre-connection script failed") == "Pre-Connection Script Failed")
        #expect(TitleCase.make("Unable to connect to the server") == "Unable to Connect to the Server")
    }
}
