import Foundation
import RedisCore

/// Pure aggregation of sampled keys into the Database Analysis summary (no Redis I/O).
public enum AnalysisAggregator {
    public static let topLimit = 15

    /// Labels and thresholds in seconds. A key lands in the first group whose threshold is greater than its TTL.
    public static let expirationBuckets: [(label: String, threshold: Int)] = [
        ("No Expiry", 0),
        ("<1 hr", 3_600),
        ("1-4 Hrs", 14_400),
        ("4-12 Hrs", 43_200),
        ("12-24 Hrs", 86_400),
        ("1-7 Days", 604_800),
        (">7 Days", 2_592_000),
        (">1 Month", 9_007_199_254_740_991),
    ]

    public static let noExpiryLabel = "No Expiry"

    public struct Result: Hashable, Sendable {
        public var totalKeys: SimpleSummary
        public var totalMemory: SimpleSummary
        public var topKeysNsp: [NspSummary]
        public var topMemoryNsp: [NspSummary]
        public var topKeysLength: [AnalyzedKey]
        public var topKeysMemory: [AnalyzedKey]
        public var expirationGroups: [SumGroup]
    }

    public static func aggregate(_ keys: [AnalyzedKey], delimiter: Data) -> Result {
        let namespaces = namespacesMap(keys, delimiter: delimiter)
        return Result(
            totalKeys: simpleSummary(keys) { _ in 1 },
            totalMemory: simpleSummary(keys) { Double($0.memory ?? 0) },
            topKeysNsp: nspSummary(namespaces, byKeys: true),
            topMemoryNsp: nspSummary(namespaces, byKeys: false),
            topKeysLength: topKeys(keys, by: \.length),
            topKeysMemory: topKeys(keys, by: \.memory),
            expirationGroups: expirationGroups(keys))
    }

    public static func simpleSummary(_ keys: [AnalyzedKey], value: (AnalyzedKey) -> Double) -> SimpleSummary {
        var total = 0.0
        var byType: [String: Double] = [:]
        var order: [String] = []
        for key in keys {
            let v = value(key)
            total += v
            if byType[key.type] == nil { order.append(key.type) }
            byType[key.type, default: 0] += v
        }

        let types = order.map { SimpleTypeSummary(type: $0, total: byType[$0] ?? 0) }
        return SimpleSummary(total: total, types: stableSortedDescending(types) { $0.total })
    }

    /// Bytes before the first occurrence of `delimiter`; nil when absent or when the namespace would be empty.
    public static func namespace(of key: Data, delimiter: Data) -> Data? {
        guard !delimiter.isEmpty, let range = key.range(of: delimiter) else { return nil }
        let nsp = key[key.startIndex..<range.lowerBound]
        return nsp.isEmpty ? nil : Data(nsp)
    }

    struct NamespaceAccumulator {
        var memory = 0
        var keys = 0
        var typeOrder: [String] = []
        var types: [String: (memory: Int, keys: Int)] = [:]
    }

    static func namespacesMap(_ keys: [AnalyzedKey], delimiter: Data) -> [(Data, NamespaceAccumulator)] {
        var map: [Data: NamespaceAccumulator] = [:]
        var order: [Data] = []
        for key in keys {
            guard let nsp = namespace(of: key.name, delimiter: delimiter) else { continue }
            var acc = map[nsp] ?? { order.append(nsp); return NamespaceAccumulator() }()
            let memory = key.memory ?? 0
            acc.keys += 1
            acc.memory += memory
            if acc.types[key.type] == nil { acc.typeOrder.append(key.type) }
            let current = acc.types[key.type] ?? (0, 0)
            acc.types[key.type] = (current.memory + memory, current.keys + 1)
            map[nsp] = acc
        }

        return order.compactMap { nsp in map[nsp].map { (nsp, $0) } }
    }

    static func nspSummary(_ namespaces: [(Data, NamespaceAccumulator)], byKeys: Bool) -> [NspSummary] {
        let summaries = namespaces.map { nsp, acc -> NspSummary in
            let types = acc.typeOrder.map { type -> NspTypeSummary in
                let t = acc.types[type] ?? (0, 0)
                return NspTypeSummary(type: type, memory: t.memory, keys: t.keys)
            }
            return NspSummary(nsp: nsp, memory: acc.memory, keys: acc.keys,
                              types: stableSortedDescending(types) { Double(byKeys ? $0.keys : $0.memory) })
        }
        return Array(stableSortedDescending(summaries) { Double(byKeys ? $0.keys : $0.memory) }.prefix(topLimit))
    }

    /// Top keys by a numeric field, descending; keys without the value sort last.
    public static func topKeys(_ keys: [AnalyzedKey], by field: KeyPath<AnalyzedKey, Int?>, limit: Int = topLimit) -> [AnalyzedKey] {
        let indexed = keys.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            switch (lhs.1[keyPath: field], rhs.1[keyPath: field]) {
            case let (a?, b?): return a != b ? a > b : lhs.0 < rhs.0
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.0 < rhs.0
            }
        }
        return sorted.prefix(limit).map(\.1)
    }

    public static func expirationGroups(_ keys: [AnalyzedKey]) -> [SumGroup] {
        var totals = Array(repeating: 0, count: expirationBuckets.count)
        for key in keys {
            if let index = expirationBuckets.firstIndex(where: { key.ttl < $0.threshold }) {
                totals[index] += key.memory ?? 0
            }
        }

        return expirationBuckets.enumerated().map { SumGroup(label: $0.element.label, total: totals[$0.offset], threshold: $0.element.threshold) }
    }

    static func stableSortedDescending<T>(_ items: [T], by value: (T) -> Double) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                let a = value(lhs.element), b = value(rhs.element)
                return a != b ? a > b : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// Extrapolation helpers (`~` prefix when the sample is smaller than the database).
public enum Extrapolation {
    public static func value(_ value: Double, factor: Double, enabled: Bool) -> Double {
        enabled ? value * factor : value
    }

    public static func isApplied(factor: Double, enabled: Bool) -> Bool {
        enabled && factor != 1
    }

    public static func keysText(_ count: Double, factor: Double, enabled: Bool) -> String {
        let v = Int(value(count, factor: factor, enabled: enabled).rounded())
        return (isApplied(factor: factor, enabled: enabled) ? "~" : "") + NumberFormatting.grouped(v)
    }

    public static func bytesText(_ bytes: Double, factor: Double, enabled: Bool) -> String {
        let v = value(bytes, factor: factor, enabled: enabled)
        return (isApplied(factor: factor, enabled: enabled) ? "~" : "") + AnalyticsFormat.bytes(v)
    }
}
