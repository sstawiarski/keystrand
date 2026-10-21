import Foundation

/// Redis key type as reported by `TYPE`. Raw values are the exact TYPE strings.
public enum KeyType: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    case string
    case hash
    case list
    case set
    case zset
    case stream
    /// `ReJSON-RL`
    case json
    /// `TSDB-TYPE`
    case timeSeries
    /// `vectorset`
    case vectorSet
    /// `graphdata`
    case graph
    /// `array` (Redis 8.8+ preview type)
    case array
    /// Any other TYPE reply (e.g. `MBbloom--`, valkey-bloom's `bloomfltr`); `none` never becomes a KeyType.
    case unknown(String)

    /// Types offered in filters and the Add Key form, in menu order.
    public static let allKnown: [KeyType] = [.hash, .list, .set, .zset, .string, .json, .stream, .graph, .timeSeries, .vectorSet, .array]

    /// Returns nil for `none` (key does not exist).
    public init?(typeReply: String) {
        switch typeReply {
        case "none", "": return nil
        default: self.init(rawValue: typeReply)
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "string": self = .string
        case "hash": self = .hash
        case "list": self = .list
        case "set": self = .set
        case "zset": self = .zset
        case "stream": self = .stream
        case "ReJSON-RL": self = .json
        case "TSDB-TYPE": self = .timeSeries
        case "vectorset": self = .vectorSet
        case "graphdata": self = .graph
        case "array": self = .array
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .string: return "string"
        case .hash: return "hash"
        case .list: return "list"
        case .set: return "set"
        case .zset: return "zset"
        case .stream: return "stream"
        case .json: return "ReJSON-RL"
        case .timeSeries: return "TSDB-TYPE"
        case .vectorSet: return "vectorset"
        case .graph: return "graphdata"
        case .array: return "array"
        case .unknown(let raw): return raw
        }
    }

    public var id: String { rawValue }
    public var description: String { rawValue }

    public var displayName: String {
        switch self {
        case .string: return "String"
        case .hash: return "Hash"
        case .list: return "List"
        case .set: return "Set"
        case .zset: return "Sorted Set"
        case .stream: return "Stream"
        case .json: return "JSON"
        case .timeSeries: return "Time Series"
        case .vectorSet: return "Vector Set"
        case .graph: return "Graph"
        case .array: return "Array"
        case .unknown(let raw):
            switch raw {
            case "MBbloom--", "bloomfltr": return "Bloom Filter"
            case "MBbloomCF": return "Cuckoo Filter"
            case "TopK-TYPE": return "Top-K"
            case "CMSk-TYPE": return "Count-Min Sketch"
            case "TDIS-TYPE": return "T-Digest"
            default: return raw.replacingOccurrences(of: "_", with: " ")
            }
        }
    }

    /// Header length label.
    public var lengthLabel: String {
        switch self {
        case .stream: return "Entries"
        case .json: return "Top-level values"
        case .timeSeries: return "Samples"
        case .graph: return "Nodes"
        default: return "Length"
        }
    }

    /// Minimum Redis server version for built-in types introduced late.
    public var minRedisVersion: String? {
        switch self {
        case .stream: return "5.0.0"
        case .vectorSet: return "8.0.0"
        case .array: return "8.8.0"
        default: return nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

public typealias RedisKeyType = KeyType

public extension KeyType {
    /// Whether the Add Key form can create this type on a server with `capabilities`.
    func isCreatable(with capabilities: DatabaseCapabilities) -> Bool {
        switch self {
        case .string, .hash, .list, .set, .zset: return true
        case .stream: return capabilities.redisVersion == nil || capabilities.isVersion(atLeast: "5.0.0")
        case .json: return capabilities.hasJSON
        case .timeSeries: return capabilities.hasTimeSeries
        case .vectorSet: return capabilities.supportsVectorSets
        case .graph, .array, .unknown: return false
        }
    }
}
