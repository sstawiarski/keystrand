import Foundation

/// Classifies decoded command arguments for production confirmation.
/// `ACL CAT dangerous` uses lowercase names with pipe-separated subcommands (`config|set`).
/// The catalog fallback uses `CONFIG SET` and applies only if the server list is empty.
public struct DangerousCommandClassifier: Sendable {
    private let serverList: Set<String>
    private let fallback: Set<String>

    public init(serverList: Set<String>, catalog: CommandCatalog?) {
        self.serverList = serverList
        let catalogNames = serverList.isEmpty ? (catalog?.dangerousCommandNames ?? []) : []
        fallback = Set(catalogNames.map { $0.lowercased() })
    }

    /// The uppercased verb (`CONFIG` for `CONFIG SET maxmemory 1`) when the command is dangerous, else nil.
    public func dangerousVerb(_ arguments: [String]) -> String? {
        guard let first = arguments.first?.lowercased() else { return nil }
        var candidates = [first]
        if arguments.count > 1 {
            let second = arguments[1].lowercased()
            candidates += ["\(first)|\(second)", "\(first) \(second)"]
        }

        let hit = candidates.contains { serverList.contains($0) || fallback.contains($0) }
        return hit ? first.uppercased() : nil
    }

    /// Distinct dangerous verbs of `commands` in order of first appearance.
    public func dangerousVerbs(in commands: [[String]]) -> [String] {
        Self.distinct(commands.compactMap(dangerousVerb))
    }

    /// Distinct `FLUSHDB` / `FLUSHALL` verbs of `commands` in order of first appearance.
    public static func flushVerbs(in commands: [[String]]) -> [String] {
        distinct(commands.compactMap { $0.first?.uppercased() }.filter { $0 == "FLUSHDB" || $0 == "FLUSHALL" })
    }

    private static func distinct(_ verbs: [String]) -> [String] {
        var out: [String] = []
        for verb in verbs where !out.contains(verb) { out.append(verb) }
        return out
    }
}
