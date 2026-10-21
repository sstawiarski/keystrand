import Foundation
@testable import MonitoringFeature
import RedisCore
import Testing

struct PubSubPatternTests {
    @Test func emptyInputMeansAllChannels() {
        #expect(PubSubPatterns.parse("") == ["*"])
        #expect(PubSubPatterns.parse("   \n ") == ["*"])
        #expect(PubSubPatterns.normalizedInput("  ") == "*")
        #expect(PubSubPatterns.normalizedInput("news.*") == "news.*")
    }

    @Test func splitsOnWhitespaceAndDeduplicates() {
        #expect(PubSubPatterns.parse("a  b\ta c*") == ["a", "b", "c*"])
    }

    @Test func headerAndTooltip() {
        #expect(PubSubPatterns.headerText(["*"]) == "Patterns: All")
        #expect(PubSubPatterns.headerText(["a", "b*"]) == "Patterns: 2")
        #expect(PubSubPatterns.headerText(["a"]) == "Patterns: 1")
        #expect(PubSubPatterns.tooltip(["a", "b*"]) == "a\nb*")
    }

    @Test func subscribedStatusTexts() {
        #expect(PubSubPatterns.subscribedText(["*"]) == "Subscribed to all channels")
        #expect(PubSubPatterns.subscribedText([]) == "Subscribed to all channels")
        #expect(PubSubPatterns.subscribedText(["news.*"]) == "Subscribed to news.*")
        #expect(PubSubPatterns.subscribedText(["a", "b"]) == "Subscribed to 2 patterns")
        #expect(PublishResult(receivers: 2).statusText == "Published to 2 clients")
        #expect(PublishResult(receivers: 1).statusText == "Published to 1 client")
        #expect(PublishResult(receivers: nil).statusText == "Message published")
    }

    @Test func publishResultTexts() {
        #expect(PublishResult(receivers: 1).detailText == "Message published to 1 subscriber")
        #expect(PublishResult(receivers: 0).detailText == "Message published to 0 subscribers")
    }
}

struct CappedBufferTests {
    @Test func appendsWithinCap() {
        var items = [1, 2]
        CappedBuffer.append([3], to: &items, cap: 5)
        #expect(items == [1, 2, 3])
    }

    @Test func trimsOldestOnOverflow() {
        var items = [1, 2, 3, 4]
        CappedBuffer.append([5, 6, 7], to: &items, cap: 5)
        #expect(items == [3, 4, 5, 6, 7])
    }

    @Test func batchLargerThanCapKeepsItsNewest() {
        var items = [1, 2]
        CappedBuffer.append(Array(10..<20), to: &items, cap: 3)
        #expect(items == [17, 18, 19])
    }

    @Test func pendingQueueDrainsInOrder() {
        let queue = PendingQueue<Int>()
        for i in 0..<5 { queue.append(i) }
        #expect(queue.count == 5)
        #expect(queue.drain() == [0, 1, 2, 3, 4])
        #expect(queue.drain().isEmpty)
    }
}

struct BinaryTextTests {
    @Test func previewFlattensControlCharacters() {
        #expect(BinaryText.preview(Data("a\nb\tc".utf8)) == "a b c")
    }

    @Test func previewEscapesInvalidUTF8() {
        #expect(BinaryText.preview(Data([0x61, 0xFF, 0x62])) == "a\\xffb")
        #expect(BinaryText.full(Data([0x00, 0xC3])) == "\u{0}\\xc3")
    }

    @Test func keepsMultibyteCharacters() {
        #expect(BinaryText.preview(Data("héllo 🙂".utf8)) == "héllo 🙂")
        #expect(BinaryText.full(Data("日本".utf8)) == "日本")
    }

    @Test func truncatesLongValues() {
        let big = Data(repeating: UInt8(ascii: "x"), count: 5_000_000)
        let preview = BinaryText.preview(big, limit: 10)
        #expect(preview == String(repeating: "x", count: 10) + "…")
        let quoted = BinaryText.quoted(big, limit: 5)
        #expect(quoted == "\"xxxxx…\"")
    }

    @Test func truncationDoesNotSplitMultibyteCharacters() {
        let data = Data(String(repeating: "é", count: 50).utf8)
        let preview = BinaryText.preview(data, limit: 10)
        #expect(preview == String(repeating: "é", count: 10) + "…")
    }

    @Test func quotedEscapes() {
        #expect(BinaryText.quoted(Data("a\"b\\c\n".utf8)) == "\"a\\\"b\\\\c\\n\"")
        #expect(BinaryText.quoted(Data([0x01, 0xFE])) == "\"\\x01\\xfe\"")
        #expect(BinaryText.quoted(Data()) == "\"\"")
    }
}

struct ProfilerFormattingTests {
    let utc = TimeZone(identifier: "UTC") ?? .current

    @Test func formatsMonitorTime() {
        #expect(ProfilerFormatting.time("1339518083.107412", timeZone: utc) == "16:21:23.107")
        #expect(ProfilerFormatting.time("1700000000.5", timeZone: utc) == "22:13:20.500")
        #expect(ProfilerFormatting.time("abc", timeZone: utc) == "Invalid time")
        #expect(ProfilerFormatting.time("", timeZone: utc) == "Invalid time")
    }

    @Test func formatsTimeInOtherZones() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 2 * 3600))
        #expect(ProfilerFormatting.time("1700000000.5", timeZone: zone) == "00:13:20.500")
    }

    @Test func context() {
        #expect(ProfilerFormatting.context(database: 0, source: "127.0.0.1:60866") == "[0 127.0.0.1:60866]")
        #expect(ProfilerFormatting.context(database: 3, source: "lua") == "[3 lua]")
        #expect(ProfilerFormatting.context(database: 1, source: "") == "[1]")
    }

    @Test func logLineUsesJSONEscaping() throws {
        let line = try MonitorLineParser.parse(#"1339518083.107412 [0 127.0.0.1:60866] "set" "a\"b" "x\ny""#)
        #expect(ProfilerFormatting.logLine(line) == #"1339518083.107412 [0 127.0.0.1:60866] "set" "a\"b" "x\ny""#)
        let lua = try MonitorLineParser.parse(#"1339518083.1 [0 lua] "get" "\x01""#)
        #expect(ProfilerFormatting.logLine(lua) == #"1339518083.1 [0 lua] "get" "\u0001""#)
    }

    @Test func jsonQuoted() {
        #expect(ProfilerFormatting.jsonQuoted("plain") == "\"plain\"")
        #expect(ProfilerFormatting.jsonQuoted("tab\there") == "\"tab\\there\"")
        #expect(ProfilerFormatting.jsonQuoted("é") == "\"é\"")
    }

    @Test func runningTime() {
        #expect(ProfilerFormatting.runningTime(0) == "0 s")
        #expect(ProfilerFormatting.runningTime(0.8) == "0 s")
        #expect(ProfilerFormatting.runningTime(128) == "2 min, 8 s")
        #expect(ProfilerFormatting.runningTime(3_661) == "1 h, 1 min, 1 s")
        #expect(ProfilerFormatting.runningTime(90_000) == "1 d, 1 h")
    }

    @Test func clockUsesTwelveHourFormat() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ProfilerFormatting.clock(date, timeZone: utc) == "10:13:20")
    }

    @Test func downloadFileName() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_000_010.5)
        #expect(ProfilerFormatting.downloadFileName(databaseName: "My DB", start: start, end: end)
            == "My DB-1700000000000-1700000010500.txt")
        #expect(ProfilerFormatting.downloadFileName(databaseName: "a/b:c", start: start, end: end)
            == "a_b_c-1700000000000-1700000010500.txt")
        #expect(ProfilerFormatting.downloadFileName(databaseName: "", start: start, end: end)
            .hasPrefix("profiler-"))
    }

    @Test func entryDisplayStrings() throws {
        let line = try MonitorLineParser.parse(#"1700000000.5 [2 10.0.0.1:1234] "hset" "h" "f" "v""#)
        let entry = ProfilerEntry(line: line, nodeLabel: nil, timeZone: utc)
        #expect(entry.timeText == "22:13:20.500")
        #expect(entry.contextText == "[2 10.0.0.1:1234]")
        #expect(entry.commandText == "\"hset\"")
        #expect(entry.argumentsText == "\"h\" \"f\" \"v\"")
        #expect(entry.copyText == #"22:13:20.500 [2 10.0.0.1:1234] "hset" "h" "f" "v""#)
        #expect(!entry.isError)
    }

    @Test func entryTruncatesHugeArgumentLists() {
        let args = (0..<5_000).map { Data("value-\($0)".utf8) }
        let line = MonitorLine(time: "1700000000.0", database: 0, source: "x", args: [Data("rpush".utf8)] + args, raw: "")
        let entry = ProfilerEntry(line: line, nodeLabel: nil, timeZone: utc)
        #expect(entry.argumentsText.count < 2_400)
        #expect(entry.argumentsText.hasSuffix("…"))
    }

    @Test func classifiesStreamFailures() {
        #expect(ProfilerStreamFailure.classify(RedisClientError.server(RESPError("NOPERM this user has no permissions to run the 'monitor' command"))) == .forbidden)
        #expect(ProfilerStreamFailure.classify(RedisClientError.server(RESPError("ERR something"))) == .server("ERR something"))
        #expect(ProfilerStreamFailure.classify(RedisClientError.connectionClosed) == .connectionLost)
        #expect(ProfilerStreamFailure.classify(nil) == .connectionLost)
    }
}

struct ProfilerLogFileWriterTests {
    @Test func writesFlushesCopiesAndDiscards() throws {
        let paths = AppPaths.temporary()
        let writer = try ProfilerLogFileWriter.makeTemporary(paths: paths)
        #expect(writer.url.deletingLastPathComponent().standardizedFileURL == paths.profilerLogsDirectory.standardizedFileURL)
        writer.append("line one")
        writer.append("line \"two\"")
        writer.flush()
        let content = try String(contentsOf: writer.url, encoding: .utf8)
        #expect(content == "line one\nline \"two\"\n")
        #expect(writer.lineCount == 2)

        let destination = paths.root.appendingPathComponent("copy.txt")
        writer.append("line three")
        try writer.copy(to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8).hasSuffix("line three\n"))

        writer.discard()
        #expect(!FileManager.default.fileExists(atPath: writer.url.path))
        writer.append("ignored after close")
        #expect(writer.lineCount == 3)
    }

    @Test func buffersLargeOutput() throws {
        let writer = try ProfilerLogFileWriter.makeTemporary(paths: .temporary())
        let line = String(repeating: "y", count: 1_000)
        for _ in 0..<200 { writer.append(line) }
        writer.close()
        let size = try FileManager.default.attributesOfItem(atPath: writer.url.path)[.size] as? Int
        #expect(size == 200 * 1_001)
        writer.discard()
    }

    @Test func removesOnlyStaleProfilerLogs() throws {
        let paths = AppPaths.temporary()
        let directory = paths.profilerLogsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("redis_old.log")
        let fresh = directory.appendingPathComponent("redis_new.log")
        let unrelated = directory.appendingPathComponent("notes.log")
        for url in [stale, fresh, unrelated] {
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        }

        let old = Date().addingTimeInterval(-3 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: unrelated.path)

        #expect(ProfilerLogFileWriter.removeStaleLogs(in: directory) == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(ProfilerLogFileWriter.removeStaleLogs(in: directory.appendingPathComponent("missing")) == 0)
    }
}
