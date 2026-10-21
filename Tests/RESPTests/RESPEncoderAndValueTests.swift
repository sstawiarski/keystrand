import Foundation
import RESP
import Testing

struct RESPEncoderTests {
    @Test func encodesMixedArguments() {
        let data = RESPEncoder.encode(["ZADD", "z", .double(1.5), .int(-3), .uint(7), .double(.infinity)])
        let expected = "*6\r\n$4\r\nZADD\r\n$1\r\nz\r\n$3\r\n1.5\r\n$2\r\n-3\r\n$1\r\n7\r\n$3\r\ninf\r\n"
        #expect(data == Data(expected.utf8))
    }

    @Test func encodesEmptyArgumentAndUnicode() {
        let data = RESPEncoder.encode(["SET", "ключ", ""])
        #expect(data == Data("*3\r\n$3\r\nSET\r\n$8\r\nключ\r\n$0\r\n\r\n".utf8))
    }

    @Test func encodesDataCommands() {
        let data = RESPEncoder.encode([Data("GET".utf8), Data([0xFF, 0x00])])
        #expect(data == Data("*2\r\n$3\r\nGET\r\n$2\r\n".utf8) + Data([0xFF, 0x00]) + Data("\r\n".utf8))
    }

    @Test func encodesPipeline() {
        let data = RESPEncoder.encodePipeline([["PING"], ["ECHO", "x"]])
        #expect(data == Data("*1\r\n$4\r\nPING\r\n*2\r\n$4\r\nECHO\r\n$1\r\nx\r\n".utf8))
    }

    @Test func commandRoundTripsThroughInlineAwareParser() throws {
        let args: [RedisArgument] = ["HSET", .data(Data([0, 1, 2, 13, 10])), "field", 42]
        let parsed = try RESPParser.parseAll(RESPEncoder.encode(args))
        #expect(parsed == [.array(args.map { .bulkString($0.data) })])
    }

    @Test func doubleFormatting() {
        #expect(RedisArgument.format(1) == "1")
        #expect(RedisArgument.format(-2.0) == "-2")
        #expect(RedisArgument.format(0.25) == "0.25")
        #expect(RedisArgument.format(-.infinity) == "-inf")
        #expect(RedisArgument.format(.nan) == "nan")
    }

    @Test func literalsAndConvertibles() {
        let a: RedisArgument = "x"
        let b: RedisArgument = 5
        let c: RedisArgument = 1.25
        #expect(a == .string("x") && b == .int(5) && c == .double(1.25))
        #expect(5.redisArgument == .int(5))
        #expect(Data([1]).redisArgument == .data(Data([1])))
        #expect(["a", "b"].redisArguments == [.string("a"), .string("b")])
    }
}

struct RESPValueTests {
    @Test func accessors() {
        #expect(RESPValue.bulk("12").intValue == 12)
        #expect(RESPValue.bulk(" 7 ").intValue == 7)
        #expect(RESPValue.integer(3).stringValue == "3")
        #expect(RESPValue.simpleString("OK").stringValue == "OK")
        #expect(RESPValue.bulk("3.5").doubleValue == 3.5)
        #expect(RESPValue.bulk("+inf").doubleValue == .infinity)
        #expect(RESPValue.double(2.9).intValue == 2)
        #expect(RESPValue.boolean(true).intValue == 1)
        #expect(RESPValue.integer(0).boolValue == false)
        #expect(RESPValue.bulk("18446744073709551615").uint64Value == .max)
        #expect(RESPValue.integer(-1).uint64Value == nil)
        #expect(RESPValue.array(nil).isNull)
        #expect(RESPValue.null.isNull)
        #expect(!RESPValue.array([]).isNull)
        #expect(RESPValue.error(RESPError("ERR x")).isError)
        #expect(RESPValue.bulkString(Data([0xFF])).stringValue == "\u{FFFD}")
        #expect(RESPValue.array([.integer(1)]).dataValue == nil)
    }

    @Test func mapAccessors() {
        let flat = RESPValue.bulkArray(["a", "1", "b", "2"])
        #expect(flat.stringKeyedMap?["b"] == .bulk("2"))
        #expect(RESPValue.bulkArray(["a"]).mapValue == nil)
        let map = RESPValue.map([(.bulk("k"), .integer(1))])
        #expect(map.arrayValue == [.bulk("k"), .integer(1)])
        #expect(RESPValue.set([.bulk("x")]).arrayValue == [.bulk("x")])
    }

    @Test func hashableAndEquatable() {
        let set: Set<RESPValue> = [.integer(1), .integer(1), .bulk("a"), .double(.nan), .double(.nan)]
        #expect(set.count == 3)
        #expect(RESPValue.bulkString(nil) != RESPValue.null)
        #expect(RESPValue.map([(.bulk("a"), .null)]) != RESPValue.map([(.bulk("a"), .integer(1))]))
    }
}

struct RedisCLIRenderingTests {
    @Test func scalars() {
        #expect(RESPValue.ok.redisCLIText() == "OK")
        #expect(RESPValue.integer(5).redisCLIText() == "(integer) 5")
        #expect(RESPValue.bulkString(nil).redisCLIText() == "(nil)")
        #expect(RESPValue.null.redisCLIText() == "(nil)")
        #expect(RESPValue.array(nil).redisCLIText() == "(nil)")
        #expect(RESPValue.error(RESPError("ERR wrong")).redisCLIText() == "(error) ERR wrong")
        #expect(RESPValue.bulk("hi").redisCLIText() == "\"hi\"")
        #expect(RESPValue.double(1.5).redisCLIText() == "(double) 1.5")
        #expect(RESPValue.boolean(false).redisCLIText() == "(false)")
        #expect(RESPValue.bigNumber("123").redisCLIText() == "(big number) 123")
        #expect(RESPValue.verbatimString(format: "txt", text: Data("a\nb".utf8)).redisCLIText() == "a\nb")
    }

    @Test func escapesLikeSdscatrepr() {
        let data = Data([0x61, 0x22, 0x5C, 0x0A, 0x0D, 0x09, 0x07, 0x08, 0x00, 0xFF, 0x7F])
        #expect(RESPValue.bulkString(data).redisCLIText() == "\"a\\\"\\\\\\n\\r\\t\\a\\b\\x00\\xff\\x7f\"")
        #expect(RESPValue.bulk("héllo").redisCLIText() == "\"h\\xc3\\xa9llo\"")
    }

    @Test func emptyAggregates() {
        #expect(RESPValue.array([]).redisCLIText() == "(empty array)")
        #expect(RESPValue.set([]).redisCLIText() == "(empty set)")
        #expect(RESPValue.map([]).redisCLIText() == "(empty hash)")
    }

    @Test func nestedNumbering() {
        let value = RESPValue.array([
            .array([.bulk("a"), .array([.integer(1), .bulkString(nil)])]),
            .bulk("b"),
        ])
        let expected = """
        1) 1) "a"
           2) 1) (integer) 1
              2) (nil)
        2) "b"
        """
        #expect(value.redisCLIText() == expected)
    }

    @Test func numberPaddingForTenOrMore() {
        let value = RESPValue.array((1...10).map { .integer(Int64($0)) })
        let lines = value.redisCLIText().split(separator: "\n")
        #expect(lines.first == " 1) (integer) 1")
        #expect(lines.last == "10) (integer) 10")
        let nested = RESPValue.array((1...10).map { _ in .array([.bulk("x"), .bulk("y")]) })
        let nestedLines = nested.redisCLIText().split(separator: "\n")
        #expect(nestedLines[0] == " 1) 1) \"x\"")
        #expect(nestedLines[1] == "    2) \"y\"")
    }

    @Test func mapsAndSets() {
        let map = RESPValue.map([(.bulk("f1"), .bulk("v1")), (.bulk("f2"), .array([.integer(1), .integer(2)]))])
        #expect(map.redisCLIText() == "1# \"f1\" => \"v1\"\n2# \"f2\" => 1) (integer) 1\n   2) (integer) 2")
        #expect(RESPValue.set([.bulk("a"), .bulk("b")]).redisCLIText() == "1~ \"a\"\n2~ \"b\"")
    }

    @Test func descriptionUsesCLIText() {
        #expect(RESPValue.integer(1).description == "(integer) 1")
    }
}
