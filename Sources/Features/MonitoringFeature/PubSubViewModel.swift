import Foundation
import Observation
import RedisCore
import RedisUI

/// Window-scoped Pub/Sub state: one dedicated PSUBSCRIBE connection, the received messages and the publish form.
@MainActor
@Observable
final class PubSubViewModel: SessionScopedObject {
    static let messageLimit = 5_000
    static let publishBadgeDuration: Duration = .seconds(3)

    typealias Connector = @MainActor @Sendable () async throws -> any PubSubTransport

    var patternInput = PubSubPatterns.defaultPattern
    private(set) var status: PubSubStatus = .unsubscribed
    private(set) var subscribedPatterns: [String] = []
    /// Arrival order (oldest first), capped at `messageLimit`.
    private(set) var messages: [PubSubEntry] = []
    /// Every message received since the last clear (drives the Clear button).
    private(set) var totalReceived = 0
    /// Why the last subscription failed or ended; the status bar then offers Resubscribe.
    var connectionError: String?
    /// True when an established subscription dropped, false when subscribing never succeeded.
    private(set) var connectionWasLost = false

    var channelInput = ""
    var messageInput = ""
    private(set) var isPublishing = false
    private(set) var publishResult: PublishResult?

    /// Newest first (the default) or oldest first; set by the Time column header.
    var sortDescending = true

    @ObservationIgnored let session: DatabaseSession
    @ObservationIgnored private let connector: Connector
    @ObservationIgnored private let queue = PendingQueue<PubSubEvent>(capacity: PubSubViewModel.messageLimit,
                                                                        dropGeneration: { $0.droppableGeneration })
    @ObservationIgnored private var transport: (any PubSubTransport)?
    @ObservationIgnored private var readerTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var publishBadgeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timestampCache: [UUID: String] = [:]
    @ObservationIgnored private var timestampCacheKey = ""

    init(session: DatabaseSession, connector: Connector? = nil) {
        self.session = session
        self.connector = connector ?? { [weak session] in
            guard let session else { throw MonitoringError.noConnection }
            return try await PubSubViewModel.openConnection(session: session)
        }
    }

    /// Pub/Sub needs one connection even on clusters: PUBLISH is broadcast to every node, so subscribing on
    /// each node would deliver every message once per node. The first reachable primary is used.
    static func openConnection(session: DatabaseSession) async throws -> any PubSubTransport {
        guard session.isCluster else {
            return try await session.makeDedicatedConnection(connectTimeout: MonitoringTimeouts.connectSeconds, retry: RetryPolicy.none)
        }
        var lastError: Error = MonitoringError.noConnection
        for node in try await session.nodes(role: .primary) {
            do {
                return try await session.makeDedicatedConnection(
                    node: node.endpoint, connectTimeout: MonitoringTimeouts.connectSeconds, retry: RetryPolicy.none)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Derived state

    var isSubscribed: Bool { status == .subscribed }
    var isEmptyState: Bool { status == .unsubscribed && messages.isEmpty }
    var canClear: Bool { totalReceived > 0 }
    var headerPatternsText: String { PubSubPatterns.headerText(displayedPatterns) }
    var patternsTooltip: String { PubSubPatterns.tooltip(displayedPatterns) }
    var showsShardedWarning: Bool { session.isCluster && session.capabilities.isVersion(atLeast: "7.0") }

    var displayedPatterns: [String] {
        subscribedPatterns.isEmpty ? PubSubPatterns.parse(patternInput) : subscribedPatterns
    }

    var rows: [PubSubEntry] { sortDescending ? messages.reversed() : messages }

    var statusText: String {
        let state: String
        switch status {
        case .subscribing: state = "Subscribing…"
        case .unsubscribing: state = "Unsubscribing…"
        case .unsubscribed:
            if connectionError == nil {
                state = "Not subscribed"
            } else {
                state = connectionWasLost ? "Connection lost" : "Could not subscribe"
            }
        case .subscribed: state = PubSubPatterns.subscribedText(subscribedPatterns)
        }

        guard totalReceived > 0 else { return state }
        let count = totalReceived == 1 ? "1 message" : "\(NumberFormatting.grouped(totalReceived)) messages"
        if totalReceived > messages.count {
            return "\(state) · \(count) (showing the last \(NumberFormatting.grouped(messages.count)))"
        }

        return "\(state) · \(count)"
    }

    func timestampText(_ entry: PubSubEntry) -> String {
        let app = session.services.settings.app
        let key = app.dateFormat + "|" + app.timezone.rawValue
        if key != timestampCacheKey || timestampCache.count > Self.messageLimit * 2 {
            timestampCache.removeAll(keepingCapacity: true)
            timestampCacheKey = key
        }

        if let cached = timestampCache[entry.id] { return cached }
        let text = TimestampFormatter.format(date: entry.receivedAt, pattern: app.dateFormat, timeZone: app.timezone.timeZone)
        timestampCache[entry.id] = text
        return text
    }

    // MARK: - Subscribe

    func toggleSubscription() async {
        if status.isActive { await unsubscribe() } else { await subscribe() }
    }

    func subscribe() async {
        guard status == .unsubscribed else { return }
        patternInput = PubSubPatterns.normalizedInput(patternInput)
        let patterns = PubSubPatterns.parse(patternInput)
        status = .subscribing
        connectionError = nil
        connectionWasLost = false
        generation += 1
        let myGeneration = generation
        let connector = self.connector
        do {
            let transport = try await withConnectTimeout(discard: { await $0.close() }) { try await connector() }
            guard status == .subscribing, generation == myGeneration else {
                await transport.close()
                return
            }
            self.transport = transport
            subscribedPatterns = patterns
            let stream = await transport.psubscribe(patterns.map { Data($0.utf8) })
            startReader(stream: stream, generation: myGeneration)
            startFlushLoop()
        } catch {
            guard generation == myGeneration else { return }
            status = .unsubscribed
            subscribedPatterns = []
            connectionError = MonitoringError.noConnectionMessage
            session.toasts.error(Self.describe(error), title: MonitoringError.noConnectionMessage)
        }
    }

    func unsubscribe() async {
        guard status.isActive else { return }
        status = .unsubscribing
        flushPending()
        await stopStreaming()
        status = .unsubscribed
        subscribedPatterns = []
    }

    func resubscribe() async {
        connectionError = nil
        await subscribe()
    }

    func clearMessages() {
        messages.removeAll()
        totalReceived = 0
        timestampCache.removeAll()
    }

    func patternFieldDidLoseFocus() {
        patternInput = PubSubPatterns.normalizedInput(patternInput)
    }

    // MARK: - Publish

    func publish() async {
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        do {
            let reply = try await session.execute(["PUBLISH", .data(Data(channelInput.utf8)), .data(Data(messageInput.utf8))])
            let receivers = reply.intValue.map(Int.init)
            messageInput = ""
            let result = PublishResult(receivers: session.isCluster ? nil : (receivers ?? 0))
            showPublishResult(result)
        } catch {
            session.toasts.error(error)
        }
    }

    func usePublishChannel(_ entry: PubSubEntry) {
        channelInput = entry.channelFullText
    }

    private func showPublishResult(_ result: PublishResult) {
        publishResult = result
        publishBadgeTask?.cancel()
        publishBadgeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.publishBadgeDuration)
            guard !Task.isCancelled, let self, self.publishResult?.id == result.id else { return }
            self.publishResult = nil
        }
    }

    // MARK: - Streaming

    private func startReader(stream: AsyncThrowingStream<PubSubMessage, Error>, generation: Int) {
        let queue = self.queue
        readerTask = Task.detached(priority: .userInitiated) {
            do {
                for try await message in stream {
                    switch message.kind {
                    case .psubscribe, .subscribe:
                        queue.append(.confirmed(generation: generation))
                    case .message, .pmessage, .smessage:
                        queue.append(.message(generation: generation, PubSubEntry(message)))
                    default:
                        break
                    }
                }

                queue.append(.ended(generation: generation, errorMessage: nil))
            } catch {
                queue.append(.ended(generation: generation, errorMessage: PubSubViewModel.describe(error)))
            }
        }
    }

    private func startFlushLoop() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MonitoringTimeouts.flushInterval)
                guard !Task.isCancelled, let self else { return }
                self.flushPending()
            }
        }
    }

    func flushPending() {
        let batch = queue.drainBatch()
        let events = batch.items
        let dropped = batch.droppedCount(generation: generation)
        guard !events.isEmpty || dropped > 0 else { return }
        var newEntries: [PubSubEntry] = []
        var ended = false
        var endedMessage: String?
        for event in events {
            switch event {
            case .confirmed(let g) where g == generation:
                if status == .subscribing { status = .subscribed }
            case .message(let g, let entry) where g == generation:
                newEntries.append(entry)
            case .ended(let g, let message) where g == generation:
                ended = true
                endedMessage = message
            default:
                break
            }
        }

        if dropped > 0 { totalReceived += dropped }
        if !newEntries.isEmpty {
            totalReceived += newEntries.count
            CappedBuffer.append(newEntries, to: &messages, cap: Self.messageLimit)
        }

        if ended, status.isActive {
            let wasConfirmed = status == .subscribed
            Task { await self.connectionLost(message: wasConfirmed ? nil : endedMessage) }
        }
    }

    /// `message` carries the server's reason when the subscription failed before it was confirmed.
    private func connectionLost(message: String?) async {
        guard status.isActive else { return }
        await stopStreaming()
        status = .unsubscribed
        subscribedPatterns = []
        connectionError = message ?? MonitoringError.noConnectionMessage
        connectionWasLost = message == nil
        session.toasts.error(message ?? "The subscription ended because the connection was lost.",
                             title: MonitoringError.noConnectionMessage)
    }

    private func stopStreaming() async {
        generation += 1
        readerTask?.cancel()
        readerTask = nil
        flushTask?.cancel()
        flushTask = nil
        _ = queue.drain()
        let transport = self.transport
        self.transport = nil
        await transport?.close()
    }

    func sessionConnectionDidReset() async {
        await stopStreaming()
        status = .unsubscribed
        subscribedPatterns = []
    }

    func sessionWillClose() async {
        publishBadgeTask?.cancel()
        await stopStreaming()
        status = .unsubscribed
    }

    nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
