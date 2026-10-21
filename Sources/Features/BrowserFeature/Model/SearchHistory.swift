import Foundation
import RedisCore

/// Per-database search history rules: max 10 per mode, newest first, deduplicated by (match, type), `*` never saved.
public enum SearchHistory {
    public static let maxPerMode = 10

    public static func adding(_ item: SearchHistoryItem, to history: [SearchHistoryItem]) -> [SearchHistoryItem] {
        let match = item.match.trimmingCharacters(in: .whitespaces)
        guard !match.isEmpty, match != "*" else { return history }
        var entry = item
        entry.match = match
        var sameMode = history.filter { $0.mode == item.mode }
        let others = history.filter { $0.mode != item.mode }
        sameMode.removeAll { $0.match == match && $0.type == item.type }
        sameMode.insert(entry, at: 0)
        return Array(sameMode.prefix(maxPerMode)) + others
    }

    public static func items(_ history: [SearchHistoryItem], mode: SearchMode) -> [SearchHistoryItem] {
        history.filter { $0.mode == mode }
    }

    public static func removing(id: UUID, from history: [SearchHistoryItem]) -> [SearchHistoryItem] {
        history.filter { $0.id != id }
    }

    public static func clearing(mode: SearchMode, in history: [SearchHistoryItem]) -> [SearchHistoryItem] {
        history.filter { $0.mode != mode }
    }
}
