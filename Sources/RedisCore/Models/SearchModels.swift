import Foundation

public enum SearchIndexKeyType: String, Codable, Sendable, Hashable, CaseIterable {
    case hash = "HASH"
    case json = "JSON"
}

public enum SearchFieldType: String, Codable, Sendable, Hashable, CaseIterable {
    case text, tag, numeric, geo, vector, geoshape
}

public struct SearchIndexAttribute: Hashable, Sendable {
    public var identifier: String
    public var attribute: String
    /// Raw FT.INFO type (`TEXT`, `TAG`, `VECTOR`, ...).
    public var type: String
    public var weight: String?
    /// Standalone flag tokens (`SORTABLE`, `NOSTEM`, ...).
    public var flags: Set<String>
    public var raw: [String: String]

    public init(identifier: String, attribute: String, type: String, weight: String? = nil,
                flags: Set<String> = [], raw: [String: String] = [:]) {
        self.identifier = identifier
        self.attribute = attribute
        self.type = type
        self.weight = weight
        self.flags = flags
        self.raw = raw
    }

    public var fieldType: SearchFieldType? { SearchFieldType(rawValue: type.lowercased()) }
    /// The name a query uses for the field (`@name`): the alias, else the identifier.
    public var queryName: String { attribute.isEmpty ? identifier : attribute }
}

public struct SearchIndexInfo: Hashable, Sendable {
    public var name: Data
    public var keyType: SearchIndexKeyType?
    public var prefixes: [String]
    public var filter: String?
    public var defaultLanguage: String?
    public var attributes: [SearchIndexAttribute]
    public var numDocs: Int
    /// Absent on valkey-search.
    public var maxDocId: Int?
    public var numRecords: Int
    public var numTerms: Int
    /// valkey-search index state (`ready`, `backfill_in_progress`, ...); nil when absent or empty.
    public var state: String?
    public var backfillInProgress: Bool?
    /// valkey-search backfill progress, 0 to 1.
    public var backfillCompleteFraction: Double?
    /// Top-level FT.INFO reply for the "raw info" view.
    public var raw: RESPValue?

    public init(name: Data, keyType: SearchIndexKeyType? = nil, prefixes: [String] = [], filter: String? = nil,
                defaultLanguage: String? = nil, attributes: [SearchIndexAttribute] = [], numDocs: Int = 0,
                maxDocId: Int? = nil, numRecords: Int = 0, numTerms: Int = 0, state: String? = nil,
                backfillInProgress: Bool? = nil, backfillCompleteFraction: Double? = nil, raw: RESPValue? = nil) {
        self.name = name
        self.keyType = keyType
        self.prefixes = prefixes
        self.filter = filter
        self.defaultLanguage = defaultLanguage
        self.attributes = attributes
        self.numDocs = numDocs
        self.maxDocId = maxDocId
        self.numRecords = numRecords
        self.numTerms = numTerms
        self.state = state
        self.backfillInProgress = backfillInProgress
        self.backfillCompleteFraction = backfillCompleteFraction
        self.raw = raw
    }
}

/// Index covering a key (Browser "View index").
public struct SearchIndexSummary: Hashable, Sendable {
    public var name: Data
    public var prefixes: [String]
    public var keyType: SearchIndexKeyType?

    public init(name: Data, prefixes: [String], keyType: SearchIndexKeyType?) {
        self.name = name
        self.prefixes = prefixes
        self.keyType = keyType
    }
}

public struct SearchKeysPage: Hashable, Sendable {
    public var total: Int
    public var keys: [Data]
    public var nextOffset: Int?
    /// TYPE of the first key, applied to every row.
    public var keyType: KeyType?

    public init(total: Int, keys: [Data], nextOffset: Int?, keyType: KeyType? = nil) {
        self.total = total
        self.keys = keys
        self.nextOffset = nextOffset
        self.keyType = keyType
    }
}
