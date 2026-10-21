import Foundation
@testable import Formatters
import Testing

private func bytes(_ b: [UInt8]) -> Data { Data(b) }

private func compact(_ data: Data, _ format: ValueFormat) -> String {
    FormatterRegistry.format(data, as: format).displayText(expanded: false)
}

struct MsgpackFormatterTests {
    @Test func decodesMsgpackFixtures() {
        let map: [UInt8] = [0x82, 0xA4, 0x6E, 0x61, 0x6D, 0x65, 0xA4, 0x74, 0x65, 0x73, 0x74, 0xA5, 0x76, 0x61, 0x6C, 0x75, 0x65, 0x7B]
        #expect(compact(bytes(map), .msgpack) == #"{"name":"test","value":123}"#)
        #expect(compact(bytes([0x93, 0x01, 0x02, 0x03]), .msgpack) == "[1,2,3]")
        #expect(compact(bytes([0x92, 0x92, 0x01, 0x02, 0x92, 0x03, 0x04]), .msgpack) == "[[1,2],[3,4]]")
        #expect(compact(bytes([0x80]), .msgpack) == "{}")
        #expect(compact(bytes([0x90]), .msgpack) == "[]")
        #expect(compact(bytes([0xC0]), .msgpack) == "null")
        #expect(compact(bytes([0xC3]), .msgpack) == "true")
        #expect(compact(bytes([0xC2]), .msgpack) == "false")
        #expect(compact(bytes([0xA5, 0x68, 0x65, 0x6C, 0x6C, 0x6F]), .msgpack) == #""hello""#)
        #expect(compact(bytes([0xFF]), .msgpack) == "-1")
        #expect(compact(bytes([0xCA, 0x40, 0x48, 0xF5, 0xC3]), .msgpack) == "3.14")
        #expect(compact(bytes([0xC4, 0x03, 0x01, 0x02, 0x03]), .msgpack) == #""\\x01\\x02\\x03""#)
    }

    @Test func integerExtremesAndKeys() {
        #expect(compact(bytes([0xCF] + Array(repeating: 0xFF, count: 8)), .msgpack) == "18446744073709551615")
        #expect(compact(bytes([0xD3, 0x80, 0, 0, 0, 0, 0, 0, 0]), .msgpack) == "-9223372036854775808")
        #expect(compact(bytes([0x81, 0x01, 0xA1, 0x61]), .msgpack) == #"{"1":"a"}"#)
        #expect(compact(bytes([0xD6, 0xFF, 0, 0, 0, 0]), .msgpack) == #""1970-01-01T00:00:00.000Z""#)
        #expect(compact(bytes([0xD4, 0x05, 0xAB]), .msgpack) == #"{"type":5,"data":"ab"}"#)
    }

    @Test func decodesDotNetLZ4Extensions() {
        // ext 99: int32 size + LZ4 block containing msgpack 42.
        #expect(compact(bytes([0xC7, 0x06, 0x63, 0, 0, 0, 0x01, 0x10, 0x2A]), .msgpack) == "42")
        // ext 98 inline form.
        #expect(compact(bytes([0xC7, 0x08, 0x62, 0, 0, 0, 0x03, 0x30, 0xA2, 0x68, 0x69]), .msgpack) == #""hi""#)
        // [ext 98 (msgpack int sizes), bin...] array form.
        #expect(compact(bytes([0x92, 0xD4, 0x62, 0x03, 0xC4, 0x04, 0x30, 0xA2, 0x68, 0x69]), .msgpack) == #""hi""#)
        // Two blocks: "[1," + "2]" split as msgpack bytes 0x92 0x01 | 0x02.
        let b1 = LZ4.encodeLiteralBlock([0x92, 0x01])
        let b2 = LZ4.encodeLiteralBlock([0x02])
        let multi: [UInt8] = [0x93, 0xD5, 0x62, 0x02, 0x01, 0xC4, UInt8(b1.count)] + b1 + [0xC4, UInt8(b2.count)] + b2
        #expect(compact(bytes(multi), .msgpack) == "[1,2]")
    }

    @Test func invalidMsgpack() {
        #expect(!FormatterRegistry.format(Data("hello".utf8), as: .msgpack).isValid)
        #expect(!FormatterRegistry.format(bytes([0x92, 0x01]), as: .msgpack).isValid)
        #expect(!FormatterRegistry.format(bytes([0xC1]), as: .msgpack).isValid)
        #expect(!FormatterRegistry.format(bytes([0xDD, 0xFF, 0xFF, 0xFF, 0xFF]), as: .msgpack).isValid)
    }

    @Test func encodesFromJSON() throws {
        let expected: [UInt8] = [0x82, 0xA4, 0x6E, 0x61, 0x6D, 0x65, 0xA4, 0x74, 0x65, 0x73, 0x74, 0xA5, 0x76, 0x61, 0x6C, 0x75, 0x65, 0x7B]
        #expect(try FormatterRegistry.parseEdited(#"{"name":"test","value":123}"#, as: .msgpack) == bytes(expected))
        let json = #"{"a":[1,-1,-33,300,-300,70000,-70000,5000000000,-5000000000,18446744073709551615,1.5,true,null,"x"],"b":{},"c":2.0}"#
        let packed = try FormatterRegistry.parseEdited(json, as: .msgpack)
        #expect(compact(packed, .msgpack) == #"{"a":[1,-1,-33,300,-300,70000,-70000,5000000000,-5000000000,18446744073709551615,1.5,true,null,"x"],"b":{},"c":2}"#)
        let long = String(repeating: "y", count: 300)
        #expect(compact(try FormatterRegistry.parseEdited("[\"\(long)\"]", as: .msgpack), .msgpack) == "[\"\(long)\"]")
        #expect(throws: FormatterError.self) { try FormatterRegistry.parseEdited("{oops", as: .msgpack) }
    }

    @Test func serializeForEditIsPrettyJSON() {
        #expect(FormatterRegistry.serializeForEdit(bytes([0x91, 0x01]), as: .msgpack) == "[\n    1\n]")
        #expect(FormatterRegistry.isNonUnicodeFormat(.msgpack, isValid: true))
        #expect(!FormatterRegistry.isNonUnicodeFormat(.msgpack, isValid: false))
    }
}

struct PHPFormatterTests {
    private func php(_ s: String) -> String { compact(Data(s.utf8), .php) }

    @Test func decodesScalarsAndArrays() {
        #expect(php(#"a:2:{i:0;s:1:"a";i:1;i:2;}"#) == #"["a",2]"#)
        #expect(php(#"a:2:{s:3:"foo";s:3:"bar";s:3:"num";d:1.5;}"#) == #"{"foo":"bar","num":1.5}"#)
        #expect(php(#"a:2:{i:1;s:1:"a";i:0;s:1:"b";}"#) == #"{"1":"a","0":"b"}"#)
        #expect(php(#"s:6:"名字";"#) == #""名字""#)
        #expect(php("i:9223372036854775807;") == "9223372036854775807")
        #expect(php("i:-5;") == "-5")
        #expect(php("N;") == "null")
        #expect(php("b:0;") == "false")
        #expect(php("d:0.1;") == "0.1")
        #expect(php("d:INF;") == "Infinity")
        #expect(php("a:0:{}") == "[]")
    }

    @Test func decodesObjectsAndReferences() {
        let obj = "O:8:\"stdClass\":2:{s:1:\"a\";i:1;s:4:\"\u{0}*\u{0}b\";b:1;}"
        #expect(php(obj) == #"{"__PHP_Incomplete_Class_Name":"stdClass","a":1,"b":true}"#)
        #expect(php(#"a:2:{i:0;a:1:{i:0;i:1;}i:1;R:2;}"#) == "[[1],[1]]")
        #expect(php(#"E:11:"Suit:Hearts";"#) == #""Suit:Hearts""#)
        #expect(php(#"C:3:"Foo":9:{s:2:"hi";}"#) == #"{"__PHP_Incomplete_Class_Name":"Foo","data":"hi"}"#)
    }

    @Test func invalidPHP() {
        #expect(!FormatterRegistry.format(Data("hello".utf8), as: .php).isValid)
        #expect(!FormatterRegistry.format(Data(#"s:5:"abc";"#.utf8), as: .php).isValid)
        #expect(!FormatterRegistry.format(Data("i:1;x".utf8), as: .php).isValid)
        #expect(!FormatterRegistry.format(Data("a:1:{i:0;i:1;".utf8), as: .php).isValid)
    }

    @Test func encodesFromJSON() throws {
        func enc(_ json: String) throws -> String { String(decoding: try FormatterRegistry.parseEdited(json, as: .php), as: UTF8.self) }
        #expect(try enc(#"["a",2]"#) == #"a:2:{i:0;s:1:"a";i:1;i:2;}"#)
        #expect(try enc(#"{"x":1.5,"1":null,"t":true}"#) == #"a:3:{s:1:"x";d:1.5;i:1;N;s:1:"t";b:1;}"#)
        #expect(try enc("12345678901234567890") == "i:12345678901234567890;")
        #expect(try enc(#""名字""#) == #"s:6:"名字";"#)
        #expect(try enc("1e25") == "d:1.0E+25;")
        #expect(try enc(#"{"__PHP_Incomplete_Class_Name":"User","id":7}"#) == #"O:4:"User":1:{s:2:"id";i:7;}"#)
        let original = #"a:2:{s:4:"list";a:2:{i:0;i:1;i:1;d:2.5;}s:3:"obj";O:3:"Foo":1:{s:1:"x";N;}}"#
        let json = FormatterRegistry.serializeForEdit(Data(original.utf8), as: .php)
        #expect(try enc(json) == original)
    }
}

struct JavaFormatterTests {
    private func java(_ b64: String) -> String { compact(Data(base64Encoded: b64) ?? Data(), .java) }

    @Test func decodesCommonTypes() {
        #expect(java(Fixtures.java_string) == #""héllo 名字""#)
        #expect(java(Fixtures.java_integer) == "42")
        #expect(java(Fixtures.java_long) == "-9000000000")
        #expect(java(Fixtures.java_double) == "3.25")
        #expect(java(Fixtures.java_boolean) == "true")
        #expect(java(Fixtures.java_arraylist) == #"["a",1,null,2.5]"#)
        #expect(java(Fixtures.java_hashmap) == #"{"k":"v","n":5}"#)
        #expect(java(Fixtures.java_linkedhashmap) == #"{"z":1,"a":["x","y"],"m":[4,5]}"#)
        #expect(java(Fixtures.java_date) == #""2023-11-14T22:13:20.000Z""#)
        #expect(java(Fixtures.java_intarray) == "[10,-20,30]")
        #expect(java(Fixtures.java_strarray) == #"["x",null,"z"]"#)
        #expect(java(Fixtures.java_enum) == #""GREEN""#)
        #expect(java(Fixtures.java_bigint) == "-123456789012345678901234567890")
        #expect(java(Fixtures.java_bigdec) == "12345.678")
        #expect(java(Fixtures.java_set) == #"["one","two"]"#)
    }

    @Test func decodesCustomClassWithFields() {
        #expect(java(Fixtures.java_person) == #"{"className":"Gen$Person","serialVersionUid":42,"fields":[{"active":true},{"age":36},{"id":1234567890123},{"initial":"A"},{"score":9.5},{"boxed":7},{"name":"Ada"},{"numbers":[1,2,3]}],"annotations":[]}"#)
    }

    @Test func invalidAndReadOnly() {
        #expect(!FormatterRegistry.format(Data("not java".utf8), as: .java).isValid)
        let truncated = (Data(base64Encoded: Fixtures.java_person) ?? Data()).prefix(40)
        #expect(!FormatterRegistry.format(Data(truncated), as: .java).isValid)
        #expect(throws: FormatterError.notEditable(.java)) { try FormatterRegistry.parseEdited("1", as: .java) }
    }

    @Test func rejectsOversizedLongString() {
        #expect(!FormatterRegistry.format(bytes([0xAC, 0xED, 0x00, 0x05, 0x7C, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), as: .java).isValid)
        #expect(!FormatterRegistry.format(bytes([0xAC, 0xED, 0x00, 0x05, 0x7C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x41]), as: .java).isValid)
        #expect(java(Data([0xAC, 0xED, 0x00, 0x05, 0x7C, 0, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69]).base64EncodedString()) == #""hi""#)
    }

    @Test func vectorElementCountIsClamped() {
        #expect(java(Self.vector(elementCount: 1).base64EncodedString()) == #"["a"]"#)
        #expect(java(Self.vector(elementCount: 5).base64EncodedString()) == #"["a","b"]"#)
        #expect(java(Self.vector(elementCount: -3).base64EncodedString()) == "[]")
    }

    private static func vector(elementCount: Int32) -> Data {
        func utf(_ s: String) -> [UInt8] { let b = Array(s.utf8); return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b }
        func int(_ v: Int32) -> [UInt8] { let u = UInt32(bitPattern: v); return [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)] }
        let uid: [UInt8] = [0xD9, 0x97, 0x7D, 0x5B, 0x80, 0x3B, 0xAF, 0x01]
        var b: [UInt8] = [0xAC, 0xED, 0x00, 0x05, 0x73, 0x72] + utf("java.util.Vector") + uid + [0x03, 0x00, 0x03]
        b += [UInt8(ascii: "I")] + utf("capacityIncrement")
        b += [UInt8(ascii: "I")] + utf("elementCount")
        b += [UInt8(ascii: "[")] + utf("elementData") + [0x74] + utf("[Ljava/lang/Object;")
        b += [0x78, 0x70]
        b += int(0) + int(elementCount)
        b += [0x75, 0x72] + utf("[Ljava.lang.Object;") + [0x90, 0xCE, 0x58, 0x9F, 0x10, 0x73, 0x29, 0x6C, 0x02, 0x00, 0x00, 0x78, 0x70]
        b += int(2) + [0x74] + utf("a") + [0x74] + utf("b")
        b += [0x78]
        return Data(b)
    }

    @Test func modifiedUTF8() {
        #expect(JavaSerialization.modifiedUTF8([0xC0, 0x80, 0x41]) == "\u{0}A")
        // U+1F600 as CESU-8 surrogate pair.
        #expect(JavaSerialization.modifiedUTF8([0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80]) == "😀")
    }

    @Test func bigDecimalWithHugeScaleUsesExponentNotation() throws {
        func bigDecimal(scale: Int32) throws -> Data {
            var b = [UInt8](try #require(Data(base64Encoded: Fixtures.java_bigdec)))
            let marker: [UInt8] = [0x78, 0x70, 0x00, 0x00, 0x00, 0x03, 0x73]
            let start = try #require(b.indices.first { b[$0...].starts(with: marker) }) + 2
            let u = UInt32(bitPattern: scale)
            b.replaceSubrange(start..<start + 4, with: [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
            return Data(b)
        }

        #expect(java(try bigDecimal(scale: 3).base64EncodedString()) == "12345.678")
        #expect(java(try bigDecimal(scale: 1_000_000).base64EncodedString()) == "12345678E-1000000")
        #expect(java(try bigDecimal(scale: -1_000_000).base64EncodedString()) == "12345678E1000000")
        #expect(java(try bigDecimal(scale: .max).base64EncodedString()) == "12345678E-2147483647")
        #expect(java(try bigDecimal(scale: .min).base64EncodedString()) == "12345678E2147483648")
    }
}

/// Hostile Java streams must fail fast with an invalid result instead of hanging or overflowing the stack.
@Suite(.timeLimit(.minutes(1)))
struct JavaMalformedStreamTests {
    private static let header: [UInt8] = [0xAC, 0xED, 0x00, 0x05]
    private static let uid: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]

    private static func desc(_ name: String) -> [UInt8] {
        let n = Array(name.utf8)
        return [0x72, 0x00, UInt8(n.count)] + n + uid + [0x02, 0x00, 0x00, 0x78]
    }

    private static func reference(_ handle: Int) -> [UInt8] {
        let h = UInt32(0x7E0000 + handle)
        return [0x71, UInt8(h >> 24), UInt8((h >> 16) & 0xFF), UInt8((h >> 8) & 0xFF), UInt8(h & 0xFF)]
    }

    private static func isRejected(_ bytes: [UInt8]) -> Bool {
        (try? JavaSerialization.decode(bytes)) == nil && !FormatterRegistry.format(Data(bytes), as: .java).isValid
    }

    /// `depth` objects of class `N` (handle 0), each one's `next` field holding the next object.
    private static func nestedObjects(_ depth: Int) -> [UInt8] {
        func utf(_ s: String) -> [UInt8] { let b = Array(s.utf8); return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b }
        var b = header + [0x73, 0x72] + utf("N") + uid + [0x02, 0x00, 0x01]
        b += [UInt8(ascii: "L")] + utf("next") + [0x74] + utf("Ljava/lang/Object;") + [0x78, 0x70]
        for _ in 1..<depth { b += [0x73] + reference(0) }
        return b + [0x70]
    }

    /// Top-level descriptors where each one's superclass is the previous one, then an object of the last.
    private static func handleChain(_ length: Int) -> [UInt8] {
        var b = header + desc("A") + [0x70]
        for handle in 0..<(length - 1) { b += desc("A") + reference(handle) }
        return b + [0x73] + reference(length - 1)
    }

    @Test func descriptorThatIsItsOwnSuperclass() {
        let hex = Array("aced0005737200014100000000000000000200007871007e0000".utf8)
        let bytes = stride(from: 0, to: hex.count, by: 2).compactMap {
            UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)
        }
        #expect(bytes.count == 26)
        #expect(Self.isRejected(bytes))
    }

    @Test func twoDescriptorCycle() {
        #expect(Self.isRejected(Self.header + [0x73] + Self.desc("A") + Self.desc("B") + Self.reference(0)))
    }

    @Test func deeplyNestedDescriptorsOnTaskStack() async {
        let bytes = Self.header + [0x73] + Array([[UInt8]](repeating: Self.desc("A"), count: 3_000).joined()) + [0x70]
        let rejected = await Task.detached { Self.isRejected(bytes) }.value
        #expect(rejected)
    }

    @Test func deeplyNestedObjectsOnTaskStack() async {
        let (shallow, deep) = await Task.detached {
            (try? JavaSerialization.decode(Self.nestedObjects(30)), Self.isRejected(Self.nestedObjects(5_000)))
        }.value
        #expect(shallow.map { JSONPrinter.print($0, indent: nil).contains("…") } == false)
        #expect(deep)
    }

    @Test func objectsChainedThroughHandlesRenderOnTaskStack() async {
        var bytes = Self.nestedObjects(1)
        for previous in 2..<302 { bytes += [0x73] + Self.reference(0) + Self.reference(previous) }
        let data = Data(bytes)
        let text = await Task.detached { () -> String? in
            let result = FormatterRegistry.format(data, as: .java)
            return result.isValid ? result.displayText(expanded: false) : nil
        }.value
        #expect(text?.contains(#""next":"…""#) == true)
    }

    @Test func longHandleBuiltChainIsCapped() async {
        let (allowed, rejected) = await Task.detached {
            (try? JavaSerialization.decode(Self.handleChain(JavaSerialization.maxDepth)),
             Self.isRejected(Self.handleChain(50_000)))
        }.value
        guard case .array(let items)? = allowed, case .object(let members)? = items.last else {
            Issue.record("a hierarchy at the limit should decode")
            return
        }
        #expect(items.count == JavaSerialization.maxDepth + 1)
        #expect(members.first == JSONMember(key: "className", value: .string("A")))
        #expect(rejected)
    }
}

struct ProtobufFormatterTests {
    @Test func decodesWireTypes() {
        #expect(compact(bytes([0x08, 0x96, 0x01]), .protobuf) == #"[{"1":150}]"#)
        #expect(compact(bytes([0x12, 0x07] + Array("testing".utf8)), .protobuf) == #"[{"2":"testing"}]"#)
        #expect(compact(bytes([0x1A, 0x03, 0x08, 0x96, 0x01]), .protobuf) == #"[{"3":[{"1":150}]}]"#)
        #expect(compact(bytes([0x0D, 0x00, 0x00, 0xC0, 0x3F]), .protobuf) == #"[{"1":1.5}]"#)
        #expect(compact(bytes([0x09, 0x01, 0, 0, 0, 0, 0, 0, 0]), .protobuf) == #"[{"1":1}]"#)
        #expect(compact(bytes([0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]), .protobuf) == #"[{"1":18446744073709551615}]"#)
        #expect(compact(bytes([0x22, 0x03, 0x01, 0x02, 0x03]), .protobuf) == #"[{"4":"\\x01\\x02\\x03"}]"#)
        #expect(compact(bytes([0x08, 0x01, 0x08, 0x02]), .protobuf) == #"[{"1":1},{"1":2}]"#)
        // Group (field 5) containing field 1 = 7.
        #expect(compact(bytes([0x2B, 0x08, 0x07, 0x2C]), .protobuf) == #"[{"5":[{"1":7}]}]"#)
    }

    @Test func invalidProtobuf() {
        #expect(!FormatterRegistry.format(Data(), as: .protobuf).isValid)
        #expect(!FormatterRegistry.format(Data("hello world".utf8), as: .protobuf).isValid)
        #expect(!FormatterRegistry.format(bytes([0x12, 0x09, 0x01]), as: .protobuf).isValid)
        #expect(!FormatterRegistry.format(bytes([0x0F]), as: .protobuf).isValid)
        // Group whose nested length-delimited field claims a huge length.
        #expect(!FormatterRegistry.format(bytes([0x0B, 0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]), as: .protobuf).isValid)
        #expect(!FormatterRegistry.format(bytes([0x0B, 0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]), as: .protobuf).isValid)
        #expect(!FormatterRegistry.format(bytes([0x0B, 0x09, 0x01, 0x02]), as: .protobuf).isValid)
        #expect(!FormatterRegistry.format(bytes([0x0B, 0x0D, 0x01]), as: .protobuf).isValid)
        #expect(throws: FormatterError.notEditable(.protobuf)) { try FormatterRegistry.parseEdited("[]", as: .protobuf) }
    }
}

struct PickleFormatterTests {
    static let expected = #"{"name":"Ada","n":1,"big":1180591620717411303424,"neg":-5,"f":1.5,"none":null,"t":true,"list":[1,"two","\\x00\\x01"],"tuple":[1,2],"set":[3],"nested":{"k":[null]}}"#

    @Test(arguments: [Fixtures.pickle_p0, Fixtures.pickle_p1, Fixtures.pickle_p2, Fixtures.pickle_p3, Fixtures.pickle_p4, Fixtures.pickle_p5])
    func decodesAllProtocols(_ b64: String) {
        let r = FormatterRegistry.format(Data(base64Encoded: b64) ?? Data(), as: .pickle)
        #expect(r.isValid)
        #expect(r.displayText(expanded: false) == Self.expected)
    }

    @Test func decodesReducersAndSharedReferences() {
        func pickle(_ b64: String) -> String { compact(Data(base64Encoded: b64) ?? Data(), .pickle) }
        #expect(pickle(Fixtures.pickle_dt) == #""2024-05-06T07:08:09.123456""#)
        #expect(pickle(Fixtures.pickle_od) == #"{"b":1,"a":2}"#)
        #expect(pickle(Fixtures.pickle_shared) == "[[1,2],[1,2]]")
        #expect(pickle(Fixtures.pickle_str) == #""名字""#)
    }

    @Test func handwrittenOpcodes() {
        // Protocol 2: a list that contains itself: ]q\x00h\x00a.
        let cyclic: [UInt8] = [0x80, 0x02, 0x5D, 0x71, 0x00, 0x68, 0x00, 0x61, 0x2E]
        #expect(compact(bytes(cyclic), .pickle) == #"["[Circular]"]"#)
        // Custom class via GLOBAL + EMPTY_TUPLE + NEWOBJ + BUILD.
        let custom: [UInt8] = [0x80, 0x02] + Array("c__main__\nPoint\n)".utf8) + [0x81] + Array("}X".utf8) + [1, 0, 0, 0]
            + Array("xK".utf8) + [5] + Array("sb.".utf8)
        #expect(compact(bytes(custom), .pickle) == #"{"__class__":"__main__.Point","state":{"x":5}}"#)
        #expect(compact(bytes([0x80, 0x04, 0x8A, 0x01, 0xFF, 0x2E]), .pickle) == "-1")
        #expect(compact(bytes([0x80, 0x04, 0x47, 0x3F, 0xF8, 0, 0, 0, 0, 0, 0, 0x2E]), .pickle) == "1.5")
    }

    @Test func invalidPickle() {
        #expect(!FormatterRegistry.format(Data("hello".utf8), as: .pickle).isValid)
        #expect(!FormatterRegistry.format(bytes([0x80, 0x04, 0x5D]), as: .pickle).isValid)
        #expect(throws: FormatterError.notEditable(.pickle)) { try FormatterRegistry.parseEdited("1", as: .pickle) }
    }
}
