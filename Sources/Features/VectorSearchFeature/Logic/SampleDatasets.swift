import Foundation
import RedisUI

struct SampleDatasetField: Hashable, Sendable, Decodable {
    var id: String
    var name: String
    var value: String
    var type: String

    enum CodingKeys: String, CodingKey { case id, name, value, type }

    init(id: String, name: String, value: String, type: String) {
        self.id = id
        self.name = name
        self.value = value
        self.type = type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        if let text = try? container.decode(String.self, forKey: .value) {
            value = text
        } else if let number = try? container.decode(Double.self, forKey: .value) {
            value = FTCreateBuilder.formatNumber(number)
        } else {
            value = ""
        }
    }

    /// Removes the localization prefix `L` from type names such as `LTEXT`.
    var fieldType: SearchFieldType {
        var raw = type.uppercased()
        if raw.hasPrefix("L") { raw.removeFirst() }
        return SearchFieldType(rawValue: raw.lowercased()) ?? .text
    }
}

struct SampleQuery: Hashable, Sendable, Decodable {
    var name: String
    var description: String
    var query: String
}

struct SampleDataset: Identifiable, Hashable, Sendable, Decodable {
    var id: SampleDatasetID
    var displayName: String
    var indexName: String
    var indexPrefix: String
    var collectionName: String
    var fields: [SampleDatasetField]
    var sampleQueries: [SampleQuery]
    /// Rewrites key names in the data file (tests load data under a unique prefix).
    var keyPrefixRewrite: KeyPrefixRewrite?

    struct KeyPrefixRewrite: Hashable, Sendable {
        var from: String
        var to: String
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, indexName, indexPrefix, collectionName, fields, sampleQueries
    }

    var cardTitle: String {
        switch id {
        case .trails: return "Trail Finder"
        case .recipes: return "Recipe Recommendations"
        }
    }

    var cardSubtitle: String {
        switch id {
        case .trails: return "Find hikes that match a mood or a scene, not just keywords."
        case .recipes: return "Discover dishes by flavor, diet, or occasion."
        }
    }

    var symbolName: String {
        switch id {
        case .trails: return "figure.hiking"
        case .recipes: return "fork.knife"
        }
    }

    var createCommand: String {
        let base = SampleDatasets.createCommand(for: id)
        return base
            .replacingOccurrences(of: SampleDatasets.defaultIndexName(for: id), with: indexName)
            .replacingOccurrences(of: "\"\(SampleDatasets.defaultPrefix(for: id))\"", with: FTCreateBuilder.quote(indexPrefix))
    }

    var fieldDrafts: [IndexFieldDraft] {
        fields.map { IndexFieldDraft(name: $0.name, sampleValue: $0.value, type: $0.fieldType) }
    }

    var keyType: SearchIndexKeyType { id == .recipes ? .json : .hash }

    func retargeted(indexName: String, prefix: String) -> SampleDataset {
        var copy = self
        copy.indexName = indexName
        copy.indexPrefix = prefix
        copy.keyPrefixRewrite = KeyPrefixRewrite(from: indexPrefix, to: prefix)
        copy.sampleQueries = sampleQueries.map { query in
            var q = query
            q.query = q.query.replacingOccurrences(of: self.indexName, with: indexName)
            return q
        }
        return copy
    }
}

enum SampleDatasetsError: Error, LocalizedError {
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name): return "The bundled sample data \"\(name)\" is missing."
        }
    }
}

enum SampleDatasets {
    private struct File: Decodable { var datasets: [SampleDataset] }

    static func load() throws -> [SampleDataset] {
        guard let url = Bundle.module.url(forResource: "vector-search-sample-data", withExtension: "json",
                                          subdirectory: "SampleData") else {
            throw SampleDatasetsError.resourceMissing("vector-search-sample-data.json")
        }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).datasets
    }

    static func dataset(_ id: SampleDatasetID) -> SampleDataset? {
        (try? load())?.first { $0.id == id }
    }

    static func dataURL(collection: String) -> URL? {
        Bundle.module.url(forResource: collection, withExtension: nil, subdirectory: "SampleData")
    }

    /// Data file contents with the optional key-prefix rewrite applied to each command's key argument.
    static func commandData(for dataset: SampleDataset) throws -> Data {
        guard let url = dataURL(collection: dataset.collectionName) else {
            throw SampleDatasetsError.resourceMissing(dataset.collectionName)
        }
        let data = try Data(contentsOf: url)
        guard let rewrite = dataset.keyPrefixRewrite, rewrite.from != rewrite.to else { return data }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard let space = line.firstIndex(of: " ") else { return line }
            let rest = line[line.index(after: space)...]
            guard rest.hasPrefix(rewrite.from) else { return line }
            return String(line[...space]) + rewrite.to + rest.dropFirst(rewrite.from.count)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func defaultIndexName(for id: SampleDatasetID) -> String {
        id == .trails ? "idx:trails_vss" : "idx:recipes_vss"
    }

    static func defaultPrefix(for id: SampleDatasetID) -> String {
        id == .trails ? "trail:" : "recipe:"
    }

    static func createCommand(for id: SampleDatasetID) -> String {
        switch id {
        case .trails:
            return """
            FT.CREATE idx:trails_vss
                ON HASH
                    PREFIX 1 "trail:"
                SCHEMA
                  "name" TEXT NOSTEM SORTABLE
                  "region" TAG SORTABLE
                  "difficulty" TAG
                  "features" TAG
                  "distance_km" NUMERIC SORTABLE
                  "elevation_gain_m" NUMERIC SORTABLE
                  "description" TEXT
                  "description_embedding" VECTOR HNSW 10
                    TYPE FLOAT32
                    DIM 64
                    DISTANCE_METRIC COSINE
                    M 16
                    EF_CONSTRUCTION 200
            """
        case .recipes:
            return """
            FT.CREATE idx:recipes_vss
                ON JSON
                  PREFIX 1 "recipe:"
                SCHEMA
                  $.title AS title TEXT
                  $.cuisine AS cuisine TAG
                  $.course AS course TAG
                  $.tags[*] AS tags TAG
                  $.summary AS summary TEXT
                  $.minutes AS minutes NUMERIC SORTABLE
                  $.embedding AS embedding VECTOR FLAT 6
                    TYPE FLOAT32
                    DIM 64
                    DISTANCE_METRIC COSINE
            """
        }
    }

    /// Library items seeded for a sample index, in dataset order.
    static func libraryItems(for dataset: SampleDataset, databaseID: DatabaseID, now: Date = Date()) -> [QueryLibraryItem] {
        dataset.sampleQueries.enumerated().map { offset, query in
            let created = now.addingTimeInterval(Double(offset) * 0.001)
            return QueryLibraryItem(databaseId: databaseID, indexName: dataset.indexName, type: .sample,
                                    name: query.name, description: query.description, query: query.query,
                                    createdAt: created, updatedAt: created)
        }
    }
}
