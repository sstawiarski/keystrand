import Foundation
import RedisUI

/// A parsed vector typed by the user: numbers or an FP32 byte string (`\x00\x00\x80\x3f…`).
enum VectorInput: Hashable, Sendable {
    case values([Double])
    case fp32(Data)

    var dimension: Int {
        switch self {
        case .values(let values): return values.count
        case .fp32(let bytes): return bytes.count / 4
        }
    }

    var isFP32: Bool {
        if case .fp32 = self { return true }
        return false
    }
}

enum VectorInputError: Error, Equatable, LocalizedError {
    case empty
    case invalidNumber
    case invalidFP32
    case fp32Length
    case dimensionMismatch(expected: Int, received: Int)

    var errorDescription: String? {
        switch self {
        case .empty: return "Enter a vector"
        case .invalidNumber: return "The vector contains a value that is not a number"
        case .invalidFP32: return "The FP32 bytes could not be decoded"
        case .fp32Length: return "FP32 data must be a whole number of 4-byte values"
        case .dimensionMismatch(let expected, let received):
            return "This vector has \(received) values, but the set expects \(expected)"
        }
    }
}

enum VectorParser {
    /// Detects the format: text starting with `\x` is an FP32 byte string, anything else is numbers separated by
    /// whitespace or commas (optional surrounding brackets).
    static func parse(_ text: String, expectedDimension: Int? = nil) -> Result<VectorInput, VectorInputError> {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        guard !trimmed.isEmpty else { return .failure(.empty) }
        let input: VectorInput
        if trimmed.hasPrefix("\\x") {
            guard let bytes = parseFP32(trimmed) else { return .failure(.invalidFP32) }
            guard !bytes.isEmpty, bytes.count % 4 == 0 else { return .failure(.fp32Length) }
            input = .fp32(bytes)
        } else {
            var body = trimmed
            if body.hasPrefix("[") && body.hasSuffix("]") { body = String(body.dropFirst().dropLast()) }
            let tokens = body.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            guard !tokens.isEmpty else { return .failure(.empty) }
            var values: [Double] = []
            values.reserveCapacity(tokens.count)
            for token in tokens {
                guard let value = Double(token), value.isFinite else { return .failure(.invalidNumber) }
                values.append(value)
            }

            input = .values(values)
        }

        if let expectedDimension, expectedDimension > 0, input.dimension != expectedDimension {
            return .failure(.dimensionMismatch(expected: expectedDimension, received: input.dimension))
        }

        return .success(input)
    }

    static func parseFP32(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        var bytes = Data()
        var index = 0
        while index < chars.count {
            guard index + 3 < chars.count, chars[index] == UInt8(ascii: "\\"), chars[index + 1] == UInt8(ascii: "x") ||
                    chars[index + 1] == UInt8(ascii: "X"),
                  let hi = hex(chars[index + 2]), let lo = hex(chars[index + 3]) else { return nil }
            bytes.append(hi << 4 | lo)
            index += 4
        }

        return bytes
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    static func help(_ text: String, expectedDimension: Int?) -> (text: String, isError: Bool) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return ("The format is recognized on its own. The first vector you add sets the dimension for the whole set.", false)
        }

        switch parse(text, expectedDimension: expectedDimension) {
        case .success(.values(let values)): return ("Numeric list, \(values.count) dimensions.", false)
        case .success(.fp32(let bytes)): return ("FP32 blob, \(bytes.count / 4) dimensions.", false)
        case .failure(let error): return (error.localizedDescription, true)
        }
    }
}

enum VectorQuantization: String, CaseIterable, Identifiable, Sendable {
    case q8 = "Q8"
    case noQuant = "NOQUANT"
    case bin = "BIN"
    var id: String { rawValue }

    /// Maps VINFO `quant-type` (`int8`, `f32`, `bin`).
    init?(quantType: String?) {
        switch quantType?.lowercased() {
        case "int8", "q8": self = .q8
        case "f32", "noquant", "float32": self = .noQuant
        case "bin", "binary": self = .bin
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .q8: return "Q8 (int8, default)"
        case .noQuant: return "NOQUANT (float32)"
        case .bin: return "BIN (binary)"
        }
    }
}

/// Options only used when the set is created (Add Key).
struct VectorSetCreateOptions: Hashable, Sendable {
    var quantization: VectorQuantization = .q8
    var reduceDimension: Int?
    var buildEF: Int?
    var links: Int?
}

enum SimilarityMode: String, CaseIterable, Identifiable, Sendable {
    case vector = "Vector"
    case element = "Element"
    var id: String { rawValue }
}

enum SimilarityQueryInput: Hashable, Sendable {
    case element(Data)
    case vector(VectorInput)
}

struct SimilarityRequest: Hashable, Sendable {
    var key: Data
    var query: SimilarityQueryInput
    var count: Int?
    var filter: String?
    var ef: Int?
    var epsilon: Double?
    var withAttributes: Bool
}

struct SimilarityMatch: Identifiable, Hashable, Sendable {
    var name: Data
    var score: Double
    var attributes: String?
    var rank: Int
    var id: Data { name }
}

struct VectorSetInfo: Hashable, Sendable {
    var quantType: String?
    var dimension: Int?
    var size: Int?
    var attributesCount: Int?
    /// Input dimension when the set was created with `REDUCE` (random projection); 0 or nil otherwise.
    var projectionInputDim: Int?
    var raw: [(String, String)] = []

    /// Dimension of vectors users must supply (the projection input when the set reduces dimensions).
    var inputDimension: Int? {
        if let projection = projectionInputDim, projection > 0 { return projection }
        return dimension
    }

    /// Options every `VADD` into this existing set must repeat (quantization and projection).
    var addOptions: VectorSetCreateOptions? {
        guard let quantization = VectorQuantization(quantType: quantType) else { return nil }
        var options = VectorSetCreateOptions(quantization: quantization)
        if let projection = projectionInputDim, projection > 0 { options.reduceDimension = dimension }
        return options
    }

    static func == (lhs: VectorSetInfo, rhs: VectorSetInfo) -> Bool {
        lhs.quantType == rhs.quantType && lhs.dimension == rhs.dimension && lhs.size == rhs.size
            && lhs.attributesCount == rhs.attributesCount && lhs.projectionInputDim == rhs.projectionInputDim
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(quantType)
        hasher.combine(dimension)
    }
}

enum VectorSetCommands {
    static let pageSize = 50
    static let maxSimilarityCount = 1_000
    static let vectorDisplayLimit = 100_000
    static let highSimilarity = 0.85

    static func add(key: Data, element: Data, vector: VectorInput, attributes: String?,
                    create: VectorSetCreateOptions? = nil) -> [RedisArgument] {
        var args: [RedisArgument] = ["VADD", .data(key)]
        if let reduce = create?.reduceDimension, reduce > 0 { args += ["REDUCE", .int(Int64(reduce))] }
        switch vector {
        case .values(let values):
            args += ["VALUES", .int(Int64(values.count))]
            args += values.map { .string(RedisArgument.format($0)) }
        case .fp32(let bytes):
            args += ["FP32", .data(bytes)]
        }

        args.append(.data(element))
        if let create {
            args.append(.string(create.quantization.rawValue))
            if let ef = create.buildEF, ef > 0 { args += ["EF", .int(Int64(ef))] }
        }

        if let attributes, !attributes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["SETATTR", .string(attributes)]
        }

        if let links = create?.links, links > 0 { args += ["M", .int(Int64(links))] }
        return args
    }

    static func similarity(_ request: SimilarityRequest) -> [RedisArgument] {
        var args: [RedisArgument] = ["VSIM", .data(request.key)]
        switch request.query {
        case .element(let name): args += ["ELE", .data(name)]
        case .vector(.values(let values)):
            args += ["VALUES", .int(Int64(values.count))] + values.map { .string(RedisArgument.format($0)) }
        case .vector(.fp32(let bytes)): args += ["FP32", .data(bytes)]
        }

        args.append("WITHSCORES")
        if request.withAttributes { args.append("WITHATTRIBS") }
        if let count = request.count { args += ["COUNT", .int(Int64(count))] }
        if let epsilon = request.epsilon { args += ["EPSILON", .string(RedisArgument.format(epsilon))] }
        if let ef = request.ef { args += ["EF", .int(Int64(ef))] }
        if let filter = request.filter, !filter.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["FILTER", .string(filter)]
        }

        return args
    }

    /// CLI-style preview of a command: tokens quoted when they contain whitespace, quotes or backslashes;
    /// FP32 payloads shown as `"\xHH…"`.
    static func preview(_ args: [RedisArgument], binaryIndexes: Set<Int> = []) -> String {
        args.enumerated().map { index, arg in
            if binaryIndexes.contains(index) {
                return "\"" + arg.data.map { String(format: "\\x%02x", $0) }.joined() + "\""
            }

            return quote(String(decoding: arg.data, as: UTF8.self))
        }.joined(separator: " ")
    }

    static func similarityPreview(_ request: SimilarityRequest) -> String {
        let args = similarity(request)
        var binary: Set<Int> = []
        if case .vector(.fp32) = request.query { binary.insert(3) }
        return preview(args, binaryIndexes: binary)
    }

    static func quote(_ token: String) -> String {
        if token.isEmpty { return "\"\"" }
        let needsQuotes = token.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }
        guard needsQuotes else { return token }
        return "\"" + token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `VSIM … WITHSCORES [WITHATTRIBS]`: RESP2 flat pairs/triples or a RESP3 map; trailing partial tuples dropped.
    static func parseSimilarity(_ reply: RESPValue, withAttributes: Bool) -> [SimilarityMatch] {
        var matches: [SimilarityMatch] = []
        if case .map(let pairs) = reply {
            for (name, value) in pairs {
                guard let data = name.dataValue else { continue }
                var score = value.doubleValue ?? .nan
                var attributes: String?
                if let parts = value.arrayValue {
                    score = parts.first?.doubleValue ?? .nan
                    attributes = parts.count > 1 ? Reply.text(parts[1]) : nil
                }

                matches.append(SimilarityMatch(name: data, score: score, attributes: attributes, rank: matches.count + 1))
            }

            return matches
        }

        let items = Reply.items(reply)
        let stride = withAttributes ? 3 : 2
        var index = 0
        while index + stride <= items.count {
            if let name = items[index].dataValue {
                let attributes = withAttributes ? Reply.text(items[index + 2]) : nil
                matches.append(SimilarityMatch(name: name, score: items[index + 1].doubleValue ?? .nan,
                                               attributes: attributes, rank: matches.count + 1))
            }

            index += stride
        }

        return matches
    }

    static func parseInfo(_ reply: RESPValue) -> VectorSetInfo {
        let pairs = reply.mapValue ?? []
        var info = VectorSetInfo()
        for (k, v) in pairs {
            guard let key = k.stringValue else { continue }
            let text = Reply.text(v) ?? ""
            info.raw.append((key, text))
            switch key {
            case "quant-type": info.quantType = text
            case "vector-dim": info.dimension = Reply.optionalInt(v)
            case "size": info.size = Reply.optionalInt(v)
            case "attributes-count": info.attributesCount = Reply.optionalInt(v)
            case "projection-input-dim": info.projectionInputDim = Reply.optionalInt(v)
            default: break
            }
        }

        return info
    }

    static func parseEmbedding(_ reply: RESPValue) -> [Double] {
        Reply.items(reply).compactMap(\.doubleValue)
    }

    static func embeddingText(_ values: [Double], limit: Int = vectorDisplayLimit) -> (text: String, truncated: Bool) {
        let truncated = values.count > limit
        let shown = truncated ? Array(values.prefix(limit)) : values
        let body = shown.map { RedisArgument.format($0) }.joined(separator: ", ")
        return ("[" + body + (truncated ? ", ...]" : "]"), truncated)
    }

    static func similarityText(_ score: Double) -> String {
        guard score.isFinite else { return "—" }
        return String(format: "%.2f %%", score * 100)
    }

    /// Top-level keys of JSON object attributes (filter autocomplete and attribute columns).
    static func attributeKeys(_ attributes: [String]) -> [String] {
        var keys = Set<String>()
        for text in attributes {
            if case .object(let members)? = try? JSONParser.parse(text) {
                for member in members { keys.insert(member.key) }
            }
        }

        return keys.sorted()
    }

    static func attributeValue(_ attributes: String?, key: String) -> String? {
        attributeValues(attributes)[key]
    }

    /// Display text of each top-level attribute (strings unquoted, other values as JSON); the last duplicate wins.
    static func attributeValues(_ attributes: String?) -> [String: String] {
        guard let attributes, case .object(let members)? = try? JSONParser.parse(attributes) else { return [:] }
        var values: [String: String] = [:]
        for member in members {
            if case .string(let s) = member.value { values[member.key] = s } else { values[member.key] = JSONLiteral.format(member.value) }
        }

        return values
    }

    /// `.token` at the end of the filter text, for autocomplete.
    static func filterToken(in text: String) -> (range: Range<String.Index>, prefix: String)? {
        filterToken(in: text, caret: nil).map { ($0.range, $0.prefix) }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// String index for a UTF-16 caret offset (nil = end), rounded down to a character boundary.
    static func index(in text: String, utf16Offset offset: Int?) -> String.Index {
        guard let offset else { return text.endIndex }
        var consumed = 0
        var index = text.startIndex
        while index < text.endIndex {
            let width = text[index].utf16.count
            if consumed + width > offset { break }
            consumed += width
            index = text.index(after: index)
        }

        return index
    }

    /// The `.token` the caret is inside (a dot not preceded by a word character, followed by word characters).
    /// `range` covers the whole token (dot included), `prefix` is the part before the caret, `start` is the
    /// UTF-16 offset of the dot.
    static func filterToken(in text: String, caret: Int?)
        -> (range: Range<String.Index>, prefix: String, word: String, start: Int)? {
        let caretIndex = index(in: text, utf16Offset: caret)
        var wordStart = caretIndex
        while wordStart > text.startIndex, isWordCharacter(text[text.index(before: wordStart)]) {
            wordStart = text.index(before: wordStart)
        }

        guard wordStart > text.startIndex else { return nil }
        let dot = text.index(before: wordStart)
        guard text[dot] == "." else { return nil }
        if dot > text.startIndex, isWordCharacter(text[text.index(before: dot)]) { return nil }
        var tokenEnd = caretIndex
        while tokenEnd < text.endIndex, isWordCharacter(text[tokenEnd]) { tokenEnd = text.index(after: tokenEnd) }
        return (dot..<tokenEnd, String(text[wordStart..<caretIndex]), String(text[wordStart..<tokenEnd]),
                dot.utf16Offset(in: text))
    }

    static func filterSuggestions(text: String, keys: [String]) -> [String] {
        filterSuggestions(text: text, caret: nil, keys: keys)
    }

    /// Known keys matching the token at the caret (case-insensitive prefix), minus keys used elsewhere.
    static func filterSuggestions(text: String, caret: Int?, keys: [String]) -> [String] {
        guard let token = filterToken(in: text, caret: caret) else { return [] }
        let elsewhere = String(text[..<token.range.lowerBound]) + " " + String(text[token.range.upperBound...])
        let usedElsewhere = Set(usedAttributes(in: elsewhere))
        let prefix = token.prefix.lowercased()
        return keys.sorted().filter {
            !usedElsewhere.contains($0) && $0.lowercased().hasPrefix(prefix) && $0 != token.word
        }
    }

    static func usedAttributes(in text: String) -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while let dot = text[index...].firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" { end = text.index(after: end) }
            let name = String(text[text.index(after: dot)..<end])
            if !name.isEmpty { result.append(name) }
            index = end
            if index >= text.endIndex { break }
        }

        return result
    }

    static func applySuggestion(_ suggestion: String, to text: String) -> String {
        applySuggestion(suggestion, to: text, caret: nil)?.text ?? text
    }

    /// Replaces the whole token at the caret; returns the new text and the caret after the inserted key.
    static func applySuggestion(_ suggestion: String, to text: String, caret: Int?) -> (text: String, caret: Int)? {
        guard let token = filterToken(in: text, caret: caret) else { return nil }
        let replacement = "." + suggestion
        return (text.replacingCharacters(in: token.range, with: replacement), token.start + replacement.utf16.count)
    }
}
