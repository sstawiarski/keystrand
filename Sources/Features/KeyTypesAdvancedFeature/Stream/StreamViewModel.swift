import Foundation
import Observation
import RedisUI

struct StreamEntryRow: Identifiable, Hashable {
    var entry: StreamEntry
    var date: String?
    var values: [StreamColumn: FormatResult]
    /// Single-line cell text of each value, cut to `collapsedLength` characters.
    var collapsed: [StreamColumn: String]
    var id: String { entry.id }

    static let collapsedLength = 650
}

struct StreamFieldInput: Identifiable, Hashable {
    let id = UUID()
    var name = ""
    var value = ""
}

@MainActor
@Observable
final class StreamViewModel {
    let context: KeyDetailsContext
    private var service: StreamService { StreamService(session: context.session, key: context.key) }

    var viewType: StreamViewType = .data
    private(set) var info: StreamInfo?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    // MARK: Data view

    private(set) var rows: [StreamEntryRow] = [] { didSet { rowsRevision &+= 1 } }
    @ObservationIgnored private var rowsRevision = 0
    /// Bumped by every entries reload; older page and reload results are dropped.
    @ObservationIgnored private var entriesGeneration = 0
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    private(set) var columns: [StreamColumn] = []
    private(set) var columnTitles: [StreamColumn: FormatResult] = [:]
    private(set) var canLoadMore = false
    private(set) var isLoadingMore = false
    var sortOrder: KeySortOrder = .desc

    /// Range filter (ms). Nil when the filter is not available.
    var range: ClosedRange<Double>? {
        didSet { if oldValue != nil, range != oldValue, !isApplyingBounds { rangeDebouncer.schedule { [weak self] in await self?.reloadEntries() } } }
    }

    private(set) var bounds: ClosedRange<Double>?
    private var isApplyingBounds = false
    private let rangeDebouncer = Debouncer(.milliseconds(350))
    private(set) var formatContext: ValueFormatContext

    // MARK: Add entry

    var isAddEntryOpen = false { didSet { context.state.isAddPanelOpen = isAddEntryOpen || isAddGroupOpen } }
    var draftId = "*"
    var draftFields: [StreamFieldInput] = [StreamFieldInput()]
    var isDraftIdFocused = true
    private(set) var isSaving = false

    // MARK: Groups

    private(set) var groups: [ConsumerGroup] = []
    var groupSort: [KeyPathComparator<ConsumerGroup>] = [KeyPathComparator(\.displayName)]
    private(set) var selectedGroup: ConsumerGroup?
    var isAddGroupOpen = false { didSet { context.state.isAddPanelOpen = isAddEntryOpen || isAddGroupOpen } }
    var draftGroupName = ""
    var draftGroupId = "$"
    var editingGroupId: Data? { didSet { context.state.isRefreshDisabled = editingGroupId != nil } }

    // MARK: Consumers / messages

    private(set) var consumers: [StreamConsumer] = []
    var consumerSort: [KeyPathComparator<StreamConsumer>] = [KeyPathComparator(\.displayName)]
    private(set) var selectedConsumer: StreamConsumer?
    private(set) var pending: [PendingEntry] = []
    private(set) var pendingCanLoadMore = false
    private(set) var isLoadingMorePending = false

    init(context: KeyDetailsContext) {
        self.context = context
        self.formatContext = ValueFormatContext.current(context.session)
    }

    var sortedGroups: [ConsumerGroup] { groups.sorted(using: groupSort) }
    var sortedConsumers: [StreamConsumer] { consumers.sorted(using: consumerSort) }

    var isRangeFiltered: Bool {
        guard let range, let bounds else { return false }
        return range != bounds
    }

    var isStreamEmpty: Bool { (info?.length ?? 0) == 0 }

    var otherConsumers: [StreamConsumer] {
        guard let selectedConsumer else { return consumers }
        return consumers.filter { $0.name != selectedConsumer.name }
            .sorted { ($0.pending, $0.displayName) < ($1.pending, $1.displayName) }
    }

    // MARK: Loading

    func load() async {
        await reloadEntries(reloadInfo: true)
    }

    func refresh() async {
        switch viewType {
        case .data:
            await reloadEntries(reloadInfo: true)
        case .groups:
            await loadGroups()
        case .consumers:
            if !(await loadConsumers()) { viewType = .groups; await loadGroups() }
        case .messages:
            if !(await loadPending()) { viewType = .consumers; _ = await loadConsumers() }
        }
    }

    func reloadEntries(reloadInfo: Bool = false) async {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        entriesGeneration += 1
        let generation = entriesGeneration
        isLoading = true
        defer { if generation == entriesGeneration { isLoading = false } }
        formatContext = ValueFormatContext.current(context.session)
        do {
            if reloadInfo || info == nil {
                let newInfo = try await service.info()
                guard generation == entriesGeneration else { return }
                info = newInfo
                applyBounds(newInfo)
            }

            let start = StreamCommands.bound(range?.lowerBound, edge: bounds?.lowerBound, open: "-")
            let end = StreamCommands.bound(range?.upperBound, edge: bounds?.upperBound, open: "+")
            let entries = try await service.entries(start: start, end: end, order: sortOrder)
            guard generation == entriesGeneration else { return }
            let built = await buildEntries(entries)
            guard generation == entriesGeneration else { return }
            columns = built.columns
            columnTitles = built.titles
            rows = built.rows
            canLoadMore = entries.count >= StreamCommands.pageSize
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard generation == entriesGeneration else { return }
            if !hasLoaded, !(error is KeyValueError) { errorMessage = error.localizedDescription }
            context.report(error)
        }
    }

    func loadMore() {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        loadMoreTask = Task { @MainActor in await loadNextPage() }
    }

    func loadNextPage() async {
        guard canLoadMore, !isLoadingMore, !isLoading, let last = rows.last?.id,
              let next = StreamID.nextId(after: last, order: sortOrder) else { return }
        let generation = entriesGeneration
        let order = sortOrder
        isLoadingMore = true
        defer { isLoadingMore = false }
        let start = StreamCommands.bound(range?.lowerBound, edge: bounds?.lowerBound, open: "-")
        let end = StreamCommands.bound(range?.upperBound, edge: bounds?.upperBound, open: "+")
        do {
            let page = order == .asc
                ? try await service.entries(start: next, end: end, order: .asc)
                : try await service.entries(start: start, end: next, order: .desc)
            guard !Task.isCancelled, generation == entriesGeneration else { return }
            let known = Set(rows.map(\.id))
            let fresh = page.filter { !known.contains($0.id) }
            let newColumns = StreamCommands.columns(for: fresh).filter { columnTitles[$0] == nil }
            let titles = await formatContext.formatAll(newColumns.map(\.name), names: true)
            let newRows = await makeRows(fresh)
            guard !Task.isCancelled, generation == entriesGeneration else { return }
            for (column, title) in zip(newColumns, titles) where columnTitles[column] == nil {
                columnTitles[column] = title
                columns.append(column)
            }

            rows += newRows
            canLoadMore = page.count >= StreamCommands.pageSize
        } catch is CancellationError {
        } catch {
            guard generation == entriesGeneration else { return }
            canLoadMore = false
            context.report(error)
        }
    }

    func toggleSort() async {
        await setSort(sortOrder == .desc ? .asc : .desc)
    }

    func setSort(_ order: KeySortOrder) async {
        guard order != sortOrder else { return }
        sortOrder = order
        await reloadEntries()
    }

    func resetRange() {
        guard let bounds else { return }
        range = bounds
    }

    func formatChanged() async {
        let current = ValueFormatContext.current(context.session)
        guard current != formatContext else { return }
        formatContext = current
        let revision = rowsRevision
        let built = await buildEntries(rows.map(\.entry))
        guard revision == rowsRevision else { return }
        columns = built.columns
        columnTitles = built.titles
        rows = built.rows
    }

    private func applyBounds(_ info: StreamInfo) {
        isApplyingBounds = true
        defer { isApplyingBounds = false }
        guard info.length > 0, let firstId = info.firstEntryId, let lastId = info.lastEntryId,
              let first = StreamID.milliseconds(firstId), let last = StreamID.milliseconds(lastId), first <= last else {
            bounds = nil
            range = nil
            return
        }
        let newBounds = first...last
        if let old = bounds, let current = range {
            let lower = current.lowerBound <= old.lowerBound ? first : max(current.lowerBound, first)
            let upper = current.upperBound >= old.upperBound ? last : min(current.upperBound, last)
            range = lower <= upper ? lower...upper : newBounds
        } else {
            range = newBounds
        }

        bounds = newBounds
    }

    private func buildEntries(_ entries: [StreamEntry]) async
        -> (columns: [StreamColumn], titles: [StreamColumn: FormatResult], rows: [StreamEntryRow]) {
        let cols = StreamCommands.columns(for: entries)
        let titles = await formatContext.formatAll(cols.map(\.name), names: true)
        let built = await makeRows(entries)
        return (cols, Dictionary(uniqueKeysWithValues: zip(cols, titles)), built)
    }

    private func makeRows(_ entries: [StreamEntry]) async -> [StreamEntryRow] {
        let formatter = formatContext
        let settings = context.session.services.settings.app
        let pattern = settings.dateFormat
        let timeZone = settings.timezone.timeZone
        let build: @Sendable () -> [StreamEntryRow] = {
            entries.map { entry in
                let values = StreamCommands.values(of: entry).mapValues { formatter.format($0) }
                let collapsed = values.mapValues {
                    FormattedValueCell.collapsedText($0, truncateLength: StreamEntryRow.collapsedLength)
                }
                return StreamEntryRow(entry: entry,
                                      date: StreamDates.entryDate(entry.id, pattern: pattern, timeZone: timeZone),
                                      values: values, collapsed: collapsed)
            }
        }
        return await Task.detached(priority: .userInitiated, operation: build).value
    }

    // MARK: Entry writes

    var draftIdError: String? {
        StreamID.entryIdError(draftId, lastGeneratedId: info?.lastGeneratedId)
    }

    var isDraftValid: Bool {
        draftIdError == nil && !draftFields.isEmpty
    }

    func openAddEntry() {
        draftId = "*"
        draftFields = [StreamFieldInput()]
        isAddGroupOpen = false
        isAddEntryOpen = true
    }

    func saveEntry() async {
        guard isDraftValid else { return }
        guard await context.confirmWrite(title: "Add Entry in Production?",
                                         message: "A new entry will be added to this stream. This database is marked as production.",
                                         button: "Add Entry", actionID: KeyConfirmations.addStreamEntry) else { return }
        isSaving = true
        defer { isSaving = false }
        let fields = draftFields.map { StreamField(name: Data($0.name.utf8), value: Data($0.value.utf8)) }
        do {
            _ = try await service.add(id: StreamID.normalizeOnBlur(draftId.trimmingCharacters(in: .whitespaces)), fields: fields)
            isAddEntryOpen = false
            await reloadEntries(reloadInfo: true)
            await context.valueChanged()
        } catch {
            context.report(error)
        }
    }

    func deleteEntry(_ id: String) async {
        do {
            _ = try await service.delete(ids: [id])
            await reloadEntries(reloadInfo: true)
            await context.valueChanged()
        } catch {
            context.report(error)
        }
    }

    // MARK: Groups

    func showGroups() async {
        viewType = .groups
        selectedGroup = nil
        selectedConsumer = nil
        await loadGroups()
    }

    func showData() async {
        viewType = .data
        selectedGroup = nil
        selectedConsumer = nil
        isAddGroupOpen = false
    }

    func loadGroups() async {
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await service.groups()
        } catch {
            context.report(error)
        }
    }

    var draftGroupIdError: String? {
        StreamID.isValidGroupId(draftGroupId) ? nil : "ID format is not correct"
    }

    func openAddGroup() {
        draftGroupName = ""
        draftGroupId = "$"
        isAddEntryOpen = false
        isAddGroupOpen = true
    }

    func saveGroup() async {
        guard !draftGroupName.isEmpty, draftGroupIdError == nil else { return }
        guard await context.confirmWrite(title: "Add Consumer Group in Production?",
                                         message: "A consumer group will be added to this stream. This database is marked as production.",
                                         button: "Add Group", actionID: KeyConfirmations.editStreamGroups) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.createGroup(name: Data(draftGroupName.utf8), id: draftGroupId)
            isAddGroupOpen = false
            if viewType != .groups { viewType = .groups; selectedGroup = nil; selectedConsumer = nil }
            await loadGroups()
        } catch {
            context.report(error)
        }
    }

    func setGroupId(_ group: ConsumerGroup, id: String) async -> Bool {
        guard StreamID.isValidGroupId(id) else { return false }
        guard await context.confirmWrite(title: "Change Last Delivered ID in Production?",
                                         message: "The group's last delivered ID will change. This database is marked as production.",
                                         button: "Save", actionID: KeyConfirmations.editStreamGroups) else { return false }
        do {
            try await service.setGroupId(group: group.name, id: id)
            editingGroupId = nil
            await loadGroups()
            return true
        } catch {
            context.report(error)
            return false
        }
    }

    func deleteGroup(_ group: ConsumerGroup) async {
        do {
            try await service.deleteGroup(group.name)
            await loadGroups()
        } catch {
            context.report(error)
        }
    }

    // MARK: Consumers

    func openGroup(_ group: ConsumerGroup) async {
        selectedGroup = group
        selectedConsumer = nil
        viewType = .consumers
        if !(await loadConsumers()) { viewType = .groups }
    }

    @discardableResult
    func loadConsumers() async -> Bool {
        guard let group = selectedGroup else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            consumers = try await service.consumers(group: group.name)
            return true
        } catch {
            context.report(error)
            return false
        }
    }

    func deleteConsumer(_ consumer: StreamConsumer) async {
        guard let group = selectedGroup else { return }
        do {
            try await service.deleteConsumer(group: group.name, consumer: consumer.name)
            await loadConsumers()
            await refreshGroupsSilently()
        } catch {
            context.report(error)
        }
    }

    // MARK: Pending messages

    func openConsumer(_ consumer: StreamConsumer) async {
        selectedConsumer = consumer
        viewType = .messages
        if !(await loadPending()) { viewType = .consumers }
    }

    @discardableResult
    func loadPending() async -> Bool {
        guard let group = selectedGroup, let consumer = selectedConsumer else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            pending = try await service.pending(group: group.name, consumer: consumer.name)
            pendingCanLoadMore = pending.count >= StreamCommands.pageSize
            return true
        } catch {
            context.report(error)
            return false
        }
    }

    func loadMorePending() {
        guard pendingCanLoadMore, !isLoadingMorePending else { return }
        Task { @MainActor in await loadNextPendingPage() }
    }

    func loadNextPendingPage() async {
        guard pendingCanLoadMore, !isLoadingMorePending, let group = selectedGroup, let consumer = selectedConsumer,
              let last = pending.last?.id else { return }
        let start: String
        if context.session.capabilities.isVersion(atLeast: "6.2") || context.session.capabilities.redisVersion == nil {
            start = "(" + last
        } else if let next = StreamID.nextId(after: last, order: .asc) {
            start = next
        } else {
            return
        }

        isLoadingMorePending = true
        defer { isLoadingMorePending = false }
        do {
            let page = try await service.pending(group: group.name, consumer: consumer.name, start: start)
            pendingCanLoadMore = page.count >= StreamCommands.pageSize
            let known = Set(pending.map(\.id))
            pending += page.filter { !known.contains($0.id) }
        } catch {
            pendingCanLoadMore = false
            context.report(error)
        }
    }

    func ack(_ entry: PendingEntry) async {
        guard let group = selectedGroup else { return }
        guard await context.confirmWrite(title: "Acknowledge Message in Production?",
                                         message: "The pending message will be acknowledged. This database is marked as production.",
                                         button: "Acknowledge", actionID: KeyConfirmations.claimStreamMessages) else { return }
        do {
            _ = try await service.ack(group: group.name, ids: [entry.id])
            pending.removeAll { $0.id == entry.id }
            await afterPendingChange()
        } catch {
            context.report(error)
        }
    }

    static let nothingClaimedMessage = "None of the pending messages has been idle long enough."

    /// Returns false when the message was not idle long enough to be claimed.
    @discardableResult
    func claim(_ entry: PendingEntry, options: ClaimOptions) async -> Bool {
        guard let group = selectedGroup else { return true }
        guard await context.confirmWrite(title: "Claim Message in Production?",
                                         message: "The pending message will be claimed. This database is marked as production.",
                                         button: "Claim", actionID: KeyConfirmations.claimStreamMessages) else { return true }
        do {
            let claimed = try await service.claim(group: group.name, ids: [entry.id], options: options)
            pending.removeAll { claimed.contains($0.id) }
            await afterPendingChange()
            return !claimed.isEmpty
        } catch {
            context.report(error)
            return true
        }
    }

    struct AutoClaimOutcome: Equatable {
        var claimedCount: Int
        /// Start ID of the next batch; `0-0` when the whole pending list was scanned.
        var next: String

        var isComplete: Bool { next == "0-0" }
    }

    /// One `XAUTOCLAIM` batch: pending messages of the group idle for at least `minIdleMs`, from `start`, into
    /// `consumer`. Returns nil when the command failed (the error is reported).
    func autoClaim(to consumer: Data, minIdleMs: Int, start: String, count: Int) async -> AutoClaimOutcome? {
        guard let group = selectedGroup else { return nil }
        guard await context.confirmWrite(title: "Claim Messages in Production?",
                                         message: "Idle pending messages will be claimed. This database is marked as production.",
                                         button: "Claim", actionID: KeyConfirmations.claimStreamMessages) else { return nil }
        do {
            let result = try await service.autoClaim(group: group.name, consumer: consumer, minIdleMs: minIdleMs,
                                                     start: start.isEmpty ? "0-0" : start, count: count)
            await loadPending()
            await afterPendingChange()
            return AutoClaimOutcome(claimedCount: result.ids.count, next: result.next.isEmpty ? "0-0" : result.next)
        } catch {
            context.report(error)
            return nil
        }
    }

    private func afterPendingChange() async {
        guard let group = selectedGroup else { return }
        if let consumers = try? await service.consumers(group: group.name) {
            self.consumers = consumers
            if let selected = selectedConsumer, let updated = consumers.first(where: { $0.name == selected.name }) {
                selectedConsumer = updated
            }
        }
        await refreshGroupsSilently()
    }

    private func refreshGroupsSilently() async {
        guard let groups = try? await service.groups() else { return }
        self.groups = groups
        if let selected = selectedGroup, let updated = groups.first(where: { $0.name == selected.name }) {
            selectedGroup = updated
        }
    }
}
