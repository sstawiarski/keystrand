import Foundation

/// Commands rejected by the CLI and Workbench, with their messages.
/// Matches prefixes of the trimmed, lowercased line.
/// Use the `arguments:` overloads before sending commands to also detect quoted or escaped verbs (`"SELECT" 3`).
public enum CommandRules {
    public static let cliUnsupported = ["monitor", "subscribe", "psubscribe", "ssubscribe", "sync", "psync",
                                        "script debug", "hello 3"]
    public static let blocking = ["blpop", "brpop", "blmove", "blmpop", "brpoplpush", "bzpopmin", "bzpopmax",
                                  "bzmpop", "xreadgroup", "xread", "waitaof", "wait"]
    public static let workbenchUnsupported = cliUnsupported + ["select"]

    /// Special guidance shown instead of running the command.
    public enum Guidance: String, Sendable, Hashable, CaseIterable {
        case monitor
        case subscribe
        case psubscribe
        case resp3

        public var message: String {
            switch self {
            case .monitor: return "Open the Profiler to watch every request the server receives."
            case .subscribe: return "Subscribe to channels in Pub/Sub."
            case .psubscribe: return "Open Pub/Sub to follow messages across every channel of this database."
            case .resp3: return "This connection stays on RESP2. Switching to RESP3 with HELLO 3 isn't supported yet."
            }
        }
    }

    static func normalized(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The unsupported CLI entry the line starts with (`"monitor"`, `"hello 3"`), if any.
    public static func cliUnsupportedMatch(_ line: String) -> String? {
        let lower = normalized(line)
        return cliUnsupported.first { lower.hasPrefix($0) }
    }

    /// The unsupported or blocking Workbench entry the line starts with, if any.
    public static func workbenchUnsupportedMatch(_ line: String) -> String? {
        let lower = normalized(line)
        return (workbenchUnsupported + blocking).first { lower.hasPrefix($0) }
    }

    public static func isBlocking(_ line: String) -> Bool {
        let lower = normalized(line)
        return blocking.contains { lower.hasPrefix($0) }
    }

    /// Joins decoded arguments with spaces.
    public static func canonicalLine(_ arguments: [String]) -> String {
        arguments.joined(separator: " ")
    }

    public static func cliUnsupportedMatch(_ line: String, arguments: [String]) -> String? {
        cliUnsupportedMatch(line) ?? cliUnsupportedMatch(canonicalLine(arguments))
    }

    public static func workbenchUnsupportedMatch(_ line: String, arguments: [String]) -> String? {
        workbenchUnsupportedMatch(line) ?? workbenchUnsupportedMatch(canonicalLine(arguments))
    }

    public static func isBlocking(_ line: String, arguments: [String]) -> Bool {
        isBlocking(line) || isBlocking(canonicalLine(arguments))
    }

    public static func guidance(for line: String, arguments: [String]) -> Guidance? {
        guidance(for: line) ?? guidance(for: canonicalLine(arguments))
    }

    /// Formats the Workbench error for an unsupported command.
    public static func workbenchErrorMessage(_ entry: String) -> String {
        "\(entry.uppercased()) can't be run from Workbench."
    }

    /// Lists commands unsupported by Workbench.
    public static func workbenchUnsupportedMessage(_ command: String) -> String {
        let list = (blocking + ["select"] + cliUnsupported + blocking).joined(separator: ", ")
        return "\(command) can't be run from Workbench. Commands Workbench doesn't run: \(list)"
    }

    /// Lists commands unsupported by the CLI, excluding MONITOR.
    public static func cliUnsupportedMessage(_ command: String) -> String {
        let list = cliUnsupported.filter { $0 != "monitor" }.joined(separator: ", ")
        return "\(command) can't be run from the CLI. Commands the CLI doesn't run: \(list)"
    }

    /// Guidance for MONITOR / SUBSCRIBE / SSUBSCRIBE / PSUBSCRIBE / HELLO 3.
    public static func guidance(for line: String) -> Guidance? {
        let words = normalized(line).split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return nil }
        switch first {
        case "monitor": return .monitor
        case "subscribe", "ssubscribe": return .subscribe
        case "psubscribe": return .psubscribe
        case "hello": return words.count > 1 && words[1] == "3" ? .resp3 : nil
        default: return nil
        }
    }
}

/// Lowercased `MODULE LIST` names of each module family; any one of a set means the module is loaded.
public enum ModuleNames {
    public static let search: Set<String> = ["search", "searchlight", "ft", "ftl"]
    /// RedisJSON (`ReJSON`) and valkey-json (`json`).
    public static let json: Set<String> = ["rejson", "json"]
    public static let bloom: Set<String> = ["bf"]
    public static let timeSeries: Set<String> = ["timeseries"]
    public static let graph: Set<String> = ["graph"]
}

/// Module requirements for command prefixes, with the unavailable-module panel text.
public struct CommandModuleRequirement: Hashable, Sendable {
    public var prefixes: [String]
    /// Lowercased MODULE LIST names that satisfy the requirement.
    public var moduleNames: Set<String>
    public var title: String
    public var subtitle: String
    public var bullets: [String]
    public var learnMoreURL: URL?

    public static let search = CommandModuleRequirement(
        prefixes: ["FT."], moduleNames: ModuleNames.search,
        title: "This database doesn't have Redis Search", subtitle: "With Redis Search you can:",
        bullets: ["Query data by field value", "Build secondary indexes", "Run full-text queries"],
        learnMoreURL: URL(string: "https://redis.io/docs/latest/develop/ai/search-and-query/"))

    public static let json = CommandModuleRequirement(
        prefixes: ["JSON."], moduleNames: ModuleNames.json,
        title: "This database doesn't have JSON support", subtitle: "With JSON you can:",
        bullets: ["Store nested documents", "Change one path in place", "Read back any part of a document"],
        learnMoreURL: URL(string: "https://redis.io/docs/latest/develop/data-types/json/"))

    public static let timeSeries = CommandModuleRequirement(
        prefixes: ["TS."], moduleNames: ModuleNames.timeSeries,
        title: "This database doesn't have time series support",
        subtitle: "With time series you can:",
        bullets: ["Append timestamped samples", "Query and aggregate ranges across many series at once",
                  "Downsample old samples automatically to keep history cheaply"],
        learnMoreURL: URL(string: "https://redis.io/docs/latest/develop/data-types/timeseries/"))

    /// Represents a valkey-bloom `bf` module with only `BF.*`, leaving `CF.`, `CMS.`, `TOPK.` and `TDIGEST.` unsatisfied.
    public static let bloomFilterOnlyModule = "bf.bloom-only"

    public static let bloomFilter = probabilisticPanel(prefixes: ["BF."],
                                                       moduleNames: ModuleNames.bloom.union([bloomFilterOnlyModule]))

    public static let probabilistic = probabilisticPanel(prefixes: ["CF.", "CMS.", "TOPK.", "TDIGEST."],
                                                         moduleNames: ModuleNames.bloom)

    private static func probabilisticPanel(prefixes: [String], moduleNames: Set<String>) -> CommandModuleRequirement {
        CommandModuleRequirement(
            prefixes: prefixes, moduleNames: moduleNames,
            title: "This database doesn't have probabilistic types",
            subtitle: "Probabilistic types in this module:",
            bullets: ["Bloom filter", "Cuckoo filter", "Count-min sketch", "Top-K", "T-digest"],
            learnMoreURL: URL(string: "https://redis.io/docs/latest/develop/data-types/probabilistic/bloom-filter/"))
    }

    public static let all: [CommandModuleRequirement] = [.search, .json, .timeSeries, .bloomFilter, .probabilistic]

    /// Requirement for a command line (`ft.search idx *` -> `.search`), or nil for core commands.
    public static func requirement(for commandLine: String) -> CommandModuleRequirement? {
        let upper = commandLine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return all.first { req in req.prefixes.contains { upper.hasPrefix($0) } }
    }

    /// Returns the module requirement missing from `loadedModules`. An empty module list counts as missing.
    public static func missing(for commandLine: String, loadedModules: [String]) -> CommandModuleRequirement? {
        guard let requirement = requirement(for: commandLine), !requirement.isSatisfied(by: loadedModules) else {
            return nil
        }
        return requirement
    }

    /// True when one of `loadedModules` (MODULE LIST names, any case) satisfies the requirement.
    public func isSatisfied(by loadedModules: [String]) -> Bool {
        !moduleNames.isDisjoint(with: loadedModules.map { $0.lowercased() })
    }
}
