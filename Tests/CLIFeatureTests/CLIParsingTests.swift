import Foundation
@testable import CLIFeature
import RedisCore
import Testing

struct CLIPlannerTests {
    @Test func repeatPrefix() {
        #expect(CLICommandPlanner.repeatPrefix("10 INCR c") == ("INCR c", 10))
        #expect(CLICommandPlanner.repeatPrefix("INCR 10") == ("INCR 10", 1))
        #expect(CLICommandPlanner.repeatPrefix("  3   get a ") == ("get a", 3))
        #expect(CLICommandPlanner.repeatPrefix("5") == ("5", 1))
        #expect(CLICommandPlanner.repeatPrefix("0 get a").count == nil)
        #expect(CLICommandPlanner.repeatPrefix("-2 get a").count == nil)
        #expect(CLICommandPlanner.repeatPrefix("2147483648 get a").count == nil)
        #expect(CLICommandPlanner.repeatPrefix("2147483647 get a").count == 2_147_483_647)
        #expect(CLICommandPlanner.repeatPrefix("1.5 get a") == ("1.5 get a", 1))
        #expect(CLICommandPlanner.repeatPrefix("0x10 get a") == ("0x10 get a", 1))
    }

    @Test func strippingRepeat() {
        #expect(CLICommandPlanner.strippingRepeat("3 get ") == "get ")
        #expect(CLICommandPlanner.strippingRepeat("get 3") == "get 3")
        #expect(CLICommandPlanner.strippingRepeat("client list") == "client list")
    }

    @Test func planLocalAndRejectedCommands() {
        #expect(CLICommandPlanner.plan("   ") == .empty)
        #expect(CLICommandPlanner.plan(" CLEAR ") == .clear)
        #expect(CLICommandPlanner.plan("0 get a") == .invalidRepeat)
        #expect(CLICommandPlanner.plan("monitor") == .guidance(.monitor))
        #expect(CLICommandPlanner.plan("SUBSCRIBE ch") == .guidance(.subscribe))
        #expect(CLICommandPlanner.plan("ssubscribe ch") == .guidance(.subscribe))
        #expect(CLICommandPlanner.plan("psubscribe *") == .guidance(.psubscribe))
        #expect(CLICommandPlanner.plan("hello 3") == .guidance(.resp3))
        #expect(CLICommandPlanner.plan("2 monitor") == .guidance(.monitor))
        let expected = "SYNC can't be run from the CLI. Commands the CLI doesn't run: "
            + "subscribe, psubscribe, ssubscribe, sync, psync, script debug, hello 3"
        #expect(CLICommandPlanner.plan("SYNC") == .unsupported(message: expected))
        if case .unsupported(let message) = CLICommandPlanner.plan("Script Debug yes") {
            #expect(message.hasPrefix("Script Debug can't be run from the CLI."))
        } else {
            Issue.record("script debug should be unsupported")
        }
    }

    @Test func planChecksTheSplitArgumentsToo() {
        #expect(CLICommandPlanner.plan(#""MONITOR""#) == .guidance(.monitor))
        #expect(CLICommandPlanner.plan(#""\x6dONITOR""#) == .guidance(.monitor))
        #expect(CLICommandPlanner.plan(#""SUBSCRIBE" ch"#) == .guidance(.subscribe))
        #expect(CLICommandPlanner.plan(#"2 'psubscribe' *"#) == .guidance(.psubscribe))
        #expect(CLICommandPlanner.plan(#"hello "3""#) == .guidance(.resp3))
        let expected = "SYNC can't be run from the CLI. Commands the CLI doesn't run: "
            + "subscribe, psubscribe, ssubscribe, sync, psync, script debug, hello 3"
        #expect(CLICommandPlanner.plan(#""SYNC""#) == .unsupported(message: expected))
        #expect(CLICommandPlanner.plan(#"'monitor"#) == .parseError(message: "Invalid arguments: a quote is never closed."))
        guard case .execute(let command) = CLICommandPlanner.plan(#"PUBLISH "subscribe" monitor"#) else {
            Issue.record("a quoted argument that is not the verb should run")
            return
        }
        #expect(command.verb == "PUBLISH")
    }

    @Test func planParseErrors() {
        #expect(CLICommandPlanner.plan("set a \"b") == .parseError(message: "Invalid arguments: a quote is never closed."))
        #expect(CLICommandPlanner.plan("set a \"b\"c") == .parseError(
            message: "Invalid arguments: add a space after the closing quote."))
    }

    @Test func planExecuteIsBinarySafe() throws {
        guard case .execute(let command) = CLICommandPlanner.plan("2 set \"k\\xff\" 'v w'") else {
            Issue.record("expected execute")
            return
        }
        #expect(command.repeatCount == 2)
        #expect(command.verb == "SET")
        #expect(command.commandLine == "set \"k\\xff\" 'v w'")
        #expect(command.args == [Data("set".utf8), Data([0x6B, 0xFF]), Data("v w".utf8)])
    }

    @Test func promptAndEndpoint() {
        #expect(CLICommandPlanner.prompt(db: 0) == "> ")
        #expect(CLICommandPlanner.prompt(db: 3) == "[db3] > ")
        #expect(CLICommandPlanner.endpointLabel(host: "localhost", port: 6390, db: 0) == "localhost:6390")
        #expect(CLICommandPlanner.endpointLabel(host: "localhost", port: 6390, db: 8) == "localhost:6390[db8]")
    }

    @Test func selectedDB() {
        #expect(CLICommandPlanner.selectedDB(args: [Data("select".utf8), Data("4".utf8)]) == 4)
        #expect(CLICommandPlanner.selectedDB(args: [Data("SELECT".utf8), Data("'5'".utf8)]) == 5)
        #expect(CLICommandPlanner.selectedDB(args: [Data("SELECT".utf8), Data("x".utf8)]) == nil)
        #expect(CLICommandPlanner.selectedDB(args: [Data("GET".utf8), Data("1".utf8)]) == nil)
    }

    @Test func guidanceSegmentsCarryLinks() {
        let monitor = CLICommandPlanner.guidanceSegments(.monitor)
        #expect(monitor.map(\.text).joined() == CommandRules.Guidance.monitor.message)
        #expect(monitor.first { $0.link == .profiler }?.text == "Profiler")
        #expect(monitor.allSatisfy { $0.style == .error })
        let psub = CLICommandPlanner.guidanceSegments(.psubscribe)
        #expect(psub.first { $0.link == .pubSub }?.text == "Pub/Sub")
        #expect(CLICommandPlanner.guidanceSegments(.resp3).allSatisfy { $0.link == nil })
    }

    @Test func flushWarningForEveryFlush() throws {
        let indexLoss = CommandWarnings.flushIndexLossWarning
        let withSearch = try #require(CLICommandPlanner.flushWarning(verb: "FLUSHDB", modules: ["search"]))
        #expect(withSearch.hasPrefix("FLUSHDB deletes every key in the current logical database."))
        #expect(withSearch.contains(indexLoss))
        let flushAll = try #require(CLICommandPlanner.flushWarning(verb: "flushall", modules: ["ReJSON", "search"]))
        #expect(flushAll.hasPrefix("FLUSHALL deletes every key in every logical database of this server."))
        #expect(flushAll.contains(indexLoss))
        let withoutSearch = try #require(CLICommandPlanner.flushWarning(verb: "FLUSHDB", modules: ["ReJSON"]))
        #expect(withoutSearch == "FLUSHDB deletes every key in the current logical database.")
        let unknownModules = try #require(CLICommandPlanner.flushWarning(verb: "FLUSHDB", modules: []))
        #expect(unknownModules.contains(indexLoss))
        #expect(CLICommandPlanner.flushWarning(verb: "DEL", modules: ["search"]) == nil)
        #expect(CLICommandPlanner.flushWarning(verb: "DEL", modules: []) == nil)
    }

    @Test func dangerousLookup() {
        func args(_ words: String...) -> [Data] { words.map { Data($0.utf8) } }
        #expect(CLICommandPlanner.isDangerous(args: args("KEYS", "*"), dangerous: ["keys"], catalog: nil))
        #expect(!CLICommandPlanner.isDangerous(args: args("GET", "k"), dangerous: ["keys"], catalog: nil))
        #expect(CLICommandPlanner.isDangerous(args: args("flushall"), dangerous: [], catalog: .shared))
        #expect(!CLICommandPlanner.isDangerous(args: args("GET", "k"), dangerous: [], catalog: .shared))
        let redis8: Set<String> = ["config|set", "acl|setuser", "client|kill", "keys"]
        #expect(CLICommandPlanner.isDangerous(args: args("CONFIG", "SET", "maxmemory", "1"), dangerous: redis8,
                                              catalog: nil))
        #expect(CLICommandPlanner.isDangerous(args: args("acl", "setuser", "u"), dangerous: redis8, catalog: nil))
        #expect(CLICommandPlanner.isDangerous(args: args("CLIENT", "KILL", "ID", "1"), dangerous: redis8, catalog: nil))
        #expect(!CLICommandPlanner.isDangerous(args: args("CONFIG"), dangerous: redis8, catalog: nil))
        #expect(!CLICommandPlanner.isDangerous(args: args("CONFIG", "GET", "x"), dangerous: redis8, catalog: nil))
        #expect(CLICommandPlanner.isDangerous(args: args("config", "set", "x", "1"), dangerous: [], catalog: .shared))
        let message = CommandWarnings.dangerousMessage(["KEYS *"], databaseName: "Prod")
        #expect(message == "KEYS * is flagged as a dangerous command. Running it on Prod can slow down or "
            + "destabilize the server.")
        let plural = CommandWarnings.dangerousMessage(["KEYS", "FLUSHDB"], databaseName: "Prod", extraWarning: "Careful.")
        #expect(plural == "KEYS, FLUSHDB are flagged as dangerous commands. Running them on Prod can slow down or "
            + "destabilize the server.\n\nCareful.")
    }

    @Test func historyCursor() {
        let history = ["c", "b", "a"]
        var cursor = CLIHistoryCursor()
        #expect(cursor.down(history) == nil)
        #expect(cursor.up(history) == "c")
        #expect(cursor.up(history) == "b")
        #expect(cursor.up(history) == "a")
        #expect(cursor.up(history) == nil)
        #expect(cursor.down(history) == "b")
        #expect(cursor.down(history) == "c")
        #expect(cursor.down(history) == nil)
        cursor.reset()
        #expect(cursor.up([]) == nil)
    }
}

struct CLIOutputBufferTests {
    @Test func appendCountsLinesAndSkipsEmpty() {
        var buffer = CLIOutputBuffer()
        buffer.append("")
        #expect(buffer.isEmpty)
        buffer.append([CLIOutputSegment("a\nb\n"), CLIOutputSegment("c", style: .error)])
        #expect(buffer.lineCount == 2)
        #expect(buffer.plainText == "a\nb\nc")
        #expect(buffer.chunks.count == 1)
    }

    @Test func trimsOldestChunksButKeepsNewest() {
        var buffer = CLIOutputBuffer(maxLines: 5)
        for i in 0..<10 { buffer.append("line \(i)\n") }
        #expect(buffer.lineCount == 5)
        #expect(buffer.chunks.first?.text == "line 5\n")
        #expect(buffer.droppedChunkCount == 5)
        buffer.append(String(repeating: "x\n", count: 50))
        #expect(buffer.chunks.count == 1)
        #expect(buffer.lineCount == 50)
        #expect(buffer.chunks.last.map { $0.id > 9 } == true)
    }

    @Test func trimsByCharactersWhenLinesStayLow() {
        var buffer = CLIOutputBuffer(maxLines: 1_000, maxCharacters: 100)
        for _ in 0..<5 { buffer.append(String(repeating: "a", count: 30) + "\n") }
        #expect(buffer.characterCount <= 100)
        #expect(buffer.chunks.count == 3)
        #expect(buffer.droppedChunkCount == 2)
        #expect(buffer.characterCount == buffer.plainText.utf16.count)
        buffer.append(String(repeating: "b", count: 500))
        #expect(buffer.chunks.count == 1)
        #expect(buffer.characterCount == 500)
        buffer.clear()
        #expect(buffer.characterCount == 0)
    }

    @Test func clearBumpsGeneration() {
        var buffer = CLIOutputBuffer()
        buffer.append("x\n")
        let generation = buffer.generation
        buffer.clear()
        #expect(buffer.isEmpty)
        #expect(buffer.generation == generation + 1)
        buffer.append("y")
        #expect(buffer.chunks.first?.id == 1)
    }
}

struct CLIReplyFormattingTests {
    @Test func redisCLIStyle() {
        #expect(CLISession.format(.integer(5), commandLine: "incr a").text == "(integer) 5")
        #expect(CLISession.format(.bulkString(nil), commandLine: "get a").text == "(nil)")
        #expect(CLISession.format(.simpleString("OK"), commandLine: "set a b").text == "\"OK\"")
        #expect(CLISession.format(.array([]), commandLine: "keys x").text == "(empty list or set)")
        #expect(CLISession.format(.error(RESPError("ERR boom")), commandLine: "x").text == "ERR boom")
        let nested = RESPValue.array([.bulk("a"), .array([.integer(1), .bulkString(nil)]), .bulkString(Data([0xE5, 0x0A]))])
        #expect(CLISession.format(nested, commandLine: "x").text
            == "1) \"a\"\n2) 1) (integer) 1\n   2) (nil)\n3) \"\\xe5\\n\"")
    }

    @Test func humanReadableAndBulkCommandsArePrintedRaw() {
        let info = RESPValue.bulkString(Data("# Server\r\nredis_version:8.0\r\n".utf8))
        #expect(CLISession.format(info, commandLine: "INFO server").text == "# Server\r\nredis_version:8.0\r\n")
        let utf8 = RESPValue.bulkString(Data("名字".utf8))
        #expect(CLISession.format(utf8, commandLine: "get k").text == "\"\\xe5\\x90\\x8d\\xe5\\xad\\x97\"")
    }

    @Test func truncatesHugeReplies() {
        let big = RESPValue.bulkString(Data(repeating: 0x61, count: 5_000))
        let formatted = CLISession.format(big, commandLine: "get big", maxCharacters: 1_000)
        #expect(formatted.text.count == 1_000)
        #expect(formatted.truncated == 5_002 - 1_000)
    }

    @Test func linkURLsRoundTrip() {
        for link in CLILink.allCases {
            #expect(CLILink(url: link.url) == link)
        }

        #expect(CLILink(url: URL(string: "https://redis.io")!) == nil)
    }
}
