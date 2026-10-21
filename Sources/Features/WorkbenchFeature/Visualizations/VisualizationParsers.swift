import Foundation
import RedisCore

extension ReplyNode {
    /// Scalar text (strings, integers); nil for arrays, nil and errors.
    var scalarText: String? {
        switch self {
        case .string(let s): return s
        case .integer(let n): return n
        default: return nil
        }
    }

    var items: [ReplyNode]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// Compact single-line text for table cells (arrays as `[a, b]`).
    var cellText: String {
        switch self {
        case .null: return "(nil)"
        case .integer(let n): return n
        case .string(let s): return s
        case .error(let e): return e
        case .array(let items): return "[" + items.map(\.cellText).joined(separator: ", ") + "]"
        }
    }

    /// `[k1, v1, k2, v2]` -> pairs (keys lowercased when `lowercaseKeys`).
    func keyValuePairs(lowercaseKeys: Bool = false) -> [(key: String, value: ReplyNode)] {
        guard let items else { return [] }
        var out: [(String, ReplyNode)] = []
        var index = 0
        while index + 1 < items.count {
            let key = items[index].scalarText ?? items[index].cellText
            out.append((lowercaseKeys ? key.lowercased() : key, items[index + 1]))
            index += 2
        }

        return out
    }
}

// MARK: - Search table

public struct SearchTableModel: Hashable, Sendable {
    public var matched: String?
    public var cursorID: String?
    public var columns: [String]
    public var rows: [[String: String]]
}

public enum SearchResultParser {
    /// FT.SEARCH / FT.AGGREGATE / FT.PROFILE (results part) reply -> table.
    public static func parse(_ node: ReplyNode, command: String) -> SearchTableModel? {
        let words = WorkbenchCommandText.words(command).map { $0.uppercased() }
        guard let name = words.first else { return nil }
        if name == "FT.PROFILE" {
            guard let items = node.items, let results = items.first else { return nil }
            let kind = words.count > 2 ? words[2] : "SEARCH"
            return kind == "AGGREGATE" ? parseAggregate(results, command: command) : parseSearch(results, command: command)
        }

        if name == "FT.AGGREGATE" { return parseAggregate(node, command: command) }
        if name == "FT.SEARCH" { return parseSearch(node, command: command) }
        return nil
    }

    public static func parseSearch(_ node: ReplyNode, command: String) -> SearchTableModel? {
        guard let items = node.items, let first = items.first else { return nil }
        let upper = WorkbenchCommandText.words(command).map { $0.uppercased() }
        let joined = upper.joined(separator: " ")
        let noContent = upper.contains("NOCONTENT") || joined.contains("RETURN 0")
        let withScores = upper.contains("WITHSCORES")
        let withPayloads = upper.contains("WITHPAYLOADS")
        let withSortKeys = upper.contains("WITHSORTKEYS")
        var chunk = noContent ? 1 : 2
        for flag in [withScores, withPayloads, withSortKeys] where flag { chunk += 1 }

        var columns: [String] = ["Doc"]
        var rows: [[String: String]] = []
        func add(_ column: String) { if !columns.contains(column) { columns.append(column) } }
        var index = 1
        while index < items.count {
            let group = Array(items[index..<min(index + chunk, items.count)])
            index += chunk
            guard let id = group.first else { continue }
            var row: [String: String] = ["Doc": id.cellText]
            var position = 1
            if withScores, position < group.count {
                add("Score")
                row["Score"] = group[position].cellText
                position += 1
            }

            if withPayloads, position < group.count {
                add("Payloads")
                row["Payloads"] = group[position].cellText
                position += 1
            }

            if withSortKeys, position < group.count {
                add("Sort key")
                row["Sort key"] = group[position].cellText
                position += 1
            }

            if !noContent, position < group.count {
                for pair in group[position].keyValuePairs() {
                    add(pair.key)
                    row[pair.key] = pair.value.cellText
                }
            }

            rows.append(row)
        }

        return SearchTableModel(matched: first.scalarText, cursorID: nil, columns: columns, rows: rows)
    }

    public static func parseAggregate(_ node: ReplyNode, command: String) -> SearchTableModel? {
        guard var items = node.items else { return nil }
        var cursor: String?
        if items.count == 2, let inner = items[0].items, items[1].scalarText != nil {
            cursor = items[1].scalarText
            items = inner
        }

        guard let first = items.first else { return nil }
        var columns: [String] = []
        var rows: [[String: String]] = []
        for rowNode in items.dropFirst() {
            var row: [String: String] = [:]
            if let values = rowNode.items, values.count > 1 {
                for pair in rowNode.keyValuePairs() {
                    if !columns.contains(pair.key) { columns.append(pair.key) }
                    row[pair.key] = pair.value.cellText
                }
            }

            rows.append(row)
        }

        return SearchTableModel(matched: first.scalarText, cursorID: cursor, columns: columns, rows: rows)
    }
}

// MARK: - FT.INFO

public struct IndexInfoModel: Hashable, Sendable {
    public var keyType: String?
    public var prefixes: [String]
    public var options: [String]
    public var columns: [String]
    public var flagColumns: [String]
    public var attributes: [[String: String]]
    public var numDocs: String
    public var maxDocID: String
    public var numRecords: String
    public var numTerms: String
}

public enum IndexInfoParser {
    public static let flags = ["NOSTEM", "NOINDEX", "SORTABLE", "WITHSUFFIXTRIE", "CASESENSITIVE", "UNF",
                               "INDEXEMPTY", "INDEXMISSING"]

    public static func parse(_ node: ReplyNode) -> IndexInfoModel? {
        let pairs = node.keyValuePairs(lowercaseKeys: true)
        guard !pairs.isEmpty else { return nil }
        func value(_ key: String) -> ReplyNode? { pairs.first { $0.key == key }?.value }

        let definition = value("index_definition")?.keyValuePairs(lowercaseKeys: true) ?? []
        let keyType = definition.first { $0.key == "key_type" }?.value.scalarText
        let prefixes = definition.first { $0.key == "prefixes" }?.value.items?.compactMap(\.scalarText) ?? []
        let options = value("index_options")?.items?.map(\.cellText) ?? []

        var columns: [String] = []
        var usedFlags: Set<String> = []
        var attributes: [[String: String]] = []
        for attribute in value("attributes")?.items ?? [] {
            guard let tokens = attribute.items else { continue }
            var row: [String: String] = [:]
            var index = 0
            while index < tokens.count {
                let key = tokens[index].scalarText?.uppercased() ?? tokens[index].cellText.uppercased()
                if flags.contains(key) {
                    row[key] = "true"
                    usedFlags.insert(key)
                    index += 1
                    continue
                }

                let next = index + 1 < tokens.count ? tokens[index + 1].cellText : ""
                if !columns.contains(key) { columns.append(key) }
                row[key] = next
                index += 2
            }

            attributes.append(row)
        }

        return IndexInfoModel(
            keyType: keyType, prefixes: prefixes, options: options, columns: columns,
            flagColumns: flags.filter(usedFlags.contains), attributes: attributes,
            numDocs: value("num_docs")?.scalarText ?? "0", maxDocID: value("max_doc_id")?.scalarText ?? "0",
            numRecords: value("num_records")?.scalarText ?? "0", numTerms: value("num_terms")?.scalarText ?? "0")
    }
}

// MARK: - CLIENT LIST

public struct ClientListModel: Hashable, Sendable {
    public var columns: [String]
    public var rows: [[String: String]]
}

public enum ClientListParser {
    public static func parse(_ text: String) -> ClientListModel {
        var columns: [String] = []
        var rows: [[String: String]] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !trimmed.isEmpty else { continue }
            var row: [String: String] = [:]
            for part in trimmed.split(separator: " ") {
                let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = kv.first else { continue }
                row[String(key)] = kv.count > 1 ? String(kv[1]) : ""
                if rows.isEmpty, !columns.contains(String(key)) { columns.append(String(key)) }
            }

            rows.append(row)
        }

        return ClientListModel(columns: columns, rows: rows)
    }
}

// MARK: - Time series

public struct TimeSeriesPoint: Hashable, Sendable {
    public var timestamp: Double
    public var value: Double
}

public struct TimeSeriesSeries: Hashable, Sendable, Identifiable {
    public var key: String
    public var labels: [String: String]
    public var points: [TimeSeriesPoint]
    public var id: String { key }
}

public enum TimeSeriesParser {
    /// TS.RANGE/REVRANGE: one series named after the key argument; TS.MRANGE/MREVRANGE: `[key, labels, points]` items.
    public static func parse(_ node: ReplyNode, command: String) -> [TimeSeriesSeries]? {
        let words = WorkbenchCommandText.words(command)
        guard let name = words.first?.uppercased(), let items = node.items else { return nil }
        if name == "TS.RANGE" || name == "TS.REVRANGE" {
            let key = words.count > 1 ? words[1] : "series"
            return [TimeSeriesSeries(key: key, labels: [:], points: points(items))]
        }

        guard name == "TS.MRANGE" || name == "TS.MREVRANGE" else { return nil }
        return items.compactMap { item in
            guard let parts = item.items, parts.count >= 3, let key = parts[0].scalarText else { return nil }
            var labels: [String: String] = [:]
            for label in parts[1].items ?? [] {
                if let pair = label.items, pair.count == 2, let k = pair[0].scalarText {
                    labels[k] = pair[1].cellText
                }
            }

            return TimeSeriesSeries(key: key, labels: labels, points: points(parts[parts.count - 1].items ?? []))
        }
    }

    static func points(_ items: [ReplyNode]) -> [TimeSeriesPoint] {
        items.compactMap { item in
            guard let pair = item.items, pair.count >= 2, let t = pair[0].scalarText.flatMap(Double.init),
                  let v = pair[1].scalarText.flatMap(Double.init) else { return nil }
            return TimeSeriesPoint(timestamp: t, value: v)
        }
    }

    /// Milliseconds when the first timestamp is beyond 1e10, otherwise seconds.
    public static func defaultUnitIsMilliseconds(_ series: [TimeSeriesSeries]) -> Bool {
        guard let first = series.lazy.compactMap(\.points.first).first else { return true }
        return first.timestamp > 1e10
    }
}

// MARK: - Explain / Profile tree

public struct PlanNode: Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var type: String
    public var detail: String?
    public var time: String?
    public var counter: String?
    public var size: String?
    public var children: [PlanNode] = []

    public init(type: String, detail: String? = nil, time: String? = nil, counter: String? = nil, size: String? = nil,
                children: [PlanNode] = []) {
        self.type = type
        self.detail = detail
        self.time = time
        self.counter = counter
        self.size = size
        self.children = children
    }
}

public enum ExplainParseResult: Hashable, Sendable {
    case tree(PlanNode)
    case empty
    case failure(String)
}

public enum ExplainParser {
    public static let emptyMessage = "This FT.EXPLAIN reply has no plan to draw."
    public static let failureMessage = "The reply couldn't be parsed."

    public static func text(of node: ReplyNode) -> String? {
        switch node {
        case .string(let s): return s.replacingOccurrences(of: "\\n", with: "\n")
        case .array(let items): return items.map(\.cellText).joined(separator: "\n")
        default: return nil
        }
    }

    public static func parse(_ node: ReplyNode) -> ExplainParseResult {
        guard let text = text(of: node) else { return .failure(failureMessage) }
        return parse(text: text)
    }

    public static func parse(text: String) -> ExplainParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "<WILDCARD>" || trimmed == "<WILDCARD>}" { return .empty }
        let root = PlanNode(type: "ROOT")
        var stack: [PlanNode] = [root]
        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == "}" {
                guard stack.count > 1 else { continue }
                let done = stack.removeLast()
                stack[stack.count - 1].children.append(done)
            } else if line.hasSuffix("{") {
                let label = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                stack.append(PlanNode(type: label.isEmpty ? "{" : label))
            } else {
                stack[stack.count - 1].children.append(leaf(line))
            }
        }

        while stack.count > 1 {
            let done = stack.removeLast()
            stack[stack.count - 1].children.append(done)
        }

        guard let top = stack.first else { return .failure(failureMessage) }
        if top.children.count == 1, let only = top.children.first { return .tree(only) }
        if top.children.isEmpty { return .empty }
        var wrapper = top
        wrapper.type = "QUERY"
        return .tree(wrapper)
    }

    /// `NUMERIC {1 <= @age <= 5}` -> type NUMERIC, detail inside the braces.
    static func leaf(_ line: String) -> PlanNode {
        if let open = line.firstIndex(of: "{"), line.hasSuffix("}") {
            let type = line[..<open].trimmingCharacters(in: .whitespaces)
            let inner = line[line.index(after: open)..<line.index(before: line.endIndex)]
            return PlanNode(type: type.isEmpty ? line : type, detail: inner.trimmingCharacters(in: .whitespaces))
        }

        return PlanNode(type: line)
    }
}

public struct ProfileModel: Hashable, Sendable {
    public var metrics: [(String, String)]
    public var tree: PlanNode?

    public static func == (lhs: ProfileModel, rhs: ProfileModel) -> Bool {
        lhs.metrics.map(\.0) == rhs.metrics.map(\.0) && lhs.metrics.map(\.1) == rhs.metrics.map(\.1) && lhs.tree == rhs.tree
    }

    public func hash(into hasher: inout Hasher) {
        for (k, v) in metrics { hasher.combine(k); hasher.combine(v) }
        hasher.combine(tree)
    }
}

public enum ProfileParser {
    static let metricKeys = ["Total profile time", "Parsing time", "Pipeline creation time", "Warning"]

    /// FT.PROFILE reply `[results, profile]` (Redis 8 `Shards`/`Coordinator` format or the older pair list).
    public static func parse(_ node: ReplyNode) -> ProfileModel? {
        guard let items = node.items, items.count >= 2 else { return nil }
        let shard = firstShard(items[1])
        guard !shard.isEmpty else { return nil }
        func value(_ key: String) -> ReplyNode? { shard.first { $0.key == key.lowercased() }?.value }
        var metrics: [(String, String)] = []
        for key in metricKeys {
            guard let node = value(key) else { continue }
            let text = node.items.map { $0.map(\.cellText).joined(separator: ", ") } ?? node.cellText
            metrics.append((key == "Total profile time" ? "Total Profile Time" : key.capitalizedFirstWords, text))
        }

        var tree = value("Iterators profile").flatMap(iteratorNode)
        for processor in processors(value("Result processors profile")) {
            let pairs = processor.keyValuePairs(lowercaseKeys: true)
            func field(_ key: String) -> String? { pairs.first { $0.key == key }?.value.cellText }
            var parent = PlanNode(type: field("type") ?? "Processor", time: field("time"),
                                  counter: field("results processed") ?? field("counter"))
            if let child = tree { parent.children = [child] }
            tree = parent
        }

        return ProfileModel(metrics: metrics, tree: tree)
    }

    static func firstShard(_ profile: ReplyNode) -> [(key: String, value: ReplyNode)] {
        guard let items = profile.items, let first = items.first else { return [] }
        if first.scalarText != nil {
            let pairs = profile.keyValuePairs(lowercaseKeys: true)
            if let shards = pairs.first(where: { $0.key == "shards" })?.value.items {
                guard let shard = shards.first else { return [] }
                if let inner = shard.items, inner.first?.items != nil, inner.count == 1, let only = inner.first {
                    return only.keyValuePairs(lowercaseKeys: true)
                }

                return shard.keyValuePairs(lowercaseKeys: true)
            }

            return pairs
        }

        var out: [(String, ReplyNode)] = []
        for entry in items {
            guard let parts = entry.items, let key = parts.first?.scalarText else { continue }
            let values = Array(parts.dropFirst())
            out.append((key.lowercased(), values.count == 1 ? values[0] : .array(values)))
        }

        return out
    }

    static func processors(_ node: ReplyNode?) -> [ReplyNode] {
        guard let items = node?.items else { return [] }
        if items.first?.scalarText != nil { return [node].compactMap { $0 } }
        return items
    }

    static func iteratorNode(_ node: ReplyNode) -> PlanNode? {
        guard let items = node.items, !items.isEmpty else { return nil }
        if items.first?.items != nil {
            let children = items.compactMap(iteratorNode)
            if children.count == 1 { return children[0] }
            return PlanNode(type: "ITERATORS", children: children)
        }

        let pairs = node.keyValuePairs(lowercaseKeys: true)
        func field(_ key: String) -> String? { pairs.first { $0.key == key }?.value.cellText }
        var detail = field("term")
        if detail == nil, let type = field("query type"), type != field("type") { detail = type }
        var plan = PlanNode(type: field("type") ?? "Iterator", detail: detail, time: field("time"),
                            counter: field("counter") ?? field("number of reading operations"),
                            size: field("size") ?? field("estimated number of matches"))
        for pair in pairs where pair.key == "child iterators" {
            guard let children = pair.value.items else { continue }
            if children.first?.scalarText != nil {
                if let child = iteratorNode(pair.value) { plan.children.append(child) }
            } else {
                plan.children += children.compactMap(iteratorNode)
            }
        }

        return plan
    }
}

extension String {
    var capitalizedFirstWords: String {
        split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - Geo

public struct GeoRow: Hashable, Sendable, Identifiable {
    public var id: Int
    public var member: String
    public var longitude: Double?
    public var latitude: Double?
    public var distance: String?
    public var hash: String?
}

/// A label/value pair of the Geospatial details view (`Distance: 166.27 km`, `items added: 2`).
public struct GeoMetric: Hashable, Sendable {
    public var label: String
    public var value: String
}

public struct GeoModel: Hashable, Sendable {
    public var rows: [GeoRow]
    public var hasCoordinates: Bool
    /// Query center (`GEOSEARCH ... FROMLONLAT lon lat`, `GEORADIUS key lon lat ...`).
    public var centerLongitude: Double?
    public var centerLatitude: Double?
    /// Command, Source key, Destination, Shape.
    public var summary: [GeoMetric]
    /// Single-value replies: GEODIST distance, GEOADD / GEOSEARCHSTORE counts.
    public var metric: GeoMetric?

    public init(rows: [GeoRow], hasCoordinates: Bool, centerLongitude: Double? = nil, centerLatitude: Double? = nil,
                summary: [GeoMetric] = [], metric: GeoMetric? = nil) {
        self.rows = rows
        self.hasCoordinates = hasCoordinates
        self.centerLongitude = centerLongitude
        self.centerLatitude = centerLatitude
        self.summary = summary
        self.metric = metric
    }
}

public enum GeoParser {
    static let storeOptions: Set<String> = ["STORE", "STOREDIST"]

    public static func parse(_ node: ReplyNode, command: String) -> GeoModel? {
        let words = WorkbenchCommandText.words(command)
        guard let name = words.first?.uppercased() else { return nil }
        let summary = summary(words)
        if let metric = metric(node, words: words) {
            return GeoModel(rows: [], hasCoordinates: false, summary: summary, metric: metric)
        }

        guard var model = parseRows(node, words: words, name: name) else { return nil }
        model.summary = summary
        return model
    }

    /// GEODIST distance and the integer replies of GEOADD / GEOSEARCHSTORE / GEORADIUS* STORE.
    static func metric(_ node: ReplyNode, words: [String]) -> GeoMetric? {
        let upper = words.map { $0.uppercased() }
        guard let name = upper.first else { return nil }
        if name == "GEODIST" {
            let unit = words.count > 4 ? words[4] : "m"
            if case .null = node { return GeoMetric(label: "Distance", value: "Not found") }
            guard let text = node.scalarText, let distance = Double(text) else { return nil }
            return GeoMetric(label: "Distance", value: "\(trimmedNumber(text, distance)) \(unit)")
        }

        let stores = name == "GEOSEARCHSTORE"
            || (name.hasPrefix("GEORADIUS") && !storeOptions.isDisjoint(with: upper.dropFirst()))
        guard name == "GEOADD" || stores else { return nil }
        guard case .integer(let count) = node else { return nil }
        return GeoMetric(label: stores ? "items stored" : "items added", value: count)
    }

    static func trimmedNumber(_ text: String, _ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : text
    }

    static func summary(_ words: [String]) -> [GeoMetric] {
        let upper = words.map { $0.uppercased() }
        guard let name = upper.first else { return [] }
        var source = words.count > 1 ? words[1] : "-"
        var destination = "-"
        if name == "GEOSEARCHSTORE" {
            destination = words.count > 1 ? words[1] : "-"
            source = words.count > 2 ? words[2] : "-"
        } else if let index = upper.firstIndex(where: storeOptions.contains), index + 1 < words.count {
            destination = words[index + 1]
        }

        let shape: String
        if name.hasPrefix("GEORADIUS") || upper.contains("BYRADIUS") {
            shape = "radius"
        } else if upper.contains("BYBOX") {
            shape = "box"
        } else {
            shape = "unknown"
        }

        return [GeoMetric(label: "Command", value: name), GeoMetric(label: "Source key", value: source),
                GeoMetric(label: "Destination", value: destination), GeoMetric(label: "Shape", value: shape)]
    }

    static func parseRows(_ node: ReplyNode, words: [String], name: String) -> GeoModel? {
        guard let items = node.items else { return nil }
        switch name {
        case "GEOPOS":
            let members = Array(words.dropFirst(2))
            let rows = items.enumerated().map { index, item -> GeoRow in
                let pair = item.items ?? []
                return GeoRow(id: index, member: index < members.count ? members[index] : "\(index + 1)",
                              longitude: pair.first?.scalarText.flatMap(Double.init),
                              latitude: pair.count > 1 ? pair[1].scalarText.flatMap(Double.init) : nil)
            }
            return GeoModel(rows: rows, hasCoordinates: true)
        case "GEOHASH":
            let members = Array(words.dropFirst(2))
            let rows = items.enumerated().map { index, item in
                GeoRow(id: index, member: index < members.count ? members[index] : "\(index + 1)",
                       hash: item.scalarText)
            }
            return GeoModel(rows: rows, hasCoordinates: false)
        default:
            let upper = Set(words.map { $0.uppercased() })
            let withDist = upper.contains("WITHDIST")
            let withHash = upper.contains("WITHHASH")
            let withCoord = upper.contains("WITHCOORD")
            let rows = items.enumerated().compactMap { index, item -> GeoRow? in
                if let member = item.scalarText { return GeoRow(id: index, member: member) }
                guard let parts = item.items, let member = parts.first?.cellText else { return nil }
                var row = GeoRow(id: index, member: member)
                var position = 1
                if withDist, position < parts.count { row.distance = parts[position].cellText; position += 1 }
                if withHash, position < parts.count { row.hash = parts[position].cellText; position += 1 }
                if withCoord, position < parts.count, let coord = parts[position].items, coord.count >= 2 {
                    row.longitude = coord[0].scalarText.flatMap(Double.init)
                    row.latitude = coord[1].scalarText.flatMap(Double.init)
                }

                return row
            }
            let center = queryCenter(words)
            return GeoModel(rows: rows, hasCoordinates: withCoord, centerLongitude: center?.0, centerLatitude: center?.1)
        }
    }

    static func queryCenter(_ words: [String]) -> (Double, Double)? {
        let upper = words.map { $0.uppercased() }
        guard let name = upper.first else { return nil }
        if name.hasPrefix("GEORADIUS"), !name.hasPrefix("GEORADIUSBYMEMBER"), words.count > 3,
           let lon = Double(words[2]), let lat = Double(words[3]) {
            return (lon, lat)
        }

        if let index = upper.firstIndex(of: "FROMLONLAT"), index + 2 < words.count,
           let lon = Double(words[index + 1]), let lat = Double(words[index + 2]) {
            return (lon, lat)
        }

        return nil
    }
}

// MARK: - JSON

public enum JSONResultParser {
    /// JSON.GET / GET string replies and JSON.MGET arrays -> JSON tree (ASCII-mode strings are unescaped first).
    public static func parse(_ node: ReplyNode, command: String, mode: RunQueryMode) -> JSONValue? {
        let name = WorkbenchCommandText.words(command).first?.uppercased() ?? ""
        if name == "JSON.MGET" {
            guard let items = node.items else { return nil }
            var values: [JSONValue] = []
            for item in items {
                if case .null = item { values.append(.null); continue }
                guard let value = parseString(item, mode: mode) else { return nil }
                values.append(value)
            }

            return .array(values)
        }

        if case .null = node { return .null }
        return parseString(node, mode: mode)
    }

    static func parseString(_ node: ReplyNode, mode: RunQueryMode) -> JSONValue? {
        guard case .string(let text) = node else { return nil }
        let decoded: String
        if mode == .ascii, let data = try? ASCIISafeEscaping.unescape(text) {
            decoded = String(decoding: data, as: UTF8.self)
        } else {
            decoded = text
        }

        return try? JSONParser.parse(decoded)
    }
}
