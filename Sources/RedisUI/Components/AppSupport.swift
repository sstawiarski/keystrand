import Foundation
import SwiftUI

/// QA launch flags parsed once from process arguments.
public struct QALaunchOptions: Sendable, Equatable {
    public static let current = QALaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    public var home = false
    public var addDatabase = false
    /// browser|workbench|analysis|slowlog|cluster|pubsub|vectorsearch
    public var section: String?
    /// cli|helper|profiler, in the order given (the flag may repeat).
    public var tools: [String] = []
    /// helper|tips|tutorials
    public var inspector: String?
    public var key: String?
    /// general|workbench|advanced, or "" for the current page (also for an unknown page name).
    public var settingsPage: String?
    public var shortcuts = false
    public var appearance: ThemeMode?
    /// new-key|bulk-actions|edit-database|tags|sample-data
    public var sheet: String?
    public var windowSize: CGSize?
    /// The `--open` value as given (`host:port[/db]`).
    public var open: String?
    /// The `--open-id` value.
    public var openID: String?
    /// True when any QA launch flag is present, including `--open` and `--open-id`.
    public var isActive = false

    public init(arguments: [String]) {
        var index = 0

        func value(after i: Int) -> String? {
            let next = i + 1
            guard next < arguments.count, !arguments[next].hasPrefix("--") else { return nil }
            return arguments[next]
        }

        while index < arguments.count {
            let argument = arguments[index]
            var consumed = 0
            switch argument {
            case "--home":
                home = true
                isActive = true
            case "--add-database":
                addDatabase = true
                isActive = true
            case "--shortcuts":
                shortcuts = true
                isActive = true
            case "--section", "--tool", "--inspector", "--key", "--sheet", "--appearance", "--window-size", "--open",
                 "--open-id":
                isActive = true
                guard let raw = value(after: index) else { break }
                consumed = 1
                apply(flag: argument, value: raw)
            case "--settings":
                isActive = true
                if let raw = value(after: index) {
                    let page = raw.lowercased()
                    settingsPage = Self.settingsPages.contains(page) ? page : ""
                    consumed = 1
                } else {
                    settingsPage = ""
                }
            default:
                break
            }

            index += 1 + consumed
        }

        if key != nil, section == nil { section = "browser" }
    }

    private mutating func apply(flag: String, value raw: String) {
        let lowered = raw.lowercased()
        switch flag {
        case "--section": section = lowered
        case "--tool": tools.append(lowered)
        case "--inspector": inspector = lowered
        case "--key": key = raw
        case "--sheet": sheet = lowered
        case "--appearance": appearance = lowered == "dark" ? .dark : lowered == "light" ? .light : nil
        case "--window-size": windowSize = Self.parseSize(lowered)
        case "--open": open = raw
        case "--open-id": openID = raw.isEmpty ? nil : raw
        default: break
        }
    }

    static let settingsPages: Set<String> = ["general", "workbench", "advanced"]

    /// `1280x800` → 1280×800; nil when malformed or either side is under 200 points.
    static func parseSize(_ text: String) -> CGSize? {
        let parts = text.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width >= 200, height >= 200 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

/// Published with `.focusedSceneValue(\.editorRunAction, …)` by the Workbench and the Vector Search query page;
/// read by the Database > Run Commands menu item (⌘↩).
public struct EditorRunAction: Sendable {
    public var canRun: Bool
    public var run: @MainActor () -> Void

    public init(canRun: Bool, run: @escaping @MainActor () -> Void) {
        self.canRun = canRun
        self.run = run
    }
}

public extension FocusedValues {
    @Entry var editorRunAction: EditorRunAction?
}

/// Matches Swift Charts' default series colors for chart marks, external node dots and legends.
/// Use `.chartForegroundStyleScale(domain:range: ChartPalette.colors)` to keep series consistent.
public enum ChartPalette {
    public static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .indigo, .mint, .cyan,
                                         .brown, .red]

    /// Cycles through `colors`; negative indexes wrap too.
    public static func color(at index: Int) -> Color {
        let count = colors.count
        return colors[((index % count) + count) % count]
    }
}
