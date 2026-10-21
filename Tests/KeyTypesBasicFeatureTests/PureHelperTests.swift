import Foundation
@testable import KeyTypesBasicFeature
import RedisCore
import TestSupport
import Testing

struct ValueEditRulesTests {
    @Test func formatEditability() {
        for format in [ValueFormat.protobuf, .java, .pickle, .vector32, .vector64, .hex, .binary] {
            #expect(!ValueEditRules.isFormatEditable(format))
        }

        for format in [ValueFormat.unicode, .ascii, .json, .msgpack, .php, .dateTime, .markdown] {
            #expect(ValueEditRules.isFormatEditable(format))
        }
    }

    @Test func nonUnicodeGuardOnlyForEditableNonUnicodeFormats() {
        #expect(!ValueEditRules.requiresNonUnicodeGuard(.unicode))
        #expect(ValueEditRules.requiresNonUnicodeGuard(.json))
        #expect(ValueEditRules.requiresNonUnicodeGuard(.ascii))
        #expect(!ValueEditRules.requiresNonUnicodeGuard(.hex))
    }

    @Test func blockReasonsInPriorityOrder() {
        let text = Data("hello".utf8)
        #expect(ValueEditRules.editBlockReason(text, format: .unicode, isValid: true, isCompressed: true)
                == ValueEditRules.cannotEditCompressed)
        #expect(ValueEditRules.editBlockReason(text, format: .unicode, isValid: true, isCompressed: false, isPartial: true)
                == ValueEditRules.loadEntireValue)
        #expect(ValueEditRules.editBlockReason(text, format: .hex, isValid: true, isCompressed: false)
                == ValueEditRules.cannotEditFormat)
        #expect(ValueEditRules.editBlockReason(text, format: .unicode, isValid: true, isCompressed: false) == nil)
    }

    @Test func nonPrintableValuesBlockUnicodeEditsButNotASCII() {
        let binary = Data([0xFF, 0x00, 0xC3])
        let reason = ValueEditRules.editBlockReason(binary, format: .unicode, isValid: false, isCompressed: false)
        #expect(reason?.hasPrefix(ValueEditRules.nonPrintableTitle) == true)
        #expect(ValueEditRules.editBlockReason(binary, format: .ascii, isValid: true, isCompressed: false) == nil)
    }

    @Test func asciiRoundTripsBinary() {
        let binary = Data([0xFF, 0x00, 0x41, 0x0A])
        let text = ValueEditRules.editorText(binary, format: .ascii)
        let encoded = ValueEditRules.encode(text, format: .ascii)
        #expect(encoded.isValid)
        #expect(encoded.data == binary)
    }

    @Test func jsonEditorPrettyPrintsAndSavesCompact() {
        let value = Data(#"{"a":1,"b":[true,null]}"#.utf8)
        let text = ValueEditRules.editorText(value, format: .json)
        #expect(text.contains("\n"))
        let encoded = ValueEditRules.encode(text, format: .json)
        #expect(encoded.isValid)
        #expect(String(decoding: encoded.data, as: UTF8.self) == #"{"a":1,"b":[true,null]}"#)
    }

    @Test func invalidJSONIsSavedAsUnicode() {
        let encoded = ValueEditRules.encode("{not json", format: .json)
        #expect(!encoded.isValid)
        #expect(encoded.data == Data("{not json".utf8))
    }

    @Test func dateTimeAndMarkdownEditRawText() {
        let stamp = Data("1700000000".utf8)
        #expect(ValueEditRules.editorText(stamp, format: .dateTime) == "1700000000")
        #expect(ValueEditRules.encode("1700000001", format: .dateTime) == (Data("1700000001".utf8), true))
        #expect(ValueEditRules.encode("# Title", format: .markdown).data == Data("# Title".utf8))
    }
}

struct TTLInputTests {
    @Test func sanitizeKeepsDigitsAndClamps() {
        #expect(TTLInput.sanitize("12a3") == "123")
        #expect(TTLInput.sanitize("007") == "7")
        #expect(TTLInput.sanitize("0") == "0")
        #expect(TTLInput.sanitize("99999999999") == "2147483647")
        #expect(TTLInput.sanitize("") == "")
    }

    @Test func parseTreatsEmptyAsNoLimit() {
        #expect(TTLInput.parse("") == -1)
        #expect(TTLInput.parse("0") == 0)
        #expect(TTLInput.parse("3600") == 3600)
        #expect(TTLInput.parse("-5") == nil)
        #expect(TTLInput.parse("2147483648") == nil)
    }

    @Test func parseCountNeedsPositive() {
        #expect(TTLInput.parseCount("3") == 3)
        #expect(TTLInput.parseCount("0") == nil)
        #expect(TTLInput.parseCount("") == nil)
        #expect(TTLInput.parseCount("x") == nil)
    }
}

struct KeyValueParsingTests {
    @Test func scanReplySplitsCursorAndItems() throws {
        let reply = RESPValue.array([.bulk("17"), .array([.bulk("a"), .bulk("1"), .bulkString(Data([0xFF]))])])
        let parsed = try #require(KeyValueParsing.scanReply(reply))
        #expect(parsed.cursor == 17)
        #expect(parsed.items == [Data("a".utf8), Data("1".utf8), Data([0xFF])])
        #expect(KeyValueParsing.scanReply(.bulk("x")) == nil)
    }

    @Test func pairsDropTrailingOddItem() {
        let pairs = KeyValueParsing.pairs([Data("f".utf8), Data("v".utf8), Data("x".utf8)])
        #expect(pairs.count == 1)
        #expect(pairs.first?.0 == Data("f".utf8))
        #expect(pairs.first?.1 == Data("v".utf8))
    }

    @Test func fieldTTLsPadsMissingEntries() {
        #expect(KeyValueParsing.fieldTTLs(.array([.integer(-1), .integer(30)]), count: 3) == [-1, 30, nil])
        #expect(KeyValueParsing.fieldTTLs(.error(RESPError("ERR")), count: 2) == [nil, nil])
    }

    @Test func poppedValuesHandleSingleArrayAndNull() {
        #expect(KeyValueParsing.poppedValues(.bulk("a")) == [Data("a".utf8)])
        #expect(KeyValueParsing.poppedValues(.array([.bulk("a"), .bulk("b")])).count == 2)
        #expect(KeyValueParsing.poppedValues(.null).isEmpty)
    }

    @Test func exactMatchUnescapesGlobCharacters() {
        #expect(KeyValueParsing.exactMatch("field") == Data("field".utf8))
        #expect(KeyValueParsing.exactMatch(#"a\*b"#) == Data("a*b".utf8))
        #expect(KeyValueParsing.exactMatch("f*") == nil)
        #expect(KeyValueParsing.exactMatch("") == nil)
    }

    @Test func listIndexAcceptsDigitsOnly() {
        #expect(KeyValueParsing.listIndex("42") == 42)
        #expect(KeyValueParsing.listIndex("-1") == nil)
        #expect(KeyValueParsing.listIndex("4a") == nil)
    }
}

struct ValueDisplayTests {
    @Test func singleLineFoldsNewlinesAndTruncates() {
        #expect(ValueDisplayFormatter.singleLine("a\nb\tc", limit: 10) == "a b c")
        #expect(ValueDisplayFormatter.singleLine(String(repeating: "x", count: 20), limit: 5) == "xxxxx…")
    }

    @Test func previewMarksInvalidConversions() {
        let formatter = ValueDisplayFormatter(format: .json)
        let preview = formatter.preview(Data("not json".utf8), columnTitle: "Value")
        #expect(!preview.isValid)
        #expect(preview.tooltip.hasPrefix("Failed to convert to JSON"))
        let valid = formatter.preview(Data(#"{"a":1}"#.utf8), columnTitle: "Value")
        #expect(valid.isValid)
        #expect(valid.tooltip.hasPrefix("Value"))
    }

    @Test func previewOfLargeValueIsBounded() {
        let big = Data(String(repeating: "abc", count: 2_000_000).utf8)
        let preview = ValueDisplayFormatter(format: .unicode).preview(big)
        #expect(preview.text.count <= ValueDisplayFormatter.collapsedLength + 1)
        #expect(preview.tooltip.count <= ValueDisplayFormatter.tooltipLength + 10)
    }

    @Test func shortNamesAreMiddleElided() {
        let long = String(repeating: "k", count: 100)
        #expect(DisplayName.short(long).count <= 68)
        #expect(DisplayName.of(Data([0x61, 0x00])) == #"a\x00"#)
    }
}

struct KeyHeaderLabelsTests {
    @Test func lengthLabelsPerType() {
        #expect(KeyHeaderLabels.stats(for: KeyInfo(name: Data(), type: .stream, length: 3)).first?.label == "Entries")
        #expect(KeyHeaderLabels.stats(for: KeyInfo(name: Data(), type: .json, length: 3)).first?.label == "Top-level values")
        #expect(KeyHeaderLabels.stats(for: KeyInfo(name: Data(), type: .timeSeries, length: 3)).first?.label == "Samples")
        #expect(KeyHeaderLabels.stats(for: KeyInfo(name: Data(), type: .graph, length: 3)).first?.label == "Nodes")
        #expect(KeyHeaderLabels.stats(for: KeyInfo(name: Data(), type: .hash, length: 1234)).first?.value == "1,234")
    }

    @Test func vectorSetAndArrayExtras() {
        let vector = KeyHeaderLabels.stats(for: KeyInfo(name: Data(), type: .vectorSet, length: 2, quantType: "int8", vectorDim: 3))
        #expect(vector.map(\.label) == ["Length", "Quantization", "Dimensions"])
        #expect(vector.map(\.shortLabel) == ["Length", "Q", "Dim"])
        let array = KeyHeaderLabels.stats(for: KeyInfo(name: Data(), type: .array, lengthString: "18446744073709551615", count: "7"))
        #expect(array.first?.value == "18446744073709551615")
        #expect(array.last?.label == "Count")
    }

    @Test func sizeAndTTLText() {
        #expect(KeyHeaderLabels.size(-1) == nil)
        #expect(KeyHeaderLabels.size(2048) == "2 KB")
        #expect(KeyHeaderLabels.ttl(-1) == "No limit")
        #expect(KeyHeaderLabels.ttl(86400) == "86,400")
    }

    @Test func metadataItemsListTypeSizeLengthAndTTL() {
        let info = KeyInfo(name: Data(), type: .hash, ttl: 90, size: 2048, length: 3)
        let items = KeyHeaderLabels.metadataItems(for: info)
        #expect(items.map(\.label) == ["Type", "Size", "Length", "TTL"])
        #expect(items.map(\.value) == ["Hash", "2 KB", "3", "1 min"])
        #expect(items.last?.help?.contains("90 s") == true)

        let big = KeyHeaderLabels.metadataItems(for: KeyInfo(name: Data(), type: .string, ttl: -1, size: -1))
        #expect(big.first { $0.label == "Size" }?.value == "Too large")
        #expect(big.first { $0.label == "Size" }?.help == KeyHeaderLabels.sizeTooLargeHelp)
        #expect(big.last?.value == "No limit")

        let unknownSize = KeyHeaderLabels.metadataItems(for: KeyInfo(name: Data(), type: .set, ttl: -1, length: 1))
        #expect(!unknownSize.contains { $0.label == "Size" })
    }

    @Test func searchablePrefix() {
        #expect(KeyHeaderViewModel.prefix(of: Data("user:1:name".utf8)) == "user:1:")
        #expect(KeyHeaderViewModel.prefix(of: Data("plain".utf8)) == nil)
    }
}

@MainActor
struct HeaderFullScreenTests {
    @Test func toggleFlipsOnceWhetherOrNotTheHostToggles() {
        let session = RedisTestServer.mockSession()
        let state = KeyDetailsState(key: Data("k".utf8))
        let hostToggles = KeyDetailsContext(session: session, key: state.key, type: .string, state: state,
                                            onToggleFullScreen: { state.isFullScreen.toggle() })
        let model = KeyHeaderViewModel(context: hostToggles)
        model.toggleFullScreen()
        #expect(state.isFullScreen)
        model.toggleFullScreen()
        #expect(!state.isFullScreen)

        let passive = KeyHeaderViewModel(context: KeyDetailsContext(session: session, key: state.key, type: .string,
                                                                    state: state))
        passive.toggleFullScreen()
        #expect(state.isFullScreen)
    }

    @Test func refreshLockCombinesOwners() {
        let state = KeyDetailsState(key: Data("k".utf8))
        RefreshLock.set(state, owner: "header", locked: true)
        RefreshLock.set(state, owner: "value", locked: true)
        RefreshLock.set(state, owner: "header", locked: false)
        #expect(state.isRefreshDisabled)
        RefreshLock.set(state, owner: "value", locked: false)
        #expect(!state.isRefreshDisabled)
    }
}

struct KeyTableTextTests {
    @Test func countSummaryUsesGroupedCounts() {
        #expect(KeyTableText.countSummary(loaded: 12, total: 12, noun: "fields") == "12 fields")
        #expect(KeyTableText.countSummary(loaded: 1_500, total: 1_200, noun: "fields") == "1,500 fields")
        #expect(KeyTableText.countSummary(loaded: 500, total: 12_345, noun: "members") == "500 of 12,345 members")
    }
}
