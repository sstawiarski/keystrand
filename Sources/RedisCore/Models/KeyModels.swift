import Foundation

/// Binary-safe key name with display helpers.
public struct RedisKeyName: Hashable, Sendable, Codable, Comparable {
    public var data: Data

    public init(_ data: Data) { self.data = data }
    public init(_ string: String) { self.data = Data(string.utf8) }

    /// True when the bytes are valid UTF-8 without control characters (other than tab/newline).
    public var isPrintable: Bool { !FormatterRegistry.isNonUnicode(data) }

    /// Unicode: lossy UTF-8 with non-printable bytes escaped as `\xHH`. HEX: lowercase hex digits.
    public func displayString(format: KeyNameFormat = .unicode) -> String {
        switch format {
        case .hex:
            return data.map { String(format: "%02x", $0) }.joined()
        case .unicode:
            if isPrintable { return String(decoding: data, as: UTF8.self) }
            var out = ""
            for byte in data {
                if byte >= 0x20 && byte < 0x7F { out.append(Character(UnicodeScalar(byte))) } else {
                    out += String(format: "\\x%02x", byte)
                }
            }

            return out
        }
    }

    public static func < (lhs: RedisKeyName, rhs: RedisKeyName) -> Bool {
        lhs.data.lexicographicallyPrecedes(rhs.data)
    }
}

/// A row in the key list. `nil` fields = not loaded yet.
public struct KeyListItem: Identifiable, Hashable, Sendable {
    public var name: Data
    public var type: KeyType?
    /// Seconds; -1 = no TTL, -2 = key does not exist.
    public var ttl: Int?
    /// Bytes from `MEMORY USAGE`; -1 = too large to measure.
    public var size: Int?

    public var id: Data { name }

    public init(name: Data, type: KeyType? = nil, ttl: Int? = nil, size: Int? = nil) {
        self.name = name
        self.type = type
        self.ttl = ttl
        self.size = size
    }
}

/// Key details header info.
public struct KeyInfo: Hashable, Sendable {
    public var name: Data
    public var type: KeyType
    /// Seconds; -1 = no TTL.
    public var ttl: Int
    /// Bytes; -1 = too large; nil = unknown.
    public var size: Int?
    public var length: Int?
    /// Exact u64 decimal length for arrays (`ARLEN`).
    public var lengthString: String?
    /// Array `ARCOUNT` (u64 decimal).
    public var count: String?
    /// Vector set `quant-type`.
    public var quantType: String?
    /// Vector set `vector-dim`.
    public var vectorDim: Int?

    public init(name: Data, type: KeyType, ttl: Int = -1, size: Int? = nil, length: Int? = nil,
                lengthString: String? = nil, count: String? = nil, quantType: String? = nil, vectorDim: Int? = nil) {
        self.name = name
        self.type = type
        self.ttl = ttl
        self.size = size
        self.length = length
        self.lengthString = lengthString
        self.count = count
        self.quantType = quantType
        self.vectorDim = vectorDim
    }
}

/// SCAN cursor: a single integer (standalone) or a composite per-node cursor for clusters,
/// serialized as `host:port@cursor||host:port@cursor`.
public enum ScanCursor: Hashable, Sendable, CustomStringConvertible {
    case standalone(UInt64)
    case cluster([RedisEndpoint: UInt64])

    public static let start = ScanCursor.standalone(0)

    /// True when every node cursor returned to 0 after at least one iteration.
    public var isComplete: Bool {
        switch self {
        case .standalone(let c): return c == 0
        case .cluster(let nodes): return nodes.values.allSatisfy { $0 == 0 }
        }
    }

    public var description: String {
        switch self {
        case .standalone(let c): return String(c)
        case .cluster(let nodes):
            return nodes.sorted { $0.key.description < $1.key.description }
                .map { "\($0.key)@\($0.value)" }.joined(separator: "||")
        }
    }

    public init?(parsing text: String) {
        if let n = UInt64(text) { self = .standalone(n); return }
        var nodes: [RedisEndpoint: UInt64] = [:]
        for part in text.components(separatedBy: "||") {
            let pieces = part.split(separator: "@", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let cursor = UInt64(pieces[1]),
                  let colon = pieces[0].lastIndex(of: ":"),
                  let port = Int(pieces[0][pieces[0].index(after: colon)...]) else { return nil }
            var host = String(pieces[0][..<colon])
            if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            nodes[RedisEndpoint(host: host, port: port)] = cursor
        }

        guard !nodes.isEmpty else { return nil }
        self = .cluster(nodes)
    }
}

public struct ScanShardState: Hashable, Sendable {
    public var endpoint: RedisEndpoint?
    public var cursor: UInt64
    public var scanned: Int
    public var total: Int?

    public init(endpoint: RedisEndpoint? = nil, cursor: UInt64 = 0, scanned: Int = 0, total: Int? = nil) {
        self.endpoint = endpoint
        self.cursor = cursor
        self.scanned = scanned
        self.total = total
    }
}

public struct ScanRequest: Hashable, Sendable {
    /// Glob pattern; `*` = all keys.
    public var match: String
    public var type: KeyType?
    /// SCAN COUNT per iteration (Settings "Keys to Scan", default 10 000).
    public var count: Int

    public init(match: String = "*", type: KeyType? = nil, count: Int = 10_000) {
        self.match = match
        self.type = type
        self.count = count
    }
}

/// Accumulated scan result for the key list.
public struct KeyScanState: Hashable, Sendable {
    public var keys: [KeyListItem]
    /// Total keys in the database (DBSIZE / keyspace), when known.
    public var total: Int?
    public var scanned: Int
    public var cursor: ScanCursor
    /// Per node ("standalone" or "host:port").
    public var shards: [String: ScanShardState]
    public var lastRefreshTime: Date?
    /// True once at least one SCAN (or exact lookup) ran, so an empty database can be complete.
    public var hasStarted: Bool

    public init(keys: [KeyListItem] = [], total: Int? = nil, scanned: Int = 0, cursor: ScanCursor = .start,
                shards: [String: ScanShardState] = [:], lastRefreshTime: Date? = nil, hasStarted: Bool = false) {
        self.keys = keys
        self.total = total
        self.scanned = scanned
        self.cursor = cursor
        self.shards = shards
        self.lastRefreshTime = lastRefreshTime
        self.hasStarted = hasStarted
    }

    public var isComplete: Bool { (hasStarted || scanned > 0) && cursor.isComplete }
}

public enum SortOrder: String, Codable, Sendable, Hashable, CaseIterable {
    case asc = "ASC"
    case desc = "DESC"
}

public enum KeyViewType: String, Codable, Sendable, Hashable, CaseIterable {
    /// Flat key list, without namespace folders.
    case list
    case tree
}

public enum SearchMode: String, Codable, Sendable, Hashable, CaseIterable {
    case pattern
    case redisearch
}

public enum BrowserColumn: String, Codable, Sendable, Hashable, CaseIterable {
    case size
    case ttl
}

public enum ListDestination: String, Codable, Sendable, Hashable, CaseIterable {
    case tail = "TAIL"
    case head = "HEAD"
}

public struct HashField: Hashable, Sendable {
    public var field: Data
    public var value: Data
    /// Field TTL seconds (Redis 7.4+ HEXPIRE); -1 = none; nil = unknown.
    public var expire: Int?

    public init(field: Data, value: Data, expire: Int? = nil) {
        self.field = field
        self.value = value
        self.expire = expire
    }
}

public struct VectorElementDraft: Hashable, Sendable {
    public var name: Data
    /// Values as typed (`0.1, 0.2`) or FP32 blob.
    public var vector: [Double]
    public var attributes: String?

    public init(name: Data, vector: [Double], attributes: String? = nil) {
        self.name = name
        self.vector = vector
        self.attributes = attributes
    }
}

public struct StreamFieldDraft: Hashable, Sendable {
    public var name: Data
    public var value: Data

    public init(name: Data, value: Data) {
        self.name = name
        self.value = value
    }
}

/// Add Key form payload.
public struct NewKeyDraft: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        case string(Data)
        case hash([HashField])
        case list(ListDestination, [Data])
        case set([Data])
        case zset([ZSetMemberDraft])
        /// JSON document text.
        case json(String)
        /// Entry id (`*` = auto) + fields.
        case stream(id: String, fields: [StreamFieldDraft])
        case vectorSet([VectorElementDraft])
        case timeSeries(TimeSeriesDraft)
    }

    public var name: Data
    /// Seconds; nil = no TTL.
    public var ttl: Int?
    public var value: Value

    public init(name: Data, ttl: Int? = nil, value: Value) {
        self.name = name
        self.ttl = ttl
        self.value = value
    }

    public var type: KeyType {
        switch value {
        case .string: return .string
        case .hash: return .hash
        case .list: return .list
        case .set: return .set
        case .zset: return .zset
        case .json: return .json
        case .stream: return .stream
        case .vectorSet: return .vectorSet
        case .timeSeries: return .timeSeries
        }
    }
}

/// `TS.CREATE` options plus initial samples (`TS.ADD`).
public struct TimeSeriesDraft: Hashable, Sendable {
    public struct Label: Hashable, Sendable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public struct Sample: Hashable, Sendable {
        /// Milliseconds since epoch, or `*` for the server time.
        public var timestamp: String
        public var value: Double

        public init(timestamp: String = "*", value: Double) {
            self.timestamp = timestamp
            self.value = value
        }
    }

    /// Milliseconds; nil = server default.
    public var retentionMs: Int?
    /// `COMPRESSED` / `UNCOMPRESSED`; nil = default.
    public var encoding: String?
    /// `BLOCK`, `FIRST`, `LAST`, `MIN`, `MAX`, `SUM`; nil = default.
    public var duplicatePolicy: String?
    public var labels: [Label]
    public var samples: [Sample]

    public init(retentionMs: Int? = nil, encoding: String? = nil, duplicatePolicy: String? = nil,
                labels: [Label] = [], samples: [Sample] = []) {
        self.retentionMs = retentionMs
        self.encoding = encoding
        self.duplicatePolicy = duplicatePolicy
        self.labels = labels
        self.samples = samples
    }
}

/// Glob helpers for SCAN / HSCAN / SSCAN / ZSCAN patterns.
public enum KeyPattern {
    /// True when the pattern contains an unescaped `*`, `?`, or `[` followed later by `]`.
    public static func isGlob(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }

            if c == "*" || c == "?" { return true }
            if c == "[" {
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "]" { return true }
                    j += 1
                }
            }

            i += 1
        }

        return false
    }

    /// `\*` -> `*`, `\?`, `\[`, `\]`, then `\\` -> `\`.
    public static func unescape(_ pattern: String) -> String {
        var out = ""
        var iterator = pattern.makeIterator()
        while let c = iterator.next() {
            if c == "\\", let next = iterator.next() {
                if ["*", "?", "[", "]", "\\"].contains(next) { out.append(next) } else { out.append(c); out.append(next) }
            } else {
                out.append(c)
            }
        }

        return out
    }

    /// Escapes glob characters so a literal name can be used as a MATCH pattern.
    public static func escape(_ name: String) -> String {
        var out = ""
        for c in name {
            if ["*", "?", "[", "]", "\\"].contains(c) { out.append("\\") }
            out.append(c)
        }

        return out
    }
}

public struct ZSetMemberDraft: Hashable, Sendable {
    public var member: Data
    public var score: Double

    public init(member: Data, score: Double) {
        self.member = member
        self.score = score
    }
}
