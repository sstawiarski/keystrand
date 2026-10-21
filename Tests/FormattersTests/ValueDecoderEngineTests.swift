import Foundation
@testable import Formatters
import Testing

struct ValueDecoderEngineTests {
    @Test(arguments: [
        ("room:chunk-state:*", "room:chunk-state:42", true), ("room:*", "user:1", false), ("user:?", "user:1", true),
        ("user:?", "user:12", false), ("user:[0-9]", "user:7", true), ("user:[^0-9]", "user:7", false),
        ("a\\*b", "a*b", true), ("a\\*b", "axb", false), ("*", "", true), ("", "x", false), ("[", "[", true),
        ("*:items:*", "user:items:9", true), ("h[ae]llo", "hallo", true), ("h[]a]llo", "h]llo", true),
    ])
    func globMatching(_ pattern: String, _ key: String, _ expected: Bool) {
        #expect(ValueDecoderEngine.matches(pattern: pattern, key: key) == expected)
    }

    @Test func specificityAndRuleSelection() {
        #expect(ValueDecoderEngine.specificity("ab") == 8)
        #expect(ValueDecoderEngine.specificity("a*") == 5)
        #expect(ValueDecoderEngine.specificity("a?[xy]\\*") == 4 + 2 + 3 + 4)
        #expect(ValueDecoderEngine.specificity("") == -1)
        let generic = ValueDecoderRule(name: "generic", keyPatterns: ["room:*"])
        let specific = ValueDecoderRule(name: "specific", keyPatterns: ["nope", "room:chunk-state:*"])
        #expect(ValueDecoderEngine.matchingRule([generic, specific], key: "room:chunk-state:1")?.name == "specific")
        #expect(ValueDecoderEngine.matchingRule([generic, specific], key: "room:x")?.name == "generic")
        #expect(ValueDecoderEngine.matchingRule([generic, specific], key: "other") == nil)
        #expect(ValueDecoderEngine.escapeGlob("a*b[1]") == "a\\*b\\[1\\]")
    }

    private func sampleSchema() -> [SchemaNode] {
        let version = BinaryFieldDefinition(id: "v", name: "version", dataType: .uint8)
        let count = BinaryFieldDefinition(id: "n", name: "count", dataType: .uint16le)
        let nameLength = BinaryFieldDefinition(id: "len", name: "len", dataType: .uint8)
        let name = BinaryFieldDefinition(id: "s", name: "name", dataType: .string, size: nil, sizeSource: .field, sizeFieldRef: "len")
        let score = BinaryFieldDefinition(id: "f", name: "score", dataType: .floatbe)
        return [.field(version), .field(count),
                .repeatBlock(RepeatBlockDefinition(id: "r", name: "items", countFieldRef: "n",
                                                   fields: [.field(nameLength), .field(name), .field(score)]))]
    }

    @Test func decodesSchemaWithRepeatsAndDynamicSizes() {
        var bytes: [UInt8] = [0x01, 0x02, 0x00]
        bytes += [0x02] + Array("ab".utf8) + [0x3F, 0xC0, 0x00, 0x00]
        bytes += [0x01] + Array("z".utf8) + [0xC0, 0x00, 0x00, 0x00]
        let parsed = ValueDecoderEngine.decode(Data(bytes), schema: sampleSchema())
        #expect(parsed == [
            .field(name: "version", size: 1, value: "1"),
            .field(name: "count", size: 2, value: "2"),
            .group(label: "0", children: [.field(name: "len", size: 1, value: "2"), .field(name: "name", size: 2, value: "ab"),
                                          .field(name: "score", size: 4, value: "1.5")]),
            .group(label: "1", children: [.field(name: "len", size: 1, value: "1"), .field(name: "name", size: 1, value: "z"),
                                          .field(name: "score", size: 4, value: "-2")]),
        ])
        #expect(ValueDecoderEngine.formatInline(Array(parsed.prefix(2))) == "[version] [1] [1] [count] [2] [2]")
        #expect(ValueDecoderEngine.formatLines(Array(parsed.prefix(3))) == """
        [version] [1] [1]
        [count] [2] [2]
          [0]
            [len] [1] [2]
            [name] [2] [ab]
            [score] [4] [1.5]
        """)
    }

    @Test func insufficientDataStopsDecoding() {
        let parsed = ValueDecoderEngine.decode(Data([0x01, 0x05]), schema: sampleSchema())
        #expect(parsed == [.field(name: "version", size: 1, value: "1"), .field(name: "count", size: 2, value: "<insufficient data>")])
    }

    @Test func repeatCountIsCapped() {
        let count = BinaryFieldDefinition(id: "n", name: "n", dataType: .uint32be)
        let byte = BinaryFieldDefinition(id: "b", name: "b", dataType: .hex, size: 1)
        let schema: [SchemaNode] = [.field(count), .repeatBlock(RepeatBlockDefinition(id: "r", countFieldRef: "n", fields: [.field(byte)]))]
        let bytes: [UInt8] = [0x00, 0x01, 0x00, 0x00] + Array(repeating: 0xAB, count: 2000)
        let parsed = ValueDecoderEngine.decode(Data(bytes), schema: schema)
        #expect(parsed.count == 1 + ValueDecoderEngine.maxRepeatIterations)
        #expect(parsed.last == .group(label: "999", children: [.field(name: "b", size: 1, value: "AB")]))
    }

    @Test func numericTypes() {
        func value(_ type: BinaryDataType, _ bytes: [UInt8]) -> String? {
            let parsed = ValueDecoderEngine.decode(Data(bytes), schema: [.field(BinaryFieldDefinition(name: "x", dataType: type))])
            if case .field(_, _, let v)? = parsed.first { return v }
            return nil
        }

        #expect(value(.int8, [0xFF]) == "-1")
        #expect(value(.boolean, [0x02]) == "true")
        #expect(value(.int16be, [0xFF, 0xFE]) == "-2")
        #expect(value(.uint32le, [0x01, 0, 0, 0x80]) == "2147483649")
        #expect(value(.bigint64be, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == "-1")
        #expect(value(.biguint64le, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == "18446744073709551615")
        #expect(value(.doublele, [0, 0, 0, 0, 0, 0, 0xF8, 0x3F]) == "1.5")
        #expect(value(.hex, [0x0A]) == "0A")
    }

    @Test func validation() {
        #expect(ValueDecoderEngine.isValid(ValueDecoderRule(keyPatterns: ["k:*"], schema: sampleSchema())))
        #expect(!ValueDecoderEngine.isValid(ValueDecoderRule(keyPatterns: [""], schema: sampleSchema())))
        #expect(!ValueDecoderEngine.isValid(ValueDecoderRule(keyPatterns: ["k"], schema: [.field(BinaryFieldDefinition(name: ""))])))
        let badRef: [SchemaNode] = [.repeatBlock(RepeatBlockDefinition(countFieldRef: "missing", fields: [.field(BinaryFieldDefinition(name: "a"))]))]
        #expect(!ValueDecoderEngine.isValid(schema: badRef))
        let prior = ValueDecoderEngine.priorNumericFields(sampleSchema(), before: "s")
        #expect(prior.map(\.name) == ["version", "count", "len"])
    }

    @Test func clipboardRoundTripRemapsIDs() throws {
        let rule = ValueDecoderRule(id: "d1", name: "Chunk", keyPatterns: ["room:*"], schema: sampleSchema())
        let text = ValueDecoderEngine.clipboardText([rule])
        #expect(text.contains("\"type\" : \"keystrand/value-decoder\""))
        let parsed = try #require(ValueDecoderEngine.rules(fromClipboard: text))
        #expect(parsed.count == 1)
        let copy = parsed[0]
        #expect(copy.id != "d1")
        #expect(copy.name == "Chunk")
        guard case .repeatBlock(let block) = copy.schema[2], case .field(let count) = copy.schema[1],
              case .field(let len) = block.fields[0], case .field(let name) = block.fields[1] else {
            Issue.record("unexpected schema shape")
            return
        }
        #expect(block.countFieldRef == count.id)
        #expect(name.sizeFieldRef == len.id)
        #expect(count.id != "n")
        #expect(ValueDecoderEngine.isValid(copy))
        // Legacy single-pattern rule with flat fields.
        let legacy = #"{"name":"old","keyPattern":"a:*","fields":[{"id":"x","name":"x","dataType":"uint8","size":1}]}"#
        let legacyRules = try #require(ValueDecoderEngine.rules(fromClipboard: legacy))
        #expect(legacyRules[0].keyPatterns == ["a:*"])
        #expect(legacyRules[0].schema.count == 1)
        #expect(ValueDecoderEngine.rules(fromClipboard: "nope") == nil)
        #expect(ValueDecoderEngine.rules(fromClipboard: "{\"x\":1}") == nil)
    }
}
