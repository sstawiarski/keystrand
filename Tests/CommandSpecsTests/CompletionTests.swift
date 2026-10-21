import CommandSpecs
import Foundation
import Testing

struct ArgumentWalkerTests {
    let catalog = CommandCatalog.shared

    func walk(_ line: String) throws -> ArgumentWalkResult {
        let words = line.split(separator: " ").map(String.init)
        let spec = try #require(catalog.match(tokens: words))
        let nameWords = catalog.wordCount(of: spec)
        return ArgumentWalker.walk(spec.arguments, tokens: Array(words.dropFirst(nameWords)))
    }

    @Test func setOptionsAfterValue() throws {
        let afterKey = try walk("SET k")
        #expect(afterKey.expected?.name == "value")
        #expect(afterKey.activeTopLevelIndex == 1)
        #expect(!afterKey.isSatisfied)

        let afterValue = try walk("SET k v")
        #expect(afterValue.isSatisfied)
        let keywords = afterValue.keywordSuggestions
        #expect(keywords.contains("NX"))
        #expect(keywords.contains("EX"))
        #expect(keywords.contains("KEEPTTL"))

        let afterEX = try walk("SET k v EX")
        #expect(afterEX.expected?.name == "seconds")
        #expect(!afterEX.isSatisfied)

        let afterEXValue = try walk("SET k v EX 10")
        #expect(afterEXValue.isSatisfied)
        #expect(afterEXValue.keywordSuggestions.contains("NX"))
        #expect(!afterEXValue.keywordSuggestions.contains("EX"))

        let outOfOrder = try walk("SET k v EX 10 NX")
        #expect(outOfOrder.isSatisfied)
        #expect(!outOfOrder.keywordSuggestions.contains("NX"))
    }

    @Test func repeatsMultipleArguments() throws {
        let del = try walk("DEL a b c")
        #expect(del.isSatisfied)
        #expect(del.candidates.contains { $0.name == "key" })

        let zadd = try walk("ZADD z NX")
        #expect(zadd.expected?.type == .block)
        #expect(zadd.keywordSuggestions.contains("GT"))
        let zaddDone = try walk("ZADD z 1 a 2 b")
        #expect(zaddDone.isSatisfied)
    }

    @Test func countedArgumentsInSearch() throws {
        let spec = try #require(catalog.spec(named: "FT.CREATE"))
        let r = ArgumentWalker.walk(spec.arguments, tokens: ["idx", "ON", "HASH", "PREFIX", "2", "a:", "b:"])
        #expect(r.keywordSuggestions.contains("SCHEMA"))
        #expect(!r.isSatisfied)
        let inPrefix = ArgumentWalker.walk(spec.arguments, tokens: ["idx", "ON", "HASH", "PREFIX", "2", "a:"])
        #expect(inPrefix.expected?.name == "prefix")
        let onKeyword = ArgumentWalker.walk(spec.arguments, tokens: ["idx", "ON"])
        #expect(Set(onKeyword.keywordSuggestions) == ["HASH", "JSON"])
    }

    @Test func searchQueryPositions() throws {
        let spec = try #require(catalog.spec(named: "FT.SEARCH"))
        #expect(ArgumentWalker.walk(spec.arguments, tokens: []).expected?.name == "index")
        #expect(ArgumentWalker.walk(spec.arguments, tokens: ["idx"]).expected?.name == "query")
        let after = ArgumentWalker.walk(spec.arguments, tokens: ["idx", "*"])
        #expect(after.isSatisfied)
        #expect(after.keywordSuggestions.contains("NOCONTENT"))
        #expect(after.keywordSuggestions.contains("LIMIT"))
        let limit = ArgumentWalker.walk(spec.arguments, tokens: ["idx", "*", "LIMIT", "0"])
        #expect(!limit.isSatisfied)
        let afterLimit = ArgumentWalker.walk(spec.arguments, tokens: ["idx", "*", "LIMIT", "0", "10"])
        #expect(afterLimit.isSatisfied)
        #expect(afterLimit.keywordSuggestions.contains("SORTBY"))
    }

    @Test func noArgumentsCommand() throws {
        let r = try walk("PING")
        #expect(r.isSatisfied)
        let dbsize = try walk("DBSIZE")
        #expect(dbsize.candidates.isEmpty)
    }
}

struct CompletionEngineTests {
    let engine = CompletionEngine()

    func complete(_ text: String, context: CompletionContext = CompletionContext()) -> CompletionResult {
        engine.complete(text: text, cursorOffset: (text as NSString).length, context: context)
    }

    @Test func commandNames() {
        let r = complete("hge")
        #expect(r.items.first?.label == "HGET")
        #expect(r.items.first?.insertText == "HGET ")
        #expect(r.items.allSatisfy { $0.kind == .command && $0.label.hasPrefix("HGE") })
        #expect(r.items.first?.documentation?.contains("Read more") == true)
        let ft = complete("FT.")
        #expect(ft.items.first?.label == "FT.SEARCH")
        let modules = complete("JSON.", context: CompletionContext(availability: CommandAvailability(modules: [])))
        #expect(modules.items.isEmpty)
    }

    @Test func subcommandsAndKeywords() {
        let sub = complete("CLIENT LI")
        #expect(sub.items.contains { $0.label == "LIST" })
        let kw = complete("SET key value e")
        #expect(kw.items.map(\.label).contains("EX"))
        #expect(kw.items.first { $0.label == "EX" }?.insertText == "EX ")
        #expect(kw.signature?.label.hasPrefix("SET key value") == true)
        let pure = complete("SET key value N")
        #expect(pure.items.first { $0.label == "NX" }?.insertText == "NX")
    }

    @Test func signatureHighlightsCurrentArgument() throws {
        let r = complete("SET mykey ")
        let sig = try #require(r.signature)
        let highlight = try #require(sig.highlight)
        #expect((sig.label as NSString).substring(with: highlight) == "value")
    }

    @Test func searchIndexesAndFields() {
        let ctx = CompletionContext(indexes: ["idx:gear", "idx:films"],
                                    fields: [SearchFieldSuggestion(name: "brand", type: "TAG"),
                                             SearchFieldSuggestion(name: "price", type: "NUMERIC")])
        let indexes = complete("FT.SEARCH idx:g", context: ctx)
        #expect(indexes.items.map(\.label) == ["idx:gear"])
        #expect(indexes.items.first?.insertText == "'idx:gear' '${1:query to search}'")
        let noIndexes = complete("FT.SEARCH ", context: CompletionContext())
        #expect(noIndexes.needsIndexes)
        let fields = complete("FT.SEARCH idx:gear '@br", context: ctx)
        #expect(fields.items.map(\.label) == ["@brand"])
        #expect(fields.items.first?.insertText == "@brand:{${1:tag}}")
        #expect(CompletionEngine.fieldTemplate(SearchFieldSuggestion(name: "v", type: "vector")) == "@v $${1:vector}")
        let insideQuery = complete("FT.SEARCH idx:gear 'hello wor", context: ctx)
        #expect(insideQuery.items.isEmpty)
        #expect(insideQuery.isInsideQuotes)
    }

    @Test func aggregateApplyTakesOneExpression() throws {
        let apply = complete("FT.AGGREGATE idx * APPLY ")
        #expect(apply.walk?.expected?.name == "expression")
        #expect(apply.walk?.expected?.type == .string)
        #expect(!apply.items.contains { $0.label == "EXISTS" })
        let functions = complete(#"FT.AGGREGATE idx * APPLY "up"#)
        #expect(functions.items.map(\.label) == ["upper"])
        let afterExpression = complete(#"FT.AGGREGATE idx * APPLY "upper(@a)" "#)
        #expect(afterExpression.walk?.expected?.name == "name")
        #expect(afterExpression.items.map(\.label) == ["AS"])
        let signature = try #require(complete("FT.AGGREGATE ").signature?.label)
        #expect(signature.contains("[APPLY expression AS name [APPLY expression AS name ...]]"))
        let aggregate = try #require(CommandCatalog.shared.spec(named: "FT.AGGREGATE"))
        #expect(CommandSyntax.render(aggregate).contains("[APPLY expression AS name"))
    }

    @Test func multilineAndParams() {
        let text = "[pipeline=2]\nFT.CREATE idx\n  ON HASH\n  S"
        let r = complete(text)
        #expect(r.command?.name == "FT.CREATE")
        #expect(r.items.contains { $0.label == "SCHEMA" })
        #expect(CompletionEngine.commandText(in: "GET a\n// comment\nSET k", cursorOffset: 23) == "SET k")
        #expect(CompletionEngine.commandText(in: "[mode=raw]GET k", cursorOffset: 15) == "GET k")
        #expect(complete("SET k v\n// note").items.isEmpty)
    }

    @Test func repeatPrefixIsSkipped() {
        let r = complete("10 INCR ")
        #expect(r.command?.name == "INCR")
    }
}

struct CLIHelpersTests {
    @Test func tabCyclesThroughMatches() {
        var completer = CommandLineCompleter()
        let first = completer.complete("cl")
        #expect(first == "CLIENT")
        let second = completer.complete(first)
        #expect(second.hasPrefix("CLIENT "))
        let back = completer.complete(second, backwards: true)
        #expect(back == "CLIENT")
        let original = completer.complete(back, backwards: true)
        #expect(original == "cl")
        #expect(completer.complete("zzzz") == "zzzz")
        completer.reset()
        #expect(completer.complete("") == "")
    }

    @Test func argumentHint() throws {
        let set = try #require(ArgumentHintCalculator.hint(for: "SET "))
        #expect(set.untyped.hasPrefix("key value"))
        let afterKey = try #require(ArgumentHintCalculator.hint(for: "SET k "))
        #expect(afterKey.untyped.hasPrefix("value [NX | XX]"))
        let optionalOnly = try #require(ArgumentHintCalculator.hint(for: "SET k v NX "))
        #expect(optionalOnly.untyped.hasPrefix("[NX | XX]"))
        let client = try #require(ArgumentHintCalculator.hint(for: "client kill "))
        #expect(client.command.name == "CLIENT KILL")
        #expect(ArgumentHintCalculator.hint(for: "PING x y") == nil || ArgumentHintCalculator.hint(for: "PING")?.untyped == "[message]")
        #expect(ArgumentHintCalculator.hint(for: "nosuchcommand") == nil)
    }

    @Test func tokenizer() {
        let line = CommandLineTokenizer.tokenize(#"SET "a b" 'c\'d' e"#)
        #expect(line.tokens.map(\.text) == ["SET", "a b", "c'd", "e"])
        #expect(!line.endsWithSeparator)
        let open = CommandLineTokenizer.tokenize(#"SET "abc "#)
        #expect(open.hasUnterminatedQuote)
        #expect(!open.endsWithSeparator)
        #expect(CommandLineTokenizer.tokenize("GET k ").endsWithSeparator)
        #expect(CommandLineTokenizer.wordCount(#"SET "a b" c"#) == 3)
        let ranges = CommandLineTokenizer.tokenize("GET  key").tokens.map(\.range)
        #expect(ranges == [NSRange(location: 0, length: 3), NSRange(location: 5, length: 3)])
    }
}
