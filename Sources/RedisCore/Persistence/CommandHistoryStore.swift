import Foundation

/// Query history for Workbench and Vector Search, newest first, at most 30 per database and type.
/// Masks command passwords and replaces results above 1 MiB with a "result too big" message.
/// Files are compact `{"schemaVersion": n, "items": [...]}` JSON; each item is encoded once and reused for later writes.
public actor CommandHistoryStore {
    static let currentSchemaVersion = 1
    public static let maxItems = 30
    public static let maxResultBytes = 1_048_576

    private let paths: AppPaths
    private var cache: [URL: [CommandExecution]] = [:]
    private var encoded: [URL: [UUID: Data]] = [:]
    private var dirty: Set<URL> = []
    private let encoder = JSONFile.makeCompactEncoder()

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// Items without `result` (load the full record with `get`).
    public func list(databaseID: DatabaseID, type: CommandExecutionType) -> [CommandExecution] {
        load(paths.commandHistoryFile(for: databaseID, type: type)).map { item in
            var copy = item
            copy.result = nil
            return copy
        }
    }

    public func get(_ id: UUID, databaseID: DatabaseID, type: CommandExecutionType) -> CommandExecution? {
        load(paths.commandHistoryFile(for: databaseID, type: type)).first { $0.id == id }
    }

    /// Stages executions and flushes them to disk.
    @discardableResult
    public func add(_ executions: [CommandExecution]) throws -> [CommandExecution] {
        let returned = stage(executions)
        try flush()
        return returned
    }

    /// Prepends new executions in memory (skips `isNotStored`), trims to 30, applies the 1 MiB rule and masks
    /// passwords; `flush()` writes the file. Returns the executions as given, with `isNotStored` set on those whose
    /// result was too big to keep.
    @discardableResult
    public func stage(_ executions: [CommandExecution]) -> [CommandExecution] {
        guard let first = executions.first else { return [] }
        let url = paths.commandHistoryFile(for: first.databaseId, type: first.type)
        var stored: [CommandExecution] = []
        var returned: [CommandExecution] = []
        var fileEncoded = encoded[url] ?? [:]
        for execution in executions {
            guard execution.isNotStored != true else {
                returned.append(execution)
                continue
            }
            var item = Self.redacted(execution)
            var data = try? encoder.encode(item)
            if let size = data?.count, size > Self.maxResultBytes, Self.exceedsSizeLimit(item) {
                item = Self.sizeLimitPlaceholder(item)
                data = try? encoder.encode(item)
                var flagged = execution
                flagged.isNotStored = true
                returned.append(flagged)
            } else {
                returned.append(execution)
            }

            if let data { fileEncoded[item.id] = data }
            stored.append(item)
        }

        guard !stored.isEmpty else { return returned }
        let all = Array((stored + load(url)).prefix(Self.maxItems))
        let kept = Set(all.map(\.id))
        encoded[url] = fileEncoded.filter { kept.contains($0.key) }
        cache[url] = all
        dirty.insert(url)
        return returned
    }

    /// Writes every file changed by `stage` since the last flush. A file that fails stays pending.
    public func flush() throws {
        var firstError: Error?
        for url in dirty.sorted(by: { $0.path < $1.path }) {
            do {
                try write(url)
                dirty.remove(url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError { throw firstError }
    }

    public func delete(_ id: UUID, databaseID: DatabaseID, type: CommandExecutionType) throws {
        let url = paths.commandHistoryFile(for: databaseID, type: type)
        cache[url] = load(url).filter { $0.id != id }
        encoded[url]?[id] = nil
        try write(url)
        dirty.remove(url)
    }

    public func clear(databaseID: DatabaseID, type: CommandExecutionType) throws {
        let url = paths.commandHistoryFile(for: databaseID, type: type)
        cache[url] = []
        encoded[url] = nil
        try write(url)
        dirty.remove(url)
    }

    public func deleteAll(databaseID: DatabaseID) {
        for type in CommandExecutionType.allCases {
            let url = paths.commandHistoryFile(for: databaseID, type: type)
            cache[url] = nil
            encoded[url] = nil
            dirty.remove(url)
            JSONFile.discard(url)
        }
    }

    private func load(_ url: URL) -> [CommandExecution] {
        if let cached = cache[url] { return cached }
        let loaded = VersionedArrayFile<CommandExecution>.load(from: url, currentVersion: Self.currentSchemaVersion)
        cache[url] = loaded
        return loaded
    }

    /// Joins the items' cached encodings into the file's item array; items read from an older file are encoded here
    /// once.
    private func write(_ url: URL) throws {
        let items = cache[url] ?? []
        var fileEncoded = encoded[url] ?? [:]
        var body = Data(#"{"schemaVersion":\#(Self.currentSchemaVersion),"items":["#.utf8)
        for (index, item) in items.enumerated() {
            let data: Data
            if let cached = fileEncoded[item.id] {
                data = cached
            } else {
                data = try encoder.encode(item)
                fileEncoded[item.id] = data
            }

            if index > 0 { body.append(UInt8(ascii: ",")) }
            body.append(data)
        }

        body.append(Data("]}".utf8))
        encoded[url] = fileEncoded
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, options: .atomic)
    }

    static func redacted(_ execution: CommandExecution) -> CommandExecution {
        var copy = execution
        copy.command = CommandRedaction.redactLines(execution.command)
        if let results = execution.result {
            copy.result = results.map { result in
                guard case .group(let items) = result.response else { return result }
                var redacted = result
                redacted.response = .group(items.map { item in
                    var copy = item
                    copy.command = CommandRedaction.redact(item.command)
                    return copy
                })
                return redacted
            }
        }

        return copy
    }

    static func applySizeLimit(_ execution: CommandExecution) -> CommandExecution {
        exceedsSizeLimit(execution) ? sizeLimitPlaceholder(execution) : execution
    }

    static func exceedsSizeLimit(_ execution: CommandExecution) -> Bool {
        guard let result = execution.result, let size = try? JSONEncoder().encode(result).count else { return false }
        return size > maxResultBytes
    }

    static func sizeLimitPlaceholder(_ execution: CommandExecution) -> CommandExecution {
        var copy = execution
        copy.result = [CommandExecutionResult(
            status: .success,
            response: .message("Output over 1 MB isn't kept. Run the command again to see it."),
            sizeLimitExceeded: true)]
        return copy
    }
}
