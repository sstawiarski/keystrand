import Foundation

/// Confirmation text for dangerous and flush commands.
public enum CommandWarnings {
    public static let flushIndexLossWarning = "Redis Search also drops every search index on the server when any "
        + "database is flushed, including indexes in other logical databases."

    /// Production type-to-confirm text. `subjects` are the dangerous verbs of a script, or one full command line.
    public static func dangerousMessage(_ subjects: [String], databaseName: String,
                                        extraWarning: String? = nil) -> String {
        let list = subjects.joined(separator: ", ")
        var message = subjects.count > 1
            ? "\(list) are flagged as dangerous commands. Running them on \(databaseName) can slow down or "
                + "destabilize the server."
            : "\(list) is flagged as a dangerous command. Running it on \(databaseName) can slow down or "
                + "destabilize the server."
        if let extraWarning { message += "\n\n" + extraWarning }
        return message
    }

    /// Warns before uppercased `FLUSHDB` or `FLUSHALL` verbs; returns nil for an empty list.
    /// `mayDropIndexes` adds the search index warning.
    public static func flushMessage(verbs: [String], mayDropIndexes: Bool) -> String? {
        guard !verbs.isEmpty else { return nil }
        var message = "\(verbs.joined(separator: " and ")) deletes every key in "
            + (verbs.contains("FLUSHALL") ? "every logical database of this server." : "the current logical database.")
        if mayDropIndexes { message += " " + flushIndexLossWarning }
        return message
    }

    /// True when Redis Search is loaded, or when the module list is unknown (empty: not loaded yet or denied).
    public static func flushMayDropIndexes(modules: [String]) -> Bool {
        modules.isEmpty || CommandModuleRequirement.search.isSatisfied(by: modules)
    }
}
