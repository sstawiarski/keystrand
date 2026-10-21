import Foundation
import RESP

public enum CommandCatalogError: Error, LocalizedError, Sendable {
    case resourcesMissing
    case invalidFile(String, String)

    public var errorDescription: String? {
        switch self {
        case .resourcesMissing: return "Bundled command specs are missing."
        case .invalidFile(let name, let detail): return "Could not read \(name): \(detail)"
        }
    }
}

/// Bundled command specs for Redis core and module providers.
public final class CommandCatalog: Sendable {
    /// Module names (lowercased, from `MODULE LIST`) that enable each non-main provider.
    public static let providerModules: [String: Set<String>] = [
        "redisearch": ModuleNames.search,
        "redisjson": ModuleNames.json,
        "redistimeseries": ModuleNames.timeSeries,
        "redisbloom": ModuleNames.bloom.union([CommandModuleRequirement.bloomFilterOnlyModule]),
        "redisgraph": ModuleNames.graph,
        "redisgears": ["rg", "redisgears", "redisgears_2"],
    ]

    /// FT commands listed first in completion lists, in this order.
    static let preferredSearchCommands = ["FT.SEARCH", "FT.AGGREGATE", "FT.CREATE", "FT.EXPLAIN", "FT.PROFILE"]

    /// Keyed by uppercased name.
    public let commands: [String: CommandSpec]
    /// Every name sorted alphabetically.
    public let sortedNames: [String]
    /// Maps container names to full subcommand names, such as `CLIENT` to `CLIENT KILL` and `CLIENT LIST`.
    public let subcommandIndex: [String: [String]]

    public init(specs: [CommandSpec]) {
        var map: [String: CommandSpec] = [:]
        for spec in specs { map[Self.normalizeName(spec.name)] = Self.normalized(spec) }
        commands = map
        sortedNames = map.keys.sorted()
        var subs: [String: [String]] = [:]
        for name in sortedNames {
            let parts = name.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { subs[String(parts[0]), default: []].append(name) }
        }

        subcommandIndex = subs
    }

    /// Lazily loaded bundled catalog (empty if resources are missing).
    public static let shared: CommandCatalog = (try? loadBundled()) ?? CommandCatalog(specs: [])

    public static func loadBundled() throws -> CommandCatalog {
        guard let dir = Bundle.module.url(forResource: "Commands", withExtension: nil) else {
            throw CommandCatalogError.resourcesMissing
        }
        return try load(directory: dir)
    }

    public static func load(directory: URL) throws -> CommandCatalog {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var specs: [CommandSpec] = []
        for file in files {
            let base = file.deletingPathExtension().lastPathComponent
            let provider = base == "redis" ? "main" : base
            let decoded: [String: CommandSpec]
            do {
                decoded = try JSONDecoder().decode([String: CommandSpec].self, from: Data(contentsOf: file))
            } catch {
                throw CommandCatalogError.invalidFile(file.lastPathComponent, error.localizedDescription)
            }

            for (name, var spec) in decoded {
                spec.name = normalizeName(name)
                spec.provider = provider
                specs.append(spec)
            }
        }

        return CommandCatalog(specs: specs)
    }

    /// Uppercased, single-spaced (`"client   list"` -> `"CLIENT LIST"`).
    public static func normalizeName(_ name: String) -> String {
        name.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalized(_ spec: CommandSpec) -> CommandSpec {
        var copy = spec
        copy.name = normalizeName(spec.name)
        if copy.group.isEmpty { copy.group = "generic" }
        copy.arguments = copy.arguments.map(collapsingExpressionBlocks)
        return copy
    }

    /// Types an expression block as one string. FT.AGGREGATE APPLY is one: its children list the functions it can call.
    private static func collapsingExpressionBlocks(_ argument: CommandArgument) -> CommandArgument {
        var copy = argument
        if copy.expression, copy.type == .block { copy.type = .string }
        copy.arguments = copy.arguments.map(collapsingExpressionBlocks)
        return copy
    }

    // MARK: - Lookup

    /// Case-insensitive lookup by full name (`"client list"`, `"FT.SEARCH"`).
    public func spec(named name: String) -> CommandSpec? {
        commands[Self.normalizeName(name)]
    }

    /// Best match for a typed command line: tries `TOKEN1 TOKEN2` (container commands) before `TOKEN1`.
    public func match(tokens: [String]) -> CommandSpec? {
        guard let first = tokens.first?.uppercased() else { return nil }
        if tokens.count > 1, let sub = commands["\(first) \(tokens[1].uppercased())"] { return sub }
        return commands[first]
    }

    /// Matches the first one or two words of a raw command line.
    public func match(line: String) -> CommandSpec? {
        let words = CommandLineTokenizer.tokenize(line).tokens.prefix(2).map(\.text)
        return match(tokens: Array(words))
    }

    /// Number of words in the command name (2 for `CLIENT LIST`).
    public func wordCount(of spec: CommandSpec) -> Int {
        spec.name.split(separator: " ").count
    }

    /// Names starting with `prefix` (case-insensitive), sorted.
    public func search(prefix: String) -> [CommandSpec] {
        let p = prefix.uppercased()
        return sortedNames.filter { $0.hasPrefix(p) }.compactMap { commands[$0] }
    }

    /// Finds names containing `text`, ignoring case, optionally within a group. Excludes deprecated RedisGraph commands.
    public func search(containing text: String, group: String? = nil) -> [CommandSpec] {
        let needle = text.trimmingCharacters(in: .whitespaces).uppercased()
        return sortedNames.compactMap { commands[$0] }.filter { spec in
            if CommandGroups.isDeprecatedCommand(spec) { return false }
            if let group, spec.group != group { return false }
            return needle.isEmpty || spec.name.contains(needle)
        }
    }

    /// The commands `availability` includes, in name order.
    public func available(_ availability: CommandAvailability) -> [CommandSpec] {
        sortedNames.compactMap { commands[$0] }.filter(availability.includes)
    }

    /// Alphabetical order, with FT.SEARCH, FT.AGGREGATE, FT.CREATE, FT.EXPLAIN and FT.PROFILE first among FT commands.
    public func completionOrder(_ specs: [CommandSpec]) -> [CommandSpec] {
        func rank(_ name: String) -> Int {
            Self.preferredSearchCommands.firstIndex(of: name) ?? Self.preferredSearchCommands.count
        }

        return specs.sorted { a, b in
            let aFT = a.name.hasPrefix("FT."), bFT = b.name.hasPrefix("FT.")
            if aFT && bFT, rank(a.name) != rank(b.name) { return rank(a.name) < rank(b.name) }
            return a.name < b.name
        }
    }

    // MARK: - Containers and groups

    /// First words of multi-word commands (`CLIENT`, `CONFIG`, `ACL`, ...).
    public var containerCommands: Set<String> {
        Set(subcommandIndex.keys)
    }

    public func isContainer(_ name: String) -> Bool {
        subcommandIndex[Self.normalizeName(name)] != nil
    }

    /// Sub-commands of a container (`CLIENT` -> `[CLIENT CACHING, CLIENT GETNAME, ...]`).
    public func subcommands(of container: String) -> [CommandSpec] {
        (subcommandIndex[Self.normalizeName(container)] ?? []).compactMap { commands[$0] }
    }

    public var groups: [String] {
        Array(Set(commands.values.map(\.group))).sorted()
    }

    /// Groups offered by the Command Helper filter (deprecated groups removed), sorted by display name.
    public var visibleGroups: [String] {
        groups.filter { !CommandGroups.isHidden($0) }
            .sorted { CommandGroups.displayName($0).lowercased() < CommandGroups.displayName($1).lowercased() }
    }

    public func commands(inGroup group: String) -> [CommandSpec] {
        sortedNames.compactMap { commands[$0] }.filter { $0.group == group }
    }

    /// Commands whose ACL categories include `@dangerous` (fallback when `ACL CAT dangerous` is unavailable).
    public var dangerousCommandNames: Set<String> {
        Set(commands.values.filter(\.isDangerous).map(\.name))
    }
}

/// Server command availability for completion lists.
public struct CommandAvailability: Hashable, Sendable {
    /// Effective MODULE LIST names; nil offers every module command.
    public let modules: [String]?
    public let includesVectorSets: Bool
    /// Whether to offer Valkey-only core commands.
    public let includesValkeyOnly: Bool
    /// Whether to offer FT.EXPLAIN, FT.EXPLAINCLI and FT.PROFILE.
    public let includesSearchExplain: Bool

    public init(modules: [String]? = nil, includesVectorSets: Bool = true, includesValkeyOnly: Bool = true,
                includesSearchExplain: Bool = true) {
        self.modules = modules
        self.includesVectorSets = includesVectorSets
        self.includesValkeyOnly = includesValkeyOnly
        self.includesSearchExplain = includesSearchExplain
    }

    /// Every command, for when the server is not known yet.
    public static let unrestricted = CommandAvailability()

    public static let valkeyOnlyCommands: Set<String> = ["DELIFEQ", "CLUSTERSCAN", "COMMANDLOG"]
    public static let searchExplainCommands: Set<String> = ["FT.EXPLAIN", "FT.EXPLAINCLI", "FT.PROFILE"]

    /// Includes core commands and module commands whose loaded provider satisfies the module requirement.
    public func includes(_ spec: CommandSpec) -> Bool {
        if !includesVectorSets && spec.group == "vector_set" { return false }
        let command = spec.name.split(separator: " ").first.map(String.init) ?? spec.name
        if !includesValkeyOnly && Self.valkeyOnlyCommands.contains(command) { return false }
        if !includesSearchExplain && Self.searchExplainCommands.contains(command) { return false }
        guard let modules else { return true }
        if spec.provider != "main" {
            guard let names = CommandCatalog.providerModules[spec.provider],
                  modules.contains(where: { names.contains($0.lowercased()) }) else { return false }
        }

        return CommandModuleRequirement.missing(for: spec.name, loadedModules: modules) == nil
    }
}
