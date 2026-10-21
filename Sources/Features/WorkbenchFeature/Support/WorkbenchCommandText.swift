import Foundation
import RedisCore

/// Raw-text helpers over a Workbench command line (quote-aware, original text preserved).
public enum WorkbenchCommandText {
    /// Quote-aware tokens with their source text (quotes kept), e.g. `FT.SEARCH 'idx' "a b"` -> 3 tokens.
    public static func rawTokens(_ command: String) -> [(text: String, raw: String)] {
        let ns = command as NSString
        return CommandLineTokenizer.tokenize(command).tokens.map { token in
            (token.text, ns.substring(with: token.range))
        }
    }

    /// Unquoted token values.
    public static func words(_ command: String) -> [String] {
        CommandLineTokenizer.tokenize(command).tokens.map(\.text)
    }

    /// Uppercased command name (two words for container commands like `CLIENT LIST`).
    public static func commandName(_ command: String, catalog: CommandCatalog = .shared) -> String {
        let words = words(command)
        guard let first = words.first?.uppercased() else { return "" }
        if words.count > 1, catalog.spec(named: "\(first) \(words[1].uppercased())") != nil {
            return "\(first) \(words[1].uppercased())"
        }

        return first
    }

    /// `FT.EXPLAIN {tokens[1...]}` for a FT.SEARCH / FT.AGGREGATE card.
    public static func explainCommand(for command: String) -> String? {
        let tokens = rawTokens(command)
        guard tokens.count >= 3, isSearchOrAggregate(tokens[0].text) else { return nil }
        return (["FT.EXPLAIN"] + tokens.dropFirst().map(\.raw)).joined(separator: " ")
    }

    /// `FT.PROFILE {index} SEARCH|AGGREGATE QUERY {tokens[2...]}`.
    public static func profileCommand(for command: String) -> String? {
        let tokens = rawTokens(command)
        guard tokens.count >= 3, isSearchOrAggregate(tokens[0].text) else { return nil }
        let kind = tokens[0].text.uppercased() == "FT.SEARCH" ? "SEARCH" : "AGGREGATE"
        return (["FT.PROFILE", tokens[1].raw, kind, "QUERY"] + tokens.dropFirst(2).map(\.raw)).joined(separator: " ")
    }

    public static func isSearchOrAggregate(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper == "FT.SEARCH" || upper == "FT.AGGREGATE"
    }

    /// Index argument of FT commands that take one (`FT.SEARCH idx ...`), when it is complete.
    public static let indexCommands: Set<String> = [
        "FT.SEARCH", "FT.AGGREGATE", "FT.EXPLAIN", "FT.EXPLAINCLI", "FT.PROFILE", "FT.SPELLCHECK", "FT.TAGVALS",
        "FT.ALTER", "FT.INFO", "FT.DROPINDEX", "FT.CURSOR",
    ]

    public static func indexName(in command: String) -> String? {
        let line = CommandLineTokenizer.tokenize(command)
        var tokens = line.tokens
        if let first = tokens.first, Int(first.text) != nil { tokens.removeFirst() }
        guard tokens.count >= 2, indexCommands.contains(tokens[0].text.uppercased()) else { return nil }
        if tokens[0].text.uppercased() == "FT.CURSOR" {
            guard tokens.count >= 3 else { return nil }
            let index = tokens[2]
            return index.isTerminated && (tokens.count > 3 || line.endsWithSeparator) ? index.text : nil
        }

        let index = tokens[1]
        guard index.isTerminated, tokens.count > 2 || line.endsWithSeparator else { return nil }
        return index.text
    }

    /// Uppercased dangerous verbs of parsed commands, judged on the arguments that will be sent.
    public static func dangerousVerbs(in commands: [String], serverList: Set<String>,
                                      catalog: CommandCatalog = .shared) -> [String] {
        DangerousCommandClassifier(serverList: serverList, catalog: catalog)
            .dangerousVerbs(in: commands.compactMap(WorkbenchScriptParser.arguments(of:)))
    }

    /// `FLUSHDB` / `FLUSHALL` verbs in a script (RediSearch drops every index on any flush).
    public static func flushVerbs(in commands: [String]) -> [String] {
        DangerousCommandClassifier.flushVerbs(in: commands.compactMap(WorkbenchScriptParser.arguments(of:)))
    }

    static let dangerousActionPrefix = "dangerous:"

    /// Skip-for-session action id of a confirmation covering `verbs` (`dangerous:KEYS` or `dangerous:KEYS,FLUSHDB`).
    public static func dangerousActionID(verbs: [String]) -> String {
        dangerousActionPrefix + verbs.joined(separator: ",")
    }

    /// Verbs skipped for the session: every verb of every `dangerous:` action id, so confirming a multi-verb run
    /// with "Don't ask again" skips each of its verbs on later runs.
    public static func skippedDangerousVerbs(_ actionIDs: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for id in actionIDs where id.hasPrefix(dangerousActionPrefix) {
            for verb in id.dropFirst(dangerousActionPrefix.count).split(separator: ",") {
                out.insert(verb.uppercased())
            }
        }

        return out
    }
}
