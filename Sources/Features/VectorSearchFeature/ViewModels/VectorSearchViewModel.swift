import Foundation
import Observation
import RedisUI
import SwiftUI

/// Preserves the current page, editor, and results across section switches.
@Observable
@MainActor
final class VectorSearchViewModel {
    let session: DatabaseSession
    private(set) var route: VectorSearchRoute = .entry

    private(set) var indexNames: [Data] = []
    private(set) var infos: [Data: SearchIndexInfo] = [:]
    private(set) var hasLoadedList = false
    private(set) var isLoadingList = false
    private(set) var isLoadingInfos = false
    private(set) var listError: String?

    var filter = ""
    var sortOrder: [KeyPathComparator<IndexListRow>] = []
    var infoPanelIndex: Data?
    var pendingDelete: Data?
    private(set) var isDeleting = false

    var isSamplePickerPresented = false
    private(set) var loadingSample: SampleDatasetID?
    private(set) var sampleProgress: BulkImportSummary?

    private(set) var query: QueryPageViewModel?
    private(set) var createIndex: CreateIndexViewModel?
    var isConfirmingDiscard = false

    private var infoTask: Task<Void, Never>?
    private var listGeneration = 0
    private var loadedDBGeneration: Int?

    init(session: DatabaseSession) {
        self.session = session
    }

    var availability: SearchAvailability {
        SearchAvailability.evaluate(state: session.state, capabilities: session.capabilities)
    }

    var showsUpgradeNotice: Bool {
        guard let version = session.capabilities.redisVersion else { return false }
        return !session.capabilities.isVersion(atLeast: "7.2.0") && !version.isEmpty
    }

    // MARK: - Index list

    var rows: [IndexListRow] {
        let rows = IndexListLogic.rows(names: indexNames, infos: infos, filter: filter)
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    var emptyTableMessage: String {
        IndexListLogic.emptyMessage(isLoading: isLoadingInfos, filter: filter)
    }

    var indexNameStrings: Set<String> {
        Set(indexNames.map { String(decoding: $0, as: UTF8.self) })
    }

    /// Loads the list on first use and after a logical-database switch.
    func loadIfNeeded() async {
        guard availability == .available else { return }
        if !hasLoadedList || loadedDBGeneration != session.dbGeneration {
            await loadIndexes()
        }
    }

    /// `FT._LIST`, then `FT.INFO` for every index in parallel; failed FT.INFO rows are dropped.
    func loadIndexes() async {
        guard availability == .available else { return }
        listGeneration += 1
        let token = listGeneration
        infoTask?.cancel()
        isLoadingList = true
        listError = nil
        loadedDBGeneration = session.dbGeneration
        do {
            let names = try await SearchIndexService(session: session).listIndexes()
            guard token == listGeneration else { return }
            indexNames = names
            infos = infos.filter { names.contains($0.key) }
            hasLoadedList = true
            isLoadingList = false
            let task = Task { await self.loadInfos(names, token: token) }
            infoTask = task
            await task.value
        } catch {
            guard token == listGeneration else { return }
            listError = error.localizedDescription
            hasLoadedList = true
            isLoadingList = false
        }

        enforceQueryGuard()
    }

    private func loadInfos(_ names: [Data], token: Int) async {
        isLoadingInfos = true
        let service = SearchIndexService(session: session)
        let loaded = await withTaskGroup(of: (Data, SearchIndexInfo?).self) { group in
            for name in names {
                group.addTask { (name, try? await service.info(name)) }
            }

            var out: [Data: SearchIndexInfo] = [:]
            for await (name, info) in group {
                if let info { out[name] = info }
            }

            return out
        }
        guard token == listGeneration, !Task.isCancelled else { return }
        infos = loaded
        isLoadingInfos = false
    }

    /// Re-reads FT.INFO for one index (info panels).
    @discardableResult
    func refreshInfo(_ name: Data) async -> SearchIndexInfo? {
        do {
            let info = try await SearchIndexService(session: session).info(name)
            infos[name] = info
            return info
        } catch {
            return nil
        }
    }

    // MARK: - Delete

    func requestDelete(_ name: Data) {
        pendingDelete = name
    }

    /// `FT.DROPINDEX` (documents kept), then removes the index's Query Library items.
    @discardableResult
    func deleteIndex(_ name: Data) async -> Bool {
        pendingDelete = nil
        guard !isDeleting else { return false }
        let display = IndexListLogic.displayName(name)
        guard await session.confirm(ConfirmationRequest(title: "Delete Index?", message: "Delete index \(display)?",
                                                        actionID: "FT.DROPINDEX", confirmButtonTitle: "Delete Index"))
        else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await session.execute(["FT.DROPINDEX", .data(name)])
        } catch {
            session.toasts.error(error)
            return false
        }

        do {
            try await session.services.queryLibraryStore.deleteByIndex(databaseID: session.id,
                                                                      indexName: String(decoding: name, as: UTF8.self))
        } catch {
            session.toasts.error("The index was deleted, but its saved queries are still in the library.",
                                 title: "Couldn't Remove Saved Queries")
        }

        if infoPanelIndex == name { infoPanelIndex = nil }
        await loadIndexes()
        return true
    }

    // MARK: - Routing

    func consumeLaunchSheet(options: QALaunchOptions = .current) {
        guard availability == .available, !Self.didConsumeLaunchSheet, options.sheet == "sample-data" else { return }
        Self.didConsumeLaunchSheet = true
        isSamplePickerPresented = true
    }

    private static var didConsumeLaunchSheet = false

    /// Page path below the index list; an empty path returns to the index list.
    func setPath(_ path: [VectorSearchDestination]) {
        guard path.isEmpty, route != .entry else { return }
        if case .createIndex = route, createIndex?.isDirty == true {
            isConfirmingDiscard = true
            return
        }

        showList()
    }

    func showList() {
        isConfirmingDiscard = false
        route = .entry
        createIndex = nil
    }

    func openQuery(_ name: Data, openIndexPanel: Bool = false, tab: QueryEditorTab? = nil) {
        if let query {
            Task { await query.setIndex(name) }
        } else {
            let model = QueryPageViewModel(session: session, indexName: name)
            query = model
            Task {
                await model.loadHistory()
                await model.loadLibrary()
            }
        }

        if openIndexPanel { query?.isIndexPanelOpen = true }
        if let tab { query?.tab = tab }
        route = .query(indexName: name, openIndexPanel: openIndexPanel)
        if infos[name] == nil { Task { await refreshInfo(name) } }
    }

    func openCreateIndex(_ request: CreateIndexRequest) {
        let model = CreateIndexViewModel(session: session, request: request) { [weak self] in
            self?.indexNameStrings ?? []
        }
        createIndex = model
        route = .createIndex(request)
        Task { await model.start() }
    }

    func browseDataset(_ name: Data) {
        session.services.settings.browser.searchMode = .redisearch
        session.navigator.navigate(.browseIndex(indexName: name))
    }

    /// Navigates away from a query page whose index is gone once the list loaded without error.
    func enforceQueryGuard() {
        guard hasLoadedList, listError == nil, case .query(let name, _) = route, !indexNames.contains(name) else { return }
        showList()
    }

    // MARK: - Cross-feature navigation

    func consumeNavigation() {
        let request = session.navigator.consume { request in
            switch request {
            case .vectorSearchQuery, .vectorSearchCreateIndex: return true
            default: return false
            }
        }
        guard let request else { return }
        handle(request)
    }

    func handle(_ request: DatabaseNavigationRequest) {
        switch request {
        case .vectorSearchQuery(let name, let openPanel):
            openQuery(name, openIndexPanel: openPanel)
        case .vectorSearchCreateIndex(let createRequest):
            openCreateIndex(createRequest)
        default:
            break
        }
    }

    // MARK: - Create index

    func createIndexFromPage() async {
        guard let createIndex else { return }
        if case .sampleData(let id) = createIndex.mode {
            await startSample(id)
            return
        }

        guard let name = await createIndex.create() else { return }
        await loadIndexes()
        await query?.loadHistory()
        openQuery(name)
    }

    // MARK: - Sample data

    func startSample(_ id: SampleDatasetID) async {
        guard let dataset = SampleDatasets.dataset(id) else {
            session.toasts.error(SampleDatasetsError.resourceMissing(id.rawValue))
            return
        }
        await startSample(dataset)
    }

    var sampleBlockedReason: String? { QuerySafety.indexCreationBlockedReason(session) }

    func startSample(_ dataset: SampleDataset) async {
        guard loadingSample == nil else { return }
        if let reason = sampleBlockedReason {
            session.toasts.error(reason, title: VectorSearchStrings.createFailedTitle)
            return
        }

        loadingSample = dataset.id
        sampleProgress = nil
        defer {
            loadingSample = nil
            sampleProgress = nil
        }
        do {
            let outcome = try await SampleDataLoader(session: session).load(dataset) { [weak self] progress in
                self?.sampleProgress = progress
            }
            if case .cancelled = outcome { return }
            isSamplePickerPresented = false
            await loadIndexes()
            let name = Data(dataset.indexName.utf8)
            openQuery(name, tab: .library)
            await query?.loadLibrary()
        } catch {
            let message = error.localizedDescription
            session.toasts.error(message.isEmpty ? VectorSearchStrings.createFailedMessage : message,
                                 title: VectorSearchStrings.createFailedTitle)
        }
    }

    // MARK: - Refresh (⌘R)

    func refresh() async {
        switch route {
        case .entry:
            await loadIndexes()
        case .query(let name, _):
            await refreshInfo(name)
            await query?.loadLibrary()
        case .createIndex:
            if createIndex?.mode == .browse { await createIndex?.keys.refresh() }
        }
    }
}
