import Foundation

/// Encodes commands as RESP arrays of bulk strings (binary safe), and reply values as RESP2/RESP3 frames.
public enum RESPEncoder {
    private static let crlf: [UInt8] = [0x0D, 0x0A]

    public static func encode(_ args: [RedisArgument]) -> Data {
        var out = Data()
        append(args, to: &out)
        return out
    }

    public static func encode(_ args: [Data]) -> Data {
        encode(args.redisArguments)
    }

    /// Encodes several commands back to back (a pipeline).
    public static func encodePipeline(_ commands: [[RedisArgument]]) -> Data {
        var out = Data()
        for command in commands { append(command, to: &out) }
        return out
    }

    public static func append(_ args: [RedisArgument], to out: inout Data) {
        let payloads = args.map(\.data)
        out.reserveCapacity(out.count + payloads.reduce(16) { $0 + $1.count + 16 })
        appendHeader(UInt8(ascii: "*"), payloads.count, to: &out)
        for bytes in payloads {
            appendHeader(UInt8(ascii: "$"), bytes.count, to: &out)
            out.append(bytes)
            out.append(contentsOf: crlf)
        }
    }

    private static func appendHeader(_ type: UInt8, _ count: Int, to out: inout Data) {
        out.append(type)
        out.append(contentsOf: Array(String(count).utf8))
        out.append(contentsOf: crlf)
    }

    /// Encodes a reply as a server frame. Simple strings and errors must not contain CR or LF.
    public static func encodeValue(_ value: RESPValue) -> Data {
        var out = Data()
        appendValue(value, to: &out)
        return out
    }

    private static func appendLine(_ type: Character, _ text: String, to out: inout Data) {
        out.append(contentsOf: Array(String(type).utf8))
        out.append(contentsOf: Array(text.utf8))
        out.append(contentsOf: crlf)
    }

    private static func appendBlob(_ type: UInt8, _ data: Data, to out: inout Data) {
        appendHeader(type, data.count, to: &out)
        out.append(data)
        out.append(contentsOf: crlf)
    }

    public static func appendValue(_ value: RESPValue, to out: inout Data) {
        switch value {
        case .simpleString(let s): appendLine("+", s, to: &out)
        case .error(let e): appendLine("-", e.message, to: &out)
        case .integer(let i): appendLine(":", String(i), to: &out)
        case .bulkString(nil): appendLine("$", "-1", to: &out)
        case .bulkString(let d?): appendBlob(UInt8(ascii: "$"), d, to: &out)
        case .array(nil): appendLine("*", "-1", to: &out)
        case .array(let items?):
            appendHeader(UInt8(ascii: "*"), items.count, to: &out)
            for item in items { appendValue(item, to: &out) }
        case .null: appendLine("_", "", to: &out)
        case .double(let d):
            let text: String
            if d.isNaN { text = "nan" } else if d.isInfinite { text = d > 0 ? "inf" : "-inf" } else { text = String(d) }
            appendLine(",", text, to: &out)
        case .boolean(let b): appendLine("#", b ? "t" : "f", to: &out)
        case .bigNumber(let s): appendLine("(", s, to: &out)
        case .verbatimString(let format, let text):
            var blob = Data(format.prefix(3).utf8)
            blob.append(UInt8(ascii: ":"))
            blob.append(text)
            appendBlob(UInt8(ascii: "="), blob, to: &out)
        case .map(let pairs):
            appendHeader(UInt8(ascii: "%"), pairs.count, to: &out)
            for (k, v) in pairs { appendValue(k, to: &out); appendValue(v, to: &out) }
        case .set(let items):
            appendHeader(UInt8(ascii: "~"), items.count, to: &out)
            for item in items { appendValue(item, to: &out) }
        case .push(let items):
            appendHeader(UInt8(ascii: ">"), items.count, to: &out)
            for item in items { appendValue(item, to: &out) }
        }
    }
}
