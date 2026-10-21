import Foundation
import RedisUI

enum VectorSearchRoute: Hashable {
    case entry
    case createIndex(CreateIndexRequest)
    case query(indexName: Data, openIndexPanel: Bool)
}

enum VectorSearchDestination: Hashable {
    case query
    case createIndex
}

extension VectorSearchRoute {
    var path: [VectorSearchDestination] {
        switch self {
        case .entry: return []
        case .createIndex: return [.createIndex]
        case .query: return [.query]
        }
    }
}

/// Whole-section gate: the section only works when a Redis Search 2.0+ module is loaded.
enum SearchAvailability: Equatable {
    case connecting
    case disconnected
    case failed(String)
    case moduleMissing
    case versionTooOld
    case available

    static let minimumSearchVersion = 20_000

    static func evaluate(state: SessionState, capabilities: DatabaseCapabilities) -> SearchAvailability {
        switch state {
        case .connecting:
            return .connecting
        case .disconnected:
            return .disconnected
        case .failed(let error):
            return .failed(error.message.isEmpty ? error.title : error.message)
        case .connected:
            guard capabilities.hasSearch else { return .moduleMissing }
            if capabilities.isRediSearch(below: minimumSearchVersion) { return .versionTooOld }
            return .available
        }
    }
}

enum VectorAlgorithm: String, CaseIterable, Identifiable, Hashable, Sendable {
    case flat = "FLAT"
    case hnsw = "HNSW"
    var id: String { rawValue }
}

enum VectorDistanceMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
    case l2 = "L2"
    case ip = "IP"
    case cosine = "COSINE"
    var id: String { rawValue }
}

enum VectorDataType: String, CaseIterable, Identifiable, Hashable, Sendable {
    case float32 = "FLOAT32"
    case float64 = "FLOAT64"
    case bfloat16 = "BFLOAT16"
    case float16 = "FLOAT16"
    var id: String { rawValue }

    var requiresFloat16Support: Bool { self == .bfloat16 || self == .float16 }

    var bytesPerElement: Int {
        switch self {
        case .float32: return 4
        case .float64: return 8
        case .bfloat16, .float16: return 2
        }
    }

    static func available(supportsFloat16: Bool) -> [VectorDataType] {
        allCases.filter { supportsFloat16 || !$0.requiresFloat16Support }
    }
}

struct VectorFieldOptions: Hashable, Sendable {
    var algorithm: VectorAlgorithm = .flat
    var dataType: VectorDataType = .float32
    var dimensions: Int? = 384
    var distanceMetric: VectorDistanceMetric = .cosine
    var initialCap: Int?
    var blockSize: Int?
    var maxEdges: Int? = 16
    var maxNeighbors: Int? = 200
    var candidateLimit: Int? = 10
    var epsilon: Double? = 0.01
}

enum PhoneticMatcher: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none = ""
    case english = "dm:en"
    case french = "dm:fr"
    case portuguese = "dm:pt"
    case spanish = "dm:es"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .english: return "English (dm:en)"
        case .french: return "French (dm:fr)"
        case .portuguese: return "Portuguese (dm:pt)"
        case .spanish: return "Spanish (dm:es)"
        }
    }
}

struct TextFieldOptions: Hashable, Sendable {
    var weight: Double? = 1
    var phonetic: PhoneticMatcher = .none
}

struct IndexFieldDraft: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var sampleValue: String
    var type: SearchFieldType
    var vector = VectorFieldOptions()
    var text = TextFieldOptions()

    init(name: String, sampleValue: String = "", type: SearchFieldType,
         vector: VectorFieldOptions = VectorFieldOptions(), text: TextFieldOptions = TextFieldOptions()) {
        self.name = name
        self.sampleValue = sampleValue
        self.type = type
        self.vector = vector
        self.text = text
    }
}

enum EditableFieldTypes {
    static let all: [SearchFieldType] = [.text, .tag, .numeric, .geo, .vector]

    static func description(_ type: SearchFieldType) -> String {
        switch type {
        case .text: return "TEXT splits values into words for full-text queries ranked by relevance."
        case .tag: return "TAG keeps each value as an exact token, such as an ID, category or status, for filtering."
        case .numeric: return "NUMERIC holds numbers for range filters and sorting."
        case .geo: return "GEO holds a longitude,latitude pair for radius and distance queries."
        case .vector: return "VECTOR holds embeddings for nearest-neighbor similarity queries."
        case .geoshape: return "GEOSHAPE holds points and polygons for spatial queries."
        }
    }

    static func shortDescription(_ type: SearchFieldType) -> String {
        switch type {
        case .text: return "Word search ranked by relevance"
        case .tag: return "Filters on exact values"
        case .numeric: return "Numeric ranges and sort order"
        case .geo: return "Radius and distance lookups"
        case .vector: return "Nearest-neighbor search"
        case .geoshape: return "Points and polygons"
        }
    }
}

extension SearchFieldType {
    var label: String { rawValue.uppercased() }
}

enum CreateIndexMode: Hashable {
    case probing
    case sampleData(SampleDatasetID)
    case browse
    case preselected
    case manual

    var isEditable: Bool {
        switch self {
        case .sampleData, .probing: return false
        default: return true
        }
    }
}

enum QueryEditorTab: String, CaseIterable, Identifiable, Hashable {
    case editor
    case library
    var id: String { rawValue }
    var title: String { self == .editor ? "Query editor" : "Query library" }
}

enum ResultViewKind: String, CaseIterable, Identifiable, Hashable {
    case table
    case text
    case json
    var id: String { rawValue }

    var title: String {
        switch self {
        case .table: return "Table"
        case .text: return "Text"
        case .json: return "JSON"
        }
    }

    var systemImage: String {
        switch self {
        case .table: return "tablecells"
        case .text: return "text.alignleft"
        case .json: return "curlybraces"
        }
    }
}

enum VectorSearchStrings {
    static let editorPlaceholder =
        "Type FT. for search command suggestions, or open the Query Library to reuse a saved query."
    static let resultsEmpty = "Run a query to see its results here."
    static let explainHelp = "Show the execution plan Redis builds for this query, without running it."
    static let profileHelp = "Run the query with timing for each step, to find the slow parts."
    static let noQueryReason = "Unavailable: the first command isn't FT.SEARCH or FT.AGGREGATE."
    static let runningReason = "Unavailable while a query runs."
    static let duplicateIndexName = "An index with this name already exists."
    static let selectKeyReason = "Choose a sample key, then pick the fields to index."
    static let addFieldReason = "The index needs at least one field."
    static let createFailedTitle = "Couldn't Create Index"
    static let createFailedMessage = "Redis didn't create the index. Try again."
    static let emptyIndexName = "(empty name)"
    static let wrongDatabaseReason = "Search indexes can only be created in logical database 0."
}
