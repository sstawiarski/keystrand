import Foundation
@testable import Formatters
import Testing

struct JSONTests {
    @Test func parsesScalarsAndKeepsNumberLiterals() throws {
        #expect(try JSONParser.parse("12345678901234567890") == .number("12345678901234567890"))
        #expect(try JSONParser.parse(" -1.5e-7 ") == .number("-1.5e-7"))
        #expect(try JSONParser.parse("true") == .bool(true))
        #expect(try JSONParser.parse("null") == .null)
        #expect(try JSONParser.parse("\"a\\u00e9\\n\\\"\"") == .string("aé\n\""))
        #expect(try JSONParser.parse("\"\\ud83d\\ude00\"") == .string("😀"))
    }

    @Test func keepsKeyOrderAndDuplicates() throws {
        let v = try JSONParser.parse(#"{"z":1,"a":{"__proto__":2,"constructor":3},"z":4}"#)
        guard case .object(let members) = v else { Issue.record("not an object"); return }
        #expect(members.map(\.key) == ["z", "a", "z"])
        #expect(v["z"] == .number("4"))
        #expect(JSONParser.duplicateKeys(in: v) == ["z"])
        #expect(throws: JSONParseError.duplicateKey("z")) { try JSONParser.parse(#"{"z":1,"z":2}"#, rejectDuplicateKeys: true) }
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "-", "tru", "\"abc", "[1] x", "{'a':1}", "\"\\q\""])
    func rejectsInvalidJSON(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(text) }
    }

    @Test func printsLikeJSONStringify() throws {
        let v = try JSONParser.parse(#"{"a":[1,{"b":null}],"c":"x\ty","d":[],"e":{}}"#)
        #expect(JSONPrinter.print(v, indent: nil) == #"{"a":[1,{"b":null}],"c":"x\ty","d":[],"e":{}}"#)
        #expect(JSONPrinter.print(v, indent: 2) == """
        {
          "a": [
            1,
            {
              "b": null
            }
          ],
          "c": "x\\ty",
          "d": [],
          "e": {}
        }
        """)
        #expect(JSONPrinter.print(.string("\u{01}\u{0C}\\")) == #""\u0001\f\\""#)
        #expect(JSONPrinter.print(.string("a\r\nb\"é\u{301}😀\u{1F}")) == #""a\r\nb\"é\#u{301}😀\u001f""#)
        #expect(JSONPrinter.print(.string("plain")) == #""plain""#)
        #expect(JSONPrinter.print(.string("")) == #""""#)
        #expect(JSONPrinter.print(.array([]), indent: 0) == "[]")
    }

    @Test func numberHelpers() {
        #expect(JSONValue.double(1.0) == .number("1"))
        #expect(JSONValue.double(0.1) == .number("0.1"))
        #expect(JSONValue.float(3.14) == .number("3.14"))
        #expect(JSONValue.double(.nan) == .number("NaN"))
        #expect(JSONValue.integer(UInt64.max) == .number("18446744073709551615"))
        #expect(JSONValue.number("1e5").typeName == "number")
        #expect(JSONValue.number("15").typeName == "integer")
    }

    @Test func deepNestingDoesNotCrash() {
        let deep = String(repeating: "[", count: 2_000) + String(repeating: "]", count: 2_000)
        #expect(throws: JSONParseError.self) { try JSONParser.parse(deep) }
        let ok = String(repeating: "[", count: 250) + String(repeating: "]", count: 250)
        #expect((try? JSONParser.parse(ok)) != nil)
    }
}
