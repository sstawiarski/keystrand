import Foundation

public enum KeyOperationError: Error, LocalizedError, Sendable, Equatable {
    case keyNotFound
    case keyAlreadyExists
    case newNameInUse
    case invalid(String)
    /// The key was created, but setting its TTL failed for the given reason.
    case createdWithoutTTL(String)

    /// Alert title for `createdWithoutTTL`, which Add Key reports after closing its sheet.
    public static let createdWithoutTTLTitle = "Unable to Set TTL"

    /// Identifies the shared "key no longer exists" error.
    public static func isKeyNotFound(_ error: Error) -> Bool {
        (error as? KeyOperationError) == .keyNotFound
    }

    public var errorDescription: String? {
        switch self {
        case .keyNotFound: return "Key with this name does not exist."
        case .keyAlreadyExists: return "This key already exists."
        case .newNameInUse: return "New key name is already in use."
        case .invalid(let message): return message
        case .createdWithoutTTL(let reason): return "The key was created, but its TTL could not be set. \(reason)"
        }
    }
}

/// TTL text field rules shared by every TTL editor (key TTL, hash field TTL, New Key).
public enum TTLInput {
    public static let maxTTL = 2_147_483_647

    /// Keeps digits only, strips leading zeros (a single `0` stays) and clamps to `maxTTL`.
    public static func sanitize(_ text: String) -> String {
        var digits = text.filter { $0.isASCII && $0.isNumber }
        while digits.count > 1, digits.hasPrefix("0") { digits.removeFirst() }
        guard !digits.isEmpty else { return "" }
        if digits.count > 10 || (Int(digits) ?? Int.max) > maxTTL { return String(maxTTL) }
        return digits
    }

    /// `""` -> -1 (no limit); digits -> seconds; anything else -> nil.
    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return -1 }
        guard isDigits(trimmed), let value = Int(trimmed), value <= maxTTL else { return nil }
        return value
    }

    /// Positive integer count field (list pop count).
    public static func parseCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, isDigits(trimmed), let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    private static func isDigits(_ text: String) -> Bool {
        text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Generic key writes shared by Browser and key-type views.
@MainActor
public struct KeyOperations {
    public let session: DatabaseSession
    /// SCAN COUNT used by bulk delete.
    public nonisolated static let bulkScanCount = 10_000
    /// Maximum `{key, error}` pairs kept by bulk delete.
    public nonisolated static let bulkMaxErrors = 500

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// `DEL` (cluster: one command per key, routed by slot). Returns the number deleted.
    /// Deleting a single key that does not exist throws `.keyNotFound`.
    @discardableResult
    public func delete(_ keys: [Data]) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        var deleted = 0
        if session.isCluster || keys.count == 1 {
            let replies = try await session.pipeline(keys.map { ["DEL", .data($0)] as [RedisArgument] })
            for reply in replies {
                if case .error(let e) = reply { throw RedisClientError.server(e) }
                deleted += Int(reply.intValue ?? 0)
            }
        } else {
            var start = 0
            while start < keys.count {
                let chunk = keys[start..<min(start + 1_000, keys.count)]
                start += 1_000
                let reply = try await session.execute((["DEL"] as [RedisArgument]) + chunk.map { .data($0) })
                deleted += Int(reply.intValue ?? 0)
            }
        }

        if keys.count == 1 && deleted == 0 { throw KeyOperationError.keyNotFound }
        return deleted
    }

    /// `EXISTS old` then `RENAMENX old new` (or `RENAME` when `overwrite`).
    public func rename(_ key: Data, to newName: Data, overwrite: Bool = false) async throws {
        guard try await exists(key) else { throw KeyOperationError.keyNotFound }
        if overwrite {
            _ = try await session.execute(["RENAME", .data(key), .data(newName)])
            return
        }

        let reply = try await session.execute(["RENAMENX", .data(key), .data(newName)])
        if reply.intValue == 0 { throw KeyOperationError.newNameInUse }
    }

    /// `ttl == nil` or -1 removes the TTL (`PERSIST`); 0 deletes the key; > 0 `EXPIRE`.
    public func setTTL(_ key: Data, seconds: Int?) async throws {
        guard let seconds, seconds >= 0 else {
            let ttl = try await session.execute(["TTL", .data(key)])
            if ttl.intValue == -2 { throw KeyOperationError.keyNotFound }
            _ = try await session.execute(["PERSIST", .data(key)])
            return
        }
        let reply = try await session.execute(["EXPIRE", .data(key), .int(Int64(seconds))])
        if reply.intValue == 0 { throw KeyOperationError.keyNotFound }
    }

    public func exists(_ key: Data) async throws -> Bool {
        (try await session.execute(["EXISTS", .data(key)]).intValue ?? 0) > 0
    }

    /// Fails with `.keyAlreadyExists` if the name is taken or `.createdWithoutTTL` if creation succeeds
    /// but setting the key TTL or a hash field TTL fails.
    public func create(_ draft: NewKeyDraft) async throws {
        guard !draft.name.isEmpty else { throw KeyOperationError.invalid("Key name should not be empty.") }
        let k = RedisArgument.data(draft.name)
        var commands: [[RedisArgument]] = []
        var fieldExpiry: [[RedisArgument]] = []

        switch draft.value {
        case .string(let value):
            var args: [RedisArgument] = ["SET", k, .data(value)]
            if let ttl = draft.ttl, ttl > 0 { args += ["EX", .int(Int64(ttl))] }
            args.append("NX")
            let reply = try await session.execute(args)
            if reply.isNull { throw KeyOperationError.keyAlreadyExists }
            return
        case .hash(let fields):
            guard !fields.isEmpty else { throw KeyOperationError.invalid("Add at least one field.") }
            commands = Self.variadic(["HSET", k], fields.map { [.data($0.field), .data($0.value)] })
            for field in fields {
                if let ttl = field.expire, ttl > 0 {
                    fieldExpiry.append(["HEXPIRE", k, .int(Int64(ttl)), "FIELDS", "1", .data(field.field)])
                }
            }
        case .list(let destination, let elements):
            guard !elements.isEmpty else { throw KeyOperationError.invalid("Add at least one element.") }
            let verb: RedisArgument = destination == .head ? "LPUSH" : "RPUSH"
            commands = Self.variadic([verb, k], elements.map { [.data($0)] })
        case .set(let members):
            guard !members.isEmpty else { throw KeyOperationError.invalid("Add at least one member.") }
            commands = Self.variadic(["SADD", k], members.map { [.data($0)] })
        case .zset(let members):
            guard !members.isEmpty else { throw KeyOperationError.invalid("Add at least one member.") }
            commands = Self.variadic(["ZADD", k], members.map { [.string(Self.scoreText($0.score)), .data($0.member)] })
        case .json(let text):
            let path: RedisArgument = session.capabilities.supportsJSONPath ? "$" : "."
            commands = [["JSON.SET", k, path, .string(text), "NX"]]
        case .stream(let id, let fields):
            guard !fields.isEmpty else { throw KeyOperationError.invalid("Add at least one field.") }
            commands.append(["XADD", k, .string(id.isEmpty ? "*" : id)] + fields.flatMap { [RedisArgument.data($0.name), .data($0.value)] })
        case .vectorSet(let elements):
            guard !elements.isEmpty else { throw KeyOperationError.invalid("Add at least one element.") }
            for element in elements {
                guard !element.vector.isEmpty else { throw KeyOperationError.invalid("Vector should not be empty.") }
                var args: [RedisArgument] = ["VADD", k, "VALUES", .int(Int64(element.vector.count))]
                args += element.vector.map { .string(RedisArgument.format($0)) }
                args.append(.data(element.name))
                if let attributes = element.attributes, !attributes.trimmingCharacters(in: .whitespaces).isEmpty {
                    args += ["SETATTR", .string(attributes)]
                }

                commands.append(args)
            }
        case .timeSeries(let ts):
            var create: [RedisArgument] = ["TS.CREATE", k]
            if let retention = ts.retentionMs { create += ["RETENTION", .int(Int64(retention))] }
            if let encoding = ts.encoding, !encoding.isEmpty { create += ["ENCODING", .string(encoding)] }
            if let policy = ts.duplicatePolicy, !policy.isEmpty { create += ["DUPLICATE_POLICY", .string(policy)] }
            if !ts.labels.isEmpty {
                create.append("LABELS")
                create += ts.labels.flatMap { [RedisArgument.string($0.name), .string($0.value)] }
            }

            commands.append(create)
            for sample in ts.samples {
                commands.append(["TS.ADD", k, .string(sample.timestamp.isEmpty ? "*" : sample.timestamp),
                                 .string(RedisArgument.format(sample.value))])
            }
        }

        try await createKey(draft.name, commands: commands, ttl: draft.ttl, expiry: fieldExpiry)
    }

    /// Creates `key` by running `commands` only while the name is free, then sets `ttl` (seconds, when > 0) and runs
    /// the further TTL commands in `expiry`. One `EVAL` makes the existence check, the commands and the TTL atomic.
    /// When scripting is unavailable (denied by ACL, renamed, disabled) it falls back to `EXISTS` followed by
    /// pipelines, which a concurrent client can race.
    ///
    /// Throws `.keyAlreadyExists` without writing when the name is taken, the server error of the first failing
    /// creation command after deleting the key, or `.createdWithoutTTL` when the key was created but a TTL command
    /// failed.
    public func createKey(_ key: Data, commands: [[RedisArgument]], ttl: Int? = nil,
                          expiry: [[RedisArgument]] = []) async throws {
        guard !commands.isEmpty else { throw KeyOperationError.invalid("Nothing to add.") }
        var expiry = expiry
        if let ttl, ttl > 0 { expiry.insert(["EXPIRE", .data(key), .int(Int64(ttl))], at: 0) }
        let all = commands + expiry
        guard all.allSatisfy({ $0.count <= Self.maxScriptCommandArguments }) else {
            try await createWithoutScript(key, commands: commands, expiry: expiry)
            return
        }
        let reply: RESPValue
        do {
            reply = try await session.execute(Self.createScriptArguments(key, commands: all, creating: commands.count))
        } catch RedisClientError.server(let error) where Self.isScriptingUnavailable(error) {
            try await createWithoutScript(key, commands: commands, expiry: expiry)
            return
        }

        switch reply.intValue {
        case 1?: return
        case 0?: throw KeyOperationError.keyAlreadyExists
        default: break
        }

        guard let items = reply.arrayValue, items.count == 2, let index = items[0].intValue,
              let message = items[1].stringValue else {
            throw RedisClientError.protocolError("Unexpected reply to the Add Key script: \(reply)")
        }
        if Int(index) > commands.count { throw KeyOperationError.createdWithoutTTL(message) }
        throw RedisClientError.server(RESPError(message))
    }

    private func createWithoutScript(_ key: Data, commands: [[RedisArgument]], expiry: [[RedisArgument]]) async throws {
        if try await exists(key) { throw KeyOperationError.keyAlreadyExists }
        let replies = try await session.pipeline(commands)
        // An `NX` command answers null when another client created the key after `EXISTS`.
        if zip(commands, replies).contains(where: { $0.last == "NX" && $1.isNull }) {
            throw KeyOperationError.keyAlreadyExists
        }
        if let error = replies.compactMap(\.errorValue).first {
            _ = try? await session.execute(["DEL", .data(key)])
            throw RedisClientError.server(error)
        }
        guard !expiry.isEmpty else { return }
        let expiryReplies: [RESPValue]
        do {
            expiryReplies = try await session.pipeline(expiry)
        } catch {
            throw KeyOperationError.createdWithoutTTL(error.localizedDescription)
        }
        if let error = expiryReplies.compactMap(\.errorValue).first {
            throw KeyOperationError.createdWithoutTTL(error.message)
        }
    }

    /// Scans every primary with `filter` and deletes matches with `UNLINK` (`DEL` before Redis 4.0) pipelines.
    /// Emits overviews (throttled to 1 s, plus the final one). Cancelling the consuming task aborts.
    public func bulkDelete(_ filter: BulkActionFilter) -> AsyncStream<BulkActionOverview> {
        let session = self.session
        let useDel = !(session.capabilities.redisVersion.map { RedisVersion($0)?.isAtLeast("4.0.0") ?? true } ?? true)
        let dbIndex = session.effectiveDB
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                let progress = BulkDeleteProgress(filter: filter)
                await progress.setStatus(.preparing)
                continuation.yield(await progress.snapshot())
                let nodes: [NodeClient]
                do {
                    nodes = try await session.nodes(role: .primary, context: .background)
                } catch {
                    await progress.fail(error.localizedDescription)
                    continuation.yield(await progress.snapshot())
                    continuation.finish()
                    return
                }

                await progress.setStatus(.running)
                continuation.yield(await progress.snapshot())
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { break }
                        continuation.yield(await progress.snapshot())
                    }
                }
                let failure: String? = await withTaskGroup(of: String?.self) { group in
                    for node in nodes {
                        group.addTask {
                            do {
                                try await Self.bulkDeleteNode(node, filter: filter, dbIndex: dbIndex, useDel: useDel,
                                                              progress: progress)
                                return nil
                            } catch is CancellationError {
                                return nil
                            } catch {
                                return error.localizedDescription
                            }
                        }
                    }

                    var first: String?
                    for await result in group where first == nil { first = result }
                    return first
                }
                ticker.cancel()
                if Task.isCancelled {
                    await progress.setStatus(.aborted)
                } else if let failure {
                    await progress.fail(failure)
                } else {
                    await progress.setStatus(.completed)
                }

                continuation.yield(await progress.snapshot())
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Bulk upload: one command per line (redis-cli syntax), 10 000 per pipeline batch.
    public func bulkUpload(_ fileContents: Data) -> AsyncStream<BulkImportSummary> {
        CommandFileImporter(session: session).run(fileContents)
    }

    // MARK: - Helpers

    /// Most arguments one command may have inside the Add Key script; Lua's `unpack` fails just under 8,000 values.
    nonisolated static let maxScriptCommandArguments = 7_000

    /// `KEYS[1]` is the new key; `ARGV` holds how many leading commands create it, then the commands as
    /// `[n1, arg1 … argN1, n2, …]`. Returns 0 without writing when the key exists, 1 when every command succeeded, or
    /// `{index, message}` for the first failing command (1-based), after which no further command runs. A failing
    /// creation command deletes the key first, so nothing is left behind.
    nonisolated static let createScript = """
        if redis.call('EXISTS', KEYS[1]) == 1 then return 0 end
        local creating, i, n, index = tonumber(ARGV[1]), 2, #ARGV, 0
        while i <= n do
          local count = tonumber(ARGV[i])
          index = index + 1
          local reply = redis.pcall(unpack(ARGV, i + 1, i + count))
          if type(reply) == 'table' and reply.err then
            if index <= creating then redis.call('DEL', KEYS[1]) end
            return {index, reply.err}
          end
          i = i + count + 1
        end
        return 1
        """

    nonisolated static func createScriptArguments(_ key: Data, commands: [[RedisArgument]],
                                                  creating: Int) -> [RedisArgument] {
        var args: [RedisArgument] = ["EVAL", .string(createScript), "1", .data(key), .int(Int64(creating))]
        for command in commands {
            args.append(.int(Int64(command.count)))
            args += command
        }

        return args
    }

    /// `prefix` followed by `elements`, split into as many commands as needed to stay within
    /// `maxScriptCommandArguments`. Each element's arguments (a field and its value) stay in one command.
    nonisolated static func variadic(_ prefix: [RedisArgument], _ elements: [[RedisArgument]]) -> [[RedisArgument]] {
        let width = max(elements.first?.count ?? 1, 1)
        let perCommand = max((maxScriptCommandArguments - prefix.count) / width, 1)
        return stride(from: 0, to: elements.count, by: perCommand).map { start in
            prefix + elements[start..<min(start + perCommand, elements.count)].joined()
        }
    }

    /// Errors `EVAL` answers before running anything because scripting is denied by ACL, renamed, or disabled.
    nonisolated static func isScriptingUnavailable(_ error: RESPError) -> Bool {
        if error.code == "NOPERM" { return true }
        if error.code == "OOM" { return false }
        let message = error.message.lowercased()
        return message.contains("unknown command") || message.contains("no permissions")
            || message.contains("not allowed")
    }

    nonisolated static func scoreText(_ score: Double) -> String {
        if score == .infinity { return "+inf" }
        if score == -.infinity { return "-inf" }
        return RedisArgument.format(score)
    }

    nonisolated static func bulkDeleteNode(_ node: NodeClient, filter: BulkActionFilter, dbIndex: Int, useDel: Bool,
                                           progress: BulkDeleteProgress) async throws {
        let total = (try? await KeyScanner.nodeTotal(node, dbIndex: dbIndex)) ?? nil
        await progress.addTotal(max(total ?? 0, 0))
        var cursor: UInt64 = 0
        var scanned = 0
        let count = max(filter.count, 1)
        repeat {
            try Task.checkCancellation()
            let page = try await KeyScanner.scanPage(node, cursor: cursor, match: filter.match.isEmpty ? "*" : filter.match,
                                                     count: count, type: filter.type)
            cursor = page.cursor
            let previous = scanned
            if cursor == 0 {
                scanned = max(total ?? scanned + count, scanned)
            } else {
                scanned += count
                if let total, total >= 0 { scanned = min(scanned, total) }
            }

            await progress.addScanned(scanned - previous)
            guard !page.keys.isEmpty else { continue }
            let verb: RedisArgument = useDel ? "DEL" : "UNLINK"
            let replies = try await node.pipeline(page.keys.map { [verb, .data($0)] })
            var failures: [BulkActionError] = []
            var succeeded = 0
            for (index, reply) in replies.enumerated() {
                if let error = reply.errorValue {
                    failures.append(BulkActionError(key: page.keys[index], error: error.message))
                } else {
                    succeeded += 1
                }
            }

            await progress.record(processed: page.keys.count, succeeded: succeeded, failures: failures)
        } while cursor != 0
    }
}

actor BulkDeleteProgress {
    private var overview: BulkActionOverview
    private let start = Date()

    init(filter: BulkActionFilter) {
        overview = BulkActionOverview(status: .initializing, filter: filter)
    }

    func setStatus(_ status: BulkActionStatus) {
        overview.status = status
    }

    func fail(_ message: String) {
        overview.status = .failed
        overview.error = message
    }

    func addTotal(_ n: Int) { overview.total += n }
    func addScanned(_ n: Int) { overview.scanned += max(n, 0) }

    func record(processed: Int, succeeded: Int, failures: [BulkActionError]) {
        overview.processed += processed
        overview.succeeded += succeeded
        overview.failed += failures.count
        let room = KeyOperations.bulkMaxErrors - overview.errors.count
        if room > 0 { overview.errors += failures.prefix(room) }
    }

    func snapshot() -> BulkActionOverview {
        var copy = overview
        copy.duration = Date().timeIntervalSince(start)
        return copy
    }
}
