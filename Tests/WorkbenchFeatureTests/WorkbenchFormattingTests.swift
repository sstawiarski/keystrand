import Foundation
@testable import WorkbenchFeature
import RedisCore
import Testing

struct WorkbenchCommandTextTests {
    @Test func explainAndProfileGeneration() {
        let command = "FT.SEARCH 'idx:gear' \"@brand:{Velorim}\" LIMIT 0 10"
        #expect(WorkbenchCommandText.explainCommand(for: command)
            == "FT.EXPLAIN 'idx:gear' \"@brand:{Velorim}\" LIMIT 0 10")
        #expect(WorkbenchCommandText.profileCommand(for: command)
            == "FT.PROFILE 'idx:gear' SEARCH QUERY \"@brand:{Velorim}\" LIMIT 0 10")
        #expect(WorkbenchCommandText.profileCommand(for: "ft.aggregate idx * GROUPBY 1 @a")
            == "FT.PROFILE idx AGGREGATE QUERY * GROUPBY 1 @a")
        #expect(WorkbenchCommandText.explainCommand(for: "GET foo bar") == nil)
        #expect(WorkbenchCommandText.explainCommand(for: "FT.SEARCH idx") == nil)
    }

    @Test func indexNameRequiresCompleteArgument() {
        #expect(WorkbenchCommandText.indexName(in: "FT.SEARCH idx ") == "idx")
        #expect(WorkbenchCommandText.indexName(in: "FT.SEARCH 'my idx' @a") == "my idx")
        #expect(WorkbenchCommandText.indexName(in: "FT.SEARCH idx") == nil)
        #expect(WorkbenchCommandText.indexName(in: "3 FT.INFO idx ") == "idx")
        #expect(WorkbenchCommandText.indexName(in: "GET idx ") == nil)
    }

    @Test func dangerousVerbsUseServerListThenCatalog() {
        let verbs = WorkbenchCommandText.dangerousVerbs(in: ["FLUSHDB", "get a", "config set x y", "keys *"],
                                                        serverList: ["flushdb", "keys", "config|set"])
        #expect(verbs == ["FLUSHDB", "CONFIG", "KEYS"])
        #expect(WorkbenchCommandText.dangerousVerbs(in: ["GET a"], serverList: ["flushdb"]).isEmpty)
    }

    @Test func dangerousVerbsJudgeTheArgumentsThatAreSent() {
        let server: Set<String> = ["flushdb", "config|set", "acl|setuser", "client|kill"]
        let commands = [#""\x46LUSHDB""#, #"'CONFIG' SET maxmemory 1"#, #"acl "setuser" u"#, "CLIENT\n  KILL ID 1",
                        "CONFIG GET x", "GET a", #"GET "unterminated"#]
        #expect(WorkbenchCommandText.dangerousVerbs(in: commands, serverList: server) == ["FLUSHDB", "CONFIG", "ACL", "CLIENT"])
        #expect(WorkbenchCommandText.dangerousVerbs(in: [#""\x46LUSHALL""#], serverList: []) == ["FLUSHALL"])
    }

    @Test func flushVerbsDetected() {
        #expect(WorkbenchCommandText.flushVerbs(in: ["set a 1", "flushdb", "FLUSHALL ASYNC", "FLUSHDB"])
            == ["FLUSHDB", "FLUSHALL"])
        #expect(WorkbenchCommandText.flushVerbs(in: ["GET flushdb"]).isEmpty)
        #expect(WorkbenchCommandText.flushVerbs(in: [#""\x46LUSHDB""#, #""FLUSHALL" ASYNC"#, "FLUSHDB"])
            == ["FLUSHDB", "FLUSHALL"])
        #expect(WorkbenchCommandText.flushVerbs(in: [#""FLUSHDB"#]).isEmpty)
    }

    @Test func dangerousMessagePlural() {
        let single = CommandWarnings.dangerousMessage(["KEYS"], databaseName: "prod")
        let plural = CommandWarnings.dangerousMessage(["KEYS", "FLUSHDB"], databaseName: "prod")
        #expect(single.hasPrefix("KEYS ") && single.contains("prod"))
        #expect(plural.hasPrefix("KEYS, FLUSHDB ") && plural.contains("prod"))
        #expect(single.replacingOccurrences(of: "KEYS", with: "") != plural.replacingOccurrences(of: "KEYS, FLUSHDB", with: ""))
        #expect(CommandWarnings.dangerousMessage(["KEYS *"], databaseName: "prod", extraWarning: "Careful.")
            == CommandWarnings.dangerousMessage(["KEYS *"], databaseName: "prod") + "\n\nCareful.")
    }

    @Test func changesIndexes() {
        #expect(WorkbenchViewModel.changesIndexes("FT.CREATE idx ON HASH SCHEMA a TEXT"))
        #expect(WorkbenchViewModel.changesIndexes("ft.dropindex idx"))
        #expect(!WorkbenchViewModel.changesIndexes("FT.SEARCH idx *"))
        #expect(WorkbenchViewModel.changesIndexes(#""FT.CREATE" idx ON HASH SCHEMA a TEXT"#))
        #expect(WorkbenchViewModel.changesIndexes(#""\x46LUSHALL""#))
    }
}

struct WorkbenchResultFormatterTests {
    @Test func titleAddsDBPrefix() {
        #expect(WorkbenchResultFormatter.title(command: "GET foo", db: 0) == "GET foo")
        #expect(WorkbenchResultFormatter.title(command: "GET foo", db: 3) == "[db3] GET foo")
        #expect(WorkbenchResultFormatter.title(command: "FT.CREATE idx\n  SCHEMA a TEXT", db: nil)
            == "FT.CREATE idx   SCHEMA a TEXT")
    }

    @Test func tooltipNumbersAndTruncates() {
        let long = String(repeating: "x", count: 600)
        let tip = WorkbenchResultFormatter.commandTooltip("a\n\(long)")
        #expect(tip.hasPrefix("1. a\n2. xxx"))
        #expect(tip.hasSuffix("…"))
        let many = (1...25).map { "l\($0)" }.joined(separator: "\n")
        let lines = WorkbenchResultFormatter.commandTooltip(many).components(separatedBy: "\n")
        #expect(lines.count == 20)
        #expect(lines[18] == "…")
        #expect(lines[19] == "25. l25")
    }

    @Test func summaryText() {
        let summary = ResultsSummary(total: 3, success: 2, fail: 1)
        #expect(WorkbenchResultFormatter.summaryText(summary, resultsMode: .group, commandCount: 3, isRunning: false)
            == "3 Command(s) - 2 success, 1 error(s)")
        let clean = ResultsSummary(total: 2, success: 2, fail: 0)
        #expect(WorkbenchResultFormatter.summaryText(clean, resultsMode: .silent, commandCount: 2, isRunning: false)
            == "2 Command(s) - 2 success")
        #expect(WorkbenchResultFormatter.summaryText(nil, resultsMode: .group, commandCount: 4, isRunning: true)
            == "4 - Command(s)")
    }

    @Test func timeLabels() {
        #expect(WorkbenchResultFormatter.timeLabel(microseconds: 0) == "0.001 msec")
        #expect(WorkbenchResultFormatter.timeLabel(microseconds: 240) == "0.24 msec")
        #expect(WorkbenchResultFormatter.timeLabel(microseconds: 12_000) == "12 msec")
        #expect(WorkbenchResultFormatter.timeLabel(microseconds: 2_500_000) == "2 s")
        #expect(WorkbenchResultFormatter.timeLabel(microseconds: 180_000_000) == "3 min")
        #expect(WorkbenchResultFormatter.timeTooltip(microseconds: 1_234_567) == "Processing Time: 1,234.567 msec")
    }

    @Test func groupLinesEchoCommands() {
        let items = [
            GroupItemResult(command: "SET a 1", response: .string("OK"), status: .success),
            GroupItemResult(command: "INCR b c", response: .error("ERR wrong number of arguments"), status: .fail),
            GroupItemResult(command: "MONITOR", response: .error("x"), status: .fail),
        ]
        let execution = CommandExecution(databaseId: DatabaseID(), command: "SET a 1\r\nINCR b c\r\nMONITOR",
                                         resultsMode: .group,
                                         result: [CommandExecutionResult(status: .success, response: .group(items))],
                                         db: 2)
        let lines = WorkbenchResultFormatter.lines(for: execution)
        #expect(lines.first == ResultLine("[db2] > SET a 1", style: .command))
        #expect(lines.contains(ResultLine("\"OK\"")))
        #expect(lines.contains(ResultLine("ERR wrong number of arguments", style: .error)))
        #expect(lines.contains { $0.style == .notice && $0.text.contains("Profiler") })
    }

    @Test func emptyStringRendersNil() {
        let execution = CommandExecution(databaseId: DatabaseID(), command: "GET missing",
                                         result: [CommandExecutionResult(status: .success, response: .reply(.string("")))])
        #expect(WorkbenchResultFormatter.lines(for: execution).map(\.text) == ["(nil)"])
    }

    @Test func longLinesAreCutForDisplayOnly() {
        let big = String(repeating: "a", count: WorkbenchResultFormatter.maxDisplayLineLength + 10)
        let execution = CommandExecution(databaseId: DatabaseID(), command: "GET big",
                                         result: [CommandExecutionResult(status: .success, response: .reply(.string(big)))])
        let shown = WorkbenchResultFormatter.lines(for: execution)
        #expect(shown[0].text.contains("more characters"))
        #expect(WorkbenchResultFormatter.copyText(for: execution).count == big.count + 2)
    }

    @Test func specialMessages() {
        #expect(WorkbenchResultFormatter.specialMessage(for: "subscribe ch") != nil)
        #expect(WorkbenchResultFormatter.specialMessage(for: "BLPOP list 0") == CommandRules.workbenchUnsupportedMessage("BLPOP"))
        #expect(WorkbenchResultFormatter.specialMessage(for: "GET k") == nil)
        #expect(WorkbenchResultFormatter.specialMessage(for: #""SELECT" 3"#) == CommandRules.workbenchUnsupportedMessage("SELECT"))
        #expect(WorkbenchResultFormatter.specialMessage(for: #""BLPOP" k 0"#) == CommandRules.workbenchUnsupportedMessage("BLPOP"))
        #expect(WorkbenchResultFormatter.specialMessage(for: #""SUBSCRIBE" ch"#) == CommandRules.Guidance.subscribe.message)
        #expect(WorkbenchResultFormatter.specialMessage(for: #"GET "select""#) == nil)
    }

    @MainActor @Test func cardNoticeFollowsItsCommand() {
        let card = WorkbenchCard(execution: CommandExecution(databaseId: DatabaseID(), command: "subscribe ch"),
                                 isOpen: true, isRunning: false, isPersisted: true)
        guard case .guidance(.subscribe)? = card.notice else {
            Issue.record("expected the subscribe guidance")
            return
        }
        card.execution.command = #""BLPOP" k 0"#
        guard case .unsupported(let message)? = card.notice else {
            Issue.record("expected the unsupported message")
            return
        }
        #expect(message == CommandRules.workbenchUnsupportedMessage("BLPOP"))
        card.execution.command = "GET k"
        #expect(card.notice == nil)
    }

    @Test func parameterTags() {
        #expect(WorkbenchResultFormatter.parameterTags(mode: .raw, resultsMode: .silent) == ["Silent mode", "Raw mode"])
        #expect(WorkbenchResultFormatter.parameterTags(mode: .ascii, resultsMode: .default).isEmpty)
    }
}

struct TutorialParsingTests {
    @Test func fenceWithParamsAndLabel() throws {
        let fence = try #require(TutorialFence.parse(info: "redis:[run_confirmation=true;mode=raw;results=group] Create a key"))
        #expect(fence.label == "Create a key")
        #expect(fence.runConfirmation)
        #expect(fence.isExecutable)
        #expect(fence.executeParams.mode == .raw)
        #expect(fence.executeParams.resultsMode == .group)
        #expect(fence.executeParams.clearEditor == false)
    }

    @Test func plainRedisFence() throws {
        let fence = try #require(TutorialFence.parse(info: "redis Retrieve the data"))
        #expect(fence.label == "Retrieve the data")
        #expect(!fence.runConfirmation)
        #expect(TutorialFence.parse(info: "redis")?.label == "")
        #expect(TutorialFence.parse(info: "json") == nil)
        #expect(TutorialFence.parse(info: "redisx label") == nil)
        #expect(TutorialFence.parse(info: "redis:[executable=false] Info")?.isExecutable == false)
    }

    @Test func longLabelsAreTruncated() {
        let fence = TutorialFence(label: String(repeating: "a", count: 100), params: nil)
        #expect(fence.displayLabel.count == TutorialFence.maxLabelLength + 1)
    }

    @Test func relativeLinksAndStartCase() throws {
        let library = try TutorialLibrary.bundled()
        let strings = try #require(library.node(id: "ds-strings"))
        #expect(library.page(linkedFrom: URL(string: "hashes.md")!, on: strings)?.id == "ds-hashes")
        #expect(library.page(linkedFrom: URL(string: "./lists.md#push-and-read")!, on: strings)?.id == "ds-lists")
        #expect(library.page(linkedFrom: URL(string: "../sq/indexing.md")!, on: strings)?.id == "sq-intro")
        #expect(library.page(linkedFrom: URL(string: "../../ds/hashes.md")!, on: strings)?.id == "ds-hashes")
        #expect(library.page(linkedFrom: URL(string: "missing.md")!, on: strings) == nil)
        #expect(library.page(linkedFrom: URL(string: "https://redis.io/hashes.md")!, on: strings) == nil)
        #expect(TutorialLibrary.startCase("search and query") == "Search And Query")
        #expect(TutorialLibrary.startCase("Redis basic and RAG use cases") == "Redis Basic And RAG Use Cases")
    }

    @Test func copyTextUsesParsedCommands() {
        #expect(TutorialsViewModel.copyText("// comment\nSET a 1\nFT.CREATE idx\n  SCHEMA a TEXT")
            == "SET a 1\nFT.CREATE idx\n  SCHEMA a TEXT")
    }

    @Test func bundledManifestLoads() throws {
        let library = try TutorialLibrary.bundled()
        #expect(library.root.label == "Tutorials")
        #expect(library.root.children?.map(\.id) == ["ds", "sq", "ks"])
        #expect(library.node(id: "sq-intro")?.isPage == true)
        #expect(library.node(id: "vss-intro")?.isPage == true)
        #expect((8...12).contains(library.allPages.count))
        let siblings = library.siblings(of: "sq-intro")
        #expect(siblings.map(\.id) == ["sq-intro", "sq-aggregations", "vss-intro"])
        #expect(library.parent(of: "sq-intro")?.id == "sq")
        #expect(library.groupPath(of: "ds-hashes") == ["Data structures"])
        for page in library.allPages {
            #expect(throws: Never.self) { _ = try library.markdown(for: page) }
        }

        #expect(library.search("Time series").map(\.id) == ["ds-ts-intro"])
        let contents = ["sq-intro": "Some text about zzqqxx here"]
        let hits = library.search("zzqqxx", contents: contents)
        #expect(hits.map(\.id) == ["sq-intro"])
        #expect(hits.first?.excerpt?.contains("zzqqxx") == true)
    }
}
