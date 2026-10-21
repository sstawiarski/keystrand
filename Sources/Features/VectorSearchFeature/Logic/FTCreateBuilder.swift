import Foundation
import RedisUI

enum FTCreateBuilder {
    /// Place TEXT fields last because RediSearch can parse a later field named `weight` as a WEIGHT modifier.
    static func typeRank(_ type: SearchFieldType) -> Int {
        switch type {
        case .numeric: return 0
        case .geo: return 1
        case .tag: return 2
        case .text: return 3
        case .vector: return 4
        case .geoshape: return 3
        }
    }

    static func quote(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func formatNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// Stable sort by type rank.
    static func ordered(_ fields: [IndexFieldDraft]) -> [IndexFieldDraft] {
        fields.enumerated()
            .sorted { lhs, rhs in
                let l = typeRank(lhs.element.type), r = typeRank(rhs.element.type)
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    static func command(indexName: String, keyType: SearchIndexKeyType, prefix: String,
                        fields: [IndexFieldDraft]) -> String {
        guard !fields.isEmpty else { return "" }
        var lines = [
            "FT.CREATE \(quote(indexName.trimmingCharacters(in: .whitespaces)))",
            "  ON \(keyType.rawValue)",
            "    PREFIX 1 \(quote(prefix))",
            "  SCHEMA",
        ]
        for field in ordered(fields) {
            lines += schemaLines(field, keyType: keyType).map { "    " + $0 }
        }

        return lines.joined(separator: "\n")
    }

    static func reference(_ name: String, keyType: SearchIndexKeyType) -> String {
        switch keyType {
        case .hash: return quote(name)
        case .json: return "$.\(name) AS \(quote(name))"
        }
    }

    static func schemaLines(_ field: IndexFieldDraft, keyType: SearchIndexKeyType) -> [String] {
        let ref = reference(field.name, keyType: keyType)
        switch field.type {
        case .tag, .numeric, .geo, .geoshape:
            return ["\(ref) \(field.type.label)"]
        case .text:
            var line = "\(ref) TEXT"
            if let weight = field.text.weight, weight != 1 { line += " WEIGHT \(formatNumber(weight))" }
            if field.text.phonetic != .none { line += " PHONETIC \(field.text.phonetic.rawValue)" }
            return [line]
        case .vector:
            let params = vectorParams(field.vector)
            return ["\(ref) VECTOR \(field.vector.algorithm.rawValue) \(params.count * 2)"]
                + params.map { "  \($0.0) \($0.1)" }
        }
    }

    static func vectorParams(_ options: VectorFieldOptions) -> [(String, String)] {
        var params: [(String, String)] = [
            ("TYPE", options.dataType.rawValue),
            ("DIM", String(options.dimensions ?? 384)),
            ("DISTANCE_METRIC", options.distanceMetric.rawValue),
        ]
        if let cap = options.initialCap { params.append(("INITIAL_CAP", String(cap))) }
        switch options.algorithm {
        case .flat:
            if let block = options.blockSize { params.append(("BLOCK_SIZE", String(block))) }
        case .hnsw:
            if let m = options.maxEdges { params.append(("M", String(m))) }
            if let ef = options.maxNeighbors { params.append(("EF_CONSTRUCTION", String(ef))) }
            if let runtime = options.candidateLimit { params.append(("EF_RUNTIME", String(runtime))) }
            if let epsilon = options.epsilon { params.append(("EPSILON", formatNumber(epsilon))) }
        }

        return params
    }
}
