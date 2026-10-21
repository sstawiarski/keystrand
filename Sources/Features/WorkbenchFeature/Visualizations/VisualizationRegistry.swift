import Foundation
import RedisCore

/// Result views a card can switch between.
public enum WorkbenchViewKind: String, Hashable, Sendable, CaseIterable, Codable, Identifiable {
    case text
    case searchTable
    case indexInfo
    case json
    case clientList
    case timeSeries
    case explain
    case profile
    case geoMap
    case geoHeatmap
    case geoTable

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .text: return "Text"
        case .searchTable, .indexInfo, .clientList: return "Table"
        case .json: return "JSON"
        case .timeSeries: return "Chart"
        case .explain, .profile: return "Visualization"
        case .geoMap: return "Map"
        case .geoHeatmap: return "Heatmap"
        case .geoTable: return "Details"
        }
    }

    public var systemImage: String {
        switch self {
        case .text: return "text.alignleft"
        case .searchTable, .indexInfo, .clientList, .geoTable: return "tablecells"
        case .json: return "curlybraces"
        case .timeSeries: return "chart.xyaxis.line"
        case .explain, .profile: return "point.3.connected.trianglepath.dotted"
        case .geoMap: return "map"
        case .geoHeatmap: return "flame"
        }
    }
}

/// Matches commands to visualizations and chooses the default view.
public enum VisualizationRegistry {
    struct Entry: Sendable {
        var kind: WorkbenchViewKind
        var commands: [String]
        var isDefault: Bool
        var requires: (@Sendable (String) -> Bool)? = nil
    }

    static let geoSearchCommands = ["GEOSEARCH", "GEORADIUS", "GEORADIUS_RO", "GEORADIUSBYMEMBER",
                                    "GEORADIUSBYMEMBER_RO"]

    static func hasWithCoord(_ normalizedCommand: String) -> Bool {
        normalizedCommand.split(separator: " ").contains("WITHCOORD")
    }

    static let entries: [Entry] = [
        Entry(kind: .profile, commands: ["FT.PROFILE"], isDefault: true),
        Entry(kind: .searchTable, commands: ["FT.SEARCH", "FT.AGGREGATE"], isDefault: true),
        Entry(kind: .searchTable, commands: ["FT.PROFILE"], isDefault: false),
        Entry(kind: .indexInfo, commands: ["FT.INFO"], isDefault: true),
        Entry(kind: .explain, commands: ["FT.EXPLAIN", "FT.EXPLAINCLI"], isDefault: true),
        Entry(kind: .json, commands: ["JSON.GET", "JSON.MGET"], isDefault: true),
        Entry(kind: .json, commands: ["GET"], isDefault: false),
        Entry(kind: .clientList, commands: ["CLIENT LIST"], isDefault: true),
        Entry(kind: .timeSeries, commands: ["TS.RANGE", "TS.REVRANGE", "TS.MRANGE", "TS.MREVRANGE"], isDefault: true),
        Entry(kind: .geoMap, commands: ["GEOPOS"], isDefault: true),
        Entry(kind: .geoMap, commands: geoSearchCommands, isDefault: true, requires: hasWithCoord),
        Entry(kind: .geoHeatmap, commands: geoSearchCommands, isDefault: false, requires: hasWithCoord),
        Entry(kind: .geoTable, commands: geoSearchCommands + ["GEOADD", "GEODIST", "GEOHASH", "GEOSEARCHSTORE"],
              isDefault: true),
        Entry(kind: .geoTable, commands: ["GEOPOS"], isDefault: false),
    ]

    /// `command` starts with `name` (case-insensitive, after leading whitespace) followed by whitespace or the end.
    public static func matches(_ command: String, name: String) -> Bool {
        let upper = normalized(command)
        guard upper.hasPrefix(name) else { return false }
        let rest = upper.dropFirst(name.count)
        return rest.first.map { $0 == " " } ?? true
    }

    static func normalized(_ command: String) -> String {
        let trimmed = command.drop { $0.isWhitespace }
        let scanned = String(trimmed.prefix(20_000)).uppercased()
        return scanned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    /// `Text` first, then every matching visualization (no duplicates).
    public static func options(for command: String) -> [WorkbenchViewKind] {
        var out: [WorkbenchViewKind] = [.text]
        let upper = normalized(command)
        for entry in entries where entry.commands.contains(where: { matches(command, name: $0) }) {
            if let requires = entry.requires, !requires(upper) { continue }
            if !out.contains(entry.kind) { out.append(entry.kind) }
        }

        return out
    }

    public static func defaultView(for command: String) -> WorkbenchViewKind {
        let upper = normalized(command)
        for entry in entries where entry.isDefault && entry.commands.contains(where: { matches(command, name: $0) }) {
            if let requires = entry.requires, !requires(upper) { continue }
            return entry.kind
        }

        return .text
    }
}
