import Foundation
import Observation
import RedisCore

/// Set members: SSCAN pages, member search (SISMEMBER for exact names), remove, Add Members.
@MainActor
@Observable
public final class SetKeyViewModel {
    public struct Row: Identifiable, Hashable, Sendable {
        public var member: Data
        public var preview: ValuePreview?
        public var id: Data { member }
    }

    public struct AddRow: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var member = ""

        public init(member: String = "") {
            self.member = member
        }
    }

    public let context: KeyDetailsContext
    public private(set) var rows: [Row] = []
    public private(set) var total = 0
    public private(set) var nextCursor: UInt64 = 0
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var loadError: String?
    public private(set) var appliedMatch = "*"
    public var searchText = ""
    public private(set) var expanded: Set<Data> = []
    public private(set) var expandedResults: [Data: FormatResult] = [:]
    public private(set) var isSaving = false

    public var isAddPanelOpen = false {
        didSet { context.state.isAddPanelOpen = isAddPanelOpen }
    }

    public var addRows: [AddRow] = [AddRow()]

    @ObservationIgnored private var formatter: ValueDisplayFormatter
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored let loads = LoadTaskSlot()

    public init(context: KeyDetailsContext) {
        self.context = context
        self.formatter = KeyViewSupport(context: context).formatter
    }

    private var support: KeyViewSupport { KeyViewSupport(context: context) }
    private var service: SetService { SetService(session: context.session) }

    public var format: ValueFormat { formatter.format }
    public var canLoadMore: Bool { nextCursor != 0 }
    public var isFiltered: Bool { appliedMatch != "*" }
    public var keyDisplayName: String { support.keyDisplayName }
    public var isLastItem: Bool { total <= 1 }

    // MARK: - Loading

    /// Starts `load()`, cancelling a load that is still running.
    public func reload() {
        loads.run { [weak self] in await self?.load() }
    }

    /// Header Refresh / auto-refresh: skipped while a load is still running.
    public func refresh() {
        loads.runUnlessRunning { [weak self] in await self?.load() }
    }

    /// Starts `applySearch()`, cancelling a load that is still running.
    public func search() {
        loads.run { [weak self] in await self?.applySearch() }
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        formatter = support.formatter
        isLoading = true
        loadError = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let page = try await service.members(context.key, match: appliedMatch)
            guard generation == loadGeneration else { return }
            total = page.total
            nextCursor = page.nextCursor
            rows = page.members.map { Row(member: $0) }
            expanded.removeAll()
            expandedResults.removeAll()
            await computePreviews(generation: generation)
        } catch {
            guard generation == loadGeneration, !isCancellation(error) else { return }
            if let keyError = error as? KeyOperationError, keyError == .keyNotFound {
                support.report(error)
                return
            }

            rows = []
            loadError = error.localizedDescription
        }
    }

    public func loadMore() async {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        do {
            let page = try await service.members(context.key, match: appliedMatch, cursor: nextCursor)
            guard generation == loadGeneration else { return }
            total = page.total
            nextCursor = page.nextCursor
            let known = Set(rows.map(\.member))
            rows += page.members.filter { !known.contains($0) }.map { Row(member: $0) }
            await computePreviews(generation: generation)
        } catch {
            support.report(error)
        }
    }

    public func applySearch() async {
        appliedMatch = searchText.isEmpty ? "*" : searchText
        await load()
    }

    public func formatChanged() async {
        formatter = support.formatter
        expanded.removeAll()
        expandedResults.removeAll()
        for index in rows.indices { rows[index].preview = nil }
        await computePreviews(generation: loadGeneration)
    }

    private func computePreviews(generation: Int) async {
        let formatter = self.formatter
        let pending = rows.enumerated().filter { $0.element.preview == nil }.map { ($0.offset, $0.element.member) }
        guard !pending.isEmpty else { return }
        let previews = await offMain { pending.map { formatter.preview($0.1, columnTitle: "Member") } }
        guard generation == loadGeneration, formatter == self.formatter else { return }
        for (i, item) in pending.enumerated() where item.0 < rows.count && rows[item.0].member == item.1 {
            rows[item.0].preview = previews[i]
        }
    }

    public func toggleExpanded(_ member: Data) async {
        if expanded.contains(member) {
            expanded.remove(member)
            expandedResults[member] = nil
            return
        }

        expanded.insert(member)
        let formatter = self.formatter
        let result = await offMain { formatter.result(member, expanded: true) }
        if expanded.contains(member) { expandedResults[member] = result }
    }

    // MARK: - Value preview

    public private(set) var preview: ValuePreviewState?

    public func showPreview(_ member: Data) async {
        let state = ValuePreviewState(title: "Member “\(DisplayName.short(member))”", result: nil,
                                      copyText: copyText(member))
        preview = state
        let formatter = self.formatter
        let result = await offMain { formatter.result(member, expanded: true) }
        if preview?.id == state.id { preview?.result = result }
    }

    public func closePreview() {
        preview = nil
    }

    // MARK: - Remove

    public func removeMember(_ member: Data) async {
        do {
            let result = try await service.remove(context.key, members: [member])
            if result.keyDeleted {
                support.keyWasDeleted()
                return
            }

            rows.removeAll { $0.member == member }
            expanded.remove(member)
            total = max(total - result.removed, 0)
            await support.refreshInfo()
        } catch {
            support.report(error)
        }
    }

    // MARK: - Add

    public func openAddPanel() {
        addRows = [AddRow()]
        isAddPanelOpen = true
    }

    public func closeAddPanel() {
        isAddPanelOpen = false
        addRows = [AddRow()]
    }

    public var canSubmitAdd: Bool { addRows.contains { !$0.member.isEmpty } }

    public func draftMembers() -> [Data] {
        var seen = Set<Data>()
        return addRows.compactMap { row in
            guard !row.member.isEmpty else { return nil }
            let data = Data(row.member.utf8)
            return seen.insert(data).inserted ? data : nil
        }
    }

    @discardableResult
    public func submitAdd() async -> Bool {
        let members = draftMembers()
        guard !members.isEmpty else { return false }
        let ok = await support.confirmProduction(
            title: "Add Members in Production?",
            message: "\(members.count) member(s) will be added to this set. This database is marked as production.",
            actionID: KeyConfirmations.addSetMembers, button: "Add members")
        guard ok else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.add(context.key, members: members)
            closeAddPanel()
            await load()
            await support.refreshInfo()
            return true
        } catch {
            support.report(error)
            return false
        }
    }

    public func copyText(_ member: Data) -> String { formatter.copyText(member) }

    public func viewDidDisappear() {
        loads.cancel()
        if isAddPanelOpen { context.state.isAddPanelOpen = false }
    }
}
