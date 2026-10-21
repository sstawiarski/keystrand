import Foundation
import Observation
import RedisCore

/// List elements: LRANGE pages, index search (LINDEX), inline LSET, Add Elements, Remove Elements.
@MainActor
@Observable
public final class ListKeyViewModel {
    public struct Row: Identifiable, Hashable, Sendable {
        public var index: Int
        public var value: Data
        public var preview: ValuePreview?
        public var id: Int { index }
    }

    public struct AddRow: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var element = ""

        public init(element: String = "") {
            self.element = element
        }
    }

    public enum Panel: Hashable { case add, remove }

    public let context: KeyDetailsContext
    public private(set) var rows: [Row] = []
    public private(set) var total = 0
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var loadError: String?
    /// Index search ("Index: n"); nil = all elements.
    public private(set) var searchedIndex: Int?
    public private(set) var searchError: String?
    public var searchText = ""
    public private(set) var expanded: Set<Int> = []
    public private(set) var expandedResults: [Int: FormatResult] = [:]

    public private(set) var editingIndex: Int?
    public var editDraft = ""
    public private(set) var isSaving = false
    @ObservationIgnored public var pendingEditAfterFormatChange: Int?

    public var panel: Panel? {
        didSet { context.state.isAddPanelOpen = panel != nil }
    }

    public var addDestination: ListDestination = .tail
    public var addRows: [AddRow] = [AddRow()]
    public var removeDestination: ListDestination = .tail
    public var removeCountText = "1"

    @ObservationIgnored private var formatter: ValueDisplayFormatter
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var editOriginalValue: Data?
    @ObservationIgnored private var editOriginalText: String?
    @ObservationIgnored let loads = LoadTaskSlot()

    public init(context: KeyDetailsContext) {
        self.context = context
        self.formatter = KeyViewSupport(context: context).formatter
    }

    private var support: KeyViewSupport { KeyViewSupport(context: context) }
    private var service: ListService { ListService(session: context.session) }

    public var format: ValueFormat { formatter.format }
    public var keyDisplayName: String { support.keyDisplayName }
    public var canLoadMore: Bool { searchedIndex == nil && rows.count < total }

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

    /// First page, or the searched index (kept across refreshes).
    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        formatter = support.formatter
        isLoading = true
        loadError = nil
        searchError = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            if let index = searchedIndex {
                do {
                    let element = try await service.element(context.key, index: index)
                    guard generation == loadGeneration else { return }
                    rows = [Row(index: element.index, value: element.value)]
                } catch KeyValueError.indexOutOfRange {
                    guard generation == loadGeneration else { return }
                    rows = []
                    searchError = KeyValueError.indexOutOfRange.localizedDescription
                }

                total = context.state.info?.length ?? total
            } else {
                let page = try await service.elements(context.key, offset: 0)
                guard generation == loadGeneration else { return }
                total = page.total
                rows = page.elements.map { Row(index: $0.index, value: $0.value) }
            }

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
            let page = try await service.elements(context.key, offset: rows.count)
            guard generation == loadGeneration else { return }
            total = page.total
            let next = rows.count
            rows += page.elements.filter { $0.index >= next }.map { Row(index: $0.index, value: $0.value) }
            await computePreviews(generation: generation)
        } catch {
            support.report(error)
        }
    }

    /// Digits -> LINDEX lookup; empty -> all elements.
    public func applySearch() async {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            searchedIndex = nil
        } else if let index = KeyValueParsing.listIndex(text) {
            searchedIndex = index
        } else {
            searchError = "Index should be a non-negative integer."
            return
        }

        await load()
    }

    public static func sanitizeIndex(_ text: String) -> String { text.filter(\.isASCIIDigit) }

    public func formatChanged() async {
        formatter = support.formatter
        expanded.removeAll()
        expandedResults.removeAll()
        let pending = pendingEditAfterFormatChange
        pendingEditAfterFormatChange = nil
        cancelEdit()
        for index in rows.indices { rows[index].preview = nil }
        await computePreviews(generation: loadGeneration)
        if let pending, rows.contains(where: { $0.index == pending }) { beginEdit(pending) }
    }

    private func computePreviews(generation: Int) async {
        let formatter = self.formatter
        let pending = rows.enumerated().filter { $0.element.preview == nil }.map { ($0.offset, $0.element.index, $0.element.value) }
        guard !pending.isEmpty else { return }
        let previews = await offMain { pending.map { formatter.preview($0.2, columnTitle: "Element") } }
        guard generation == loadGeneration, formatter == self.formatter else { return }
        for (i, item) in pending.enumerated() where item.0 < rows.count && rows[item.0].index == item.1 {
            rows[item.0].preview = previews[i]
        }
    }

    public func toggleExpanded(_ index: Int) async {
        if expanded.contains(index) {
            expanded.remove(index)
            expandedResults[index] = nil
            return
        }

        guard let row = rows.first(where: { $0.index == index }) else { return }
        expanded.insert(index)
        let formatter = self.formatter
        let result = await offMain { formatter.result(row.value, expanded: true) }
        if expanded.contains(index) { expandedResults[index] = result }
    }

    // MARK: - Value preview

    public private(set) var preview: ValuePreviewState?

    public func showPreview(_ index: Int) async {
        guard let row = rows.first(where: { $0.index == index }) else { return }
        let state = ValuePreviewState(title: "Element \(index)", result: nil, copyText: copyText(row.value))
        preview = state
        let formatter = self.formatter
        let result = await offMain { formatter.result(row.value, expanded: true) }
        if preview?.id == state.id { preview?.result = result }
    }

    public func closePreview() {
        preview = nil
    }

    // MARK: - Edit (LSET)

    public func editBlockReason(_ row: Row) -> String? {
        ValueEditRules.editBlockReason(row.value, format: format, isValid: row.preview?.isValid ?? true,
                                       isCompressed: row.preview?.isCompressed ?? false)
    }

    public var needsNonUnicodeGuard: Bool { ValueEditRules.requiresNonUnicodeGuard(format) }

    public func beginEdit(_ index: Int) {
        guard let row = rows.first(where: { $0.index == index }), editBlockReason(row) == nil else { return }
        editDraft = ValueEditRules.editorText(row.value, format: format)
        editOriginalText = editDraft
        editOriginalValue = row.value
        editingIndex = index
        RefreshLock.set(context.state, owner: "value", locked: true)
    }

    public func cancelEdit() {
        editingIndex = nil
        editDraft = ""
        editOriginalText = nil
        editOriginalValue = nil
        RefreshLock.set(context.state, owner: "value", locked: false)
    }

    /// `LSET` only while the element still holds the bytes the edit started from; an unchanged draft writes nothing.
    @discardableResult
    public func saveEdit() async -> Bool {
        guard let index = editingIndex, let original = editOriginalValue else { return false }
        if editDraft == editOriginalText {
            cancelEdit()
            return true
        }

        let ok = await support.confirmProduction(title: "Edit Value in Production?",
                                                 message: "The stored value will be overwritten. This database is marked as production.",
                                                 actionID: KeyConfirmations.editValue, button: "Save")
        guard ok else { return false }
        let value = ValueEditRules.encode(editDraft, format: format).data
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.set(context.key, index: index, value: value, expected: original)
            if let position = rows.firstIndex(where: { $0.index == index }) {
                rows[position].value = value
                rows[position].preview = nil
            }

            if expanded.contains(index) {
                expanded.remove(index)
                await toggleExpanded(index)
            }

            cancelEdit()
            await computePreviews(generation: loadGeneration)
            await support.refreshInfo()
            return true
        } catch {
            support.report(error)
            return false
        }
    }

    // MARK: - Panels

    public func openPanel(_ panel: Panel) {
        cancelEdit()
        addRows = [AddRow()]
        removeCountText = "1"
        self.panel = panel
    }

    public func closePanel() {
        panel = nil
        addRows = [AddRow()]
    }

    public var canSubmitAdd: Bool { addRows.contains { !$0.element.isEmpty } }

    /// Every row is an element (empty rows are skipped only when at least one row has text).
    public func draftElements() -> [Data] {
        addRows.filter { !$0.element.isEmpty }.map { Data($0.element.utf8) }
    }

    @discardableResult
    public func submitAdd() async -> Bool {
        let elements = draftElements()
        guard !elements.isEmpty else { return false }
        let ok = await support.confirmProduction(
            title: "Add Elements in Production?",
            message: "\(elements.count) element(s) will be pushed onto this list. This database is marked as production.",
            actionID: KeyConfirmations.addListElements, button: "Add elements")
        guard ok else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.push(context.key, elements: elements, destination: addDestination)
            closePanel()
            cancelEdit()
            await load()
            await support.refreshInfo()
            return true
        } catch {
            support.report(error)
            return false
        }
    }

    /// Pop with count needs Redis 6.2 (unknown versions are allowed).
    public var supportsPopCount: Bool {
        let caps = context.session.capabilities
        return caps.redisVersion == nil || caps.isVersion(atLeast: "6.2.0")
    }

    public var removeCount: Int? {
        supportsPopCount ? TTLInput.parseCount(removeCountText) : 1
    }

    /// "The last 3 elements of “key” will be removed."
    public var removeConfirmationMessage: String {
        let count = removeCount ?? 0
        let position = removeDestination == .head ? "first" : "last"
        let subject = count == 1 ? "The \(position) element" : "The \(position) \(count) elements"
        let base = "\(subject) of “\(DisplayName.short(keyDisplayName))” will be removed."
        return removeDeletesKey ? base + " Removing every element deletes the key." : base
    }

    public var removeDeletesKey: Bool { (removeCount ?? 0) >= total }

    /// Remove asks once: no dialog in Development, the production confirmation in Production, a dialog otherwise.
    public var skipsRemoveConfirmation: Bool { context.session.environment != .unspecified }

    @discardableResult
    public func submitRemove() async -> [Data]? {
        guard let count = removeCount else { return nil }
        let request = ConfirmationRequest(title: "Remove Elements in Production?",
                                          message: removeConfirmationMessage, actionID: KeyConfirmations.removeItems,
                                          confirmButtonTitle: "Remove")
        guard await support.confirmProduction(request) else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            let removed = try await service.pop(context.key, count: count, destination: removeDestination)
            closePanel()
            cancelEdit()
            let exists = (try? await KeyOperations(session: context.session).exists(context.key)) ?? true
            if !exists {
                support.keyWasDeleted()
                return removed
            }

            await load()
            await support.refreshInfo()
            return removed
        } catch {
            support.report(error)
            return nil
        }
    }

    public func copyText(_ value: Data) -> String { formatter.copyText(value) }

    public func viewDidDisappear() {
        loads.cancel()
        RefreshLock.set(context.state, owner: "value", locked: false)
        if panel != nil { context.state.isAddPanelOpen = false }
    }
}
