import Foundation
import RedisUI

/// Pending "FLUSHDB / FLUSHALL drops every search index" confirmation on the query page.
struct QueryFlushWarning: Identifiable, Hashable {
    let id = UUID()
    var verbs: [String]
    var message: String
}

enum QuerySafety {
    /// Upper bound of commands one run may expand to (`N COMMAND` repeat prefixes included).
    static let maxCommands = 10_000

    static func tooManyCommandsMessage(_ count: Int) -> String {
        "This run expands to \(NumberFormatting.grouped(count)) commands. "
            + "Run at most \(NumberFormatting.grouped(maxCommands)) commands at once."
    }

    /// Uppercased dangerous verbs of parsed commands, judged on the arguments that will be sent.
    static func dangerousVerbs(in commands: [String], serverList: Set<String>,
                               catalog: CommandCatalog = .shared) -> [String] {
        DangerousCommandClassifier(serverList: serverList, catalog: catalog)
            .dangerousVerbs(in: commands.compactMap(WorkbenchScriptParser.arguments(of:)))
    }

    /// `FLUSHDB` / `FLUSHALL` verbs in script order (RediSearch drops every index on any flush).
    static func flushVerbs(in commands: [String]) -> [String] {
        DangerousCommandClassifier.flushVerbs(in: commands.compactMap(WorkbenchScriptParser.arguments(of:)))
    }

    static func dangerousMessage(verbs: [String], databaseName: String) -> String {
        CommandWarnings.dangerousMessage(verbs, databaseName: databaseName)
    }

    static func flushMessage(verbs: [String], hasSearch: Bool) -> String {
        CommandWarnings.flushMessage(verbs: verbs, mayDropIndexes: hasSearch) ?? ""
    }

    @MainActor
    static func indexCreationBlockedReason(_ session: DatabaseSession) -> String? {
        guard session.capabilities.searchIndexesRequireDB0, session.effectiveDB != 0 else { return nil }
        return VectorSearchStrings.wrongDatabaseReason
    }
}
