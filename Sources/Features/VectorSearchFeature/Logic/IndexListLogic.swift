import Foundation
import RedisUI

struct IndexListRow: Identifiable, Hashable {
    var id: Data { name }
    var name: Data
    var displayName: String
    var sortName: String
    var prefixes: [String]
    var prefixText: String
    var keyType: SearchIndexKeyType?
    var fieldTypes: [SearchFieldType]
    var typesText: String { fieldTypes.map(\.label).joined(separator: ", ") }
    var numDocs: Int
    var numRecords: Int
    var numTerms: Int
    var numFields: Int
}

enum IndexListLogic {
    static let badgeTypes: Set<SearchFieldType> = [.text, .tag, .numeric, .geo, .vector]

    static func displayName(_ name: Data) -> String {
        name.isEmpty ? VectorSearchStrings.emptyIndexName : RedisKeyName(name).displayString()
    }

    static func prefixText(_ prefixes: [String]) -> String {
        prefixes.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    /// Unique attribute types in attribute order; types without a badge (GEOSHAPE, unknown) are dropped.
    static func fieldTypes(_ attributes: [SearchIndexAttribute]) -> [SearchFieldType] {
        var seen = Set<SearchFieldType>()
        return attributes.compactMap(\.fieldType).filter { badgeTypes.contains($0) && seen.insert($0).inserted }
    }

    static func row(_ info: SearchIndexInfo) -> IndexListRow {
        let display = displayName(info.name)
        return IndexListRow(name: info.name, displayName: display, sortName: display.lowercased(),
                            prefixes: info.prefixes, prefixText: prefixText(info.prefixes), keyType: info.keyType,
                            fieldTypes: fieldTypes(info.attributes), numDocs: info.numDocs,
                            numRecords: info.numRecords, numTerms: info.numTerms, numFields: info.attributes.count)
    }

    /// Keeps FT._LIST order and drops indexes whose FT.INFO failed.
    /// Filters names by a trimmed, case-insensitive substring.
    static func rows(names: [Data], infos: [Data: SearchIndexInfo], filter: String) -> [IndexListRow] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return names.compactMap { infos[$0] }.map(row).filter { row in
            needle.isEmpty || row.displayName.lowercased().contains(needle)
        }
    }

    static func emptyMessage(isLoading: Bool, filter: String) -> String {
        if isLoading { return "Loading…" }
        if !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No results found" }
        return "No indexes found"
    }

    // MARK: - Index info text

    static func indexingSentence(_ info: SearchIndexInfo) -> String {
        let type = info.keyType.map { $0 == .hash ? "HASH " : "JSON " } ?? ""
        if info.prefixes.isEmpty { return "Covers all \(type)keys." }
        return "Covers \(type)keys starting with \(prefixText(info.prefixes))."
    }

    static func optionsText(filter: String?, language: String?) -> String {
        var parts: [String] = []
        if let filter, !filter.isEmpty { parts.append("Filter: \(filter)") }
        if let language, !language.isEmpty { parts.append("Language: \(language)") }
        return parts.isEmpty ? "No filter or default language set." : parts.joined(separator: " · ")
    }

    static func summaryText(_ info: SearchIndexInfo) -> String {
        let max = info.maxDocId.map { " (max ID \($0))" } ?? ""
        return "Documents: \(info.numDocs)\(max) · Records: \(info.numRecords) · Terms: \(info.numTerms)"
    }

    /// Backfill progress ("42%") while a valkey-search index is backfilling, nil otherwise.
    static func backfillText(_ info: SearchIndexInfo) -> String? {
        guard info.backfillInProgress == true, let fraction = info.backfillCompleteFraction, fraction.isFinite else {
            return nil
        }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// Formats the valkey-search state and optional backfill progress; returns nil if FT.INFO has no state.
    static func stateText(_ info: SearchIndexInfo) -> String? {
        guard let state = info.state else { return nil }
        return "State: \(state)" + (backfillText(info).map { " (\($0) backfilled)" } ?? "")
    }

    static let flagOrder = ["SORTABLE", "NOINDEX", "CASESENSITIVE", "UNF", "NOSTEM", "WITHSUFFIXTRIE", "INDEXEMPTY", "INDEXMISSING"]

    /// Flag columns present on at least one attribute, in the fixed order.
    static func flagColumns(_ attributes: [SearchIndexAttribute]) -> [String] {
        let present = attributes.reduce(into: Set<String>()) { $0.formUnion($1.flags) }
        return flagOrder.filter(present.contains)
    }

    static func hasWeights(_ attributes: [SearchIndexAttribute]) -> Bool {
        attributes.contains { !($0.weight ?? "").isEmpty }
    }
}

enum IndexListColumn: CaseIterable, Hashable {
    case name, prefix, types, docs, records, terms, fields

    static let tableMinWidth: CGFloat = 640
    static let described: [IndexListColumn] = [.prefix, .docs, .records, .terms, .fields]

    var title: String {
        switch self {
        case .name: return "Name"
        case .prefix: return "Prefix"
        case .types: return "Types"
        case .docs: return "Docs"
        case .records: return "Records"
        case .terms: return "Terms"
        case .fields: return "Fields"
        }
    }

    var tooltip: String {
        switch self {
        case .prefix: return "The index covers every key whose name starts with this prefix."
        case .docs: return "How many documents are in the index right now."
        case .records: return "One record per indexed field value, so a document with 5 indexed fields adds 5 records."
        case .terms: return "Distinct words the TEXT fields add to the full-text dictionary."
        case .fields: return "Fields declared in the index schema."
        default: return ""
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 160
        case .prefix: return 110
        case .types: return 110
        case .docs, .records, .terms, .fields: return 65
        }
    }
}
