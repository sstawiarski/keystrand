import Foundation
import Network
import RedisCore
import Synchronization

/// Scripted RESP server on a free `127.0.0.1` port. Each connection answers commands in order.
/// If `handler` returns nil, `PING` returns `PONG` and `INFO` reports a non-loading Redis 7.2 server.
/// `HELLO` returns an unknown-command error; all other commands return `OK`.
public final class FakeRedisServer: Sendable {
    public typealias Handler = @Sendable ([String]) async -> RESPValue?

    public let port: Int
    public var endpoint: RedisEndpoint { RedisEndpoint(host: "127.0.0.1", port: port) }

    private let listener: NWListener
    private let handler: Handler
    private let state = Mutex(State())

    private struct State {
        var received: [[String]] = []
        var connections: [NWConnection] = []
    }

    private init(listener: NWListener, port: Int, handler: @escaping Handler) {
        self.listener = listener
        self.port = port
        self.handler = handler
    }

    public static func start(handler: @escaping Handler = { _ in nil }) async throws -> FakeRedisServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "keystrand.tests.fake-redis")
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<Int, Error>?
                switch state {
                case .ready: result = .success(Int(listener.port?.rawValue ?? 0))
                case .failed(let error): result = .failure(error)
                default: result = nil
                }

                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let server = FakeRedisServer(listener: listener, port: port, handler: handler)
        listener.newConnectionHandler = { [weak server] connection in server?.accept(connection, queue: queue) }
        return server
    }

    /// Every command received so far, in arrival order.
    public var received: [[String]] { state.withLock { $0.received } }

    /// Commands received whose name (uppercased) is `name`.
    public func received(_ name: String) -> [[String]] {
        received.filter { $0.first?.uppercased() == name.uppercased() }
    }

    /// Closes every accepted connection; the listener keeps accepting new ones.
    public func dropConnections() {
        let open = state.withLock { state in
            defer { state.connections.removeAll() }
            return state.connections
        }
        for connection in open { connection.cancel() }
    }

    public func stop() {
        dropConnections()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection, queue: DispatchQueue) {
        state.withLock { $0.connections.append(connection) }
        let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: continuation.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, into: continuation)
        Task { [weak self] in
            var parser = RESPParser()
            for await chunk in chunks {
                parser.feed(chunk)
                while let value = try? parser.next() {
                    guard let self else { return }
                    let command = (value.arrayValue ?? []).map { $0.stringValue ?? "" }
                    self.state.withLock { $0.received.append(command) }
                    let reply = await self.handler(command) ?? Self.defaultReply(command)
                    connection.send(content: RESPEncoder.encodeValue(reply), completion: .idempotent)
                }
            }
        }
    }

    private func receive(on connection: NWConnection, into continuation: AsyncStream<Data>.Continuation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { continuation.yield(data) }
            if error != nil || isComplete {
                continuation.finish()
            } else {
                self?.receive(on: connection, into: continuation)
            }
        }
    }

    private static func defaultReply(_ command: [String]) -> RESPValue {
        switch command.first?.uppercased() {
        case "PING": return .simpleString("PONG")
        case "INFO": return .bulk("# Server\r\nredis_version:7.2.0\r\nredis_mode:standalone\r\nloading:0\r\n")
        case "HELLO": return .error(RESPError("ERR unknown command 'HELLO'"))
        default: return .simpleString("OK")
        }
    }
}
