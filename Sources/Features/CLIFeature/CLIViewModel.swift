import Foundation
import Observation
import RedisCore

/// A FLUSHDB / FLUSHALL waiting for the user's go-ahead.
public struct CLIFlushConfirmation: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var verb: String
    public var message: String
}

/// CLI state for one database window: output buffer, prompt DB, input + history, and the dedicated connection.
/// Lives in `session.scopedObject`, so it survives section switches and panel minimize.
@MainActor
@Observable
public final class CLIViewModel: SessionScopedObject {
    public enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    public let session: DatabaseSession
    public let helper: CommandHelperContext
    public private(set) var output: CLIOutputBuffer
    public private(set) var input = ""
    public private(set) var dbIndex: Int
    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var isExecuting = false
    public private(set) var hint: String?
    public private(set) var pendingFlush: CLIFlushConfirmation?
    /// The server the open CLI connection was made to; nil while closed.
    public private(set) var connectedEndpoint: RedisEndpoint?

    @ObservationIgnored private let connector: CLISession.Connector
    @ObservationIgnored private var cli: CLISession?
    @ObservationIgnored private var completer: CommandLineCompleter?
    @ObservationIgnored private var lastCompletion: String?
    @ObservationIgnored private var history = CLIHistoryCursor()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var flushContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var connectedFingerprint: CLIConnectionFingerprint?
    @ObservationIgnored private var settingsChangeTask: Task<Void, Never>?

    static let settingsChangedMessage = "Connection settings changed. Reconnecting…"

    public init(session: DatabaseSession, helper: CommandHelperContext? = nil, connector: CLISession.Connector? = nil,
                maxOutputLines: Int = CLIOutputBuffer.defaultMaxLines) {
        self.session = session
        self.helper = helper ?? session.scopedObject(CommandHelperContext.self) { CommandHelperContext() }
        self.connector = connector ?? Self.sessionConnector(session)
        self.output = CLIOutputBuffer(maxLines: maxOutputLines)
        self.dbIndex = session.effectiveDB
        self.helper.loadIfNeeded()
        observeConnectionSettings()
    }

    /// The view model shared by every CLI view of this session.
    public static func shared(for session: DatabaseSession) -> CLIViewModel {
        session.scopedObject(CLIViewModel.self) { CLIViewModel(session: session) }
    }

    static func sessionConnector(_ session: DatabaseSession) -> CLISession.Connector {
        { [weak session] node in
            guard let session else { throw RedisClientError.notConnected }
            let connection = try await session.makeDedicatedConnection(node: node, context: .cli)
            let db = await connection.selectedDB
            return CLISession.Link(client: connection, db: db)
        }
    }

    // MARK: - Derived

    public var prompt: String { CLICommandPlanner.prompt(db: dbIndex) }

    public var isConnected: Bool { connectionState == .connected }

    public var canType: Bool { isConnected && !isExecuting }

    public var endpointLabel: String {
        let endpoint = connectedEndpoint ?? session.config.endpoint
        return CLICommandPlanner.endpointLabel(host: endpoint.host, port: endpoint.port, db: dbIndex)
    }

    // MARK: - Lifecycle

    /// Opens the CLI connection if none exists.
    public func open() {
        guard cli == nil, connectTask == nil else { return }
        connectTask = Task { [weak self] in
            await self?.openAndWait()
            self?.connectTask = nil
        }
    }

    /// `open()` that returns once connected or failed.
    public func openAndWait() async {
        guard cli == nil else { return }
        dbIndex = session.effectiveDB
        connectedFingerprint = CLIConnectionFingerprint(session.config)
        connectedEndpoint = session.config.endpoint
        var intro: [CLIOutputSegment] = []
        if output.isEmpty {
            intro = [
                CLIOutputSegment(CLICommandPlanner.introPrefix, style: .intro),
                CLIOutputSegment(CLICommandPlanner.introLink, style: .intro, link: .workbench),
                CLIOutputSegment(CLICommandPlanner.introSuffix, style: .intro),
            ]
        }

        output.append(intro + [
            CLIOutputSegment("\n\nConnecting…\n\nPinging Redis server on "),
            CLIOutputSegment(endpointLabel),
        ])
        let session = CLISession(connector: connector, isCluster: self.session.isCluster,
                                 defaultHost: self.session.config.host, initialDB: dbIndex)
        cli = session
        connectionState = .connecting
        do {
            let db = try await session.connect()
            guard cli === session else {
                await session.close()
                return
            }
            dbIndex = db
            connectionState = .connected
            appendConnectedLines()
        } catch {
            guard cli === session else { return }
            await session.close()
            cli = nil
            connectedEndpoint = nil
            let message = Self.message(for: error)
            connectionState = .failed(message)
            output.append("\n\(message)\n\n", style: .error)
        }
    }

    /// Closes the CLI: ends the dedicated connection and keeps the output for the next open.
    public func closeCLI() async {
        cancelRequested = true
        runTask?.cancel()
        resolveFlush(confirmed: false)
        connectTask?.cancel()
        connectTask = nil
        let old = cli
        cli = nil
        connectedEndpoint = nil
        connectionState = .idle
        await old?.close()
    }

    /// Re-creates the connection after a failure or on request.
    public func reconnect() async {
        if cli == nil {
            await openAndWait()
            return
        }

        await reconnectAfterFailure()
    }

    public func sessionWillClose() async {
        settingsChangeTask?.cancel()
        settingsChangeTask = nil
        await closeCLI()
    }

    /// Follow endpoint, credential, and TLS edits after `dbGeneration` changes so the CLI uses the updated server.
    private func observeConnectionSettings() {
        withObservationTracking {
            _ = session.dbGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeConnectionSettings()
                self?.connectionSettingsMayHaveChanged()
            }
        }
    }

    func connectionSettingsMayHaveChanged() {
        guard cli != nil || connectTask != nil, let connectedFingerprint,
              connectedFingerprint != CLIConnectionFingerprint(session.config) else { return }
        let previous = settingsChangeTask
        settingsChangeTask = Task { [weak self] in
            await previous?.value
            await self?.reconnectWithNewSettings()
        }
    }

    private func reconnectWithNewSettings() async {
        guard let connectedFingerprint, connectedFingerprint != CLIConnectionFingerprint(session.config) else { return }
        await closeCLI()
        output.append("\n\(Self.settingsChangedMessage)\n", style: .muted)
        await openAndWait()
    }

    // MARK: - Input

    public func setInput(_ text: String) {
        guard text != input else { return }
        input = text
        if text != lastCompletion {
            completer?.reset()
            lastCompletion = nil
        }

        helper.cliInputChanged(text)
        updateHint()
    }

    public func historyUp() -> String? {
        guard let entry = history.up(session.services.settings.ui.cliInputHistory) else { return nil }
        setInput(entry)
        return entry
    }

    public func historyDown() -> String? {
        guard let entry = history.down(session.services.settings.ui.cliInputHistory) else { return nil }
        setInput(entry)
        return entry
    }

    /// Tab / Shift+Tab: cycles command names starting with the input (the first entry is the original text).
    public func complete(backwards: Bool) -> String? {
        guard let catalog = helper.catalog else { return nil }
        if completer == nil { completer = CommandLineCompleter(catalog: catalog) }
        guard var completer else { return nil }
        completer.availability = session.capabilities.commandAvailability
        let replacement = completer.complete(input, backwards: backwards)
        self.completer = completer
        guard replacement != input else { return nil }
        lastCompletion = replacement
        setInput(replacement)
        return replacement
    }

    private func updateHint() {
        guard let catalog = helper.catalog else {
            hint = nil
            return
        }
        let line = CLICommandPlanner.strippingRepeat(input)
        hint = ArgumentHintCalculator.hint(for: line, catalog: catalog)?.untyped
    }

    public func clearOutput() {
        output.clear()
    }

    // MARK: - Execution

    /// Submits the current input (Enter).
    public func submitInput() {
        guard canType, runTask == nil else { return }
        let text = input
        setInput("")
        runTask = Task { [weak self] in
            defer { self?.runTask = nil }
            await self?.submit(text)
        }
    }

    /// Runs one submitted line to completion.
    public func submit(_ text: String) async {
        guard !isExecuting else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        history.reset()
        lastCompletion = nil
        completer?.reset()
        setInput("")
        if !trimmed.isEmpty { session.services.settings.pushCLIHistory(trimmed) }

        let action = CLICommandPlanner.plan(text)
        if action == .clear {
            clearOutput()
            return
        }

        output.append([
            CLIOutputSegment("\n" + prompt),
            CLIOutputSegment(text, style: .command),
            CLIOutputSegment("\n"),
        ])
        switch action {
        case .empty, .clear:
            return
        case .invalidRepeat:
            output.append(CLICommandPlanner.invalidRepeatMessage + "\n", style: .error)
        case .guidance(let guidance):
            output.append(CLICommandPlanner.guidanceSegments(guidance) + [CLIOutputSegment("\n")])
        case .unsupported(let message), .parseError(let message):
            output.append(message + "\n", style: .error)
        case .execute(let command):
            isExecuting = true
            cancelRequested = false
            await run(command)
            isExecuting = false
        }
    }

    private func run(_ command: CLIPreparedCommand) async {
        guard await confirmIfNeeded(command) else {
            output.append(CLICommandPlanner.commandCancelledMessage + "\n")
            return
        }
        for _ in 0..<command.repeatCount {
            if cancelRequested || Task.isCancelled { break }
            guard let cli else {
                output.append(CLICommandPlanner.connectionClosedMessage + "\n", style: .error)
                return
            }
            do {
                let reply = try await cli.execute(command.args, commandLine: command.commandLine)
                for line in reply.redirects { output.append(line + "\n") }
                var segments = [CLIOutputSegment(reply.text, style: reply.isError ? .error : .reply)]
                if reply.truncatedCharacters > 0 {
                    segments.append(CLIOutputSegment(
                        "\n… output truncated: \(reply.truncatedCharacters) more characters not shown",
                        style: .muted))
                }

                segments.append(CLIOutputSegment("\n"))
                output.append(segments)
                dbIndex = reply.db
                if !reply.isError { session.liveTips.reportCLICommand(command.commandLine) }
            } catch {
                if cancelRequested || Task.isCancelled {
                    output.append(CLICommandPlanner.commandCancelledMessage + "\n")
                } else {
                    output.append(CLICommandPlanner.connectionClosedMessage + "\n", style: .error)
                    await reconnectAfterFailure()
                }

                return
            }
        }

        if cancelRequested { output.append(CLICommandPlanner.commandCancelledMessage + "\n") }
    }

    /// Stops waiting for a reply (blocking commands, long repeats): the connection is re-created.
    public func cancelExecution() {
        guard isExecuting else { return }
        cancelRequested = true
        resolveFlush(confirmed: false)
        let current = cli
        Task {
            await current?.close()
        }
    }

    private func confirmIfNeeded(_ command: CLIPreparedCommand) async -> Bool {
        let modules = session.modules.map(\.name)
        let flushWarning = CLICommandPlanner.flushWarning(verb: command.verb, modules: modules)
        if session.isProduction,
           CLICommandPlanner.isDangerous(args: command.args, dangerous: session.dangerousCommands,
                                         catalog: helper.catalog) {
            let request = ConfirmationRequest(
                title: "Production Database: Check Before Running",
                message: CommandWarnings.dangerousMessage([command.commandLine], databaseName: session.confirmationName,
                                                          extraWarning: flushWarning),
                actionID: "redis-command:\(command.verb)",
                confirmButtonTitle: "Run Command")
            return await session.confirm(request)
        }

        if let flushWarning {
            return await withCheckedContinuation { continuation in
                flushContinuation?.resume(returning: false)
                flushContinuation = continuation
                pendingFlush = CLIFlushConfirmation(verb: command.verb, message: flushWarning)
            }
        }

        return true
    }

    /// Answers the FLUSHDB / FLUSHALL warning.
    public func resolveFlush(confirmed: Bool) {
        pendingFlush = nil
        let continuation = flushContinuation
        flushContinuation = nil
        continuation?.resume(returning: confirmed)
    }

    /// Cancels the given warning when the dialog closes without an answer; a no-op once it was answered.
    public func dismissFlush(_ id: CLIFlushConfirmation.ID) {
        guard pendingFlush?.id == id else { return }
        resolveFlush(confirmed: false)
    }

    private func reconnectAfterFailure() async {
        guard let cli else { return }
        connectionState = .connecting
        do {
            let db = try await cli.reconnect()
            guard self.cli === cli else {
                await cli.close()
                return
            }
            dbIndex = db
            connectionState = .connected
            appendConnectedLines()
        } catch {
            await cli.close()
            guard self.cli === cli else { return }
            self.cli = nil
            connectedEndpoint = nil
            let message = Self.message(for: error)
            connectionState = .failed(message)
            output.append("\n\(message)\n\n", style: .error)
        }
    }

    private func appendConnectedLines() {
        output.append("\nConnected.\nReady to execute commands.\n\n")
    }

    // MARK: - Links

    public func open(_ link: CLILink) {
        let navigator = session.navigator
        switch link {
        case .workbench:
            navigator.openBottomTools.remove(.cli)
            navigator.navigate(.section(.workbench))
        case .profiler:
            navigator.navigate(.bottomPanel(.profiler))
        case .pubSub:
            navigator.navigate(.pubSub)
        }
    }

    static func message(for error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.isEmpty ? "Could not connect to the database." : text
    }
}
