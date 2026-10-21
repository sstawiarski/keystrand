import Foundation
import RESP

/// Scripted client for tests and SwiftUI previews.
/// Tries a non-nil `handler` result, FIFO queued replies by full command then command name,
/// and `responses` by full command (`GET foo`) then uppercase command name (`GET`). Returns `.null` if none match.
public actor MockRedisClient: RedisClient {
    public typealias Handler = @Sendable ([Data]) -> RESPValue?

    public private(set) var executedCommands: [[Data]] = []
    public private(set) var isClosed = false
    /// Number of `pipeline` calls (a single `execute` counts as one batch too).
    public private(set) var batchCount = 0
    private var responses: [String: RESPValue]
    private var queued: [String: [RESPValue]] = [:]
    private let handler: Handler?
    private var transportError: RedisClientError?

    public init(responses: [String: RESPValue] = [:], handler: Handler? = nil) {
        self.responses = responses
        self.handler = handler
    }

    public func setResponse(_ value: RESPValue, for command: String) {
        responses[command] = value
    }

    /// Replies returned once each, in order, for `command` (full text or command name).
    public func enqueue(_ values: [RESPValue], for command: String) {
        queued[command, default: []].append(contentsOf: values)
    }

    /// Makes every following call throw `error` (simulates a dropped socket); `nil` restores normal behavior.
    public func setTransportError(_ error: RedisClientError?) {
        transportError = error
    }

    /// Executed commands as space-joined UTF-8 text (`"SET k v"`).
    public var executedCommandStrings: [String] {
        executedCommands.map { $0.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ") }
    }

    public func resetRecording() {
        executedCommands.removeAll()
        batchCount = 0
    }

    public func execute(_ args: [RedisArgument]) async throws -> RESPValue {
        if let transportError { throw transportError }
        batchCount += 1
        let reply = respond(to: args)
        if case .error(let e) = reply { throw RedisClientError.server(e) }
        return reply
    }

    public func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue] {
        if let transportError { throw transportError }
        batchCount += 1
        return commands.map(respond(to:))
    }

    public func close() async {
        isClosed = true
    }

    private func respond(to args: [RedisArgument]) -> RESPValue {
        let raw = args.map(\.data)
        executedCommands.append(raw)
        if let handler, let reply = handler(raw) { return reply }
        let text = raw.map { String(decoding: $0, as: UTF8.self) }
        let full = text.joined(separator: " ")
        let name = text.first?.uppercased() ?? ""
        for key in [full, name] {
            if var values = queued[key], !values.isEmpty {
                let reply = values.removeFirst()
                queued[key] = values
                return reply
            }
        }

        if let reply = responses[full] { return reply }
        if let reply = responses[name] { return reply }
        return .null
    }
}
