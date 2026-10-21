import Foundation
import RESP
import Testing

private func bytes(_ s: String) -> Data { Data(s.utf8) }

private func parseOne(_ s: String) throws -> RESPValue? {
    var parser = RESPParser()
    parser.feed(bytes(s))
    return try parser.next()
}

struct RESPParserTests {

    // MARK: RESP2 scalars

    @Test func simpleString() throws {
        #expect(try parseOne("+OK\r\n") == .simpleString("OK"))
        #expect(try parseOne("+\r\n") == .simpleString(""))
    }

    @Test func errorReply() throws {
        let value = try parseOne("-WRONGTYPE Operation against a key\r\n")
        #expect(value == .error(RESPError("WRONGTYPE Operation against a key")))
        #expect(value?.errorValue?.code == "WRONGTYPE")
        #expect(RESPError("MOVED 3999 127.0.0.1:6381").code == "MOVED")
        #expect(RESPError("unknown thing").code == nil)
    }

    @Test func integers() throws {
        #expect(try parseOne(":0\r\n") == .integer(0))
        #expect(try parseOne(":-42\r\n") == .integer(-42))
        #expect(try parseOne(":+7\r\n") == .integer(7))
        #expect(try parseOne(":9223372036854775807\r\n") == .integer(.max))
        #expect(try parseOne(":-9223372036854775808\r\n") == .integer(.min))
        #expect(throws: RESPParserError.self) { try parseOne(":9223372036854775808\r\n") }
        #expect(throws: RESPParserError.self) { try parseOne(":12a\r\n") }
        #expect(throws: RESPParserError.self) { try parseOne(":\r\n") }
    }

    @Test func bulkStrings() throws {
        #expect(try parseOne("$5\r\nhello\r\n") == .bulk("hello"))
        #expect(try parseOne("$0\r\n\r\n") == .bulkString(Data()))
        #expect(try parseOne("$-1\r\n") == .bulkString(nil))
        #expect(try parseOne("$-1\r\n")?.isNull == true)
    }

    @Test func bulkStringIsBinarySafe() throws {
        let payload = Data([0x00, 0x0D, 0x0A, 0xFF, 0x24, 0x0D])
        var data = bytes("$6\r\n")
        data.append(payload)
        data.append(bytes("\r\n"))
        var parser = RESPParser()
        parser.feed(data)
        #expect(try parser.next() == .bulkString(payload))
    }

    @Test func bulkStringMissingTerminatorThrows() {
        #expect(throws: RESPParserError.self) { try parseOne("$3\r\nabcXY") }
    }

    @Test func invalidLengthsThrow() {
        #expect(throws: RESPParserError.self) { try parseOne("$-2\r\n") }
        #expect(throws: RESPParserError.self) { try parseOne("$abc\r\n") }
        #expect(throws: RESPParserError.self) { try parseOne("*x\r\n") }
    }

    @Test func invalidTypeByteThrows() {
        #expect(throws: RESPParserError.invalidTypeByte(UInt8(ascii: "?"))) { try parseOne("?what\r\n") }
    }

    @Test func bulkLengthLimit() {
        var parser = RESPParser(maxBulkLength: 10)
        parser.feed(bytes("$11\r\n"))
        #expect(throws: RESPParserError.self) { try parser.next() }
    }

    // MARK: Aggregates

    @Test func arrays() throws {
        #expect(try parseOne("*0\r\n") == .array([]))
        #expect(try parseOne("*-1\r\n") == .array(nil))
        #expect(try parseOne("*3\r\n:1\r\n$1\r\na\r\n$-1\r\n") == .array([.integer(1), .bulk("a"), .bulkString(nil)]))
    }

    @Test func nestedArrays() throws {
        let value = try parseOne("*2\r\n*2\r\n:1\r\n*1\r\n+x\r\n*0\r\n")
        #expect(value == .array([.array([.integer(1), .array([.simpleString("x")])]), .array([])]))
    }

    @Test func errorsInsideArrays() throws {
        let value = try parseOne("*2\r\n+OK\r\n-ERR boom\r\n")
        #expect(value == .array([.ok, .error(RESPError("ERR boom"))]))
    }

    @Test func deepNestingIsLimited() {
        var parser = RESPParser(maxDepth: 8)
        parser.feed(bytes(String(repeating: "*1\r\n", count: 9) + ":1\r\n"))
        #expect(throws: RESPParserError.self) { try parser.next() }
        var ok = RESPParser(maxDepth: 8)
        ok.feed(bytes(String(repeating: "*1\r\n", count: 8) + ":1\r\n"))
        #expect((try? ok.next()) != nil)
    }

    @Test func multipleValuesInOneChunk() throws {
        var parser = RESPParser()
        parser.feed(bytes("+A\r\n:1\r\n$1\r\nb\r\n*1\r\n_\r\n"))
        let values = try parser.drain()
        #expect(values == [.simpleString("A"), .integer(1), .bulk("b"), .array([.null])])
        #expect(parser.bufferedByteCount == 0)
        #expect(!parser.isInsideAggregate)
    }

    // MARK: RESP3

    @Test func resp3Scalars() throws {
        #expect(try parseOne("_\r\n") == .null)
        #expect(try parseOne("#t\r\n") == .boolean(true))
        #expect(try parseOne("#f\r\n") == .boolean(false))
        #expect(throws: RESPParserError.self) { try parseOne("#x\r\n") }
        #expect(try parseOne(",3.14\r\n") == .double(3.14))
        #expect(try parseOne(",10\r\n") == .double(10))
        #expect(try parseOne(",inf\r\n") == .double(.infinity))
        #expect(try parseOne(",-inf\r\n") == .double(-.infinity))
        #expect(try parseOne(",nan\r\n")?.doubleValue?.isNaN == true)
        #expect(try parseOne(",1.5e3\r\n") == .double(1500))
        #expect(throws: RESPParserError.self) { try parseOne(",abc\r\n") }
        #expect(try parseOne("(3492890328409238509324850943850943825024385\r\n") == .bigNumber("3492890328409238509324850943850943825024385"))
    }

    @Test func blobErrorAndVerbatim() throws {
        #expect(try parseOne("!21\r\nSYNTAX invalid syntax\r\n") == .error(RESPError("SYNTAX invalid syntax")))
        #expect(try parseOne("=15\r\ntxt:Some string\r\n") == .verbatimString(format: "txt", text: bytes("Some string")))
        #expect(try parseOne("=7\r\nmkd:# H\r\n") == .verbatimString(format: "mkd", text: bytes("# H")))
    }

    @Test func mapsSetsPush() throws {
        let map = try parseOne("%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n")
        #expect(map == .map([(.simpleString("first"), .integer(1)), (.simpleString("second"), .integer(2))]))
        #expect(map?.stringKeyedMap?["second"] == .integer(2))
        #expect(try parseOne("%0\r\n") == .map([]))
        #expect(try parseOne("~2\r\n+a\r\n+b\r\n") == .set([.simpleString("a"), .simpleString("b")]))
        #expect(try parseOne(">3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$2\r\nhi\r\n") == .push([.bulk("message"), .bulk("ch"), .bulk("hi")]))
        #expect(try parseOne("%-1\r\n") == .null)
    }

    @Test func attributesAreSkipped() throws {
        #expect(try parseOne("|1\r\n+key-popularity\r\n%1\r\n$1\r\na\r\n,0.19\r\n:42\r\n") == .integer(42))
        // Attribute in front of an array element does not count as an element.
        let value = try parseOne("*2\r\n:1\r\n|1\r\n+ttl\r\n:3600\r\n:2\r\n")
        #expect(value == .array([.integer(1), .integer(2)]))
        #expect(try parseOne("|0\r\n+OK\r\n") == .ok)
    }

    @Test func inlineCommandsWhenEnabled() throws {
        var parser = RESPParser(allowInline: true)
        parser.feed(bytes("PING\r\nSET k \"a b\\n\" 'c d'\r\n*1\r\n$4\r\nPING\r\n"))
        #expect(try parser.next() == .bulkArray(["PING"]))
        #expect(try parser.next() == .bulkArray(["SET", "k", "a b\n", "c d"]))
        #expect(try parser.next() == .bulkArray(["PING"]))
        var strict = RESPParser()
        strict.feed(bytes("PING\r\n"))
        #expect(throws: RESPParserError.self) { try strict.next() }
    }

    // MARK: Incremental

    @Test func incompleteFramesReturnNil() throws {
        for partial in ["+OK", "+OK\r", "$5\r\nhel", "$5\r\nhello\r", "*2\r\n:1\r\n", "%1\r\n+a\r\n", ":", "", "|1\r\n+a\r\n:1\r\n"] {
            var parser = RESPParser()
            parser.feed(bytes(partial))
            #expect(try parser.next() == nil, "partial \(partial.debugDescription)")
        }
    }

    @Test func crInsideSimpleStringWaitsForLF() throws {
        var parser = RESPParser()
        parser.feed(bytes("+a\rb\r"))
        #expect(try parser.next() == nil)
        parser.feed(bytes("\n"))
        #expect(try parser.next() == .simpleString("a\rb"))
    }

    static let corpus: [RESPValue] = [
        .ok,
        .error(RESPError("ERR unknown command 'foo'")),
        .integer(-123456789),
        .bulk("hello world"),
        .bulkString(Data([0, 13, 10, 255, 128, 13])),
        .bulkString(nil),
        .bulkString(Data()),
        .array(nil),
        .array([]),
        .array([.bulk("a"), .array([.integer(1), .array([.bulkString(nil), .bulk("deep")])]), .simpleString("x")]),
        .null,
        .double(2.5),
        .double(-.infinity),
        .boolean(true),
        .bigNumber("123456789012345678901234567890"),
        .verbatimString(format: "txt", text: Data("verbatim\r\ntext".utf8)),
        .map([(.bulk("k1"), .integer(1)), (.bulk("k2"), .array([.bulk("v")]))]),
        .set([.bulk("m1"), .bulk("m2")]),
        .push([.bulk("pmessage"), .bulk("*"), .bulk("ch"), .bulk("payload")]),
    ]

    @Test func splitAtEveryByte() throws {
        var stream = Data()
        for value in Self.corpus { RESPEncoder.appendValue(value, to: &stream) }
        let all = [UInt8](stream)
        for split in 0...all.count {
            var parser = RESPParser()
            parser.feed(Data(all[0..<split]))
            var values = try parser.drain()
            parser.feed(Data(all[split...]))
            values += try parser.drain()
            #expect(values == Self.corpus, "split at \(split)")
            #expect(parser.bufferedByteCount == 0)
        }
    }

    @Test func byteAtATime() throws {
        var stream = Data()
        for value in Self.corpus { RESPEncoder.appendValue(value, to: &stream) }
        var parser = RESPParser()
        var values: [RESPValue] = []
        for byte in stream {
            parser.feed([byte])
            values += try parser.drain()
        }

        #expect(values == Self.corpus)
    }

    @Test func randomChunkingIsDeterministic() throws {
        var stream = Data()
        for _ in 0..<20 { for value in Self.corpus { RESPEncoder.appendValue(value, to: &stream) } }
        let all = [UInt8](stream)
        var rng = SeededGenerator(seed: 0xC0FFEE)
        for _ in 0..<200 {
            var parser = RESPParser()
            var values: [RESPValue] = []
            var index = 0
            while index < all.count {
                let size = Int.random(in: 1...97, using: &rng)
                let end = min(all.count, index + size)
                parser.feed(Data(all[index..<end]))
                values += try parser.drain()
                index = end
            }

            #expect(values.count == Self.corpus.count * 20)
            #expect(Array(values.prefix(Self.corpus.count)) == Self.corpus)
        }
    }

    @Test func largeBulkStringInChunks() throws {
        let payload = Data((0..<(5 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let frame = RESPEncoder.encodeValue(.bulkString(payload))
        var parser = RESPParser()
        var result: RESPValue?
        var index = 0
        while index < frame.count {
            let end = min(frame.count, index + 65_536)
            parser.feed(frame.subdata(in: index..<end))
            if let value = try parser.next() { result = value }
            index = end
        }

        #expect(result == .bulkString(payload))
        #expect(parser.bufferedByteCount == 0)
    }

    @Test func largeArrayInChunksIsLinear() throws {
        let count = 200_000
        let value = RESPValue.array((0..<count).map { .bulk("member:\($0)") })
        let frame = RESPEncoder.encodeValue(value)
        var parser = RESPParser()
        var result: RESPValue?
        var index = 0
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            while index < frame.count {
                let end = min(frame.count, index + 4096)
                parser.feed(frame.subdata(in: index..<end))
                if let v = try parser.next() { result = v }
                index = end
            }
        }
        #expect(result?.arrayValue?.count == count)
        #expect(result?.arrayValue?.last == .bulk("member:\(count - 1)"))
        #expect(elapsed < .seconds(20))
    }

    @Test func resetClearsState() throws {
        var parser = RESPParser()
        parser.feed(bytes("*2\r\n:1\r\n"))
        #expect(try parser.next() == nil)
        #expect(parser.isInsideAggregate)
        parser.reset()
        parser.feed(bytes("+OK\r\n"))
        #expect(try parser.next() == .ok)
    }

    @Test func parseAllRejectsIncomplete() throws {
        #expect(try RESPParser.parseAll(bytes("+A\r\n:2\r\n")) == [.simpleString("A"), .integer(2)])
        #expect(throws: RESPParserError.self) { try RESPParser.parseAll(bytes("*2\r\n:1\r\n")) }
    }
}

/// SplitMix64, so the chunking test is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
