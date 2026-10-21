import Foundation

public enum SlowLogDurationUnit: String, Codable, Sendable, Hashable, CaseIterable {
    case microseconds = "µs"
    case milliseconds = "ms"

    public var label: String { self == .microseconds ? "µs" : "msec" }
}

public enum RecommendationName: String, Codable, Sendable, Hashable, CaseIterable {
    case setPassword
    case luaScript
    case bigHashes
    case bigStrings
    case bigSets
    case bigAmountOfConnectedClients
    case useSmallerKeys
    case avoidLogicalDatabases
    case combineSmallStringsToHashes
    case increaseSetMaxIntsetEntries
    case hashHashtableToZiplist
    case compressionForList
    case zSetHashtableToZiplist
    case rts = "RTS"
    case redisVersion
    case searchIndexes
    case searchJSON
    case stringToJson
    case searchVisualization
    case searchHash
}
