import Foundation
@testable import Formatters
import Testing

private let utc = TimeZone(identifier: "UTC") ?? .current

private func hex(_ s: String) -> Data {
    var out = Data()
    var chars = Array(s.filter { !$0.isWhitespace })
    while chars.count >= 2 {
        out.append(UInt8(String(chars[0...1]), radix: 16) ?? 0)
        chars.removeFirst(2)
    }

    return out
}

struct UnicodeFormatterTests {
    @Test func validUTF8() {
        let r = FormatterRegistry.format(Data("héllo 名字".utf8), as: .unicode)
        #expect(r.isValid)
        #expect(r.text == "héllo 名字")
        #expect(r.kind == .text)
    }

    @Test func invalidUTF8IsLossyAndFlagged() {
        let r = FormatterRegistry.format(Data([0x61, 0xFF, 0x62]), as: .unicode)
        #expect(!r.isValid)
        #expect(r.text == "a\u{FFFD}b")
    }

    @Test func encodeIsUTF8() throws {
        #expect(try FormatterRegistry.parseEdited("名", as: .unicode) == Data([0xE5, 0x90, 0x8D]))
    }
}

struct ASCIIFormatterTests {
    @Test func escapesLikeRedisCli() {
        let bytes = Data([0x00, 0x07, 0x08, 0x09, 0x0A, 0x0D, 0x22, 0x5C, 0x41, 0x7F, 0xE5, 0x20])
        #expect(FormatterRegistry.format(bytes, as: .ascii).text == #"\x00\a\b\t\n\r\"\\A\x7f\xe5 "#)
    }

    @Test func roundTripsEveryByte() throws {
        let all = Data((0...255).map { UInt8($0) })
        let text = FormatterRegistry.format(all, as: .ascii).text
        #expect(try FormatterRegistry.parseEdited(text, as: .ascii) == all)
    }

    @Test func parsesTypedUnicodeAndEscapes() throws {
        #expect(try FormatterRegistry.parseEdited(#"名\x00\"x\q"#, as: .ascii) == Data([0xE5, 0x90, 0x8D, 0x00, 0x22, 0x78, 0x5C, 0x71]))
    }
}

struct HexBinaryFormatterTests {
    @Test func hexRoundTrip() throws {
        let bytes = Data([0x00, 0xAB, 0x10, 0xFF])
        #expect(FormatterRegistry.format(bytes, as: .hex).text == "00ab10ff")
        #expect(try FormatterRegistry.parseEdited("00 AB 10 ff", as: .hex) == bytes)
        #expect(throws: FormatterError.self) { try FormatterRegistry.parseEdited("abc", as: .hex) }
        #expect(throws: FormatterError.self) { try FormatterRegistry.parseEdited("zz", as: .hex) }
        #expect(try FormatterRegistry.parseEditedLeniently("zz", as: .hex) == Data("zz".utf8))
    }

    @Test func binaryRoundTrip() throws {
        let bytes = Data([0x00, 0xA5, 0xFF])
        #expect(FormatterRegistry.format(bytes, as: .binary).text == "000000001010010111111111")
        #expect(try FormatterRegistry.parseEdited("00000000 10100101 11111111", as: .binary) == bytes)
        #expect(throws: FormatterError.self) { try FormatterRegistry.parseEdited("0101", as: .binary) }
        #expect(throws: FormatterError.self) { try FormatterRegistry.parseEdited("0101010x", as: .binary) }
        #expect(FormatterRegistry.format(Data(), as: .binary).text == "")
    }
}

struct JSONFormatterTests {
    @Test func validJSONBecomesTree() {
        let r = FormatterRegistry.format(Data(#"{"id":12345678901234567890,"tags":["a"]}"#.utf8), as: .json)
        #expect(r.isValid)
        #expect(r.kind == .json)
        #expect(r.displayText(expanded: false) == #"{"id":12345678901234567890,"tags":["a"]}"#)
        #expect(r.text == "{\n    \"id\": 12345678901234567890,\n    \"tags\": [\n        \"a\"\n    ]\n}")
    }

    @Test func invalidJSONFallsBackToText() {
        let r = FormatterRegistry.format(Data("not json".utf8), as: .json)
        #expect(!r.isValid)
        #expect(r.text == "not json")
        #expect(FormatResult.failedTitle(.json) == "Failed to convert to JSON")
    }

    @Test func editSerializesPrettyAndSavesCompact() throws {
        let data = Data(#"{"a": 1,   "b": [true, null]}"#.utf8)
        #expect(FormatterRegistry.serializeForEdit(data, as: .json) == "{\n    \"a\": 1,\n    \"b\": [\n        true,\n        null\n    ]\n}")
        #expect(FormatterRegistry.serializeForEdit(data, as: .json, indent: 2) == "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null\n  ]\n}")
        #expect(try FormatterRegistry.parseEdited("{ \"a\" : 1e3 }", as: .json) == Data(#"{"a":1e3}"#.utf8))
        #expect(throws: FormatterError.self) { try FormatterRegistry.parseEdited("{bad", as: .json) }
        #expect(try FormatterRegistry.parseEditedLeniently("{bad", as: .json) == Data("{bad".utf8))
        #expect(!FormatterRegistry.isValidInput("{bad", as: .json))
        #expect(FormatterRegistry.isValidInput("[1]", as: .json))
    }
}

struct VectorFormatterTests {
    @Test func float32LittleEndian() {
        let r = FormatterRegistry.format(hex("0000c03f 000000c0 ff"), as: .vector32)
        #expect(r.isValid)
        #expect(r.text == "[1.5,-2]")
        #expect(FormatterRegistry.format(hex("0000c03f000000c0"), as: .vector32, options: FormatOptions(expanded: true)).text == "[1.5, -2]")
    }

    @Test func float64LittleEndian() {
        #expect(FormatterRegistry.format(hex("9a9999999999b93f 000000000000f0bf"), as: .vector64).text == "[0.1,-1]")
    }

    @Test func utf8TextIsShownAsText() {
        let r = FormatterRegistry.format(Data("plain".utf8), as: .vector32)
        #expect(r.isValid)
        #expect(r.text == "plain")
    }

    @Test func encodeRoundTrips() throws {
        let packed = try FormatterRegistry.parseEdited("[1.5, -2, 0.25]", as: .vector32)
        #expect(packed == hex("0000c03f 000000c0 0000803e"))
        #expect(FormatterRegistry.format(packed, as: .vector32).text == "[1.5,-2,0.25]")
        let packed64 = try FormatterRegistry.parseEdited("[0.1,-1]", as: .vector64)
        #expect(packed64 == hex("9a9999999999b93f 000000000000f0bf"))
        #expect(try FormatterRegistry.parseEdited("hello", as: .vector32) == Data("hello".utf8))
        #expect(throws: FormatterError.self) { try FormatterRegistry.parseEdited("[1, x]", as: .vector32) }
    }

    @Test func nonFiniteValues() {
        let bytes = hex("0000c07f 0000807f")
        #expect(FormatterRegistry.format(bytes, as: .vector32).text == "[NaN,Infinity]")
    }
}

struct DateTimeFormatterTests {
    private func format(_ s: String, _ pattern: String = TimestampFormatter.defaultPattern) -> FormatResult {
        FormatterRegistry.format(Data(s.utf8), as: .dateTime, options: FormatOptions(dateFormat: pattern, timeZone: utc))
    }

    @Test func secondsMillisMicrosNanos() {
        #expect(format("1700000000").text == "22:13:20 14 Nov 2023")
        #expect(format(" 1700000000123 ", "yyyy-MM-dd HH:mm:ss.SSS").text == "2023-11-14 22:13:20.123")
        #expect(format("1700000000123456", "yyyy-MM-dd HH:mm:ss.SSS").text == "2023-11-14 22:13:20.123")
        #expect(format("1700000000123456789", "yyyy-MM-dd HH:mm:ss.SSS").text == "2023-11-14 22:13:20.123")
        #expect(format("1700000000.5", "HH:mm:ss.SSS").text == "22:13:20.500")
        #expect(format("-123456789", "yyyy-MM-dd HH:mm:ss").text == "1966-02-02 02:26:51")
    }

    @Test func dateFnsTokens() {
        #expect(format("1700000000", "do MMM yyyy").text == "14th Nov 2023")
        #expect(format("1700000000", "dd.MM.yyyy HH:mm:ss").text == "14.11.2023 22:13:20")
        #expect(format("1700000000", "dd-MMM-yyyy HH:mm:ss.SSS").text == "14-Nov-2023 22:13:20.000")
        #expect(format("1700000000", "'Day' d").text == "Day 14")
        #expect(format("1700000000", "T").text == "1700000000000")
        #expect(format("1700000000", "PP").text == "Nov 14, 2023")
        #expect(TimestampFormatter.ordinal(1) == "1st")
        #expect(TimestampFormatter.ordinal(12) == "12th")
        #expect(TimestampFormatter.ordinal(23) == "23rd")
        #expect(TimestampFormatter.isValidPattern("HH:mm"))
        #expect(!TimestampFormatter.isValidPattern(""))
        #expect(!TimestampFormatter.isValidPattern("'open"))
    }

    @Test func nonTimestampIsInvalid() {
        let r = format("hello")
        #expect(!r.isValid)
        #expect(r.text == "hello")
        #expect(!format("12345678911").isValid)
        #expect(throws: FormatterError.notEditable(.dateTime)) { try FormatterRegistry.parseEdited("x", as: .dateTime) }
    }

    @Test(arguments: [
        ("1234567891", true), ("1234567891234", true), ("1234567891234567", true), ("1234567891234567891", true),
        ("1234567891.2", true), ("-123456789", true), ("", false), ("-", false), ("0", false), ("1", false), ("123", false),
        ("12345678911", false), ("12345678912345", false), ("12345678912345678", false), ("1234567891.2.2", false),
        ("1234567891asd", false), ("inf", false), ("-inf", false), ("1234567891:12", false), ("1234567891a12", false),
    ])
    func checkTimestampDetection(_ input: String, _ expected: Bool) {
        #expect(TimestampFormatter.isTimestamp(input) == expected)
    }
}

struct MarkdownFormatterTests {
    @Test func passThroughFlaggedMarkdown() {
        let r = FormatterRegistry.format(Data("# Title\n*x*".utf8), as: .markdown)
        #expect(r.kind == .markdown)
        #expect(r.text == "# Title\n*x*")
        #expect(r.isValid)
        #expect(throws: FormatterError.notEditable(.markdown)) { try FormatterRegistry.parseEdited("x", as: .markdown) }
    }
}
