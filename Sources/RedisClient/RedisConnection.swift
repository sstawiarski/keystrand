import Foundation
import Network
import RESP

/// Standalone Redis connection over `NWConnection` with optional TLS.
/// The handshake sends HELLO/AUTH, CLIENT SETNAME and SELECT for nonzero `dbIndex`, then optionally waits for INFO `loading:0`.
/// Commands execute FIFO; pipelines write all commands before reading replies. Subscribe and MONITOR modes reject other commands.
/// Dropped connections reconnect on the next command. In-flight commands fail and are never resent.
/// `close()` is terminal until an explicit `connect()`.
public actor RedisConnection: RedisClient {
    /// Rebuilds the connection config before each reconnect attempt (pre-connect script, SSH tunnel restart,
    /// sentinel master re-resolution).
    public typealias ReconnectConfigProvider = @Sendable () async throws -> RedisConnectionConfig

    /// The config the connection was created with.
    public let config: RedisConnectionConfig
    /// Config used for the next connection attempt (updated by the reconnect provider).
    private var active: RedisConnectionConfig
    public private(set) var isConnected = false
    /// Logical database currently selected on this socket (tracks `SELECT`).
    public private(set) var selectedDB: Int
    /// Protocol negotiated with `HELLO` (RESP2 unless `config.protocolVersion == .resp3` and the server agreed).
    public private(set) var negotiatedProtocol: RESPProtocolVersion = .resp2

    private enum Phase {
        case idle
        case connecting(Task<Void, Error>)
        case connected
        case closed

        var isClosed: Bool {
            if case .closed = self { true } else { false }
        }
    }

    private enum Mode {
        case normal
        case subscribed
        /// Unsubscribe sent after the stream ended; confirmation frames are dropped until the count is 0.
        case draining
        case monitorStarting
        case monitoring
    }

    private final class PendingRequest {
        let id: UInt64
        let expected: Int
        var replies: [RESPValue] = []
        var continuation: CheckedContinuation<[RESPValue], Error>?
        var timeoutTask: Task<Void, Never>?

        init(id: UInt64, expected: Int, continuation: CheckedContinuation<[RESPValue], Error>) {
            self.id = id
            self.expected = expected
            self.continuation = continuation
            replies.reserveCapacity(expected)
        }

        func resume(_ result: Result<[RESPValue], Error>) {
            timeoutTask?.cancel()
            timeoutTask = nil
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private struct Subscription {
        let id: UUID
        let continuation: AsyncThrowingStream<PubSubMessage, Error>.Continuation
        var channels: Set<Data>
        var patterns: Set<Data>
    }

    private struct MonitorSession {
        let id: UUID
        let continuation: AsyncThrowingStream<MonitorLine, Error>.Continuation
    }

    private var phase: Phase = .idle
    private var mode: Mode = .normal
    private var transport: NWTransport?
    private var generation = 0
    private var readerTask: Task<Void, Never>?
    private var parser = RESPParser()
    private var pending: [PendingRequest] = []
    private var pendingHead = 0
    private var nextRequestID: UInt64 = 0
    private var subscription: Subscription?
    private var monitorSession: MonitorSession?
    private var attachedTunnels: [SSHTunnel] = []
    private var reconnectProvider: ReconnectConfigProvider?

    public init(config: RedisConnectionConfig) {
        self.config = config
        self.active = config
        self.selectedDB = config.dbIndex
    }

    /// Creates and connects in one step. Cancelling the calling task closes the connection and throws.
    public static func connect(config: RedisConnectionConfig) async throws -> RedisConnection {
        let connection = RedisConnection(config: config)
        try await connection.connectOwned()
        return connection
    }

    /// Closes this caller-owned connection on cancellation so an abandoned connect cannot finish in the background.
    func connectOwned() async throws {
        do {
            try await withTaskCancellationHandler {
                try await connect()
            } onCancel: {
                Task { await self.close() }
            }
            if Task.isCancelled { throw RedisClientError.cancelled }
        } catch {
            await close()
            throw error
        }
    }

    /// Opens the socket and runs the handshake. Retries per `active.retry`.
    public func connect() async throws {
        switch phase {
        case .connected where transport != nil: return
        case .connecting(let task): return try await task.value
        default: break
        }

        let task = Task { try await self.connectWithRetry() }
        phase = .connecting(task)
        do {
            try await task.value
            if case .connecting = phase { phase = .connected }
        } catch {
            if case .connecting = phase { phase = .idle }
            throw error
        }
    }

    /// SSH tunnels started for this connection; stopped by `close()`.
    func attach(tunnels: [SSHTunnel]) {
        attachedTunnels.append(contentsOf: tunnels)
    }

    /// Installs a provider called before every later connection attempt (not the one already made).
    public func setReconnectProvider(_ provider: ReconnectConfigProvider?) {
        reconnectProvider = provider
    }

    // MARK: - Commands

    public func execute(_ args: [RedisArgument]) async throws -> RESPValue {
        let reply = try await pipeline([args]).first ?? .null
        if case .error(let e) = reply { throw RedisClientError.server(e) }
        return reply
    }

    public func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        guard acceptsCommands else {
            throw RedisClientError.invalidConfiguration("The connection is in Pub/Sub or MONITOR mode.")
        }
        try await ensureConnected()
        let replies = try await send(commands, timeout: active.commandTimeout)
        trackSelect(commands, replies)
        return replies
    }

    /// `execute` with an explicit timeout (seconds) overriding `active.commandTimeout`.
    public func execute(_ args: [RedisArgument], timeout: TimeInterval?) async throws -> RESPValue {
        guard acceptsCommands else {
            throw RedisClientError.invalidConfiguration("The connection is in Pub/Sub or MONITOR mode.")
        }
        try await ensureConnected()
        let reply = try await send([args], timeout: timeout).first ?? .null
        trackSelect([args], [reply])
        if case .error(let e) = reply { throw RedisClientError.server(e) }
        return reply
    }

    /// `SELECT db` and update `selectedDB`.
    public func select(db: Int) async throws {
        _ = try await execute(["SELECT", .int(Int64(db))])
        selectedDB = db
    }

    public func ping() async throws -> Bool {
        try await execute(["PING"]).stringValue?.uppercased() == "PONG"
    }

    /// Returns once the socket is cancelled and the attached SSH tunnels have exited.
    public func close() async {
        if case .connecting(let task) = phase { task.cancel() }
        phase = .closed
        let closing = transport
        let tunnels = attachedTunnels
        attachedTunnels.removeAll()
        tearDown(error: .connectionClosed, endStreamsCleanly: true)
        await closing?.waitUntilCancelled()
        for tunnel in tunnels { await tunnel.stop() }
    }

    // MARK: - Streaming (dedicated connections only)

    /// Enters subscribe mode (`SUBSCRIBE` / `PSUBSCRIBE`). Handles RESP2 `message`/`pmessage` arrays and
    /// RESP3 push frames. The stream finishes when the connection closes; cancelling the consuming task
    /// unsubscribes. Subscribe/unsubscribe confirmations are delivered too (`kind` tells them apart).
    /// Starting a new subscription on the same connection finishes the previous stream.
    public func subscribe(channels: [Data] = [], patterns: [Data] = []) -> AsyncThrowingStream<PubSubMessage, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PubSubMessage.self,
                                                                   bufferingPolicy: .bufferingNewest(100_000))
        guard !channels.isEmpty || !patterns.isEmpty else {
            continuation.finish(throwing: RedisClientError.invalidConfiguration("Nothing to subscribe to."))
            return stream
        }
        let id = UUID()
        subscription?.continuation.finish()
        subscription = Subscription(id: id, continuation: continuation, channels: Set(channels), patterns: Set(patterns))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.subscriptionEnded(id) }
        }
        Task { await self.startSubscription(id, channels: channels, patterns: patterns) }
        return stream
    }

    /// Subscribes to patterns with `PSUBSCRIBE`.
    public func psubscribe(_ patterns: [Data]) -> AsyncThrowingStream<PubSubMessage, Error> {
        subscribe(channels: [], patterns: patterns)
    }

    /// Unsubscribes from the given channels/patterns (empty lists = all of that kind). When no
    /// subscriptions remain the stream finishes and the connection returns to normal mode.
    public func unsubscribe(channels: [Data] = [], patterns: [Data] = []) async throws {
        guard let transport, let current = subscription, case .subscribed = mode else { return }
        var payload = Data()
        let all = channels.isEmpty && patterns.isEmpty
        if all ? !current.channels.isEmpty : !channels.isEmpty {
            RESPEncoder.append([RedisArgument.string("UNSUBSCRIBE")] + channels.map(RedisArgument.data), to: &payload)
        }

        if all ? !current.patterns.isEmpty : !patterns.isEmpty {
            RESPEncoder.append([RedisArgument.string("PUNSUBSCRIBE")] + patterns.map(RedisArgument.data), to: &payload)
        }

        if !payload.isEmpty { transport.send(payload) }
    }

    public func punsubscribe(_ patterns: [Data] = []) async throws {
        try await unsubscribe(channels: [], patterns: patterns)
    }

    /// Sends `MONITOR` and streams parsed lines until cancelled or closed. Cancelling closes the connection.
    public func monitor() -> AsyncThrowingStream<MonitorLine, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MonitorLine.self,
                                                                   bufferingPolicy: .bufferingNewest(100_000))
        let id = UUID()
        monitorSession?.continuation.finish()
        monitorSession = MonitorSession(id: id, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.monitorEnded(id) }
        }
        Task { await self.startMonitor(id) }
        return stream
    }

    // MARK: - Connect / handshake

    private var acceptsCommands: Bool {
        switch mode {
        case .normal, .draining: return true
        default: return false
        }
    }

    /// Reconnects a dropped connection. Throws `notConnected` after `close()`.
    func ensureConnected() async throws {
        switch phase {
        case .connected where transport != nil: return
        case .closed: throw RedisClientError.notConnected
        default: try await connect()
        }
    }

    private func connectWithRetry() async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try Task.checkCancellation()
                if let reconnectProvider {
                    let fresh = try await reconnectProvider()
                    try Task.checkCancellation()
                    active = fresh
                }

                try await openAndHandshake()
                return
            } catch {
                resetTransport(error: (error as? RedisClientError) ?? .connectionClosed)
                guard Self.isRetryable(error), attempt < active.retry.maxAttempts else { throw error }
                try await Task.sleep(nanoseconds: UInt64(active.retry.delayMs(forAttempt: attempt)) * 1_000_000)
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? RedisClientError else { return false }
        switch error {
        case .connectionFailed, .connectionClosed, .timeout: return true
        default: return false
        }
    }

    private func openAndHandshake() async throws {
        let transport = try NWTransport(config: active)
        try await transport.start(timeout: active.connectTimeout)
        if Task.isCancelled || phase.isClosed {
            transport.close(nil)
            throw RedisClientError.cancelled
        }

        generation += 1
        let currentGeneration = generation
        self.transport = transport
        parser.reset()
        mode = .normal
        let events = transport.events
        readerTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event, generation: currentGeneration)
            }
        }
        isConnected = true
        try await handshake()
    }

    private func handshake() async throws {
        let timeout = max(active.connectTimeout, 1)
        let password = active.password.flatMap { $0.isEmpty ? nil : $0 }
        let username = active.username.flatMap { $0.isEmpty ? nil : $0 }

        if active.protocolVersion == .resp3 {
            var hello: [RedisArgument] = ["HELLO", "3"]
            if let password { hello += ["AUTH", .string(username ?? "default"), .string(password)] }
            let reply = try await send([hello], timeout: timeout)[0]
            if case .error(let e) = reply {
                if Self.isAuthFailure(e) { throw RedisClientError.authenticationFailed(e.message) }
                negotiatedProtocol = .resp2
                try await authenticate(username: username, password: password, timeout: timeout)
            } else {
                negotiatedProtocol = .resp3
            }
        } else {
            negotiatedProtocol = .resp2
            try await authenticate(username: username, password: password, timeout: timeout)
        }

        var setup: [[RedisArgument]] = []
        if let name = active.clientName, !name.isEmpty {
            setup.append(["CLIENT", "SETNAME", .string(Self.sanitizedClientName(name))])
        }

        if selectedDB > 0 { setup.append(["SELECT", .int(Int64(selectedDB))]) }
        if !setup.isEmpty {
            let replies = try await send(setup, timeout: timeout)
            if selectedDB > 0, case .error(let e) = replies.last ?? .null {
                throw RedisClientError.server(e)
            }
        }

        if active.readyCheck { try await waitUntilLoaded() }
    }

    private func authenticate(username: String?, password: String?, timeout: TimeInterval) async throws {
        guard let password else { return }
        var auth: [RedisArgument] = ["AUTH"]
        if let username { auth.append(.string(username)) }
        auth.append(.string(password))
        let reply = try await send([auth], timeout: timeout)[0]
        guard case .error(let e) = reply else { return }
        let message = e.message.lowercased()
        if message.contains("without any password configured") || message.contains("no password is set") { return }
        if Self.isAuthFailure(e) { throw RedisClientError.authenticationFailed(e.message) }
        throw RedisClientError.server(e)
    }

    private static func isAuthFailure(_ e: RESPError) -> Bool {
        let message = e.message
        return e.code == "WRONGPASS" || e.code == "NOAUTH" || message == "ERR invalid password"
            || message.contains("invalid username-password pair")
    }

    /// Client names may not contain spaces or newlines.
    static func sanitizedClientName(_ name: String) -> String {
        String(name.map { $0.isWhitespace ? "-" : $0 })
    }

    private func waitUntilLoaded() async throws {
        let deadline = Date().addingTimeInterval(max(active.connectTimeout, 5))
        while true {
            let reply = try await send([["INFO", "persistence"]], timeout: max(active.connectTimeout, 1))[0]
            guard case .bulkString(let data?) = reply else { return }
            let text = String(decoding: data, as: UTF8.self)
            guard text.contains("loading:1") else { return }
            if Date() > deadline { throw RedisClientError.timeout }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: - Request queue

    private func send(_ commands: [[RedisArgument]], timeout: TimeInterval?) async throws -> [RESPValue] {
        guard let transport else { throw RedisClientError.notConnected }
        var payload = Data()
        for command in commands { RESPEncoder.append(command, to: &payload) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RESPValue], Error>) in
            nextRequestID &+= 1
            let requestID = nextRequestID
            let request = PendingRequest(id: requestID, expected: commands.count, continuation: continuation)
            pending.append(request)
            if let timeout, timeout > 0 {
                request.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.expireRequest(id: requestID)
                }
            }

            transport.send(payload)
        }
    }

    /// An unanswered request fails all in-flight requests with `timeout` and drops the socket so the next command reconnects.
    private func expireRequest(id: UInt64) {
        guard pendingHead < pending.count, pending[pendingHead...].contains(where: { $0.id == id }) else { return }
        switch phase {
        case .connected:
            phase = .idle
            tearDown(error: .timeout, endStreamsCleanly: false)
        case .connecting, .idle:
            resetTransport(error: .timeout)
        case .closed:
            break
        }
    }

    private func trackSelect(_ commands: [[RedisArgument]], _ replies: [RESPValue]) {
        for (command, reply) in zip(commands, replies) {
            guard command.count == 2, case .simpleString = reply,
                  String(decoding: command[0].data, as: UTF8.self).uppercased() == "SELECT",
                  let db = Int(String(decoding: command[1].data, as: UTF8.self)) else { continue }
            selectedDB = db
        }
    }

    private func handle(_ event: TransportEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .data(let data):
            parser.feed(data)
            do {
                while let value = try parser.next() { dispatch(value) }
            } catch {
                transport?.close(.protocolError(error.localizedDescription))
            }
        case .closed(let error):
            switch phase {
            case .closed:
                tearDown(error: .connectionClosed, endStreamsCleanly: true)
            case .connecting:
                resetTransport(error: error ?? .connectionClosed)
            case .connected, .idle:
                phase = .idle
                tearDown(error: error ?? .connectionClosed, endStreamsCleanly: false)
            }
        }
    }

    private func dispatch(_ value: RESPValue) {
        if case .push = value {
            handlePubSubFrame(value)
            return
        }

        if pendingHead < pending.count {
            if mode == .subscribed || mode == .draining, PubSubFrameParser.parse(value) != nil {
                handlePubSubFrame(value)
                return
            }

            let request = pending[pendingHead]
            request.replies.append(value)
            if request.replies.count == request.expected {
                pendingHead += 1
                request.resume(.success(request.replies))
                compactPending()
            }

            return
        }

        switch mode {
        case .subscribed, .draining:
            if case .error(let e) = value {
                subscription?.continuation.finish(throwing: RedisClientError.server(e))
                subscription = nil
                mode = .normal
            } else {
                handlePubSubFrame(value)
            }
        case .monitorStarting:
            if case .error(let e) = value {
                monitorSession?.continuation.finish(throwing: RedisClientError.server(e))
                monitorSession = nil
                mode = .normal
            } else {
                mode = .monitoring
            }
        case .monitoring:
            switch value {
            case .simpleString(let line):
                if let parsed = try? MonitorLineParser.parse(line) { monitorSession?.continuation.yield(parsed) }
            case .error(let e):
                monitorSession?.continuation.finish(throwing: RedisClientError.server(e))
                monitorSession = nil
            default:
                break
            }
        case .normal:
            break
        }
    }

    private func compactPending() {
        if pendingHead == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead > 1024 {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
    }

    private func handlePubSubFrame(_ value: RESPValue) {
        guard let message = PubSubFrameParser.parse(value) else { return }
        if mode == .draining {
            if PubSubFrameParser.isConfirmation(message.kind), message.subscriptionCount == 0 { mode = .normal }
            return
        }

        guard var current = subscription else { return }
        switch message.kind {
        case .subscribe: current.channels.insert(message.channel)
        case .psubscribe: current.patterns.insert(message.channel)
        case .unsubscribe: current.channels.remove(message.channel)
        case .punsubscribe: current.patterns.remove(message.channel)
        default: break
        }

        subscription = current
        current.continuation.yield(message)
        if (message.kind == .unsubscribe || message.kind == .punsubscribe), message.subscriptionCount == 0 {
            subscription = nil
            mode = .normal
            current.continuation.finish()
        }
    }

    private func startSubscription(_ id: UUID, channels: [Data], patterns: [Data]) async {
        do {
            try await ensureConnected()
        } catch {
            if subscription?.id == id {
                subscription?.continuation.finish(throwing: error)
                subscription = nil
            }

            return
        }

        // Let a previous subscription finish unsubscribing so its confirmations do not end this stream.
        for _ in 0..<40 where mode == .draining {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if mode == .draining { resetTransport(error: .connectionClosed); try? await ensureConnected() }
        guard subscription?.id == id, let transport else { return }
        mode = .subscribed
        var payload = Data()
        if !channels.isEmpty {
            RESPEncoder.append([RedisArgument.string("SUBSCRIBE")] + channels.map(RedisArgument.data), to: &payload)
        }

        if !patterns.isEmpty {
            RESPEncoder.append([RedisArgument.string("PSUBSCRIBE")] + patterns.map(RedisArgument.data), to: &payload)
        }

        transport.send(payload)
    }

    private func subscriptionEnded(_ id: UUID) {
        guard let current = subscription, current.id == id else { return }
        subscription = nil
        guard let transport, case .subscribed = mode else { return }
        var payload = Data()
        var expectsConfirmation = false
        if !current.channels.isEmpty {
            RESPEncoder.append(["UNSUBSCRIBE"], to: &payload)
            expectsConfirmation = true
        }

        if !current.patterns.isEmpty {
            RESPEncoder.append(["PUNSUBSCRIBE"], to: &payload)
            expectsConfirmation = true
        }

        if expectsConfirmation {
            mode = .draining
            transport.send(payload)
        } else {
            // Subscribe confirmations have not arrived yet; the socket state is unknown, so drop it.
            mode = .normal
            transport.close(nil)
        }
    }

    private func startMonitor(_ id: UUID) async {
        do {
            try await ensureConnected()
        } catch {
            if monitorSession?.id == id {
                monitorSession?.continuation.finish(throwing: error)
                monitorSession = nil
            }

            return
        }

        guard monitorSession?.id == id, let transport, case .normal = mode else {
            if monitorSession?.id == id {
                monitorSession?.continuation.finish(throwing: RedisClientError.invalidConfiguration("The connection is busy."))
                monitorSession = nil
            }

            return
        }
        mode = .monitorStarting
        transport.send(RESPEncoder.encode(["MONITOR"]))
    }

    private func monitorEnded(_ id: UUID) {
        guard let current = monitorSession, current.id == id else { return }
        monitorSession = nil
        // Drops the socket because old servers cannot reliably exit MONITOR mode. Reconnects on demand.
        if case .closed = phase {} else { phase = .idle }
        tearDown(error: .connectionClosed, endStreamsCleanly: true)
    }

    /// Closes the socket and fails requests in flight; streams are left alone.
    private func resetTransport(error: RedisClientError) {
        generation += 1
        readerTask?.cancel()
        readerTask = nil
        transport?.close(nil)
        transport = nil
        isConnected = false
        parser.reset()
        mode = .normal
        let inFlight = pending[pendingHead...]
        pending.removeAll()
        pendingHead = 0
        for request in inFlight { request.resume(.failure(error)) }
    }

    /// Fails everything in flight and resets the socket state. Streams end with `error` unless `endStreamsCleanly`.
    private func tearDown(error: RedisClientError, endStreamsCleanly: Bool) {
        resetTransport(error: error)
        if let subscription {
            if endStreamsCleanly { subscription.continuation.finish() } else { subscription.continuation.finish(throwing: error) }
        }

        subscription = nil
        if let monitorSession {
            if endStreamsCleanly { monitorSession.continuation.finish() } else { monitorSession.continuation.finish(throwing: error) }
        }

        monitorSession = nil
        mode = .normal
    }
}
