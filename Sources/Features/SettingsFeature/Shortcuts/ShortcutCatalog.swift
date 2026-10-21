import Foundation

public struct ShortcutItem: Hashable, Sendable, Identifiable {
    public var description: String
    /// Key combination in menu notation, such as `⇧⌘H`.
    public var keys: String
    public var id: String { description + keys }

    public init(_ description: String, _ keys: String) {
        self.description = description
        self.keys = keys
    }
}

public struct ShortcutGroup: Hashable, Sendable, Identifiable {
    public var title: String
    public var items: [ShortcutItem]
    public var id: String { title }

    public init(title: String, items: [ShortcutItem]) {
        self.title = title
        self.items = items
    }
}

/// Keyboard shortcut groups for the app.
public enum ShortcutCatalog {
    public static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Application", items: [
            ShortcutItem("Add database", "⌘N"),
            ShortcutItem("Import connections", "⇧⌘I"),
            ShortcutItem("Show Redis databases", "⌘0"),
            ShortcutItem("Settings", "⌘,"),
            ShortcutItem("Keyboard shortcuts", "⌘/"),
        ]),
        ShortcutGroup(title: "Database Window", items: [
            ShortcutItem("Browser", "⌘1"),
            ShortcutItem("Workbench", "⌘2"),
            ShortcutItem("Vector Search", "⌘3"),
            ShortcutItem("Database Analysis", "⌘4"),
            ShortcutItem("Slow Log", "⌘5"),
            ShortcutItem("Cluster Details", "⌘6"),
            ShortcutItem("Pub/Sub", "⌘7"),
            ShortcutItem("Show or hide the sidebar", "⌃⌘S"),
            ShortcutItem("Show or hide the inspector", "⌥⌘I"),
            ShortcutItem("Command Helper", "⇧⌘H"),
            ShortcutItem("Show or hide the bottom panel", "⇧⌘Y"),
            ShortcutItem("Show or hide the CLI", "⌃`"),
            ShortcutItem("Show or hide the Profiler", "⇧⌘P"),
            ShortcutItem("Refresh", "⌘R"),
            ShortcutItem("Switch database", "⌘O"),
            ShortcutItem("Edit database", "⌥⌘E"),
            ShortcutItem("Reconnect", "⇧⌘R"),
        ]),
        ShortcutGroup(title: "Browser", items: [
            ShortcutItem("New key", "⇧⌘N"),
            ShortcutItem("Show as list / as tree", "⌃⌘1 / ⌃⌘2"),
            ShortcutItem("View options", "⌘J"),
            ShortcutItem("Copy key name", "⌥⌘C"),
            ShortcutItem("Rename key", "Return"),
            ShortcutItem("Delete key", "⌫"),
            ShortcutItem("Preview value", "Space"),
            ShortcutItem("Find keys", "⌘F"),
        ]),
        ShortcutGroup(title: "Vector Search", items: [
            ShortcutItem("Get index info", "⌘I"),
        ]),
        ShortcutGroup(title: "Workbench", items: [
            ShortcutItem("Run commands", "⌘↩"),
            ShortcutItem("Stop running commands", "⌘."),
            ShortcutItem("Show completions", "⌃Space"),
            ShortcutItem("Show command hints", "⇧⌘Space"),
            ShortcutItem("Previous command from history", "↑ (at the start of the editor)"),
        ]),
        ShortcutGroup(title: "CLI", items: [
            ShortcutItem("Complete command / previous completion", "Tab / ⇧Tab"),
            ShortcutItem("Clear the screen", "⌘K or ⌃L"),
            ShortcutItem("Previous / next command", "↑ / ↓"),
        ]),
    ]

    /// Groups whose description or keys contain `query` (case-insensitive); empty groups are dropped.
    public static func filtered(_ query: String, in groups: [ShortcutGroup] = groups) -> [ShortcutGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(needle) { return group }
            let items = group.items.filter {
                $0.description.localizedCaseInsensitiveContains(needle) || $0.keys.localizedCaseInsensitiveContains(needle)
            }
            return items.isEmpty ? nil : ShortcutGroup(title: group.title, items: items)
        }
    }
}
