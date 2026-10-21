import Foundation

/// Binary field types for hash value decoders.
public enum BinaryDataType: String, Codable, CaseIterable, Sendable, Hashable {
    case uint8, int8, boolean
    case uint16le, uint16be, int16le, int16be
    case uint32le, uint32be, int32le, int32be
    case floatle, floatbe
    case bigint64le, bigint64be, biguint64le, biguint64be
    case doublele, doublebe
    case string, hex

    /// Byte width for fixed-size types; `nil` for `string` / `hex`.
    public var fixedSize: Int? {
        switch self {
        case .uint8, .int8, .boolean: return 1
        case .uint16le, .uint16be, .int16le, .int16be: return 2
        case .uint32le, .uint32be, .int32le, .int32be, .floatle, .floatbe: return 4
        case .bigint64le, .bigint64be, .biguint64le, .biguint64be, .doublele, .doublebe: return 8
        case .string, .hex: return nil
        }
    }

    /// Integer types whose decoded value can drive a repeat count or a field size.
    public var isNumericCount: Bool {
        switch self {
        case .boolean, .floatle, .floatbe, .doublele, .doublebe, .string, .hex: return false
        default: return true
        }
    }

    public var isCustomSize: Bool { fixedSize == nil }
}

public enum FieldSizeSource: String, Codable, Sendable, Hashable {
    case fixed
    case field
}

public struct BinaryFieldDefinition: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var dataType: BinaryDataType
    /// Byte length for `string` / `hex` with a fixed size (`nil` while the form field is empty).
    public var size: Int?
    public var sizeSource: FieldSizeSource
    /// Id of a prior numeric field whose value is the byte length.
    public var sizeFieldRef: String?

    public init(id: String = ValueDecoderEngine.newID("field"), name: String = "", dataType: BinaryDataType = .uint8,
                size: Int? = 1, sizeSource: FieldSizeSource = .fixed, sizeFieldRef: String? = nil) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.size = size
        self.sizeSource = sizeSource
        self.sizeFieldRef = sizeFieldRef
    }
}

public struct RepeatBlockDefinition: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Id of a prior numeric field whose value is the repeat count.
    public var countFieldRef: String
    public var fields: [SchemaNode]

    public init(id: String = ValueDecoderEngine.newID("repeat"), name: String = "", countFieldRef: String = "",
                fields: [SchemaNode] = [.field(BinaryFieldDefinition())]) {
        self.id = id
        self.name = name
        self.countFieldRef = countFieldRef
        self.fields = fields
    }
}

public indirect enum SchemaNode: Codable, Sendable, Hashable, Identifiable {
    case field(BinaryFieldDefinition)
    case repeatBlock(RepeatBlockDefinition)

    public var id: String {
        switch self {
        case .field(let f): return f.id
        case .repeatBlock(let r): return r.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, name, dataType, size, sizeSource, sizeFieldRef, countFieldRef, fields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "field"
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? ValueDecoderEngine.newID(kind)
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if kind == "repeat" {
            self = .repeatBlock(RepeatBlockDefinition(
                id: id, name: name,
                countFieldRef: try c.decodeIfPresent(String.self, forKey: .countFieldRef) ?? "",
                fields: try c.decodeIfPresent([SchemaNode].self, forKey: .fields) ?? []))
            return
        }

        let typeText = try c.decodeIfPresent(String.self, forKey: .dataType) ?? "uint8"
        var size: Int?
        if let n = try? c.decodeIfPresent(Int.self, forKey: .size) {
            size = n
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .size), d.isFinite, d == d.rounded() {
            size = Int(d)
        }

        self = .field(BinaryFieldDefinition(
            id: id, name: name, dataType: BinaryDataType(rawValue: typeText) ?? .uint8, size: size,
            sizeSource: FieldSizeSource(rawValue: try c.decodeIfPresent(String.self, forKey: .sizeSource) ?? "fixed") ?? .fixed,
            sizeFieldRef: try c.decodeIfPresent(String.self, forKey: .sizeFieldRef)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .field(let f):
            try c.encode(f.id, forKey: .id)
            try c.encode("field", forKey: .kind)
            try c.encode(f.name, forKey: .name)
            try c.encode(f.dataType.rawValue, forKey: .dataType)
            if let size = f.size { try c.encode(size, forKey: .size) } else { try c.encode("", forKey: .size) }
            try c.encode(f.sizeSource.rawValue, forKey: .sizeSource)
            try c.encodeIfPresent(f.sizeFieldRef, forKey: .sizeFieldRef)
        case .repeatBlock(let r):
            try c.encode(r.id, forKey: .id)
            try c.encode("repeat", forKey: .kind)
            try c.encode(r.name, forKey: .name)
            try c.encode(r.countFieldRef, forKey: .countFieldRef)
            try c.encode(r.fields, forKey: .fields)
        }
    }
}

public struct ValueDecoderRule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var keyPatterns: [String]
    /// Always `"binary"`.
    public var decoderType: String
    public var schema: [SchemaNode]

    public init(id: String = ValueDecoderEngine.newID("decoder"), name: String = "", keyPatterns: [String] = [""],
                decoderType: String = "binary", schema: [SchemaNode] = [.field(BinaryFieldDefinition())]) {
        self.id = id
        self.name = name
        self.keyPatterns = keyPatterns
        self.decoderType = decoderType
        self.schema = schema
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, keyPatterns, decoderType, schema, keyPattern, fields
    }

    /// Accepts the legacy `keyPattern` string and flat `fields` array.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ValueDecoderEngine.newID("decoder")
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        decoderType = try c.decodeIfPresent(String.self, forKey: .decoderType) ?? "binary"
        var patterns = try c.decodeIfPresent([String].self, forKey: .keyPatterns) ?? []
        if patterns.isEmpty, let legacy = try c.decodeIfPresent(String.self, forKey: .keyPattern), !legacy.isEmpty {
            patterns = [legacy]
        }

        keyPatterns = patterns
        var nodes = try c.decodeIfPresent([SchemaNode].self, forKey: .schema) ?? []
        if nodes.isEmpty { nodes = try c.decodeIfPresent([SchemaNode].self, forKey: .fields) ?? [] }
        schema = nodes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(keyPatterns, forKey: .keyPatterns)
        try c.encode(decoderType, forKey: .decoderType)
        try c.encode(schema, forKey: .schema)
    }

    /// Name, or the first key pattern, or "Untitled decoder".
    public var label: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return keyPatterns.first(where: { !$0.isEmpty }) ?? "Untitled decoder"
    }
}

public indirect enum ParsedBinaryNode: Hashable, Sendable {
    case field(name: String, size: Int, value: String)
    case group(label: String, children: [ParsedBinaryNode])
}

public enum ValueDecoderEngine {
    public static let maxRepeatIterations = 1000
    public static let insufficientData = "<insufficient data>"
    public static let clipboardType = "keystrand/value-decoder"
    public static let clipboardVersion = 1

    public static func newID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    // MARK: Key patterns

    /// Redis-style glob (`*`, `?`, `[a-z]`, `[^x]`, `\` escapes) over the whole key name.
    public static func matches(pattern: String, key: String) -> Bool {
        guard !pattern.isEmpty, let tokens = globTokens(pattern) else { return false }
        return globMatch(tokens[...], Array(key)[...])
    }

    /// Literal 4, escaped 4, `[class]` 3, `?` 2, `*` 1; empty pattern -1.
    public static func specificity(_ pattern: String) -> Int {
        guard !pattern.isEmpty else { return -1 }
        let chars = Array(pattern)
        var score = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                score += 4
                i += 2
            } else if c == "*" {
                score += 1
                i += 1
            } else if c == "?" {
                score += 2
                i += 1
            } else if c == "[", let (_, next) = characterClass(chars, at: i) {
                score += 3
                i = next
            } else {
                score += 4
                i += 1
            }
        }

        return score
    }

    /// The rule whose best matching pattern is most specific (first rule wins ties).
    public static func matchingRule(_ rules: [ValueDecoderRule], key: String) -> ValueDecoderRule? {
        var best: ValueDecoderRule?
        var bestScore = -1
        for rule in rules {
            let score = rule.keyPatterns.filter { matches(pattern: $0, key: key) }.map(specificity).max() ?? -1
            if score > bestScore {
                bestScore = score
                best = rule
            }
        }

        return best
    }

    /// Escapes glob metacharacters so the key name matches only itself.
    public static func escapeGlob(_ literal: String) -> String {
        var out = ""
        for c in literal {
            if "\\*?[]".contains(c) { out.append("\\") }
            out.append(c)
        }

        return out
    }

    private enum GlobToken {
        case literal(Character)
        case any
        case star
        case set(negated: Bool, items: [ClosedRange<Character>])
    }

    private static func characterClass(_ chars: [Character], at start: Int) -> ((Bool, [ClosedRange<Character>]), Int)? {
        var i = start + 1
        guard i < chars.count else { return nil }
        var negated = false
        if chars[i] == "^" {
            negated = true
            i += 1
        }

        guard i < chars.count else { return nil }
        var items: [ClosedRange<Character>] = []
        if chars[i] == "]" {
            items.append("]"..."]")
            i += 1
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                items.append(chars[i + 1]...chars[i + 1])
                i += 2
                continue
            }

            if c == "]" {
                return items.isEmpty ? nil : ((negated, items), i + 1)
            }

            if i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2] != "]" {
                let lo = min(c, chars[i + 2]), hi = max(c, chars[i + 2])
                items.append(lo...hi)
                i += 3
                continue
            }

            items.append(c...c)
            i += 1
        }

        return nil
    }

    private static func globTokens(_ pattern: String) -> [GlobToken]? {
        let chars = Array(pattern)
        var tokens: [GlobToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "*?\\[]".contains(chars[i + 1]) {
                tokens.append(.literal(chars[i + 1]))
                i += 2
            } else if c == "*" {
                tokens.append(.star)
                i += 1
            } else if c == "?" {
                tokens.append(.any)
                i += 1
            } else if c == "[", let ((negated, items), next) = characterClass(chars, at: i) {
                tokens.append(.set(negated: negated, items: items))
                i = next
            } else {
                tokens.append(.literal(c))
                i += 1
            }
        }

        return tokens
    }

    private static func globMatch(_ pattern: ArraySlice<GlobToken>, _ text: ArraySlice<Character>) -> Bool {
        var p = pattern.startIndex, t = text.startIndex
        var starP: Int?, starT = 0
        while t < text.endIndex {
            if p < pattern.endIndex {
                switch pattern[p] {
                case .star:
                    starP = p
                    starT = t
                    p += 1
                    continue
                case .any:
                    p += 1
                    t += 1
                    continue
                case .literal(let c) where c == text[t]:
                    p += 1
                    t += 1
                    continue
                case .set(let negated, let items) where items.contains(where: { $0.contains(text[t]) }) != negated:
                    p += 1
                    t += 1
                    continue
                default:
                    break
                }
            }

            guard let sp = starP else { return false }
            p = sp + 1
            starT += 1
            t = starT
        }

        while p < pattern.endIndex, case .star = pattern[p] { p += 1 }
        return p == pattern.endIndex
    }

    // MARK: Validation

    struct NumericRef {
        var id: String
        var name: String
    }

    public static func isValid(_ rule: ValueDecoderRule) -> Bool {
        !rule.keyPatterns.filter({ !$0.isEmpty }).isEmpty && isValid(schema: rule.schema)
    }

    public static func isValid(schema: [SchemaNode]) -> Bool {
        !schema.isEmpty && schema.indices.allSatisfy { isNodeValid(schema[$0], prior: [], siblings: schema, index: $0) }
    }

    /// Prior numeric fields (by id and display name) usable as a size or count reference for `nodeID`.
    public static func priorNumericFields(_ schema: [SchemaNode], before nodeID: String) -> [(id: String, name: String)] {
        var result: [(String, String)] = []

        func walk(_ nodes: [SchemaNode]) -> Bool {
            for node in nodes {
                if node.id == nodeID { return true }
                switch node {
                case .field(let f):
                    let name = f.name.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, f.dataType.isNumericCount { result.append((f.id, name)) }
                case .repeatBlock(let r):
                    if walk(r.fields) { return true }
                }
            }

            return false
        }

        _ = walk(schema)
        return result.map { (id: $0.0, name: $0.1) }
    }

    private static func scope(_ prior: [NumericRef], _ siblings: [SchemaNode], _ index: Int) -> [NumericRef] {
        prior + siblings.prefix(index).compactMap { node -> NumericRef? in
            guard case .field(let f) = node else { return nil }
            let name = f.name.trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && f.dataType.isNumericCount ? NumericRef(id: f.id, name: name) : nil
        }
    }

    private static func isNodeValid(_ node: SchemaNode, prior: [NumericRef], siblings: [SchemaNode], index: Int) -> Bool {
        let refs = scope(prior, siblings, index)
        switch node {
        case .field(let f):
            guard !f.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            if f.dataType.isCustomSize, f.sizeSource == .field {
                return refs.contains { $0.id == f.sizeFieldRef }
            }

            return (f.size ?? 0) > 0
        case .repeatBlock(let r):
            guard !r.countFieldRef.isEmpty, refs.contains(where: { $0.id == r.countFieldRef }), !r.fields.isEmpty else { return false }
            return r.fields.indices.allSatisfy { isNodeValid(r.fields[$0], prior: refs, siblings: r.fields, index: $0) }
        }
    }

    // MARK: Decoding

    private final class Budget {
        var remainingGroups = ValueDecoderEngine.maxRepeatIterations
    }

    public static func decode(_ data: Data, schema: [SchemaNode]) -> [ParsedBinaryNode] {
        let bytes = [UInt8](data)
        var numeric: [String: Int] = [:]
        return parse(bytes, schema, offset: 0, numeric: &numeric, budget: Budget()).results
    }

    private static func parse(_ bytes: [UInt8], _ nodes: [SchemaNode], offset start: Int, numeric: inout [String: Int],
                              budget: Budget) -> (results: [ParsedBinaryNode], offset: Int, truncated: Bool) {
        var offset = start
        var results: [ParsedBinaryNode] = []
        for node in nodes {
            switch node {
            case .field(let field):
                let size = resolveSize(field, numeric)
                guard !field.name.isEmpty, size >= 0 else { continue }
                if size == 0 {
                    results.append(.field(name: field.name, size: 0, value: ""))
                    continue
                }

                guard offset + size <= bytes.count else {
                    results.append(.field(name: field.name, size: size, value: insufficientData))
                    return (results, offset, false)
                }
                let slice = Array(bytes[offset..<offset + size])
                let value = fieldValue(slice, field.dataType)
                if field.dataType.isNumericCount { numeric[field.id] = countValue(value) }
                results.append(.field(name: field.name, size: size, value: value))
                offset += size
            case .repeatBlock(let block):
                let full = max(0, numeric[block.countFieldRef] ?? 0)
                let count = min(min(full, maxRepeatIterations), budget.remainingGroups)
                var decoded = 0
                for index in 0..<count {
                    guard budget.remainingGroups > 0 else { break }
                    budget.remainingGroups -= 1
                    var scopeValues = numeric
                    let child = parse(bytes, block.fields, offset: offset, numeric: &scopeValues, budget: budget)
                    results.append(.group(label: String(index), children: child.results))
                    offset = child.offset
                    decoded += 1
                    if containsInsufficient(child.results) { return (results, offset, false) }
                    if child.truncated { return (results, offset, true) }
                }

                if decoded < full { return (results, offset, true) }
            }
        }

        return (results, offset, false)
    }

    private static func resolveSize(_ field: BinaryFieldDefinition, _ numeric: [String: Int]) -> Int {
        if let fixed = field.dataType.fixedSize { return fixed }
        if field.sizeSource == .field, let ref = field.sizeFieldRef { return numeric[ref] ?? 0 }
        return field.size ?? 0
    }

    private static func containsInsufficient(_ nodes: [ParsedBinaryNode]) -> Bool {
        nodes.contains { node in
            switch node {
            case .field(_, _, let value): return value == insufficientData
            case .group(_, let children): return containsInsufficient(children)
            }
        }
    }

    private static func countValue(_ text: String) -> Int {
        if let i = Int64(text) { return i < 0 ? 0 : Int(min(i, 9_007_199_254_740_991)) }
        if UInt64(text) != nil { return 9_007_199_254_740_991 }
        return 0
    }

    private static func fieldValue(_ b: [UInt8], _ type: BinaryDataType) -> String {
        func le(_ n: Int) -> UInt64 { (0..<n).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64(b[$1]) } }
        func be(_ n: Int) -> UInt64 { (0..<n).reduce(UInt64(0)) { $0 << 8 | UInt64(b[$1]) } }
        switch type {
        case .uint8: return String(b[0])
        case .int8: return String(Int8(bitPattern: b[0]))
        case .boolean: return b[0] != 0 ? "true" : "false"
        case .uint16le: return String(UInt16(le(2)))
        case .uint16be: return String(UInt16(be(2)))
        case .int16le: return String(Int16(bitPattern: UInt16(le(2))))
        case .int16be: return String(Int16(bitPattern: UInt16(be(2))))
        case .uint32le: return String(UInt32(le(4)))
        case .uint32be: return String(UInt32(be(4)))
        case .int32le: return String(Int32(bitPattern: UInt32(le(4))))
        case .int32be: return String(Int32(bitPattern: UInt32(be(4))))
        case .floatle: return JSONNumberText.float(Float(bitPattern: UInt32(le(4))))
        case .floatbe: return JSONNumberText.float(Float(bitPattern: UInt32(be(4))))
        case .bigint64le: return String(Int64(bitPattern: le(8)))
        case .bigint64be: return String(Int64(bitPattern: be(8)))
        case .biguint64le: return String(le(8))
        case .biguint64be: return String(be(8))
        case .doublele: return JSONNumberText.double(Double(bitPattern: le(8)))
        case .doublebe: return JSONNumberText.double(Double(bitPattern: be(8)))
        case .string: return String(decoding: b, as: UTF8.self)
        case .hex: return spacedUpperHex(b)
        }
    }

    static func spacedUpperHex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 3)
        for byte in bytes {
            if !out.isEmpty { out.append(0x20) }
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }

        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Display

    /// One `[name] [size] [value]` line per field; groups as indented `[index]` headers.
    public static func formatLines(_ nodes: [ParsedBinaryNode]) -> String {
        var lines: [String] = []

        func walk(_ items: [ParsedBinaryNode], _ depth: Int) {
            for node in items {
                switch node {
                case .group(let label, let children):
                    lines.append(String(repeating: "  ", count: depth + 1) + "[\(label)]")
                    walk(children, depth + 2)
                case .field(let name, let size, let value):
                    lines.append(String(repeating: "  ", count: depth) + "[\(name)] [\(size)] [\(value)]")
                }
            }
        }

        walk(nodes, 0)
        return lines.joined(separator: "\n")
    }

    public static func formatInline(_ nodes: [ParsedBinaryNode]) -> String {
        var parts: [String] = []

        func walk(_ items: [ParsedBinaryNode]) {
            for node in items {
                switch node {
                case .group(let label, let children):
                    parts.append("[\(label)]")
                    walk(children)
                case .field(let name, let size, let value):
                    parts.append("[\(name)] [\(size)] [\(value)]")
                }
            }
        }

        walk(nodes)
        return parts.joined(separator: " ")
    }

    // MARK: Clipboard

    /// `{"type": "keystrand/value-decoder", "version": 1, "decoders": [...]}` pretty-printed.
    public static func clipboardText(_ rules: [ValueDecoderRule]) -> String {
        struct Payload: Encodable {
            let type: String
            let version: Int
            let decoders: [ValueDecoderRule]
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let payload = Payload(type: clipboardType, version: clipboardVersion, decoders: rules)
        guard let data = try? encoder.encode(payload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Accepts the clipboard payload, a bare array of rules, or a single rule. Ids are regenerated.
    public static func rules(fromClipboard text: String) -> [ValueDecoderRule]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var candidates: [Any] = []
        if let array = object as? [Any] {
            candidates = array
        } else if let dict = object as? [String: Any] {
            if dict["type"] as? String == clipboardType, let list = dict["decoders"] as? [Any] {
                candidates = list
            } else {
                candidates = [dict]
            }
        }

        let rules = candidates.compactMap { candidate -> ValueDecoderRule? in
            guard let dict = candidate as? [String: Any],
                  dict["keyPatterns"] is [Any] || dict["keyPattern"] is String || dict["schema"] is [Any] || dict["fields"] is [Any],
                  let json = try? JSONSerialization.data(withJSONObject: dict),
                  let rule = try? JSONDecoder().decode(ValueDecoderRule.self, from: json) else { return nil }
            return cloned(rule)
        }
        return rules.isEmpty ? nil : rules
    }

    /// Copy with fresh ids; size/count references are remapped to the new ids.
    public static func cloned(_ rule: ValueDecoderRule) -> ValueDecoderRule {
        var map: [String: String] = [:]

        func collect(_ nodes: [SchemaNode]) {
            for node in nodes {
                switch node {
                case .field(let f): map[f.id] = map[f.id] ?? newID("field")
                case .repeatBlock(let r):
                    map[r.id] = map[r.id] ?? newID("repeat")
                    collect(r.fields)
                }
            }
        }

        func remap(_ nodes: [SchemaNode]) -> [SchemaNode] {
            nodes.map { node in
                switch node {
                case .field(var f):
                    f.id = map[f.id] ?? f.id
                    if let ref = f.sizeFieldRef { f.sizeFieldRef = map[ref] ?? ref }
                    return .field(f)
                case .repeatBlock(var r):
                    r.id = map[r.id] ?? r.id
                    r.countFieldRef = map[r.countFieldRef] ?? r.countFieldRef
                    r.fields = remap(r.fields)
                    return .repeatBlock(r)
                }
            }
        }

        collect(rule.schema)
        var copy = rule
        copy.id = newID("decoder")
        copy.keyPatterns = rule.keyPatterns.filter { !$0.isEmpty }
        copy.schema = remap(rule.schema)
        return copy
    }
}
