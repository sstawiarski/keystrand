import Foundation
import RedisCore

public struct AnalysisFilter: Codable, Hashable, Sendable {
    public var type: String?
    public var match: String
    public var count: Int

    public init(type: String? = nil, match: String = "*", count: Int = 10_000) {
        self.type = type
        self.match = match
        self.count = count
    }
}

public struct AnalysisProgress: Codable, Hashable, Sendable {
    public var total: Int
    public var scanned: Int
    public var processed: Int

    public init(total: Int = 0, scanned: Int = 0, processed: Int = 0) {
        self.total = total
        self.scanned = scanned
        self.processed = processed
    }

    public static func + (lhs: AnalysisProgress, rhs: AnalysisProgress) -> AnalysisProgress {
        AnalysisProgress(total: lhs.total + rhs.total, scanned: lhs.scanned + rhs.scanned, processed: lhs.processed + rhs.processed)
    }
}

public struct SimpleTypeSummary: Codable, Hashable, Sendable {
    public var type: String
    public var total: Double

    public init(type: String, total: Double) {
        self.type = type
        self.total = total
    }
}

public struct SimpleSummary: Codable, Hashable, Sendable {
    public var total: Double
    public var types: [SimpleTypeSummary]

    public init(total: Double = 0, types: [SimpleTypeSummary] = []) {
        self.total = total
        self.types = types
    }
}

public struct NspTypeSummary: Codable, Hashable, Sendable {
    public var type: String
    public var memory: Int
    public var keys: Int

    public init(type: String, memory: Int, keys: Int) {
        self.type = type
        self.memory = memory
        self.keys = keys
    }
}

public struct NspSummary: Codable, Hashable, Sendable, Identifiable {
    public var nsp: Data
    public var memory: Int
    public var keys: Int
    public var types: [NspTypeSummary]

    public var id: Data { nsp }

    public init(nsp: Data, memory: Int, keys: Int, types: [NspTypeSummary]) {
        self.nsp = nsp
        self.memory = memory
        self.keys = keys
        self.types = types
    }
}

public struct AnalyzedKey: Codable, Hashable, Sendable, Identifiable {
    public var name: Data
    public var type: String
    public var memory: Int?
    public var length: Int?
    /// Seconds; -1 = no expiry, -2 = key vanished between SCAN and TTL.
    public var ttl: Int

    public var id: Data { name }

    public init(name: Data, type: String, memory: Int? = nil, length: Int? = nil, ttl: Int = -1) {
        self.name = name
        self.type = type
        self.memory = memory
        self.length = length
        self.ttl = ttl
    }
}

public struct SumGroup: Codable, Hashable, Sendable, Identifiable {
    public var label: String
    public var total: Int
    public var threshold: Int

    public var id: String { label }

    public init(label: String, total: Int, threshold: Int) {
        self.label = label
        self.total = total
        self.threshold = threshold
    }
}

public struct RecommendationParams: Codable, Hashable, Sendable {
    public var keys: [Data]

    public init(keys: [Data] = []) { self.keys = keys }
}

public struct AnalysisRecommendation: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var params: RecommendationParams?
    public var vote: String?

    public var id: String { name }

    public init(name: String, params: RecommendationParams? = nil, vote: String? = nil) {
        self.name = name
        self.params = params
        self.vote = vote
    }

    public init(_ name: RecommendationName, key: Data? = nil) {
        self.init(name: name.rawValue, params: key.map { RecommendationParams(keys: [$0]) })
    }
}

public struct DatabaseAnalysisReport: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var databaseId: DatabaseID
    public var createdAt: Date
    public var db: Int?
    public var delimiter: String
    public var filter: AnalysisFilter
    public var progress: AnalysisProgress
    public var totalKeys: SimpleSummary
    public var totalMemory: SimpleSummary
    public var topKeysNsp: [NspSummary]
    public var topMemoryNsp: [NspSummary]
    public var topKeysLength: [AnalyzedKey]
    public var topKeysMemory: [AnalyzedKey]
    public var expirationGroups: [SumGroup]
    public var recommendations: [AnalysisRecommendation]

    public init(id: UUID = UUID(), databaseId: DatabaseID, createdAt: Date = Date(), db: Int? = nil, delimiter: String = ":",
                filter: AnalysisFilter = AnalysisFilter(), progress: AnalysisProgress = AnalysisProgress(),
                totalKeys: SimpleSummary = SimpleSummary(), totalMemory: SimpleSummary = SimpleSummary(),
                topKeysNsp: [NspSummary] = [], topMemoryNsp: [NspSummary] = [], topKeysLength: [AnalyzedKey] = [],
                topKeysMemory: [AnalyzedKey] = [], expirationGroups: [SumGroup] = [], recommendations: [AnalysisRecommendation] = []) {
        self.id = id
        self.databaseId = databaseId
        self.createdAt = createdAt
        self.db = db
        self.delimiter = delimiter
        self.filter = filter
        self.progress = progress
        self.totalKeys = totalKeys
        self.totalMemory = totalMemory
        self.topKeysNsp = topKeysNsp
        self.topMemoryNsp = topMemoryNsp
        self.topKeysLength = topKeysLength
        self.topKeysMemory = topKeysMemory
        self.expirationGroups = expirationGroups
        self.recommendations = recommendations
    }

    public var short: ShortDatabaseAnalysis { ShortDatabaseAnalysis(id: id, createdAt: createdAt, db: db) }

    /// `total / processed` when the sample is smaller than the database; 1 otherwise.
    public var extrapolationFactor: Double {
        guard progress.processed > 0, progress.total > 0 else { return 1 }
        return Double(progress.total) / Double(progress.processed)
    }
}

public struct ShortDatabaseAnalysis: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var db: Int?

    public init(id: UUID, createdAt: Date, db: Int?) {
        self.id = id
        self.createdAt = createdAt
        self.db = db
    }
}

public enum AnalysisError: Error, LocalizedError, Equatable {
    case notFound
    case undecodable
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Database analysis was not found."
        case .undecodable: return "Unable to read this report. Re-run the report generation."
        case .cancelled: return "Database analysis was cancelled."
        }
    }
}
