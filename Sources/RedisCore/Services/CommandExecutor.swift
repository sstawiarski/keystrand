import Foundation

/// Splits Workbench and Vector Search scripts at lines that start without whitespace.
/// Drops `//` comment lines and expands `N COMMAND` repeat prefixes.
public enum WorkbenchScriptParser {
    /// Largest `N` an `N COMMAND` prefix expands to. A larger count stays one unexpanded command, which the
    /// executor fails with `invalidRepeatMessage`.
    public static let maxRepeatCount = 100_000

    public static func parse(_ script: String) throws -> [String] {
        var lines = logicalLines(script)
        if let first = lines.first, isParamsLine(first) { lines[0] = removeParams(first) }
        var expanded: [String] = []
        for line in lines {
            let (command, count) = repeatCount(line)
            let repeats = (1...maxRepeatCount).contains(count ?? 0)
            let cleaned = removeComments((repeats ? command : line).trimmingCharacters(in: .whitespacesAndNewlines))
            guard !cleaned.isEmpty else { continue }
            if repeats, let count {
                expanded.append(contentsOf: repeatElement(cleaned, count: count))
            } else {
                expanded.append(cleaned)
            }
        }

        return expanded
    }

    /// Params from a first line like `[pipeline=3;mode=raw;results=group]`, or nil when there is none.
    /// Unknown keys and invalid values are ignored.
    public static func parseParams(_ script: String) -> ExecuteParams? {
        guard let first = logicalLines(script).first, isParamsLine(first) else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        let open = trimmed.index(after: trimmed.startIndex)
        guard let end = trimmed.firstIndex(of: "]"), open <= end else { return nil }
        let body = trimmed[open..<end].replacingOccurrences(of: " ", with: "")
        var params = ExecuteParams()
        for pair in body.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, !kv[1].isEmpty else { continue }
            let value = kv[1]
            switch kv[0] {
            case "pipeline":
                if let n = Int(value), n >= 0 { params.batchSize = n }
            case "mode":
                switch value.lowercased() {
                case "raw": params.mode = .raw
                case "ascii": params.mode = .ascii
                default: break
                }
            case "results":
                switch value.lowercased() {
                case "group", "group_mode": params.resultsMode = .group
                case "single", "default": params.resultsMode = .default
                case "silent": params.resultsMode = .silent
                default: break
                }
            case "run_confirmation":
                params.runConfirmation = Bool(value.lowercased())
            case "executable":
                params.executable = Bool(value.lowercased())
            case "clearEditor":
                if let flag = Bool(value.lowercased()) { params.clearEditor = flag }
            default:
                break
            }
        }

        return params
    }

    /// Joins continuation lines: split on `(\r\n|\n|\r)+\s+`, drop blank pieces, join with a single space.
    public static func multilineToOneLine(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(\r\n|\n|\r)+\s+"#) else { return text }
        let ns = text as NSString
        var pieces: [String] = []
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            last = match.range.location + match.range.length
        }

        pieces.append(ns.substring(from: last))
        return pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " ")
    }

    /// Decoded arguments `CommandExecutor` sends for one parsed command (escapes resolved, so `"\x46LUSHDB"` is
    /// `FLUSHDB`), or nil when the command does not split and is never sent.
    public static func arguments(of command: String) -> [String]? {
        try? CommandLineSplitter.splitStrings(multilineToOneLine(command))
    }

    /// `"10 INCR c"` -> (`"INCR c"`, 10). `count` is nil when the first word is not numeric; a numeric but invalid
    /// count (0, negative, fractional) returns the line unchanged with that number.
    public static func repeatCount(_ line: String) -> (command: String, count: Int?) {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let number = Double(first), parts.count == 2,
              !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else {
            return (line, nil)
        }
        guard number >= 1, number == number.rounded(), number <= Double(Int32.max) else { return (line, 0) }
        return (String(parts[1]), Int(number))
    }

    /// True when the first word is a number that is not a valid repeat count.
    public static func hasInvalidRepeat(_ command: String) -> Bool {
        let (_, count) = repeatCount(command)
        return count == 0
    }

    /// The inline error for a command whose repeat prefix is invalid or above `maxRepeatCount`, or nil.
    public static func invalidRepeatMessage(_ command: String) -> String? {
        let (_, count) = repeatCount(command)
        guard let count, count == 0 || count > maxRepeatCount else { return nil }
        let first = command.split(separator: " ", maxSplits: 1).first.flatMap { Double($0) } ?? 0
        guard first > Double(maxRepeatCount) else { return "The repeat count before the command isn't valid." }
        return "The repeat count cannot be larger than \(NumberFormatting.grouped(maxRepeatCount))."
    }

    // MARK: - Private

    static func logicalLines(_ script: String) -> [String] {
        let normalized = script.replacingOccurrences(of: "\r\n", with: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"\n(?=[^\s])"#) else { return [normalized] }
        let ns = normalized as NSString
        var out: [String] = []
        var last = 0
        for match in regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            last = match.range.location + match.range.length
        }

        out.append(ns.substring(from: last))
        return out
    }

    static func isParamsLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") && trimmed.contains("]")
    }

    static func removeParams(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let close = trimmed.firstIndex(of: "]") else { return trimmed }
        return String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Drops lines that are only an indented `//` comment and strips `//...` outside quotes.
    static func removeComments(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { line in
                guard let first = line.first, first.isWhitespace else { return true }
                return !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            .map(stripLineComment)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripLineComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if let q = quote {
                if c == q && previous != "\\" { quote = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            } else if c == "/", previous == "/" {
                return String(line[..<line.index(before: index)])
            }

            previous = c
            index = line.index(after: index)
        }

        return line
    }
}

/// Runs editor commands for Workbench (`.workbench`) and Vector Search (`.search`): chunked pipelines,
/// group/silent modes, per-command microsecond timing, history persistence.
@MainActor
public struct CommandExecutor {
    public let session: DatabaseSession
    public let history: CommandHistoryStore
    public let type: CommandExecutionType

    public init(session: DatabaseSession, history: CommandHistoryStore, type: CommandExecutionType = .workbench) {
        self.session = session
        self.history = history
        self.type = type
    }

    /// Executes `commands` (already parsed) and returns one execution per card (one total in group/silent mode),
    /// in script order. `client` replaces the pooled `.workbench` client, so a caller can keep connection state
    /// (MULTI, CLIENT REPLY) off the shared one. `onChunk` receives each chunk's executions as soon as they finish.
    /// A transport failure fails the whole chunk, calls `onTransportFailure`, and skips the remaining chunks. History
    /// is updated in memory per chunk and written once when the run ends; a failed write keeps the replies, flags the
    /// returned executions `isNotStored`, and reports the error to `onPersistError`. Cancelling the calling task stops
    /// before the next chunk, drops the unfinished one, saves the finished ones, and throws `CancellationError`.
    public func run(_ commands: [String], params: ExecuteParams, settings: AppSettings,
                    client: (any RedisClient)? = nil,
                    onPersistError: (@MainActor (Error) -> Void)? = nil,
                    onChunk: (@MainActor ([CommandExecution]) -> Void)? = nil,
                    onTransportFailure: (@MainActor () -> Void)? = nil) async throws -> [CommandExecution] {
        guard !commands.isEmpty else { return [] }
        let mode = params.mode ?? settings.workbenchRunQueryMode
        let resultsMode = params.resultsMode ?? settings.workbenchResultsMode
        let batchSize = params.batchSize ?? settings.workbenchBatchSize
        let runClient: any RedisClient
        if let client {
            runClient = client
        } else {
            runClient = try await session.client(context: .workbench)
        }

        let db = session.effectiveDB
        let prepared = await Self.prepareAll(commands)
        var all: [CommandExecution] = []
        var cancelled = false

        if resultsMode == .group || resultsMode == .silent {
            let (execution, transportFailed) = await runGroup(prepared, commands: commands, client: runClient,
                                                              mode: mode, resultsMode: resultsMode, db: db)
            if Task.isCancelled {
                cancelled = true
            } else {
                all = await history.stage([execution])
                onChunk?(all)
                if transportFailed { onTransportFailure?() }
            }
        } else {
            let chunkSize = batchSize > 1 ? batchSize : 1
            var start = 0
            while start < prepared.count {
                guard !Task.isCancelled else {
                    cancelled = true
                    break
                }
                let chunk = Array(prepared[start..<min(start + chunkSize, prepared.count)])
                start += chunkSize
                let (executions, transportFailed) = await runChunk(chunk, client: runClient, mode: mode, db: db)
                guard !Task.isCancelled else {
                    cancelled = true
                    break
                }
                let staged = await history.stage(executions)
                onChunk?(staged)
                all += staged
                if transportFailed {
                    onTransportFailure?()
                    break
                }
            }
        }

        do {
            try await history.flush()
        } catch {
            onPersistError?(error)
            all = all.map { execution in
                var copy = execution
                copy.isNotStored = true
                return copy
            }
        }

        if cancelled { throw CancellationError() }
        return all
    }

    // MARK: - Chunks

    struct Prepared: Sendable {
        var text: String
        var args: [Data]?
        var failure: String?
    }

    /// Prepares large scripts off the main actor to avoid blocking the UI.
    nonisolated static func prepareAll(_ commands: [String]) async -> [Prepared] {
        await Task.detached(priority: .userInitiated) { commands.map(prepare) }.value
    }

    nonisolated static func prepare(_ command: String) -> Prepared {
        let oneLine = WorkbenchScriptParser.multilineToOneLine(command)
        let split = Result { try CommandLineSplitter.split(oneLine) }
        let arguments = ((try? split.get()) ?? []).map { String(decoding: $0, as: UTF8.self) }
        if let entry = CommandRules.workbenchUnsupportedMatch(oneLine, arguments: arguments) {
            return Prepared(text: oneLine, failure: CommandRules.workbenchErrorMessage(entry))
        }

        if let message = WorkbenchScriptParser.invalidRepeatMessage(oneLine) {
            return Prepared(text: oneLine, failure: message)
        }

        do {
            let args = try split.get()
            guard !args.isEmpty else { return Prepared(text: oneLine, failure: "Invalid arguments") }
            return Prepared(text: oneLine, args: args)
        } catch {
            return Prepared(text: oneLine, failure: error.localizedDescription)
        }
    }

    private func send(_ prepared: [Prepared], client: any RedisClient) async -> (replies: [RESPValue], error: String?, micros: Int) {
        let sendable = prepared.compactMap(\.args)
        var replies: [RESPValue] = []
        var transportError: String?
        let started = DispatchTime.now().uptimeNanoseconds
        if !sendable.isEmpty {
            do {
                replies = try await client.pipeline(sendable.map(\.redisArguments))
            } catch {
                transportError = error.localizedDescription
            }
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000)
        return (replies, transportError, elapsed)
    }

    private func runChunk(_ prepared: [Prepared], client: any RedisClient, mode: RunQueryMode,
                          db: Int) async -> ([CommandExecution], Bool) {
        let (replies, transportError, elapsed) = await send(prepared, client: client)
        let results = await Self.buildResults(prepared, replies: replies, transportError: transportError, mode: mode)
        var executions: [CommandExecution] = []
        for (item, result) in zip(prepared, results) {
            executions.append(CommandExecution(databaseId: session.id, command: item.text, mode: mode,
                                               resultsMode: .default, type: type, result: [result],
                                               executionTime: item.failure == nil ? max(elapsed, 1) : 0, db: db))
        }

        return (executions, transportError != nil)
    }

    private func runGroup(_ prepared: [Prepared], commands: [String], client: any RedisClient, mode: RunQueryMode,
                          resultsMode: ResultsMode, db: Int) async -> (CommandExecution, Bool) {
        let (replies, transportError, elapsed) = await send(prepared, client: client)
        let results = await Self.buildResults(prepared, replies: replies, transportError: transportError, mode: mode)
        var items: [GroupItemResult] = []
        for (item, single) in zip(prepared, results) {
            let node: ReplyNode
            if case .reply(let n) = single.response { node = n } else { node = .null }
            items.append(GroupItemResult(command: item.text, response: node, status: single.status))
        }

        let success = items.filter { $0.status == .success }.count
        let summary = ResultsSummary(total: items.count, success: success, fail: items.count - success)
        let kept = resultsMode == .silent ? items.filter { $0.status == .fail } : items
        let execution = CommandExecution(databaseId: session.id, command: commands.joined(separator: "\r\n"),
                                         mode: mode, resultsMode: resultsMode, type: type, summary: summary,
                                         result: [CommandExecutionResult(status: .success, response: .group(kept))],
                                         executionTime: max(elapsed, 1), db: db)
        return (execution, transportError != nil)
    }

    /// Builds one result per prepared command off the main actor because large replies take seconds.
    private nonisolated static func buildResults(_ prepared: [Prepared], replies: [RESPValue], transportError: String?,
                                                 mode: RunQueryMode) async -> [CommandExecutionResult] {
        await Task.detached(priority: .userInitiated) {
            var out: [CommandExecutionResult] = []
            out.reserveCapacity(prepared.count)
            var replyIndex = 0
            for item in prepared {
                if let failure = item.failure {
                    out.append(CommandExecutionResult(status: .fail, response: .reply(.error(failure))))
                } else if let transportError {
                    out.append(CommandExecutionResult(status: .fail, response: .reply(.error(transportError))))
                    replyIndex += 1
                } else {
                    let reply = replyIndex < replies.count ? replies[replyIndex] : .null
                    replyIndex += 1
                    out.append(result(reply, mode: mode, command: item))
                }
            }

            return out
        }.value
    }

    private nonisolated static func result(_ reply: RESPValue, mode: RunQueryMode, command: Prepared) -> CommandExecutionResult {
        if let error = reply.errorValue {
            return CommandExecutionResult(status: .fail, response: .reply(.error(error.message)))
        }

        let args = command.args ?? []
        let head = args.prefix(2).map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
        do {
            let node = try ReplyNodeBuilder.build(reply, mode: mode, command: head)
            return CommandExecutionResult(status: .success, response: .reply(node))
        } catch {
            return CommandExecutionResult(status: .fail, response: .reply(.error(error.localizedDescription)))
        }
    }
}
