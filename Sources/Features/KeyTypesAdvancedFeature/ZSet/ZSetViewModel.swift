import Foundation
import Observation
import RedisUI

struct ZSetRow: Identifiable, Hashable {
    var member: ZSetMember
    var formatted: FormatResult
    var collapsed: String
    var id: Data { member.name }
    /// Sort key of the Score column (the table does not sort locally; the header asks the server).
    var sortScore: Double { member.numericScore ?? 0 }
}

struct ZSetDraftRow: Identifiable, Hashable {
    let id = UUID()
    var member = ""
    var score = ""
}

@MainActor
@Observable
final class ZSetViewModel {
    let context: KeyDetailsContext
    private var service: ZSetService { ZSetService(session: context.session, key: context.key) }

    private(set) var rows: [ZSetRow] = [] { didSet { rowsRevision &+= 1 } }
    @ObservationIgnored private var rowsRevision = 0
    private(set) var total = 0
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var sortOrder: KeySortOrder = .asc
    /// Applied member search ("" = none).
    private(set) var appliedSearch = ""
    var searchText = ""
    private var searchCursor: UInt64 = 0
    private(set) var formatContext: ValueFormatContext

    var editingMember: Data? { didSet { syncRefreshDisabled() } }
    var isAddPanelOpen = false { didSet { syncRefreshDisabled(); context.state.isAddPanelOpen = isAddPanelOpen } }
    var draftRows: [ZSetDraftRow] = [ZSetDraftRow()]
    private(set) var isSaving = false
    private var loadTask: Task<Void, Never>?
    /// Bumped by every full load; page and format results from an older generation are dropped.
    @ObservationIgnored private var loadGeneration = 0

    init(context: KeyDetailsContext) {
        self.context = context
        self.formatContext = ValueFormatContext.current(context.session)
    }

    var isSearching: Bool { !appliedSearch.isEmpty }
    var canLoadMore: Bool { isSearching ? searchCursor != 0 : rows.count < total }

    var isAddValid: Bool {
        !draftRows.isEmpty && draftRows.allSatisfy { ZSetCommands.isValidScore($0.score) }
    }

    // MARK: Loading

    func load() async {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        formatContext = ValueFormatContext.current(context.session)
        do {
            let page: ZSetPage
            if isSearching {
                page = try await service.search(pattern: appliedSearch, cursor: 0)
            } else {
                page = try await service.load(offset: 0, count: ZSetCommands.pageSize, order: sortOrder)
            }

            let newRows = await makeRows(page.members)
            guard generation == loadGeneration else { return }
            if isSearching { searchCursor = page.nextCursor }
            total = page.total
            rows = newRows
            let (tips, key) = (context.session.liveTips, context.key)
            let sample = page.members.prefix(LiveTipRules.timeSeriesSampleSize).map { (member: $0.name, score: $0.score) }
            Task { await tips.reportZSetLoaded(key: key, members: sample) }
            hasLoaded = true
        } catch is CancellationError {
        } catch {
            guard generation == loadGeneration else { return }
            handle(error)
        }
    }

    func loadMore() {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        loadTask = Task { @MainActor in await loadNextPage() }
    }

    func loadNextPage() async {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        let generation = loadGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page: ZSetPage
            if isSearching {
                page = try await service.search(pattern: appliedSearch, cursor: searchCursor)
            } else {
                page = try await service.load(offset: rows.count, count: ZSetCommands.pageSize, order: sortOrder)
            }

            guard !Task.isCancelled, generation == loadGeneration else { return }
            let known = Set(rows.map(\.id))
            let newRows = await makeRows(page.members.filter { !known.contains($0.name) })
            guard !Task.isCancelled, generation == loadGeneration else { return }
            if isSearching { searchCursor = page.nextCursor }
            total = page.total
            rows += newRows
        } catch is CancellationError {
        } catch {
            guard generation == loadGeneration else { return }
            handle(error)
        }
    }

    func refresh() async {
        guard editingMember == nil else { return }
        await load()
    }

    func toggleSort() async {
        await setSort(sortOrder == .asc ? .desc : .asc)
    }

    func setSort(_ order: KeySortOrder) async {
        guard order != sortOrder else { return }
        sortOrder = order
        await load()
    }

    func applySearch() async {
        appliedSearch = searchText
        await load()
    }

    func closeSearch() async {
        searchText = ""
        guard isSearching else { return }
        appliedSearch = ""
        await load()
    }

    func formatChanged() async {
        let context = ValueFormatContext.current(self.context.session)
        guard context != formatContext else { return }
        formatContext = context
        editingMember = nil
        let revision = rowsRevision
        let reformatted = await makeRows(rows.map(\.member))
        guard revision == rowsRevision else { return }
        rows = reformatted
    }

    private func makeRows(_ members: [ZSetMember]) async -> [ZSetRow] {
        let formatted = await formatContext.formatAll(members.map(\.name))
        let collapsed = await FormattedValueCell.collapsedTexts(formatted)
        return zip(members, zip(formatted, collapsed)).map { ZSetRow(member: $0, formatted: $1.0, collapsed: $1.1) }
    }

    // MARK: Writes

    func updateScore(member: Data, score text: String) async {
        let score = ZSetCommands.normalizeScore(text)
        guard !score.isEmpty else {
            context.session.toasts.error("Score should be a number.")
            return
        }
        guard await context.confirmWrite(title: "Edit Value in Production?",
                                         message: "The stored value will be overwritten. This database is marked as production.",
                                         button: "Save", actionID: KeyConfirmations.editValue) else { return }
        do {
            try await service.updateScore(member: member, score: score)
            if let index = rows.firstIndex(where: { $0.id == member }) { rows[index].member.score = score }
            editingMember = nil
            await context.valueChanged()
        } catch {
            handle(error)
        }
    }

    func remove(_ member: Data) async {
        do {
            let remaining = try await service.remove([member])
            if remaining == 0 {
                context.keyWasDeleted()
                return
            }

            rows.removeAll { $0.id == member }
            total = remaining
            await context.valueChanged()
        } catch {
            handle(error)
        }
    }

    func openAddPanel() {
        draftRows = [ZSetDraftRow()]
        isAddPanelOpen = true
    }

    func saveDrafts() async {
        guard isAddValid else { return }
        let members = draftRows.map { (member: Data($0.member.utf8), score: ZSetCommands.normalizeScore($0.score)) }
        guard await context.confirmWrite(title: "Add Members in Production?",
                                         message: "\(members.count) member(s) will be added to this sorted set. This database is marked as production.",
                                         button: "Add Members", actionID: KeyConfirmations.addZSetMembers) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.add(members)
            isAddPanelOpen = false
            await load()
            await context.valueChanged()
        } catch {
            context.report(error)
        }
    }

    private func handle(_ error: Error) {
        if KeyOperationError.isKeyNotFound(error) {
            context.report(error)
            return
        }

        if !hasLoaded { errorMessage = error.localizedDescription }
        context.report(error)
    }

    private func syncRefreshDisabled() {
        context.state.isRefreshDisabled = editingMember != nil
    }

    func lastItemWarning() -> String? {
        total <= 1 ? "Removing the last item deletes the key." : nil
    }
}
