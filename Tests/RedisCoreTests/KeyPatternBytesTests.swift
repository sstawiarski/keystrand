import Foundation
@testable import RedisCore
import Testing

struct KeyPatternBytesTests {
    @Test func hexEscapesBecomeBytes() {
        #expect(KeyPattern.matchBytes("user:\\xff*") == Data([0x75, 0x73, 0x65, 0x72, 0x3A, 0xFF, 0x2A]))
        #expect(KeyPattern.matchBytes("\\x2a") == Data([0x5C, 0x2A]))
        #expect(KeyPattern.matchBytes("a\\*b") == Data("a\\*b".utf8))
        #expect(KeyPattern.matchBytes("\\xzz") == Data("\\xzz".utf8))
    }

    @Test func literalBytesResolveEscapes() {
        #expect(KeyPattern.literalBytes("k\\xc3\\x28") == Data([0x6B, 0xC3, 0x28]))
        #expect(KeyPattern.literalBytes("a\\*b") == Data("a*b".utf8))
        #expect(KeyPattern.literalBytes("a\\nb") == Data("a\\nb".utf8))
        #expect(!KeyPattern.isGlob("k\\xff"))
    }

    @Test func hexFilterReadsBytePairs() {
        #expect(KeyPattern.fromHexFilter("6b65*") == "\\x6b\\x65*")
        #expect(KeyPattern.fromHexFilter("6B 65") == "\\x6B\\x65")
        #expect(KeyPattern.fromHexFilter("*") == "*")
        #expect(KeyPattern.fromHexFilter("6b6") == nil)
        #expect(KeyPattern.fromHexFilter("user") == nil)
        #expect(KeyPattern.matchBytes(KeyPattern.fromHexFilter("ff*") ?? "") == Data([0xFF, 0x2A]))
    }

    @Test func importedLinesKeepNonUTF8Bytes() {
        var line = Array("SET k".utf8)
        line += [0x20, 0xFF, 0xFE, 0x0A]
        var summary = BulkImportSummary()
        var offset = 0
        let batch = CommandFileImporter.nextBatch(in: Data(line), offset: &offset, summary: &summary)
        #expect(batch == [[Data("SET".utf8), Data("k".utf8), Data([0xFF, 0xFE])]])
        #expect(summary.failed == 0)
    }
}
