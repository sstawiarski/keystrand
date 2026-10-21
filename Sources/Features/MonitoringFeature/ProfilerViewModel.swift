import Foundation
import Observation
import RedisCore

/// Window-scoped Profiler (MONITOR) state: one dedicated connection per node, a capped line list, and an
/// optional uncapped log file.
@MainActor
@Observable
final class ProfilerViewModel: SessionScopedObject {
    static let lineLimit = 10_000

    typealias Connector = @MainActor @Sendable () async throws -> [MonitorNodeConnection]

    private(set) var phase: ProfilerPhase = .idle
    /// Newest last, capped at `lineLimit`.
    private(set) var entries: [ProfilerEntry] = []
    /// Lines received since start (including those trimmed from the list).
    private(set) var totalLines = 0
    /// Bumped on every list change so views can react without diffing `entries`.
    private(set) var entriesVersion = 0
    private(set) var hasReceivedLine = false
    /// Connection lost: Resume stays disabled until reset.
    private(set) var isResumeLocked = false
    /// Error shown in the not-started view (connection failure on start).
    private(set) var startError: String?
    /// Write every line to a log file in `ProfilerLogs/` ("Save Log").
    var saveToFile = false
    private(set) var logFileURL: URL?
    var autoScroll = true
    /// Production databases confirm before MONITOR starts.
    var isConfirmingProductionStart = false
    /// Node labels of the current run (cluster), in color order.
    private(set) var nodeLabels: [String] = []

    private(set) var startedAt: Date?
    private(set) var pausedAt: Date?
    @ObservationIgnored private var runningSince: Date?
    @ObservationIgnored private var accumulatedRunning: TimeInterval = 0

    @ObservationIgnored let session: DatabaseSession
    @ObservationIgnored private let connector: Connector
    @ObservationIgnored private let queue = PendingQueue<ProfilerEvent>(capacity: ProfilerViewModel.lineLimit,
                                                                           dropGeneration: { $0.droppableGeneration })
    @ObservationIgnored private var connections: [MonitorNodeConnection] = []
    @ObservationIgnored private var readerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var logWriter: ProfilerLogFileWriter?

    init(session: DatabaseSession, connector: Connector? = nil) {
        self.session = session
        self.connector = connector ?? { [weak session] in
            guard let session else { throw MonitoringError.noConnection }
            return try await ProfilerViewModel.openConnections(session: session)
        }
    }

    /// One MONITOR connection per node: the database itself, or every cluster node (primaries and replicas).
    /// On a cluster, nodes that cannot be reached are skipped and reported; it throws only when none can.
    static func openConnections(session: DatabaseSession) async throws -> [MonitorNodeConnection] {
        guard session.isCluster else {
            let connection = try await session.makeDedicatedConnection(
                connectTimeout: MonitoringTimeouts.connectSeconds, retry: RetryPolicy.none)
            return [MonitorNodeConnection(nodeLabel: nil, transport: connection)]
        }
        var out: [MonitorNodeConnection] = []
        var failures: [String] = []
        var firstError: Error?
        for node in try await session.nodes(role: nil) {
            do {
                let connection = try await session.makeDedicatedConnection(
                    node: node.endpoint, connectTimeout: MonitoringTimeouts.connectSeconds, retry: RetryPolicy.none)
                out.append(MonitorNodeConnection(nodeLabel: node.endpoint.description, transport: connection))
            } catch {
                firstError = firstError ?? error
                failures.append("\(node.endpoint): \(error.localizedDescription)")
            }
        }
        guard !out.isEmpty else { throw firstError ?? MonitoringError.noConnection }
        if !failures.isEmpty {
            session.toasts.error("The Profiler runs without these nodes:\n" + failures.joined(separator: "\n"),
                                 title: "Some Nodes Not Profiled")
        }

        return out
    }

    // MARK: - Derived state

    var isRunning: Bool { phase == .running || phase == .starting }
    var isPaused: Bool { phase == .paused }
    var isStarted: Bool { phase.isStarted }
    var canClear: Bool { !entries.isEmpty }
    var isTrimmed: Bool { totalLines > entries.count && !entries.isEmpty }
    var isProduction: Bool { session.isProduction }
    var isCluster: Bool { session.isCluster }

    /// Running time accumulated only while MONITOR was active.
    func runningTime(now: Date = Date()) -> TimeInterval {
        accumulatedRunning + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    var pausedSummary: (start: String, paused: String, duration: String)? {
        guard let startedAt, let pausedAt else { return nil }
        let zone = timeZone
        return (ProfilerFormatting.clock(startedAt, timeZone: zone), ProfilerFormatting.clock(pausedAt, timeZone: zone),
                ProfilerFormatting.runningTime(runningTime()))
    }

    var suggestedDownloadName: String {
        ProfilerFormatting.downloadFileName(databaseName: session.config.name, start: startedAt ?? Date(), end: Date())
    }

    func nodeColorIndex(_ label: String?) -> Int? {
        guard let label else { return nil }
        return nodeLabels.firstIndex(of: label)
    }

    private var timeZone: TimeZone { session.services.settings.app.timezone.timeZone }

    // MARK: - Controls

    func start() async {
        switch phase {
        case .idle, .forbidden:
            logWriter?.discard()
            resetState(keepSaveOption: true)
            startedAt = Date()
            if saveToFile {
                do {
                    let writer = try ProfilerLogFileWriter.makeTemporary(paths: session.services.paths)
                    logWriter = writer
                    logFileURL = writer.url
                } catch {
                    session.toasts.error(error, title: "Profiler Log Not Created")
                    saveToFile = false
                }
            }

            await openStreams(isResume: false)
        case .paused:
            guard !isResumeLocked else { return }
            await openStreams(isResume: true)
        case .starting, .running:
            return
        }
    }

    func pause() async {
        guard isRunning else { return }
        flushPending()
        await stopStreams()
        markPaused()
    }

    func togglePause() async {
        if isRunning { await pause() } else if isPaused { await start() }
    }

    /// Start from the not-started state; production databases confirm first.
    func requestStart() {
        if isProduction && !phase.isStarted {
            isConfirmingProductionStart = true
        } else {
            Task { await start() }
        }
    }

    func primaryAction() {
        switch phase {
        case .idle, .forbidden: requestStart()
        case .starting, .running: Task { await pause() }
        case .paused: Task { await start() }
        }
    }

    var primaryActionTitle: String {
        switch phase {
        case .idle, .forbidden: return "Start"
        case .starting, .running: return "Pause"
        case .paused: return "Resume"
        }
    }

    var primaryActionSymbol: String {
        switch phase {
        case .idle, .forbidden: return "record.circle"
        case .starting, .running: return "pause.circle"
        case .paused: return "play.circle"
        }
    }

    var isPrimaryActionEnabled: Bool {
        switch phase {
        case .starting: return false
        case .paused: return !isResumeLocked
        default: return true
        }
    }

    var commands: ProfilerCommands {
        ProfilerCommands(title: primaryActionTitle + " Profiler", isEnabled: isPrimaryActionEnabled) { [weak self] in
            self?.primaryAction()
        }
    }

    /// Empties the list without stopping MONITOR.
    func clear() {
        entries.removeAll()
        entriesVersion += 1
    }

    /// Stops, deletes the log file, and returns to the not-started view.
    func reset() async {
        await stopStreams()
        logWriter?.discard()
        resetState(keepSaveOption: true)
        savedLogLineCount = nil
        pendingDiscard = nil
    }

    @ObservationIgnored var onClose: (@MainActor () -> Void)?

    func close() async {
        await reset()
        if let onClose { onClose() } else { session.navigator.openBottomTools.remove(.profiler) }
    }

    enum DiscardAction: Equatable { case reset, close }

    var pendingDiscard: DiscardAction?
    /// Lines in the log file at the last successful Save Log.
    @ObservationIgnored private var savedLogLineCount: Int?

    var logLineCount: Int { logWriter?.lineCount ?? 0 }

    var hasUnsavedLog: Bool {
        guard let logWriter else { return false }
        let lines = logWriter.lineCount
        return lines > 0 && lines != savedLogLineCount
    }

    /// Resets now, or asks first when that would delete an unsaved log.
    func requestReset() {
        if hasUnsavedLog { pendingDiscard = .reset } else { Task { await reset() } }
    }

    /// Closes now, or asks first when that would delete an unsaved log.
    func requestClose() {
        if hasUnsavedLog { pendingDiscard = .close } else { Task { await close() } }
    }

    func confirmDiscard() async {
        guard let action = pendingDiscard else { return }
        pendingDiscard = nil
        switch action {
        case .reset: await reset()
        case .close: await close()
        }
    }

    func copyLog(to destination: URL) throws {
        guard let logWriter else { throw ProfilerLogError.missing }
        try logWriter.copy(to: destination)
        savedLogLineCount = logWriter.lineCount
    }

    func flushLogFile() {
        logWriter?.flush()
    }

    func sessionWillClose() async {
        await stopStreams()
        logWriter?.discard()
        logWriter = nil
    }

    // MARK: - Streaming

    private func openStreams(isResume: Bool) async {
        phase = .starting
        startError = nil
        generation += 1
        let myGeneration = generation
        let connector = self.connector
        let opened: [MonitorNodeConnection]
        do {
            opened = try await withConnectTimeout(discard: { late in
                for connection in late { await connection.transport.close() }
            }) { try await connector() }
        } catch {
            guard generation == myGeneration else { return }
            let detail = PubSubViewModel.describe(error)
            if isResume {
                appendError(MonitoringError.noConnectionMessage)
                markPaused()
            } else {
                phase = .idle
                startError = MonitoringError.noConnectionMessage
                logWriter?.discard()
                logWriter = nil
                logFileURL = nil
            }

            session.toasts.error(detail, title: MonitoringError.noConnectionMessage)
            return
        }

        guard generation == myGeneration, phase == .starting else {
            for connection in opened { await connection.transport.close() }
            return
        }
        connections = opened
        let labels = opened.compactMap(\.nodeLabel)
        nodeLabels = labels.sorted()
        runningSince = Date()
        pausedAt = nil
        phase = .running
        let zone = timeZone
        for connection in opened {
            let stream = await connection.transport.monitor()
            readerTasks.append(Self.startReader(stream: stream, nodeLabel: connection.nodeLabel, generation: myGeneration,
                                                timeZone: zone, queue: queue, writer: logWriter))
        }

        startFlushLoop()
    }

    private nonisolated static func startReader(stream: AsyncThrowingStream<MonitorLine, Error>, nodeLabel: String?,
                                                generation: Int, timeZone: TimeZone, queue: PendingQueue<ProfilerEvent>,
                                                writer: ProfilerLogFileWriter?) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            do {
                for try await line in stream {
                    writer?.append(ProfilerFormatting.logLine(line))
                    queue.append(.line(generation: generation, ProfilerEntry(line: line, nodeLabel: nodeLabel, timeZone: timeZone)))
                }

                if !Task.isCancelled {
                    queue.append(.ended(generation: generation, nodeLabel: nodeLabel, failure: .connectionLost))
                }
            } catch {
                queue.append(.ended(generation: generation, nodeLabel: nodeLabel,
                                    failure: ProfilerStreamFailure.classify(error)))
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
        var newEntries: [ProfilerEntry] = []
        var failure: (ProfilerStreamFailure, String?)?
        for event in events {
            switch event {
            case .line(let g, let entry) where g == generation:
                if failure == nil { newEntries.append(entry) }
            case .ended(let g, let node, let reason) where g == generation:
                if failure == nil { failure = (reason, node) }
            default:
                break
            }
        }

        if dropped > 0 {
            totalLines += dropped
            hasReceivedLine = true
        }

        if !newEntries.isEmpty {
            totalLines += newEntries.count
            hasReceivedLine = true
            append(newEntries)
        }

        if let (reason, node) = failure, isRunning {
            Task { await self.streamFailed(reason, nodeLabel: node) }
        }
    }

    private func streamFailed(_ failure: ProfilerStreamFailure, nodeLabel: String?) async {
        guard isRunning else { return }
        await stopStreams()
        switch failure {
        case .forbidden:
            entries.removeAll()
            entriesVersion += 1
            runningSince = nil
            phase = .forbidden(MonitoringError.forbiddenMessage)
        case .server(let message):
            appendError(message, nodeLabel: nodeLabel)
            markPaused()
        case .connectionLost:
            appendError(MonitoringError.connectionLostMessage, nodeLabel: nodeLabel)
            isResumeLocked = true
            markPaused()
        }
    }

    private func append(_ newEntries: [ProfilerEntry]) {
        CappedBuffer.append(newEntries, to: &entries, cap: Self.lineLimit)
        entriesVersion += 1
    }

    private func appendError(_ message: String, nodeLabel: String? = nil) {
        append([ProfilerEntry(errorMessage: message, nodeLabel: nodeLabel, timeZone: timeZone)])
    }

    private func markPaused() {
        if let runningSince { accumulatedRunning += Date().timeIntervalSince(runningSince) }
        runningSince = nil
        pausedAt = Date()
        phase = .paused
        logWriter?.flush()
    }

    private func stopStreams() async {
        generation += 1
        for task in readerTasks { task.cancel() }
        readerTasks.removeAll()
        flushTask?.cancel()
        flushTask = nil
        _ = queue.drain()
        let open = connections
        connections.removeAll()
        for connection in open { await connection.transport.close() }
    }

    private func resetState(keepSaveOption: Bool) {
        let save = saveToFile
        phase = .idle
        entries.removeAll()
        entriesVersion += 1
        totalLines = 0
        hasReceivedLine = false
        isResumeLocked = false
        startError = nil
        logWriter = nil
        logFileURL = nil
        nodeLabels = []
        startedAt = nil
        pausedAt = nil
        runningSince = nil
        accumulatedRunning = 0
        saveToFile = keepSaveOption ? save : false
    }
}
