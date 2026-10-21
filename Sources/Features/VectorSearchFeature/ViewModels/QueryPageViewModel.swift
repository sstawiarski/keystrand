import Foundation
import Observation
import RedisUI

@Observable
@MainActor
final class QueryPageViewModel {
    static let batchSize = 5

    let session: DatabaseSession
    private(set) var indexName: Data

    var editorText = "" {
        didSet {
            if editorText != oldValue { searchCommand = QueryCommands.searchCommand(in: editorText) }
        }
    }

    /// First editor command when it is FT.SEARCH / FT.AGGREGATE (Explain / Profile), cached per editor text.
    private(set) var searchCommand: QueryCommands.SearchCommand?
    var tab: QueryEditorTab = .editor
    var isIndexPanelOpen = false
    private(set) var isRunning = false
    private(set) var cards: [ResultCardModel] = []
    private(set) var isLoadingHistory = false
    private(set) var historyLoaded = false
    private(set) var isClearing = false
    private(set) var scrollToTopToken = 0

    private(set) var libraryItems: [QueryLibraryItem] = []
    private(set) var isLoadingLibrary = false
    private(set) var libraryLoaded = false
    private(set) var libraryError: String?
    var librarySearch = ""
    var expandedLibraryItemID: UUID?
    var pendingLibraryDelete: QueryLibraryItem?

    var isSaveSheetPresented = false
    var expandedCard: ResultCardModel?
    private(set) var flushWarning: QueryFlushWarning?
    @ObservationIgnored private var flushContinuation: CheckedContinuation<Bool, Never>?
    var saveName = ""
    private(set) var isSaving = false

    init(session: DatabaseSession, indexName: Data) {
        self.session = session
        self.indexName = indexName
    }

    var indexNameString: String { String(decoding: indexName, as: UTF8.self) }
    private var history: CommandHistoryStore { session.services.commandHistoryStore }
    private var library: QueryLibraryStore { session.services.queryLibraryStore }

    // MARK: - Index

    /// Switches the page to another index; the library is reloaded, editor and results are kept.
    func setIndex(_ name: Data) async {
        guard name != indexName else { return }
        indexName = name
        expandedLibraryItemID = nil
        librarySearch = ""
        await loadLibrary()
    }

    // MARK: - Editor state

    var supportsExplain: Bool { session.capabilities.supportsSearchExplain }

    var explainDisabledReason: String? {
        if isRunning { return VectorSearchStrings.runningReason }
        return searchCommand == nil ? VectorSearchStrings.noQueryReason : nil
    }

    var canRun: Bool { !isRunning && !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSave: Bool { canRun }

    // MARK: - History

    func loadHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        let items = await history.list(databaseID: session.id, type: .search)
        let running = cards.filter(\.isLoading)
        var existing: [UUID: ResultCardModel] = [:]
        for card in cards where !card.isLoading { existing[card.execution.id] = card }
        cards = running + items.map { existing[$0.id] ?? ResultCardModel(execution: $0, isOpen: false) }
        isLoadingHistory = false
        historyLoaded = true
    }

    // MARK: - Run

    func runEditor() async {
        await run(script: editorText)
    }

    func run(script: String) async {
        guard !isRunning else { return }
        let count = QueryCommands.expandedCount(in: script)
        guard count <= QuerySafety.maxCommands else {
            session.toasts.error(QuerySafety.tooManyCommandsMessage(count), title: "Too many commands")
            return
        }
        await run(commands: QueryCommands.commands(in: script))
    }

    func explain() async {
        guard supportsExplain, let command = searchCommand else { return }
        await run(commands: [QueryCommands.explain(command)])
    }

    func profile() async {
        guard supportsExplain, let command = searchCommand else { return }
        await run(commands: [QueryCommands.profile(command)])
    }

    func explain(_ card: ResultCardModel) async {
        guard supportsExplain, let command = QueryCommands.parseSearchCommand(card.command) else { return }
        await run(commands: [QueryCommands.explain(command)])
    }

    func profile(_ card: ResultCardModel) async {
        guard supportsExplain, let command = QueryCommands.parseSearchCommand(card.command) else { return }
        await run(commands: [QueryCommands.profile(command)])
    }

    func rerun(_ card: ResultCardModel) async {
        await run(commands: [card.command])
    }

    /// Runs pipelines of 5 commands. Shows each pipeline in script order, with later pipelines above earlier ones.
    /// Placeholder results appear immediately and fill when each pipeline finishes.
    func run(commands: [String]) async {
        guard !isRunning, !commands.isEmpty else { return }
        guard commands.count <= QuerySafety.maxCommands else {
            session.toasts.error(QuerySafety.tooManyCommandsMessage(commands.count), title: "Too many commands")
            return
        }
        guard await confirmDangerous(commands), await confirmFlush(commands) else { return }
        isRunning = true
        defer { isRunning = false }

        let placeholders = commands.map { command in
            ResultCardModel(execution: CommandExecution(databaseId: session.id,
                                                        command: WorkbenchScriptParser.multilineToOneLine(command),
                                                        type: .search, db: session.effectiveDB),
                            isOpen: true, isLoading: true)
        }
        let chunks = stride(from: 0, to: placeholders.count, by: Self.batchSize).map {
            Array(placeholders[$0..<min($0 + Self.batchSize, placeholders.count)])
        }
        cards.insert(contentsOf: chunks.reversed().flatMap { $0 }, at: 0)
        trimCards()
        scrollToTopToken += 1

        var pending = placeholders
        let executor = CommandExecutor(session: session, history: history, type: .search)
        let params = ExecuteParams(batchSize: Self.batchSize, mode: .ascii, resultsMode: .default, clearEditor: false)
        do {
            _ = try await executor.run(commands, params: params, settings: session.services.settings.app,
                                       onPersistError: { [weak self] error in
                self?.session.toasts.error(error, title: "Results could not be saved")
            }, onChunk: { executions in
                for execution in executions {
                    guard !pending.isEmpty else { break }
                    pending.removeFirst().complete(with: execution)
                }
            })
            let skipped = Set(pending.map(\.id))
            cards.removeAll { skipped.contains($0.id) }
        } catch {
            let message = error.localizedDescription.isEmpty ? "The command didn't run." : error.localizedDescription
            for card in pending { card.fail(message) }
        }

        trimCards()
    }

    /// Requires typed confirmation for dangerous commands on production databases.
    /// Shared `dangerous:<VERB>` action IDs preserve "Don't ask again" across sections.
    func confirmDangerous(_ commands: [String]) async -> Bool {
        guard session.isProduction else { return true }
        let verbs = QuerySafety.dangerousVerbs(in: commands, serverList: session.dangerousCommands)
        guard !verbs.isEmpty else { return true }
        let ids = verbs.map { "dangerous:\($0)" }
        if ids.allSatisfy(session.confirmations.skippedActionIDs.contains) { return true }
        let request = ConfirmationRequest(
            title: "Production Database: Check Before Running",
            message: QuerySafety.dangerousMessage(verbs: verbs, databaseName: session.confirmationName),
            actionID: ids.count == 1 ? ids[0] : "dangerous:" + verbs.joined(separator: ","),
            confirmButtonTitle: "Run command")
        return await session.confirm(request)
    }

    /// FLUSHDB / FLUSHALL drop every search index on the server; ask on every database.
    func confirmFlush(_ commands: [String]) async -> Bool {
        let verbs = QuerySafety.flushVerbs(in: commands)
        guard !verbs.isEmpty else { return true }
        let message = QuerySafety.flushMessage(verbs: verbs, hasSearch: true)
        flushContinuation?.resume(returning: false)
        return await withCheckedContinuation { continuation in
            flushContinuation = continuation
            flushWarning = QueryFlushWarning(verbs: verbs, message: message)
        }
    }

    func resolveFlushWarning(proceed: Bool) {
        flushWarning = nil
        flushContinuation?.resume(returning: proceed)
        flushContinuation = nil
    }

    private func trimCards() {
        if cards.count > CommandHistoryStore.maxItems {
            cards = Array(cards.prefix(CommandHistoryStore.maxItems))
        }
    }

    // MARK: - Cards

    func toggle(_ card: ResultCardModel) async {
        guard !card.isLoading else { return }
        card.isOpen.toggle()
        guard card.isOpen else { return }
        if card.hasResult {
            card.computeContent()
            return
        }

        if let full = await history.get(card.execution.id, databaseID: session.id, type: .search), full.result != nil {
            card.attachResult(full)
        } else {
            card.setLoadError("This result couldn't be loaded.")
        }
    }

    func delete(_ card: ResultCardModel) async {
        guard !card.isLoading else { return }
        do {
            try await history.delete(card.execution.id, databaseID: session.id, type: .search)
            cards.removeAll { $0.id == card.id }
        } catch {
            session.toasts.error(error)
        }
    }

    func clearResults() async {
        guard !isClearing, !isRunning else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await history.clear(databaseID: session.id, type: .search)
            cards.removeAll { !$0.isLoading }
        } catch {
            session.toasts.error(error)
        }
    }

    // MARK: - Query library

    var filteredLibrary: [QueryLibraryItem] {
        let needle = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return libraryItems }
        return libraryItems.filter { item in
            item.name.lowercased().contains(needle) || (item.description ?? "").lowercased().contains(needle)
                || item.query.lowercased().contains(needle)
        }
    }

    var showsLibrarySearch: Bool { !libraryItems.isEmpty || !librarySearch.isEmpty }

    var libraryEmptyMessage: String {
        libraryItems.isEmpty
            ? "Save a query from the editor to add it here."
            : "No saved queries match the search."
    }

    func loadLibrary() async {
        isLoadingLibrary = true
        libraryError = nil
        libraryItems = await library.list(databaseID: session.id, indexName: indexNameString)
        isLoadingLibrary = false
        libraryLoaded = true
    }

    func beginSave() {
        guard canSave else { return }
        saveName = ""
        isSaveSheetPresented = true
    }

    @discardableResult
    func save() async -> Bool {
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        let item = QueryLibraryItem(databaseId: session.id, indexName: indexNameString, type: .saved, name: name,
                                    query: editorText)
        do {
            try await library.create(item)
            isSaveSheetPresented = false
            await loadLibrary()
            return true
        } catch {
            session.toasts.error("The query wasn't added to the library. Try again.", title: "Couldn't Save Query")
            return false
        }
    }

    func editorText(for item: QueryLibraryItem) -> String {
        if item.type == .sample, let description = item.description, !description.isEmpty {
            return "// \(description)\n\(item.query)"
        }

        return item.query
    }

    func load(_ item: QueryLibraryItem) {
        editorText = editorText(for: item)
        tab = .editor
    }

    func run(_ item: QueryLibraryItem) async {
        await run(script: item.query)
    }

    func toggleLibraryItem(_ item: QueryLibraryItem) {
        expandedLibraryItemID = expandedLibraryItemID == item.id ? nil : item.id
    }

    func deleteLibraryItem(_ item: QueryLibraryItem) async {
        do {
            try await library.delete(item.id, databaseID: session.id)
            if expandedLibraryItemID == item.id { expandedLibraryItemID = nil }
            await loadLibrary()
        } catch {
            session.toasts.error(error)
        }
    }

    // MARK: - Templates

    func apply(_ template: QueryCommands.Template, controller: CodeEditorController?) {
        let expanded = CodeSnippet.expand(template.snippet)
        editorText = expanded.text
        tab = .editor
        if let controller, controller.isAttached {
            controller.replaceAll(with: expanded.text)
            controller.focus()
        }
    }
}
