import AppKit
import Foundation
import Observation
import RedisUI

/// Where a run was started from (only editor runs clear the editor).
public enum WorkbenchRunSource: Sendable, Hashable {
    case editor
    case rerun
    case tutorial
    case generated
}

/// Pending "FLUSHDB drops every search index" confirmation.
public struct FlushWarning: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var verbs: [String]
    public var message: String
}

public enum WorkbenchError: Error, LocalizedError, Equatable {
    case busy
    case emptyName
    case emptyQuery

    public var errorDescription: String? {
        switch self {
        case .busy: return "Commands are still running…"
        case .emptyName: return "Enter a name for the query."
        case .emptyQuery: return "The editor is empty. Type a command to save it."
        }
    }
}

/// Editor, result, history, library and completion state for one database window.
/// Kept in `session.scopedObject` to survive section switches.
@MainActor
@Observable
public final class WorkbenchViewModel: SessionScopedObject {
    public static let maxCards = CommandHistoryStore.maxItems

    public let session: DatabaseSession

    public var editorText = "" {
        didSet {
            let empty = !editorText.contains(where: { !$0.isWhitespace })
            if empty != isEditorEmpty { isEditorEmpty = empty }
        }
    }

    /// True while the editor holds only whitespace; changes only when that flips, so views can read it per keystroke.
    public private(set) var isEditorEmpty = true
    public private(set) var cards: [WorkbenchCard] = []
    public private(set) var isRunning = false
    /// True from Stop until the run has ended.
    public private(set) var isStopping = false
    public private(set) var isLoadingHistory = false
    public private(set) var historyLoaded = false
    public private(set) var isClearing = false
    public var fullscreenCardID: UUID?
    public private(set) var flushWarning: FlushWarning?
    /// Incremented when cards are added (the results list scrolls to the top).
    public private(set) var scrollToTopToken = 0
    public private(set) var libraryItems: [QueryLibraryItem] = []
    public private(set) var isLoadingLibrary = false
    public private(set) var timeSeriesPreferences = TimeSeriesPreferences()
    /// False until the bundled command specs load.
    public private(set) var isCommandCatalogLoaded = WorkbenchViewModel.commandCatalogReady

    private static var commandCatalogReady = false

    @ObservationIgnored private var flushContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var historyIndex = -1
    @ObservationIgnored private var historyText: String?
    @ObservationIgnored private let engine = CompletionEngine()
    @ObservationIgnored private(set) var indexNames: [String] = []
    @ObservationIgnored private(set) var fieldCache: [String: [SearchFieldSuggestion]] = [:]
    @ObservationIgnored private var fieldRequests: Set<String> = []
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var preferencesLoaded = false
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// This window's dedicated Workbench connection keeps script state (MULTI, CLIENT REPLY OFF) off pooled clients.
    /// Dropped after Stop, a transport failure, a stateful command or a logical database switch.
    @ObservationIgnored private var runClient: (client: any RedisClient, db: Int)?

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// The window-scoped instance shared by the Workbench and the Tutorials panel.
    public static func shared(for session: DatabaseSession) -> WorkbenchViewModel {
        session.scopedObject(WorkbenchViewModel.self) { WorkbenchViewModel(session: session) }
    }

    var settings: SettingsStore { session.services.settings }
    var history: CommandHistoryStore { session.services.commandHistoryStore }

    public func sessionWillClose() async {
        runTask?.cancel()
        await dropRunClient()
    }

    public func sessionConnectionDidReset() async {
        runTask?.cancel()
        await dropRunClient()
    }

    // MARK: - Lifecycle

    /// Loads history, preferences and the search index list once.
    public func onAppear() async {
        if !preferencesLoaded {
            preferencesLoaded = true
            await loadPreferences()
        }

        if !historyLoaded { await loadHistory() }
        await refreshIndexes()
    }

    /// Loads `CommandCatalog.shared` off the main actor so the first editor render does not block on it.
    public func loadCommandCatalog() async {
        guard !isCommandCatalogLoaded else { return }
        await Task.detached(priority: .userInitiated) { _ = CommandCatalog.shared }.value
        Self.commandCatalogReady = true
        isCommandCatalogLoaded = true
    }

    public func loadHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let items = await history.list(databaseID: session.id, type: .workbench)
        let running = cards.filter(\.isRunning)
        let loaded = items.map { item in
            WorkbenchCard(execution: item, isOpen: false, isRunning: false, isPersisted: true,
                          selectedView: defaultView(for: item), commandCount: item.summary?.total ?? 1)
        }
        let liveIDs = Set(cards.filter { !$0.isRunning }.map(\.execution.id))
        let kept = cards.filter { !$0.isRunning && liveIDs.contains($0.execution.id) }
        var merged = running + kept
        for card in loaded where !merged.contains(where: { $0.execution.id == card.execution.id }) {
            merged.append(card)
        }

        cards = Array(merged.prefix(Self.maxCards))
        historyLoaded = true
    }

    func defaultView(for execution: CommandExecution) -> WorkbenchViewKind {
        guard execution.resultsMode == .default else { return .text }
        let kind = VisualizationRegistry.defaultView(for: execution.command)
        if kind == .timeSeries, timeSeriesPreferences.selectedView == "text" { return .text }
        return kind
    }

    // MARK: - Running

    /// Cmd+Enter / Run button: runs the editor content and clears the editor when the Cleanup setting is on.
    public func runEditor() async {
        let script = editorText
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await run(script: script, params: ExecuteParams(clearEditor: true), source: .editor)
    }

    /// Runs a script (editor, re-run, tutorial). A params line in the script wins over `params`, which wins over
    /// Settings. Returns false when nothing ran (busy, empty, cancelled, parse error).
    @discardableResult
    public func run(script: String, params: ExecuteParams = ExecuteParams(clearEditor: false),
                    source: WorkbenchRunSource = .generated, onFinish: (@MainActor () -> Void)? = nil) async -> Bool {
        defer { onFinish?() }
        guard !isRunning, !isStarting else {
            NSSound.beep()
            return false
        }
        isStarting = true
        let commands: [String]
        do {
            commands = try await Task.detached(priority: .userInitiated) {
                try WorkbenchScriptParser.parse(script)
            }.value
        } catch {
            isStarting = false
            session.toasts.error(error, title: "Run Failed")
            return false
        }

        guard !commands.isEmpty else {
            isStarting = false
            return false
        }
        let resolved = resolveParams(script: script, params: params)
        guard await confirmDangerous(commands), await confirmFlush(commands) else {
            isStarting = false
            return false
        }
        isRunning = true
        isStarting = false
        defer {
            isRunning = false
            isStopping = false
            runTask = nil
        }
        historyIndex = -1
        if source == .editor, resolved.clearEditor, settings.app.workbenchCleanup, editorText == script {
            editorText = ""
        }

        let task = Task { await self.execute(commands, params: resolved) }
        runTask = task
        await task.value
        if commands.contains(where: Self.changesIndexes) { await refreshIndexes() }
        return true
    }

    func resolveParams(script: String, params: ExecuteParams) -> ExecuteParams {
        let app = settings.app
        let inline = WorkbenchScriptParser.parseParams(script)
        var out = params
        out.batchSize = inline?.batchSize ?? params.batchSize ?? app.workbenchBatchSize
        out.mode = inline?.mode ?? params.mode ?? app.workbenchRunQueryMode
        out.resultsMode = inline?.resultsMode ?? params.resultsMode ?? app.workbenchResultsMode
        if let inline, inline.clearEditor == false { out.clearEditor = false }
        return out
    }

    private func execute(_ commands: [String], params: ExecuteParams) async {
        let resultsMode = params.resultsMode ?? .default
        let mode = params.mode ?? .ascii
        let grouped = resultsMode != .default
        let batch = params.batchSize ?? 5
        let chunkSize = grouped ? max(commands.count, 1) : max(batch, 1)
        let chunks: [[String]] = stride(from: 0, to: commands.count, by: chunkSize).map {
            Array(commands[$0..<min($0 + chunkSize, commands.count)])
        }
        let db = session.effectiveDB
        var pending: [WorkbenchCard] = []
        var chunkIndex = 0

        func insertPlaceholders(_ index: Int) {
            guard index < chunks.count else {
                pending = []
                return
            }
            let chunk = chunks[index]
            if grouped {
                let execution = CommandExecution(databaseId: session.id, command: chunk.joined(separator: "\r\n"),
                                                 mode: mode, resultsMode: resultsMode, db: db)
                pending = [WorkbenchCard(execution: execution, isOpen: true, isRunning: true, isPersisted: false,
                                         selectedView: .text, commandCount: chunk.count)]
            } else {
                pending = chunk.map { command in
                    let execution = CommandExecution(databaseId: session.id,
                                                     command: WorkbenchScriptParser.multilineToOneLine(command),
                                                     mode: mode, db: db)
                    return WorkbenchCard(execution: execution, isOpen: true, isRunning: true, isPersisted: false,
                                         selectedView: .text)
                }
            }

            cards.insert(contentsOf: pending, at: 0)
            trimCards()
            scrollToTopToken += 1
        }

        insertPlaceholders(0)
        let executor = CommandExecutor(session: session, history: history, type: .workbench)
        var keepsClient = await Task.detached { !commands.contains(where: Self.changesConnectionState) }.value
        do {
            let client = try await workbenchClient()
            let executions = try await executor.run(
                commands, params: params, settings: settings.app, client: client,
                onPersistError: { [weak self] error in
                    let failure = Self.runFailure(error, skippedLaterCommands: false)
                    self?.session.toasts.error(failure.toastText, title: failure.toastTitle)
                }, onChunk: { [weak self] executions in
                    guard let self else { return }
                    self.complete(pending, with: executions)
                    chunkIndex += 1
                    insertPlaceholders(chunkIndex)
                }, onTransportFailure: {
                    keepsClient = false
                })
            markNotStored(executions)
        } catch is CancellationError {
            keepsClient = false
            for card in pending {
                card.execution.result = [CommandExecutionResult(status: .fail,
                                                                response: .reply(.error(Self.stoppedMessage)))]
                card.isRunning = false
                card.renderText()
            }

            pending = []
        } catch {
            keepsClient = false
            let failure = Self.runFailure(error, skippedLaterCommands: chunkIndex + 1 < chunks.count)
            for card in pending {
                card.execution.result = [CommandExecutionResult(status: .fail, response: .reply(.error(failure.cardText)))]
                card.isRunning = false
                card.renderText()
            }

            pending = []
            session.toasts.error(failure.toastText, title: failure.toastTitle)
        }

        let leftovers = Set(pending.map(\.id))
        if !leftovers.isEmpty { cards.removeAll { leftovers.contains($0.id) } }
        if !keepsClient { await dropRunClient() }
    }

    static let stoppedMessage = "Stopped. Commands already sent to Redis may have run."

    /// Stop button / Cmd-.: cancels the run and closes its connection, so a command that never replies
    /// (CLIENT REPLY OFF, a long script) cannot keep the Workbench busy.
    public func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        runTask?.cancel()
        Task { await dropRunClient() }
    }

    private func workbenchClient() async throws -> any RedisClient {
        let db = session.effectiveDB
        if let runClient, runClient.db == db { return runClient.client }
        await dropRunClient()
        let client = try await session.makeDedicatedClient(context: .workbench)
        runClient = (client, db)
        return client
    }

    private func dropRunClient() async {
        guard let client = runClient?.client else { return }
        runClient = nil
        await client.close()
    }

    /// Commands that leave state on the connection that the next run must not inherit.
    nonisolated static func changesConnectionState(_ command: String) -> Bool {
        guard let name = WorkbenchScriptParser.arguments(of: command)?.first?.uppercased() else { return false }
        return ["MULTI", "WATCH", "HELLO", "AUTH", "RESET", "READONLY", "READWRITE", "CLIENT"].contains(name)
    }

    private func markNotStored(_ executions: [CommandExecution]) {
        let failed = Set(executions.filter { $0.isNotStored == true }.map(\.id))
        guard !failed.isEmpty else { return }
        for card in cards where failed.contains(card.execution.id) { card.showsNotStoredWarning = true }
    }

    struct RunFailure: Equatable {
        var cardText: String
        var toastTitle: String
        var toastText: String
    }

    /// History writes happen after Redis ran the chunk, so a file error must not read as a command failure.
    nonisolated static func runFailure(_ error: Error, skippedLaterCommands: Bool) -> RunFailure {
        let description = error.localizedDescription
        guard error is CocoaError || error is EncodingError else {
            return RunFailure(cardText: description, toastTitle: "Run Failed", toastText: description)
        }
        var toast = "The commands ran, but their results could not be saved: \(description)"
        if skippedLaterCommands { toast += " The remaining commands were not run." }
        return RunFailure(
            cardText: "The command was sent to Redis, but its result could not be saved to the Workbench history: "
                + description,
            toastTitle: "Results could not be saved",
            toastText: toast)
    }

    private func complete(_ placeholders: [WorkbenchCard], with executions: [CommandExecution]) {
        for (index, execution) in executions.enumerated() {
            let card: WorkbenchCard
            if index < placeholders.count {
                card = placeholders[index]
            } else {
                card = WorkbenchCard(execution: execution, isOpen: true, isRunning: false, isPersisted: true)
                cards.insert(card, at: 0)
            }

            card.execution = execution
            card.isRunning = false
            card.isPersisted = true
            card.commandCount = execution.summary?.total ?? card.commandCount
            card.selectedView = defaultView(for: execution)
            card.showsNotStoredWarning = execution.isNotStored == true
            card.isOpen = card.isExpandable
            card.renderText()
        }

        trimCards()
    }

    private func trimCards() {
        guard cards.count > Self.maxCards else { return }
        var overflow = cards.count - Self.maxCards
        var index = cards.count - 1
        while overflow > 0, index >= 0 {
            if !cards[index].isRunning {
                cards.remove(at: index)
                overflow -= 1
            }

            index -= 1
        }
    }

    nonisolated static func changesIndexes(_ command: String) -> Bool {
        let name = WorkbenchScriptParser.arguments(of: command)?.first?.uppercased() ?? ""
        return ["FT.CREATE", "FT.DROPINDEX", "FT.DROP", "FT.ALIASADD", "FT.ALIASDEL", "FT.ALTER", "FLUSHDB",
                "FLUSHALL"].contains(name)
    }

    /// `Run again`: the card's command with its own mode / results mode; the editor is untouched.
    public func rerun(_ card: WorkbenchCard) async {
        guard !card.execution.command.isEmpty else { return }
        await run(script: card.execution.command,
                  params: ExecuteParams(mode: card.execution.mode, resultsMode: card.execution.resultsMode,
                                        clearEditor: false),
                  source: .rerun)
    }

    /// `Profile the command` / `Explain the command` for FT.SEARCH / FT.AGGREGATE cards.
    public func runGenerated(for card: WorkbenchCard, explain: Bool) async {
        let command = explain ? WorkbenchCommandText.explainCommand(for: card.execution.command)
            : WorkbenchCommandText.profileCommand(for: card.execution.command)
        guard let command else { return }
        await run(script: command,
                  params: ExecuteParams(mode: card.execution.mode, resultsMode: card.execution.resultsMode,
                                        clearEditor: false),
                  source: .generated)
    }

    // MARK: - Safety

    /// Production databases: type-to-confirm before dangerous commands (skipped per verb for the session).
    func confirmDangerous(_ commands: [String]) async -> Bool {
        guard session.isProduction else { return true }
        let verbs = WorkbenchCommandText.dangerousVerbs(in: commands, serverList: session.dangerousCommands)
        guard !verbs.isEmpty else { return true }
        let skipped = WorkbenchCommandText.skippedDangerousVerbs(session.confirmations.skippedActionIDs)
        if verbs.allSatisfy({ skipped.contains($0.uppercased()) }) { return true }
        let request = ConfirmationRequest(
            title: "Production Database: Check Before Running",
            message: CommandWarnings.dangerousMessage(verbs, databaseName: session.confirmationName),
            actionID: WorkbenchCommandText.dangerousActionID(verbs: verbs),
            confirmButtonTitle: "Run Command")
        return await session.confirm(request)
    }

    /// FLUSHDB / FLUSHALL also drop every RediSearch index on the server; ask before running them.
    func confirmFlush(_ commands: [String]) async -> Bool {
        let verbs = WorkbenchCommandText.flushVerbs(in: commands)
        let mayDropIndexes = session.capabilities.hasSearch
            || CommandWarnings.flushMayDropIndexes(modules: session.modules.map(\.name))
        guard let message = CommandWarnings.flushMessage(verbs: verbs, mayDropIndexes: mayDropIndexes) else {
            return true
        }
        flushContinuation?.resume(returning: false)
        return await withCheckedContinuation { continuation in
            flushContinuation = continuation
            flushWarning = FlushWarning(verbs: verbs, message: message)
        }
    }

    public func resolveFlushWarning(proceed: Bool) {
        flushWarning = nil
        flushContinuation?.resume(returning: proceed)
        flushContinuation = nil
    }

    // MARK: - Cards

    public func toggle(_ card: WorkbenchCard) async {
        guard card.isExpandable else { return }
        card.isOpen.toggle()
        if card.isOpen { await loadResultIfNeeded(card) }
    }

    public func loadResultIfNeeded(_ card: WorkbenchCard) async {
        guard card.execution.result == nil, card.isPersisted, !card.isLoadingResult else {
            if card.lines == nil, card.execution.result != nil { card.renderText() }
            return
        }
        card.isLoadingResult = true
        defer { card.isLoadingResult = false }
        guard let full = await history.get(card.execution.id, databaseID: session.id, type: .workbench),
              full.result != nil else {
            card.loadError = "This result has been cleared. Run the command again for fresh output."
            return
        }
        card.execution.result = full.result
        card.loadError = nil
        await card.renderText().value
    }

    public func delete(_ card: WorkbenchCard) async {
        if card.isPersisted {
            do {
                try await history.delete(card.execution.id, databaseID: session.id, type: .workbench)
            } catch {
                session.toasts.error(error)
                return
            }
        }

        cards.removeAll { $0.id == card.id }
        if fullscreenCardID == card.id { fullscreenCardID = nil }
    }

    /// `Clear Results`: deletes this database's Workbench history.
    public func clearResults() async {
        guard !isRunning, !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await history.clear(databaseID: session.id, type: .workbench)
            cards.removeAll { !$0.isRunning }
            fullscreenCardID = nil
        } catch {
            session.toasts.error(error)
        }
    }

    /// Esc while a card is fullscreen; returns false when no card was fullscreen.
    @discardableResult
    public func exitFullscreen() -> Bool {
        guard fullscreenCardID != nil else { return false }
        fullscreenCardID = nil
        return true
    }

    public func card(id: UUID?) -> WorkbenchCard? {
        guard let id else { return nil }
        return cards.first { $0.id == id }
    }

    /// Persists the Text-vs-Chart choice for time series cards.
    public func select(_ view: WorkbenchViewKind, for card: WorkbenchCard) {
        card.selectedView = view
        guard VisualizationRegistry.options(for: card.execution.command).contains(.timeSeries) else { return }
        guard view == .text || view == .timeSeries else { return }
        var prefs = timeSeriesPreferences
        prefs.selectedView = view == .text ? "text" : "chart"
        saveTimeSeriesPreferences(prefs)
    }

    public func updateChartConfig(_ config: TimeSeriesChartConfig) {
        var prefs = timeSeriesPreferences
        prefs.chartConfig = config
        saveTimeSeriesPreferences(prefs)
    }

    private func loadPreferences() async {
        let settings = await session.services.databaseSettingsStore.settings(for: session.id)
        if let prefs = settings.feature(TimeSeriesPreferences.self, key: TimeSeriesPreferences.featureKey) {
            timeSeriesPreferences = prefs
        }
    }

    private func saveTimeSeriesPreferences(_ prefs: TimeSeriesPreferences) {
        guard prefs != timeSeriesPreferences else { return }
        timeSeriesPreferences = prefs
        let store = session.services.databaseSettingsStore
        let id = session.id
        let toasts = session.toasts
        Task {
            do {
                try await store.update(id) { $0.setFeature(prefs, key: TimeSeriesPreferences.featureKey) }
            } catch {
                toasts.error(error)
            }
        }
    }

    // MARK: - Editor

    /// Replaces the editor content without executing it.
    public func enqueueScript(_ script: String) {
        editorText = script
        historyIndex = -1
    }

    /// Up arrow on the first line: walks older commands of the result cards.
    public func historyUp(caretAtStart: Bool) -> Bool {
        let commands = cards.filter { !$0.execution.command.isEmpty }.map(\.execution.command)
        guard !commands.isEmpty, caretAtStart || historyIndex >= 0 else { return false }
        let next = historyIndex + 1
        if next >= commands.count {
            historyIndex = -1
            historyText = ""
            editorText = ""
            return true
        }

        historyIndex = next
        let text = commands[next].replacingOccurrences(of: "\r\n", with: "\n")
        historyText = text
        editorText = text
        return true
    }

    /// Call when the editor text changes; typing resets the history walk.
    public func editorTextDidChange() {
        if editorText != historyText {
            historyIndex = -1
            historyText = nil
        }
    }

    // MARK: - Completion

    public func completions(text: String, cursor: Int) -> [CodeCompletion] {
        var fields: [SearchFieldSuggestion] = []
        if let query = CompletionEngine.commandText(in: text, cursorOffset: cursor),
           let index = WorkbenchCommandText.indexName(in: query) {
            if let cached = fieldCache[index] { fields = cached } else { requestFields(index) }
        }

        let context = CompletionContext(indexes: indexNames, fields: fields,
                                        availability: session.capabilities.commandAvailability)
        let result = engine.complete(text: text, cursorOffset: cursor, context: context)
        if result.needsIndexes {
            return [CodeCompletion(label: "No indexes to display", insertText: result.currentWord,
                                   detail: "Create an index", kind: .other)]
        }

        return result.items.map(Self.codeCompletion)
    }

    static func codeCompletion(_ item: CompletionItem) -> CodeCompletion {
        let kind: CodeCompletion.Kind
        switch item.kind {
        case .command, .subcommand: kind = .command
        case .keyword: kind = .keyword
        case .index: kind = .index
        case .field: kind = .field
        case .function: kind = .snippet
        }

        return CodeCompletion(label: item.label, insertText: item.insertText, detail: item.detail,
                              documentation: item.documentation, kind: kind)
    }

    public func signature(text: String, cursor: Int) -> CodeSignatureHint? {
        if let hint = engine.signature(text: text, cursorOffset: cursor) {
            return CodeSignatureHint(label: hint.label, highlight: hint.highlight, documentation: hint.documentation)
        }

        guard let query = CompletionEngine.commandText(in: text, cursorOffset: cursor),
              let hint = ArgumentHintCalculator.hint(for: query) else { return nil }
        let label = "\(hint.command.name) \(hint.full)"
        let range = (label as NSString).range(of: hint.untyped, options: .backwards)
        return CodeSignatureHint(label: label, highlight: range.location == NSNotFound ? nil : range,
                                 documentation: hint.command.summary)
    }

    /// `FT._LIST` for index-name completion (only when Redis Search is loaded).
    public func refreshIndexes() async {
        guard session.capabilities.hasSearch else { return }
        do {
            let names = try await SearchIndexService(session: session).listIndexes()
            indexNames = names.map { String(decoding: $0, as: UTF8.self) }.sorted()
            fieldCache = [:]
        } catch {
            indexNames = []
        }
    }

    private func requestFields(_ index: String) {
        guard session.capabilities.hasSearch, !fieldRequests.contains(index) else { return }
        fieldRequests.insert(index)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            defer { self.fieldRequests.remove(index) }
            guard let info = try? await SearchIndexService(session: self.session).info(Data(index.utf8)) else {
                self.fieldCache[index] = []
                return
            }
            self.fieldCache[index] = info.attributes.map { SearchFieldSuggestion(name: $0.attribute, type: $0.type) }
        }
    }

    // MARK: - Query library

    var library: QueryLibraryStore { session.services.queryLibraryStore }

    public func loadLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        libraryItems = await library.list(databaseID: session.id)
    }

    /// Items whose name, description or query contains `search` (case-insensitive).
    public func filteredLibrary(_ search: String) -> [QueryLibraryItem] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return libraryItems }
        return libraryItems.filter {
            $0.name.lowercased().contains(needle) || $0.query.lowercased().contains(needle)
                || ($0.description?.lowercased().contains(needle) ?? false)
        }
    }

    /// Saves `query` (defaulting to the editor) under `name`; detects the index from an FT command.
    /// Throws `WorkbenchError` for an empty name or query and propagates store errors.
    @discardableResult
    public func saveQuery(name: String, query: String? = nil) async throws -> QueryLibraryItem {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (query ?? editorText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw WorkbenchError.emptyName }
        guard !text.isEmpty else { throw WorkbenchError.emptyQuery }
        let firstCommand = (try? WorkbenchScriptParser.parse(text))?.first ?? text
        let index = WorkbenchCommandText.indexName(in: firstCommand + " ") ?? ""
        let item = QueryLibraryItem(databaseId: session.id, indexName: index, type: .saved, name: trimmedName,
                                    query: text)
        try await library.create(item)
        await loadLibrary()
        return item
    }

    public func deleteQuery(_ item: QueryLibraryItem) async {
        do {
            try await library.delete(item.id, databaseID: session.id)
            libraryItems.removeAll { $0.id == item.id }
        } catch {
            session.toasts.error(error)
        }
    }

    /// Puts a saved query into the editor (samples get their description as a `//` comment).
    public func loadQuery(_ item: QueryLibraryItem) {
        if item.type == .sample, let description = item.description, !description.isEmpty {
            enqueueScript("// \(description)\n\(item.query)")
        } else {
            enqueueScript(item.query)
        }
    }
}
