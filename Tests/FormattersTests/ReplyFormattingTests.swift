import Foundation
@testable import Formatters
import RESP
import Testing

struct ReplyNodeBuilderTests {
    @Test func asciiModeEscapesBytes() throws {
        let value = RESPValue.bulkString(Data([0xE5, 0x90, 0x8D, 0x22]))
        #expect(try ReplyNodeBuilder.build(value, mode: .ascii, command: "GET k") == .string(#"\xe5\x90\x8d\""#))
        #expect(try ReplyNodeBuilder.build(value, mode: .raw, command: "GET k") == .string("名\""))
    }

    @Test func humanReadableCommandsStayUTF8() throws {
        let info = RESPValue.bulkString(Data("# Server\r\nredis_version:8.0".utf8))
        #expect(try ReplyNodeBuilder.build(info, mode: .ascii, command: "info server") == .string("# Server\r\nredis_version:8.0"))
        #expect(ReplyNodeBuilder.isHumanReadable("CLIENT   LIST"))
        #expect(ReplyNodeBuilder.isHumanReadable("memory doctor"))
        #expect(!ReplyNodeBuilder.isHumanReadable("client kill"))
    }

    @Test func mapsEveryRESPType() throws {
        let value = RESPValue.array([
            .integer(-3), .null, .bulkString(nil), .error(RESPError("ERR bad")), .simpleString("OK"),
            .bigNumber("18446744073709551616"), .boolean(true), .double(1.5),
            .map([(.simpleString("k"), .integer(1))]), .set([.simpleString("m")]),
        ])
        let node = try ReplyNodeBuilder.build(value, mode: .ascii, command: "X")
        #expect(node == .array([
            .integer("-3"), .null, .null, .error("ERR bad"), .string("OK"), .integer("18446744073709551616"),
            .integer("1"), .string("1.5"), .array([.string("k"), .integer("1")]), .array([.string("m")]),
        ]))
    }

    @Test func replyNodeIsCodable() throws {
        let node = ReplyNode.array([.string("a"), .integer("1"), .null, .error("e"), .array([])])
        let data = try JSONEncoder().encode(node)
        #expect(try JSONDecoder().decode(ReplyNode.self, from: data) == node)
    }
}

struct ReplyTextFormatterTests {
    @Test func scalars() throws {
        #expect(try ReplyTextFormatter.text(.null) == "(nil)")
        #expect(try ReplyTextFormatter.text(.integer("5")) == "(integer) 5")
        #expect(try ReplyTextFormatter.text(.string("OK")) == "\"OK\"")
        #expect(try ReplyTextFormatter.text(.error("ERR x")) == "ERR x")
        #expect(try ReplyTextFormatter.text(.array([])) == "(empty list or set)")
        #expect(ReplyTextFormatter.text(.string("# Server\nx:1"), command: "info") == "# Server\nx:1")
        #expect(ReplyTextFormatter.text(.string("v"), command: "get k") == "\"v\"")
    }

    @Test func nestedArraysIndentThreeSpacesPerLevel() throws {
        let node = ReplyNode.array([
            .string("a"),
            .array([.string("b"), .integer("2"), .array([.string("c"), .string("d")])]),
            .null,
            .array([]),
        ])
        #expect(try ReplyTextFormatter.text(node) == """
        1) "a"
        2) 1) "b"
           2) (integer) 2
           3) 1) "c"
              2) "d"
        3) (nil)
        4) (empty list or set)
        """)
    }
}

struct ASCIISafeEscapingTests {
    @Test func escapeAndUnescape() throws {
        #expect(try ASCIISafeEscaping.escape(Data([0x07, 0x41, 0x0A, 0xFF])) == #"\aA\n\xff"#)
        #expect(try ASCIISafeEscaping.unescape(#"\x41\x4a\"\\\a\b\t\n\r\z\x4"#) == Data([0x41, 0x4A, 0x22, 0x5C, 0x07, 0x08, 0x09, 0x0A, 0x0D, 0x5C, 0x7A, 0x5C, 0x78, 0x34]))
        let all = Data((0...255).map { UInt8($0) })
        #expect(try ASCIISafeEscaping.unescape(try ASCIISafeEscaping.escape(all)) == all)
    }
}

struct CommandLineSplitterTests {
    private func split(_ s: String) throws -> [String] { try CommandLineSplitter.splitStrings(s) }

    @Test func splitsLikeRedisCli() throws {
        #expect(try split(#"set "a b" 'c d'"#) == ["set", "a b", "c d"])
        #expect(try split("  a   b  ") == ["a", "b"])
        #expect(try split(#"foo"bar""#) == ["foobar"])
        #expect(try split(#"'it\'s'"#) == ["it's"])
        #expect(try split(#""""#) == [""])
        #expect(try split(#""\xZZ""#) == ["xZZ"])
        #expect(try split("set k 名字") == ["set", "k", "名字"])
        #expect(try split("") == [])
        #expect(try split("a\tb") == ["a", "b"])
    }

    @Test func binaryEscapes() throws {
        let args = try CommandLineSplitter.split(#"set k "\x00\xff\n\t\a\b\r\"""#)
        #expect(args == [Data("set".utf8), Data("k".utf8), Data([0x00, 0xFF, 0x0A, 0x09, 0x07, 0x08, 0x0D, 0x22])])
    }

    @Test func errors() {
        #expect(throws: CommandLineSplitterError.unbalancedQuotes) { try CommandLineSplitter.split(#"get "abc"#) }
        #expect(throws: CommandLineSplitterError.unbalancedQuotes) { try CommandLineSplitter.split("get 'abc") }
        #expect(throws: CommandLineSplitterError.invalidArguments) { try CommandLineSplitter.split(#"get "a"b"#) }
        #expect(CommandLineSplitterError.unbalancedQuotes.errorDescription == "Invalid arguments: a quote is never closed.")
        #expect(CommandLineSplitterError.invalidArguments.errorDescription == "Invalid arguments: add a space after the closing quote.")
    }
}

struct DisplayFormattingTests {
    @Test(arguments: [
        ("1234567891", true), ("1234567891234", true), ("-123456789", true), ("123", false), ("1234567891asd", false),
        ("2024-08-02T00:00:00.000Z", true), ("10-10-2020", true), ("10/10/2020", true), ("10/10/2020invalid", false),
        ("invalid", false), ("", false), ("user:1", false),
    ])
    func timestampDetector(_ input: String, _ expected: Bool) {
        #expect(TimestampDetector.isTimestamp(input) == expected)
    }

    @Test func helpers() {
        #expect(ByteFormatter.format(0) == "0 B")
        #expect(ByteFormatter.format(1024) == "1 KB")
        #expect(DurationText.full(seconds: 3725) == "1 h 2 min 5 s")
        #expect(DurationText.firstUnit(seconds: 90000) == "1 d")
        #expect(NumberFormatting.approximatePercentage(total: 1000, part: 1) == "<1%")
        #expect(TextTruncation.formatLongName(String(repeating: "a", count: 600)).count == 500)
    }

    @Test func bigIntText() {
        #expect(BigIntText.fromTwosComplementLE([0xFF]) == "-1")
        #expect(BigIntText.fromTwosComplementLE([0x00, 0x80]) == "-32768")
        #expect(BigIntText.fromTwosComplementLE([0xFF, 0x00]) == "255")
        #expect(BigIntText.fromMagnitude(bigEndian: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], negative: false) == "18446744073709551616")
        #expect(BigIntText.applyScale("-5", scale: 3) == "-0.005")
        #expect(BigIntText.applyScale("12", scale: -2) == "1200")
    }

    @Test func bigIntTextLargeValues() {
        let tenToThe30: [UInt8] = [0x0C, 0x9F, 0x2C, 0x9C, 0xD0, 0x46, 0x74, 0xED, 0xEA, 0x40, 0x00, 0x00, 0x00]
        #expect(BigIntText.fromMagnitude(bigEndian: tenToThe30, negative: true) == "-1" + String(repeating: "0", count: 30))
        #expect(BigIntText.fromMagnitude(bigEndian: [0, 0, 0x3B, 0x9A, 0xCA, 0x00], negative: false) == "1000000000")
        #expect(BigIntText.fromMagnitude(bigEndian: [0, 0], negative: false) == "0")

        let allOnes = [UInt8](repeating: 0xFF, count: BigIntText.maxDecimalBytes)
        let digits = BigIntText.fromMagnitude(bigEndian: allOnes, negative: false)
        #expect(digits.count == 39_457)
        #expect(digits.hasPrefix("40141321820360630391"))
        #expect(digits.hasSuffix("65812318570934173695"))

        let tooLong = [UInt8](repeating: 0xAB, count: BigIntText.maxDecimalBytes + 1)
        #expect(BigIntText.fromMagnitude(bigEndian: tooLong, negative: true) == "-0x" + tooLong.hexString)
    }

    @Test func hexFieldUsesUppercasePairs() {
        #expect(ValueDecoderEngine.spacedUpperHex([0x0A, 0xFF, 0x00]) == "0A FF 00")
        #expect(ValueDecoderEngine.spacedUpperHex([]) == "")
    }

    @Test func bigDecimalScaleKeepsOutputSmall() throws {
        let limit = BigIntText.maxScalePadding
        #expect(BigIntText.applyScale("12345", scale: 2) == "123.45")
        #expect(BigIntText.applyScale("0", scale: 2) == "0.00")
        #expect(BigIntText.applyScale("0", scale: -3) == "0")
        #expect(BigIntText.applyScale("5", scale: limit) == "0." + String(repeating: "0", count: limit - 1) + "5")
        #expect(BigIntText.applyScale("5", scale: limit + 1) == "5E-\(limit + 1)")
        #expect(BigIntText.applyScale("7", scale: -limit) == "7" + String(repeating: "0", count: limit))
        #expect(BigIntText.applyScale("7", scale: -limit - 1) == "7E\(limit + 1)")
        #expect(BigIntText.applyScale("123", scale: 1_000_000) == "123E-1000000")
        #expect(BigIntText.applyScale("-123", scale: -1_000_000) == "-123E1000000")
        #expect(BigIntText.applyScale("123", scale: Int(Int32.max)) == "123E-2147483647")
        #expect(BigIntText.applyScale("-123", scale: Int(Int32.min)) == "-123E2147483648")
        #expect(BigIntText.applyScale("1", scale: Int.min) == "1E9223372036854775808")
        let long = String(repeating: "9", count: 5_000)
        #expect(BigIntText.applyScale(long, scale: 4_000) == String(repeating: "9", count: 1_000) + "." + String(repeating: "9", count: 4_000))
        for text in ["123E-1000000", "-123E1000000", "123E-2147483647", "-123E2147483648", "0.00"] {
            _ = try JSONParser.parse(text)
        }
    }
}
