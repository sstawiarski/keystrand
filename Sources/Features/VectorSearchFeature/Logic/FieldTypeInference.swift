import Foundation
import RedisUI

/// Infers index field types without actor isolation so large samples can run off the main actor.
enum FieldTypeInference {
    /// Sample values kept for display; long values are cut to keep the schema table light.
    static let maxSampleLength = 2_000

    // MARK: - Key-derived defaults

    static func prefix(forKey key: String) -> String {
        guard let index = key.lastIndex(of: ":") else { return "" }
        return String(key[...index])
    }

    static func defaultIndexName(prefix: String) -> String {
        var trimmed = prefix
        if trimmed.hasSuffix(":") { trimmed.removeLast() }
        return trimmed.isEmpty ? "idx:myindex" : "idx:\(trimmed)"
    }

    // MARK: - Binary vectors

    static func isFloat32Vector(_ data: Data) -> Bool {
        guard data.count >= 8, data.count % 4 == 0 else { return false }
        if String(data: data, encoding: .utf8) != nil { return false }
        return float32Values(data).allSatisfy(\.isFinite)
    }

    static func float32Values(_ data: Data, limit: Int = .max) -> [Float] {
        let count = min(data.count / 4, limit)
        var out: [Float] = []
        out.reserveCapacity(count)
        let bytes = [UInt8](data.prefix(count * 4))
        for i in 0..<count {
            let b = i * 4
            let bits = UInt32(bytes[b]) | UInt32(bytes[b + 1]) << 8 | UInt32(bytes[b + 2]) << 16 | UInt32(bytes[b + 3]) << 24
            out.append(Float(bitPattern: bits))
        }

        return out
    }

    /// `[a, b, c, d, ...] (N dims)` with JavaScript `toPrecision(6)` formatting.
    static func vectorPreview(_ values: [Double], dims: Int) -> String {
        let shown = values.prefix(4).map { toPrecision($0, 6) }.joined(separator: ", ")
        let more = dims > 4 ? ", ..." : ""
        return "[\(shown)\(more)] (\(dims) dims)"
    }

    /// JavaScript `Number.prototype.toPrecision`.
    static func toPrecision(_ value: Double, _ precision: Int) -> String {
        guard value.isFinite else { return String(value) }
        if value == 0 { return precision > 1 ? "0." + String(repeating: "0", count: precision - 1) : "0" }
        let exponent = Int(floor(log10(abs(value))))
        if exponent < -6 || exponent >= precision {
            let formatted = String(format: "%.\(max(precision - 1, 0))e", value)
            guard let eIndex = formatted.firstIndex(of: "e") else { return formatted }
            let mantissa = formatted[..<eIndex]
            let exp = Int(formatted[formatted.index(after: eIndex)...]) ?? 0
            return "\(mantissa)e\(exp >= 0 ? "+" : "-")\(abs(exp))"
        }

        let decimals = max(precision - 1 - exponent, 0)
        return String(format: "%.\(decimals)f", value)
    }

    // MARK: - Hash

    static func inferHash(_ pairs: [(field: Data, value: Data)]) -> [IndexFieldDraft] {
        var regular: [IndexFieldDraft] = []
        var vectors: [IndexFieldDraft] = []
        var seen = Set<String>()
        for pair in pairs {
            let name = String(decoding: pair.field, as: UTF8.self)
            guard seen.insert(name).inserted else { continue }
            if isFloat32Vector(pair.value) {
                let dims = pair.value.count / 4
                let preview = vectorPreview(float32Values(pair.value, limit: 4).map(Double.init), dims: dims)
                var options = VectorFieldOptions()
                options.algorithm = .flat
                options.dataType = .float32
                options.dimensions = dims
                vectors.append(IndexFieldDraft(name: name, sampleValue: preview, type: .vector, vector: options))
                continue
            }

            let text = RedisKeyName(pair.value).displayString()
            let (type, dims) = inferString(text, strictNumbers: false)
            regular.append(makeField(name: name, sample: text, type: type, dims: dims))
        }

        return regular + vectors
    }

    // MARK: - JSON

    /// Top-level members only; nested objects/arrays that are not geo/vector are returned in `skipped`.
    static func inferJSON(_ value: JSONValue) -> (fields: [IndexFieldDraft], skipped: [String]) {
        var root = value
        if case .array(let items) = value, let first = items.first { root = first }
        guard let members = root.members else { return ([], []) }
        var fields: [IndexFieldDraft] = []
        var skipped: [String] = []
        for member in members {
            if let (type, dims) = inferJSONValue(member.value) {
                fields.append(makeField(name: member.key, sample: jsonSample(member.value), type: type, dims: dims))
            } else {
                skipped.append(member.key)
            }
        }

        return (fields, skipped)
    }

    static func jsonSample(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .array, .object: return value.compactText
        }
    }

    /// Nil when the value must be skipped (nested container that is neither geo nor vector).
    static func inferJSONValue(_ value: JSONValue) -> (SearchFieldType, Int?)? {
        switch value {
        case .null, .bool: return (.tag, nil)
        case .number: return (.numeric, nil)
        case .string(let s): return inferString(s, strictNumbers: true)
        case .array(let items):
            let numbers = items.compactMap(numberValue)
            guard numbers.count == items.count else { return nil }
            if numbers.count == 2, isLonLat(numbers[0], numbers[1]) { return (.geo, nil) }
            if numbers.count >= 2, numbers.allSatisfy(\.isFinite) { return (.vector, numbers.count) }
            return nil
        case .object:
            if isGeoObject(value) { return (.geo, nil) }
            return nil
        }
    }

    // MARK: - Strings

    /// Infers GEO from valid "lon,lat" strings and VECTOR from JSON numeric arrays.
    /// Other numbers become NUMERIC only for hashes; short strings become TAG and long strings become TEXT.
    static func inferString(_ text: String, strictNumbers: Bool) -> (SearchFieldType, Int?) {
        if let (lon, lat) = parseLonLatString(text), isLonLat(lon, lat) { return (.geo, nil) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"),
           case .array(let items)? = try? JSONParser.parse(trimmed) {
            let numbers = items.compactMap(numberValue)
            if numbers.count == items.count, numbers.count >= 2, numbers.allSatisfy(\.isFinite) {
                return (.vector, numbers.count)
            }
        }

        if !strictNumbers, isNumericString(trimmed) { return (.numeric, nil) }
        return text.count < 50 ? (.tag, nil) : (.text, nil)
    }

    static func isNumericString(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return false }
        return value.isFinite
    }

    static func parseLonLatString(_ text: String) -> (Double, Double)? {
        let pattern = #"^\s*(-?\d+(\.\d+)?)\s*,\s*(-?\d+(\.\d+)?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let lon = Double(ns.substring(with: match.range(at: 1))),
              let lat = Double(ns.substring(with: match.range(at: 3))) else { return nil }
        return (lon, lat)
    }

    static func isLonLat(_ lon: Double, _ lat: Double) -> Bool {
        lon.isFinite && lat.isFinite && abs(lon) <= 180 && abs(lat) <= 90
    }

    static func isGeoObject(_ value: JSONValue) -> Bool {
        let lon = (value["lon"] ?? value["longitude"]).flatMap(numberValue)
        let lat = (value["lat"] ?? value["latitude"]).flatMap(numberValue)
        guard let lon, let lat else { return false }
        return isLonLat(lon, lat)
    }

    static func numberValue(_ value: JSONValue) -> Double? {
        if case .number(let text) = value { return Double(text) }
        return nil
    }

    static func makeField(name: String, sample: String, type: SearchFieldType, dims: Int?) -> IndexFieldDraft {
        var field = IndexFieldDraft(name: name, sampleValue: String(sample.prefix(maxSampleLength)), type: type)
        if let dims {
            field.vector.dimensions = dims
            field.vector.algorithm = .flat
            field.vector.dataType = .float32
        }

        return field
    }

    // MARK: - Notices

    static func skippedNotice(_ names: [String]) -> String? {
        switch names.count {
        case 0: return nil
        case 1: return "Skipped \"\(names[0])\" because nested objects and arrays can't be indexed as they are."
        default:
            return "Skipped \(names.count) fields (\(names.joined(separator: ", "))) because nested objects and arrays can't be indexed as they are."
        }
    }
}
