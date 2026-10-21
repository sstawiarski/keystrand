import Foundation
import RESP
import Testing

struct RESPSmokeTests {
    @Test func encodesCommand() {
        let data = RESPEncoder.encode(["SET", "k", .data(Data([0x00, 0xFF]))])
        #expect(data == Data("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$2\r\n".utf8) + Data([0x00, 0xFF]) + Data("\r\n".utf8))
    }

    @Test func parsesIncrementally() throws {
        var parser = RESPParser()
        parser.feed(Data("*2\r\n$3\r\nfoo\r\n:4".utf8))
        #expect(try parser.next() == nil)
        parser.feed(Data("2\r\n+OK\r\n".utf8))
        #expect(try parser.next() == .array([.bulkString(Data("foo".utf8)), .integer(42)]))
        #expect(try parser.next() == .simpleString("OK"))
        #expect(try parser.next() == nil)
    }

    @Test func rendersLikeRedisCLI() {
        let value = RESPValue.array([.bulkString(Data("a".utf8)), .integer(1), .bulkString(nil)])
        #expect(value.redisCLIText() == "1) \"a\"\n2) (integer) 1\n3) (nil)")
    }
}
