import Foundation
import Observation
import RedisCore

/// Validation rules of the Manage Tags sheet.
public enum TagValidation {
    public static let charactersMessage =
        "Use only letters, digits, spaces, and - _ . + @ : in tags."
    public static let keyLengthMessage = "Keys can have at most 64 characters"
    public static let valueLengthMessage = "Values can have at most 128 characters"
    public static let uniqueKeyMessage = "Each key can appear only once"

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.@:+ ")

    /// Lowercases input and strips leading spaces.
    public static func sanitizeInput(_ text: String) -> String {
        var lowered = text.lowercased()
        while lowered.hasPrefix(" ") { lowered.removeFirst() }
        return lowered
    }

    public static func keyError(_ key: String, otherKeys: [String]) -> String? {
        guard !key.isEmpty else { return nil }
        if key.count > 64 { return keyLengthMessage }
        if !isAllowed(key) { return charactersMessage }
        if otherKeys.contains(key) { return uniqueKeyMessage }
        return nil
    }

    public static func valueError(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        if value.count > 128 { return valueLengthMessage }
        if !isAllowed(value) { return charactersMessage }
        return nil
    }

    static func isAllowed(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Preset suggestions shown alongside the existing tags.
    public static let presets: [DatabaseTag] = [
        DatabaseTag(key: "environment", value: "production"),
        DatabaseTag(key: "environment", value: "staging"),
        DatabaseTag(key: "environment", value: "qa"),
        DatabaseTag(key: "application", value: ""),
        DatabaseTag(key: "product", value: ""),
        DatabaseTag(key: "team", value: ""),
        DatabaseTag(key: "owner", value: ""),
    ]
}

/// State of the Manage Tags sheet for one database.
@MainActor
@Observable
public final class TagEditorModel {
    public struct Row: Identifiable, Hashable {
        public let id: UUID
        public var key: String
        public var value: String

        public init(id: UUID = UUID(), key: String = "", value: String = "") {
            self.id = id
            self.key = key
            self.value = value
        }
    }

    public let databaseName: String
    public private(set) var original: [DatabaseTag]
    public var rows: [Row]
    /// Every tag used by any database (suggestions).
    public var knownTags: [DatabaseTag]

    public init(databaseName: String, tags: [DatabaseTag], knownTags: [DatabaseTag] = []) {
        self.databaseName = databaseName
        self.original = tags
        self.rows = tags.isEmpty ? [Row()] : tags.map { Row(key: $0.key, value: $0.value) }
        self.knownTags = knownTags
    }

    public func addRow() {
        rows.append(Row())
    }

    public func removeRow(_ id: UUID) {
        rows.removeAll { $0.id == id }
        if rows.isEmpty { rows.append(Row()) }
    }

    public func setKey(_ key: String, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].key = TagValidation.sanitizeInput(key)
    }

    public func setValue(_ value: String, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].value = TagValidation.sanitizeInput(value)
    }

    public func keyError(for row: Row) -> String? {
        let others = rows.filter { $0.id != row.id }.map(\.key)
        return TagValidation.keyError(row.key, otherKeys: others)
    }

    public func valueError(for row: Row) -> String? {
        TagValidation.valueError(row.value)
    }

    /// Value field is disabled until the key is non-empty and valid.
    public func isValueEnabled(_ row: Row) -> Bool {
        !row.key.isEmpty && keyError(for: row) == nil
    }

    /// Tags to save: rows with an empty key or value are dropped.
    public var resultTags: [DatabaseTag] {
        rows.filter { !$0.key.isEmpty && !$0.value.isEmpty }.map { DatabaseTag(key: $0.key, value: $0.value) }
    }

    public var isValid: Bool {
        rows.allSatisfy { keyError(for: $0) == nil && valueError(for: $0) == nil }
    }

    public var isModified: Bool {
        resultTags != original
    }

    public var canSave: Bool { isValid && isModified }

    // MARK: - Suggestions

    private var suggestionPool: [DatabaseTag] {
        var seen = Set<DatabaseTag>()
        return (TagValidation.presets + knownTags).filter { seen.insert($0).inserted }
    }

    /// Keys not yet used by another row, filtered by the typed text.
    public func keySuggestions(for row: Row) -> [String] {
        let used = Set(rows.filter { $0.id != row.id }.map(\.key))
        var seen = Set<String>()
        let keys = suggestionPool.map(\.key).filter { !used.contains($0) && seen.insert($0).inserted }
        guard !row.key.isEmpty else { return keys }
        return keys.filter { $0.contains(row.key) && $0 != row.key }
    }

    /// Values known for the row's key, filtered by the typed text.
    public func valueSuggestions(for row: Row) -> [String] {
        var seen = Set<String>()
        let values = suggestionPool.filter { $0.key == row.key && !$0.value.isEmpty }.map(\.value)
            .filter { seen.insert($0).inserted }
        guard !row.value.isEmpty else { return values }
        return values.filter { $0.contains(row.value) && $0 != row.value }
    }
}
