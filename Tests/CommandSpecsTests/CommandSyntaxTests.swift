import CommandSpecs
import Foundation
import Testing

struct CommandSyntaxTests {
    let catalog = CommandCatalog.shared

    @Test func rendersCoreCommands() throws {
        let hset = try #require(catalog.spec(named: "HSET"))
        #expect(CommandSyntax.render(hset) == "HSET key data [data ...]" || CommandSyntax.render(hset) == "HSET key field value [field value ...]")
        let set = try #require(catalog.spec(named: "SET"))
        let rendered = CommandSyntax.render(set)
        #expect(rendered.hasPrefix("SET key value [NX | XX]"))
        #expect(rendered.contains("[GET]"))
        #expect(rendered.contains("EX seconds | PX milliseconds"))
        let del = try #require(catalog.spec(named: "DEL"))
        #expect(CommandSyntax.render(del) == "DEL key [key ...]")
    }

    @Test func rendersZAddAndClientKill() throws {
        let zadd = try #require(catalog.spec(named: "ZADD"))
        #expect(CommandSyntax.render(zadd) == "ZADD key [NX | XX] [GT | LT] [CH] [INCR] score member [score member ...]")
        let kill = try #require(catalog.spec(named: "client kill"))
        #expect(CommandSyntax.render(kill).hasPrefix("CLIENT KILL "))
    }

    @Test func pureNameDropsRepetition() {
        let arg = CommandArgument(name: "key", type: .key, multiple: true)
        #expect(CommandSyntax.syntax(arg) == "key [key ...]")
        #expect(CommandSyntax.syntax(arg, pureName: true) == "key")
        let tokenRepeat = CommandArgument(name: "pattern", type: .pattern, token: "GET", optional: true,
                                          multiple: true, multipleToken: true)
        #expect(CommandSyntax.syntax(tokenRepeat) == "[GET pattern [GET pattern ...]]")
        let onlyMandatory = CommandArgument(name: "x", type: .string, optional: true)
        #expect(CommandSyntax.syntax(onlyMandatory, onlyMandatory: true) == "")
        let emptyToken = CommandArgument(name: "v", type: .string, token: "")
        #expect(CommandSyntax.syntax(emptyToken) == "\"\" v")
        let enumArg = CommandArgument(name: "e", type: .enumeration, enumValues: ["A", "B"])
        #expect(CommandSyntax.syntax(enumArg) == "A | B")
    }

    @Test func helpers() throws {
        #expect(CommandSyntax.complexityShortNotation("O(1)") == "O(1)")
        #expect(CommandSyntax.complexityShortNotation("Depends on subcommand.") == "")
        #expect(CommandSyntax.docURL(for: "CLIENT LIST")?.absoluteString == "https://redis.io/docs/latest/commands/client-list/")
        #expect(CommandSyntax.kindLabel(CommandArgument(name: "k", type: .key, optional: true, multiple: true)) == "Multiple")
        #expect(CommandSyntax.kindLabel(CommandArgument(name: "k", type: .key, optional: true)) == "Optional")
        #expect(CommandSyntax.kindLabel(CommandArgument(name: "k", type: .key)) == "Required")
        let get = try #require(catalog.spec(named: "GET"))
        let doc = CommandSyntax.markdownDocumentation(get)
        #expect(doc.contains("[Read more](https://redis.io/docs/latest/commands/get/)"))
        #expect(doc.contains("_Required_ `key`"))
    }

    @Test func groupsAndContainers() {
        #expect(CommandGroups.displayName("sorted-set") == "Sorted Set")
        #expect(CommandGroups.displayName("bf") == "Bloom Filter")
        #expect(CommandGroups.displayName("some_group") == "Some group")
        #expect(!catalog.visibleGroups.contains("graph"))
        #expect(catalog.visibleGroups.contains("string"))
        #expect(catalog.isContainer("client"))
        #expect(catalog.subcommands(of: "CLIENT").contains { $0.name == "CLIENT LIST" })
        #expect(catalog.containerCommands.contains("CONFIG"))
        #expect(catalog.commands(inGroup: "hash").contains { $0.name == "HSET" })
    }

    @Test func searchesAndFilters() {
        let results = catalog.search(containing: "list")
        #expect(results.contains { $0.name == "CLIENT LIST" })
        #expect(!results.contains { $0.name.hasPrefix("GRAPH.") })
        #expect(catalog.search(containing: "GRAPH.QUERY").isEmpty)
        #expect(catalog.search(containing: "", group: "hash").allSatisfy { $0.group == "hash" })
        #expect(catalog.search(prefix: "hge").map(\.name) == ["HGET", "HGETALL", "HGETDEL", "HGETEX"].filter { catalog.spec(named: $0) != nil })
        let core = catalog.available(CommandAvailability(modules: []))
        #expect(!core.contains { $0.name.hasPrefix("FT.") })
        let withSearch = catalog.available(CommandAvailability(modules: ["search", "ReJSON"]))
        #expect(withSearch.contains { $0.name == "FT.SEARCH" })
        #expect(withSearch.contains { $0.name == "JSON.GET" })
        #expect(!withSearch.contains { $0.name == "TS.ADD" })
        #expect(catalog.dangerousCommandNames.contains("FLUSHALL"))
        #expect(catalog.match(line: "client   list  ")?.name == "CLIENT LIST")
    }

    @Test func orderingPutsSearchCommandsFirst() {
        let ft = catalog.search(prefix: "FT.")
        let ordered = catalog.completionOrder(ft).map(\.name)
        #expect(Array(ordered.prefix(5)) == ["FT.SEARCH", "FT.AGGREGATE", "FT.CREATE", "FT.EXPLAIN", "FT.PROFILE"])
    }
}

struct CommandRulesTests {
    @Test func unsupportedMatching() {
        #expect(CommandRules.cliUnsupportedMatch("  MONITOR") == "monitor")
        #expect(CommandRules.cliUnsupportedMatch("hello 3") == "hello 3")
        #expect(CommandRules.cliUnsupportedMatch("hello 2") == nil)
        #expect(CommandRules.cliUnsupportedMatch("GET k") == nil)
        #expect(CommandRules.workbenchUnsupportedMatch("select 1") == "select")
        #expect(CommandRules.workbenchUnsupportedMatch("BLPOP list 0") == "blpop")
        #expect(CommandRules.isBlocking("xread streams s 0"))
        #expect(CommandRules.workbenchErrorMessage("blpop") ==
                "BLPOP can't be run from Workbench.")
        #expect(CommandRules.cliUnsupportedMessage("sync").hasPrefix("sync can't be run from the CLI. Commands the CLI doesn't run: subscribe, psubscribe"))
        #expect(CommandRules.guidance(for: "monitor") == .monitor)
        #expect(CommandRules.guidance(for: "SSUBSCRIBE ch") == .subscribe)
        #expect(CommandRules.guidance(for: "psubscribe *") == .psubscribe)
        #expect(CommandRules.guidance(for: "HELLO 3") == .resp3)
        #expect(CommandRules.guidance(for: "HELLO") == nil)
    }

    @Test func argumentOverloadsCatchQuotedVerbs() {
        #expect(CommandRules.canonicalLine(["SELECT", "3"]) == "SELECT 3")
        #expect(CommandRules.workbenchUnsupportedMatch(#""SELECT" 3"#) == nil)
        #expect(CommandRules.workbenchUnsupportedMatch(#""SELECT" 3"#, arguments: ["SELECT", "3"]) == "select")
        #expect(CommandRules.workbenchUnsupportedMatch(#""BLPOP" k 0"#, arguments: ["BLPOP", "k", "0"]) == "blpop")
        #expect(CommandRules.isBlocking(#""BLPOP" k 0"#, arguments: ["BLPOP", "k", "0"]))
        #expect(CommandRules.cliUnsupportedMatch(#""SYNC""#, arguments: ["SYNC"]) == "sync")
        #expect(CommandRules.guidance(for: #""MONITOR""#, arguments: ["MONITOR"]) == .monitor)
        #expect(CommandRules.guidance(for: #"hello "3""#, arguments: ["hello", "3"]) == .resp3)
        #expect(CommandRules.guidance(for: "monitor", arguments: []) == .monitor)
        #expect(CommandRules.workbenchUnsupportedMatch(#"GET "select""#, arguments: ["GET", "select"]) == nil)
        #expect(!CommandRules.isBlocking(#"GET "blpop""#, arguments: ["GET", "blpop"]))
        #expect(CommandRules.workbenchUnsupportedMatch(#""SELECT"#, arguments: []) == nil)
    }

    @Test func moduleRequirements() {
        let req = CommandModuleRequirement.requirement(for: "ft.search idx *")
        #expect(req == .search)
        #expect(req?.isSatisfied(by: ["search"]) == true)
        #expect(req?.isSatisfied(by: ["ReJSON"]) == false)
        #expect(CommandModuleRequirement.requirement(for: "JSON.GET k")?.isSatisfied(by: ["ReJSON"]) == true)
        #expect(CommandModuleRequirement.requirement(for: "TOPK.ADD k a") == .probabilistic)
        #expect(CommandModuleRequirement.requirement(for: "GET k") == nil)
    }
}
