import Foundation

/// Display names and visibility of command groups (Command Helper filter, group badges).
public enum CommandGroups {
    public static let displayNames: [String: String] = [
        "hash": "Hash", "list": "List", "set": "Set", "sorted-set": "Sorted Set", "string": "String",
        "json": "JSON", "stream": "Stream", "bitmap": "Bitmap", "cluster": "Cluster", "connection": "Connection",
        "geo": "Geo", "generic": "Generic", "pubsub": "Pub/Sub", "scripting": "Scripting",
        "transactions": "Transactions", "timeseries": "TimeSeries", "server": "Server", "hyperloglog": "HyperLogLog",
        "cms": "CMS", "tdigest": "TDigest", "topk": "TopK", "bf": "Bloom Filter", "cf": "Cuckoo Filter",
        "search": "search",
    ]

    /// Groups hidden from the Command Helper (RedisGraph is deprecated).
    public static let hiddenGroups: Set<String> = ["graph"]

    /// Display name; unknown groups get `_` replaced by spaces and the first letter capitalized.
    public static func displayName(_ group: String) -> String {
        if let name = displayNames[group] { return name }
        let spaced = group.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    public static func isHidden(_ group: String) -> Bool {
        hiddenGroups.contains(group.lowercased())
    }

    /// True for commands the Command Helper hides (deprecated RedisGraph).
    public static func isDeprecatedCommand(_ spec: CommandSpec) -> Bool {
        isHidden(spec.group) || spec.name.hasPrefix("GRAPH.")
    }
}
