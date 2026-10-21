import Foundation
@testable import BrowserFeature
import RedisCore
import Testing

struct BrowserFormattingTests {
    @Test func summaryWithoutFilterShowsTotal() {
        let text = BrowserFormatting.summary(found: 10, total: 1_234, scanned: 500, isComplete: false, isFiltered: false,
                                             isTree: false, isLoading: false, hasStarted: true)
        #expect(text == "1,234 keys")
    }

    @Test func summaryWithFilterShowsResultsAndScanned() {
        let text = BrowserFormatting.summary(found: 3, total: 2_000, scanned: 1_000, isComplete: false, isFiltered: true,
                                             isTree: false, isLoading: false, hasStarted: true)
        #expect(text == "Found 3 · scanned 1,000 of 2,000")
    }

    @Test func summaryMarksApproximateScannedCount() {
        let text = BrowserFormatting.summary(found: 3, total: 100, scanned: 100, isComplete: false, isFiltered: false,
                                             isTree: true, isLoading: false, hasStarted: true)
        #expect(text == "Found 3 · scanned ~100 of 100")
        let complete = BrowserFormatting.summary(found: 3, total: 100, scanned: 100, isComplete: true, isFiltered: false,
                                                 isTree: true, isLoading: false, hasStarted: true)
        #expect(complete == "Found 3 · scanned 100 of 100")
    }

    @Test func summaryUnknownTotal() {
        #expect(BrowserFormatting.summary(found: 0, total: nil, scanned: 0, isComplete: false, isFiltered: false,
                                          isTree: false, isLoading: true, hasStarted: false) == "Scanning…")
        #expect(BrowserFormatting.summary(found: 5, total: nil, scanned: 500, isComplete: false, isFiltered: false,
                                          isTree: false, isLoading: false, hasStarted: true) == "5 keys")
        #expect(BrowserFormatting.searchSummary(found: 12, total: 1_234) == "Found 12 of 1,234")
        #expect(BrowserFormatting.keyCount(1) == "1 key")
    }

    @Test func percentages() {
        #expect(BrowserFormatting.percentage(0.4) == "<1%")
        #expect(BrowserFormatting.percentage(12.6) == "13%")
        #expect(BrowserFormatting.percentage(0) == "0%")
    }

    @Test func sizeAndTTLText() {
        #expect(BrowserFormatting.sizeText(nil) == "-")
        #expect(BrowserFormatting.sizeText(0) == "-")
        #expect(BrowserFormatting.sizeText(-1) == "-")
        #expect(BrowserFormatting.sizeText(2_048) == "2 KB")
        #expect(BrowserFormatting.sizeText(1_500, decimals: 3) == "1.465 KB")
        #expect(BrowserFormatting.ttlText(-1) == "No limit")
        #expect(BrowserFormatting.ttlText(480) == "8 min")
        #expect(BrowserFormatting.ttlText(nil) == "")
        #expect(BrowserFormatting.ttlTooltip(3_725).hasPrefix("3,725 s, 1 h 2 min 5 s\nExpires at "))
        #expect(BrowserFormatting.ttlTooltip(-1) == "No limit")
    }

    @Test func cellNameKeepsWhitespaceAndCuts() {
        #expect(BrowserFormatting.cellName("a  b") == "a\u{00A0}\u{00A0}b")
        #expect(BrowserFormatting.cellName("plain name") == "plain name")
        let long = String(repeating: "x", count: 300)
        #expect(BrowserFormatting.cellName(long).count == 200)
    }

    @Test func shortAndTooltipNames() {
        let long = String(repeating: "a", count: 100) + "TAIL_PART_12345"
        let short = BrowserFormatting.shortName(long)
        #expect(short.count == 68)
        #expect(short.hasSuffix("TAIL_PART_12345"))
        #expect(BrowserFormatting.tooltipName("short") == "short")
    }

    @Test func sanitizeTTL() {
        #expect(BrowserFormatting.sanitizeTTL("") == "")
        #expect(BrowserFormatting.sanitizeTTL("00120") == "120")
        #expect(BrowserFormatting.sanitizeTTL("0") == "0")
        #expect(BrowserFormatting.sanitizeTTL("12a3") == "123")
        #expect(BrowserFormatting.sanitizeTTL("99999999999") == "2147483647")
    }

    @Test func parseScore() {
        #expect(BrowserFormatting.parseScore("1.5") == 1.5)
        #expect(BrowserFormatting.parseScore("-3") == -3)
        #expect(BrowserFormatting.parseScore("inf") == .infinity)
        #expect(BrowserFormatting.parseScore("-inf") == -.infinity)
        #expect(BrowserFormatting.parseScore("abc") == nil)
        #expect(BrowserFormatting.parseScore("") == nil)
        #expect(BrowserFormatting.parseScore("1.1234567890123456") == nil)
        #expect(BrowserFormatting.parseScore("1.123456789012345") != nil)
    }

    @Test func streamIDsAndTimestamps() {
        #expect(BrowserFormatting.isValidStreamID("*"))
        #expect(BrowserFormatting.isValidStreamID("1700000000000-0"))
        #expect(BrowserFormatting.isValidStreamID("12-*"))
        #expect(BrowserFormatting.isValidStreamID("12"))
        #expect(!BrowserFormatting.isValidStreamID("abc"))
        #expect(!BrowserFormatting.isValidStreamID("1-2-3"))
        #expect(BrowserFormatting.isValidTimestamp("*"))
        #expect(BrowserFormatting.isValidTimestamp("1000"))
        #expect(!BrowserFormatting.isValidTimestamp("10s"))
    }

    @Test func bulkHelpers() {
        #expect(BrowserFormatting.expectedAmount(found: 10, total: 1_000, scanned: 100) == 100)
        #expect(BrowserFormatting.expectedAmount(found: 10, total: 100, scanned: 100) == 10)
        #expect(BrowserFormatting.expectedAmount(found: 10, total: nil, scanned: 100) == nil)
        #expect(BrowserFormatting.expectedAmount(found: 0, total: 10, scanned: 0) == nil)
        #expect(BrowserFormatting.bulkDuration(3_723.456) == "1:02:03.456")
        #expect(BrowserFormatting.bulkDuration(0) == "0:00:00.000")
        #expect(BrowserFormatting.progress(scanned: 50, total: 200) == 25)
        #expect(BrowserFormatting.progress(scanned: 500, total: 200) == 100)
        #expect(BrowserFormatting.progress(scanned: 5, total: 0) == 0)
        #expect(BrowserFormatting.simplePrefix(of: "user:*") == "user:")
        #expect(BrowserFormatting.simplePrefix(of: "us?r:*") == nil)
        #expect(BrowserFormatting.simplePrefix(of: "user") == nil)
    }

    @Test func bulkReport() {
        let overview = BulkActionOverview(status: .completed, total: 3, scanned: 3, processed: 3, succeeded: 2, failed: 1,
                                          errors: [BulkActionError(key: Data("bad".utf8), error: "boom")], duration: 1.5,
                                          filter: BulkActionFilter(match: "a*", type: .hash))
        let report = BrowserFormatting.bulkDeleteReport(overview)
        #expect(report.contains("bad - Error: boom"))
        #expect(report.contains("Keys Processed: 3"))
        #expect(report.contains("Key type: Hash"))
        #expect(report.contains("Time Taken: 0:00:01.500"))
        #expect(BulkActionsViewModel.reportFileName().hasPrefix("bulk-delete-report-"))
    }

    @Test func folderTooltip() {
        let single = BrowserFormatting.folderTooltip(fullName: "user", delimiters: [":"], keyCount: 2, percentage: 50)
        #expect(single == "user:*\n2 keys (50%)")
        let multi = BrowserFormatting.folderTooltip(fullName: "a", delimiters: [":", "-"], keyCount: 1, percentage: 0.5)
        #expect(multi.contains("1 key (<1%)"))
        #expect(multi.contains("Delimiters: : -"))
    }

    @Test func searchHistoryRules() {
        var history: [SearchHistoryItem] = []
        history = SearchHistory.adding(SearchHistoryItem(mode: .pattern, match: "*"), to: history)
        #expect(history.isEmpty)
        for i in 0..<12 {
            history = SearchHistory.adding(SearchHistoryItem(mode: .pattern, match: "k\(i)*"), to: history)
        }

        #expect(history.count == SearchHistory.maxPerMode)
        #expect(history.first?.match == "k11*")
        history = SearchHistory.adding(SearchHistoryItem(mode: .pattern, match: "k5*"), to: history)
        #expect(history.first?.match == "k5*")
        #expect(history.filter { $0.match == "k5*" }.count == 1)
        history = SearchHistory.adding(SearchHistoryItem(mode: .pattern, match: "k5*", type: .hash), to: history)
        #expect(history.filter { $0.match == "k5*" }.count == 2)
        history = SearchHistory.adding(SearchHistoryItem(mode: .redisearch, match: "@name:bike"), to: history)
        #expect(SearchHistory.items(history, mode: .redisearch).count == 1)
        history = SearchHistory.clearing(mode: .pattern, in: history)
        #expect(history.count == 1)
        let id = history[0].id
        #expect(SearchHistory.removing(id: id, from: history).isEmpty)
    }

    @Test func sampleDataFileSelection() throws {
        let manifest = SampleDataLoader.Manifest(files: [
            .init(path: "common", modules: nil),
            .init(path: "json", modules: ["rejson"]),
            .init(path: "search", modules: ["search", "searchlight", "ft", "ftl"]),
        ])
        #expect(SampleDataLoader.selectFiles(manifest, modules: []) == ["common"])
        let modules = [RedisModuleInfo(name: "ReJSON", version: 20_000), RedisModuleInfo(name: "search", version: 21_000)]
        #expect(SampleDataLoader.selectFiles(manifest, modules: modules) == ["common", "json", "search"])
        #expect(try SampleDataLoader.files(for: []) == ["common"])
        let script = try SampleDataLoader.script(for: [])
        #expect(String(decoding: script, as: UTF8.self).contains("HSET library:books:1 "))
    }

    @Test func bundledSampleDataParsesForEveryModule() throws {
        let modules = ["ReJSON", "search", "timeseries", "bf", "vectorset"].map { RedisModuleInfo(name: $0, version: 1) }
        #expect(try SampleDataLoader.files(for: modules) == ["common", "json", "search", "timeseries", "bloom", "vectorset"])
        let script = try SampleDataLoader.script(for: modules)
        let lines = script.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }).filter { !$0.isEmpty }
        let commands = try lines.map { try CommandLineSplitter.split(bytes: Array($0)) }
        #expect(commands.count > 300)
        let names = Set(commands.compactMap { $0.first.map { String(decoding: $0, as: UTF8.self) } })
        #expect(names.isSuperset(of: ["SET", "HSET", "RPUSH", "SADD", "ZADD", "XADD", "XGROUP", "PFADD", "SETBIT", "GEOADD",
                                      "JSON.SET", "FT.CREATE", "TS.CREATE", "BF.RESERVE", "VADD"]))
        let keys = commands.compactMap { $0.count > 1 ? $0[1] : nil }
        #expect(keys.contains { String(data: $0, encoding: .utf8) == nil })
    }

    @Test func listSortPutsUnloadedLast() {
        let keys = [
            KeyListItem(name: Data("b".utf8), ttl: 50, size: 10),
            KeyListItem(name: Data("a".utf8), ttl: -1, size: nil),
            KeyListItem(name: Data("c".utf8), ttl: 10, size: 30),
        ]
        let byName = BrowserViewModel.sorted(keys, by: KeyListSort(field: .name, order: .asc), format: .unicode)
        #expect(byName.map { String(decoding: $0.name, as: UTF8.self) } == ["a", "b", "c"])
        let byTTL = BrowserViewModel.sorted(keys, by: KeyListSort(field: .ttl, order: .desc), format: .unicode)
        #expect(byTTL.map { String(decoding: $0.name, as: UTF8.self) } == ["b", "c", "a"])
        let bySize = BrowserViewModel.sorted(keys, by: KeyListSort(field: .size, order: .asc), format: .unicode)
        #expect(bySize.map { String(decoding: $0.name, as: UTF8.self) } == ["b", "c", "a"])
    }
}

struct BrowserDesignLogicTests {
    @Test func prefixPatternUsesTheLastDelimiter() {
        #expect(BrowserFormatting.prefixPattern(for: "user:1:name", delimiters: [":"]) == "user:1:*")
        #expect(BrowserFormatting.prefixPattern(for: "a-b:c", delimiters: [":", "-"]) == "a-b:*")
        #expect(BrowserFormatting.prefixPattern(for: "plain", delimiters: [":"]) == nil)
        #expect(BrowserFormatting.prefixPattern(for: "trailing:", delimiters: [":"]) == nil)
        #expect(BrowserFormatting.prefixPattern(for: "we*ird:x", delimiters: [":"]) == #"we\*ird:*"#)
    }

    @Test func viewOptionsDelimiters() {
        #expect(ViewOptionsDraft.parseDelimiters(":") == [":"])
        #expect(ViewOptionsDraft.parseDelimiters(": , -") == [":", "-"])
        #expect(ViewOptionsDraft.parseDelimiters(":, :") == [":"])
        #expect(ViewOptionsDraft.parseDelimiters("") == [":"])
        #expect(ViewOptionsDraft.parseDelimiters(",") == [","])
        #expect(ViewOptionsDraft.delimitersText([":", "-"]) == ":, -")
    }

    @Test func viewOptionsDropsSortOnHiddenColumn() {
        var draft = ViewOptionsDraft(showsTTL: true, showsSize: true, sort: KeyListSort(field: .size, order: .desc),
                                     tree: KeyTreeOptions())
        #expect(draft.sort == KeyListSort(field: .size, order: .desc))
        draft.showsSize = false
        #expect(draft.sort == nil)
        draft.sortField = .name
        #expect(draft.sort == KeyListSort(field: .name, order: .desc))
    }

    @Test func singlePaneBelow720() {
        #expect(BrowserLayout.isSinglePane(width: 719))
        #expect(!BrowserLayout.isSinglePane(width: 720))
        #expect(!BrowserLayout.isSinglePane(width: 0))
    }
}

struct BulkTextTests {
    @Test func scannedEstimate() {
        #expect(BulkText.scanned(scanned: 400, total: 1_000, found: 12) == "40% (400 of 1,000 scanned), found 12")
    }
}

struct KeyListColumnTests {
    @Test func narrowPaneHidesSizeThenTTL() {
        #expect(BrowserViewModel.columnsHidden(atWidth: 0).isEmpty)
        #expect(BrowserViewModel.columnsHidden(atWidth: 640).isEmpty)
        #expect(BrowserViewModel.columnsHidden(atWidth: 450) == [.size])
        #expect(BrowserViewModel.columnsHidden(atWidth: 380) == [.size, .ttl])
    }

    @Test func typeFilterOffersArrayOnlyWhenSupported() {
        let redis88 = DatabaseCapabilities(redisVersion: "8.8.0", hasArrayCommands: true)
        let redis80 = DatabaseCapabilities(redisVersion: "8.0.0", hasArrayCommands: false)
        #expect(KeyTypeFilterMenu.types(capabilities: redis88).last == .array)
        #expect(!KeyTypeFilterMenu.types(capabilities: redis80).contains(.array))
    }
}

struct SampleDataErrorTests {
    @Test func failedCommandsAreCountedWithTheFirstError() {
        let error = SampleDataError.commandsFailed(failed: 2, total: 1_200, firstError: "JSON.SET: unknown command")
        #expect(error.localizedDescription == "2 of 1,200 commands failed. JSON.SET: unknown command")
        #expect(SampleDataError.commandsFailed(failed: 1, total: 3, firstError: nil).localizedDescription
            == "1 of 3 commands failed.")
    }
}
