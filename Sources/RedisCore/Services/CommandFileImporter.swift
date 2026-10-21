import Foundation

/// Imports a text file of redis-cli commands (bulk upload, sample data).
/// Commands are sent in pipelines of 10 000 on a dedicated client that is closed afterwards, so connection-state
/// commands in the file (SELECT, AUTH, CLIENT, MULTI, SUBSCRIBE, READONLY) never reach the shared pooled clients.
/// On clusters the client routes each command to its slot owner.
/// The file is read one batch at a time off the main actor, so only one batch of parsed commands is in memory.
@MainActor
public struct CommandFileImporter {
    public nonisolated static let batchSize = 10_000
    /// Error lines kept in the summary.
    public nonisolated static let maxErrors = 500
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// Progress stream ending with `isFinished == true`. Cancelling the consumer stops after the current batch.
    public func run(_ fileContents: Data) -> AsyncStream<BulkImportSummary> {
        let session = self.session
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.importCommands(fileContents, session: session, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs the import to completion and returns its final summary.
    public func importAll(_ fileContents: Data) async -> BulkImportSummary {
        var last = BulkImportSummary(isFinished: true)
        for await summary in run(fileContents) { last = summary }
        return last
    }

    // MARK: - Import loop

    private nonisolated static func importCommands(_ data: Data, session: DatabaseSession,
                                                   continuation: AsyncStream<BulkImportSummary>.Continuation) async {
        let start = Date()
        var summary = BulkImportSummary()
        var client: (any RedisClient)?
        var clientError: Error?
        var offset = 0

        while !Task.isCancelled {
            let commands = nextBatch(in: data, offset: &offset, summary: &summary)
            if commands.isEmpty { break }
            do {
                if client == nil, clientError == nil {
                    do {
                        client = try await session.makeDedicatedClient()
                    } catch {
                        clientError = error
                    }
                }

                if let clientError { throw clientError }
                guard let client else { throw RedisClientError.notConnected }
                let replies = try await client.pipeline(commands)
                for (index, reply) in replies.enumerated() {
                    if let error = reply.errorValue {
                        summary.failed += 1
                        note("\(describe(commands[index])): \(error.message)", in: &summary)
                    } else {
                        summary.succeeded += 1
                    }
                }

                summary.processed += commands.count
            } catch {
                summary.processed += commands.count
                summary.failed += commands.count
                note(error.localizedDescription, in: &summary)
            }

            summary.duration = Date().timeIntervalSince(start)
            continuation.yield(summary)
        }

        await client?.close()
        summary.duration = Date().timeIntervalSince(start)
        summary.isFinished = true
        continuation.yield(summary)
        continuation.finish()
    }

    /// Parses lines from `offset` until `batchSize` commands are collected or the data ends, and advances `offset`.
    /// Lines that fail to parse are counted as failed in `summary`. An empty result means the data is exhausted.
    nonisolated static func nextBatch(in data: Data, offset: inout Int, summary: inout BulkImportSummary,
                                      limit: Int = batchSize) -> [[Data]] {
        var batch: [[Data]] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            while batch.count < limit, let line = nextLineBytes(in: bytes, offset: &offset) {
                let trimmed = trimmingWhitespace(line)
                guard !trimmed.isEmpty else { continue }
                do {
                    let args = try CommandLineSplitter.split(bytes: Array(trimmed))
                    if !args.isEmpty { batch.append(args) }
                } catch {
                    summary.processed += 1
                    summary.failed += 1
                    note("\(String(decoding: trimmed, as: UTF8.self).prefix(100)): \(error.localizedDescription)",
                         in: &summary)
                }
            }
        }
        return batch
    }

    /// The next UTF-8 line (`\n`, `\r\n` or `\r` separated) at `offset`, or nil at the end of the data.
    nonisolated static func nextLine(in bytes: UnsafeBufferPointer<UInt8>, offset: inout Int) -> String? {
        nextLineBytes(in: bytes, offset: &offset).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The raw bytes of the next line, so arguments that are not valid UTF-8 reach Redis unchanged.
    nonisolated static func nextLineBytes(in bytes: UnsafeBufferPointer<UInt8>, offset: inout Int) -> ArraySlice<UInt8>? {
        guard offset < bytes.count else { return nil }
        let start = offset
        var i = start
        while i < bytes.count, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
        let line = ArraySlice(UnsafeBufferPointer(rebasing: bytes[start..<i]))
        if i < bytes.count {
            if bytes[i] == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
            i += 1
        }

        offset = i
        return line
    }

    // MARK: - Helpers

    nonisolated static func trimmingWhitespace(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || (0x09...0x0D).contains(b) }
        guard let first = line.firstIndex(where: { !isSpace($0) }),
              let last = line.lastIndex(where: { !isSpace($0) }) else { return [] }
        return line[first...last]
    }

    nonisolated static func describe(_ args: [Data]) -> String {
        let text = args.prefix(3).map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
        return String(text.prefix(100))
    }

    nonisolated static func note(_ message: String, in summary: inout BulkImportSummary) {
        if summary.errors.count < maxErrors { summary.errors.append(message) }
    }
}
