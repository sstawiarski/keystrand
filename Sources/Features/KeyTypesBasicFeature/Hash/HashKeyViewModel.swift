import Foundation
import Observation
import RedisCore

/// Hash fields: HSCAN pages, field filter, inline value / field TTL edits, delete, Add Fields.
@MainActor
@Observable
public final class HashKeyViewModel {
    public struct Row: Identifiable, Hashable, Sendable {
        public var field: Data
        public var value: Data
        /// Field TTL seconds; -1 none; nil unknown.
        public var expire: Int?
        public var fieldPreview: ValuePreview?
        public var valuePreview: ValuePreview?
        public var id: Data { field }
    }

    public struct AddRow: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var field = ""
        public var value = ""
        public var ttl = ""

        public init(field: String = "", value: String = "", ttl: String = "") {
            self.field = field
            self.value = value
            self.ttl = ttl
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
    public var showTTL = true
    public private(set) var expanded: Set<Data> = []
    public private(set) var expandedResults: [Data: (field: FormatResult, value: FormatResult)] = [:]

    public private(set) var editingField: Data?
    public var editDraft = ""
    public private(set) var editingTTLField: Data?
    public var ttlDraft = ""
    public private(set) var isSaving = false

    public var isAddPanelOpen = false {
        didSet { context.state.isAddPanelOpen = isAddPanelOpen }
    }

    public var addRows: [AddRow] = [AddRow()]

    /// Field to edit once the format switches to Unicode ("Change to Unicode" in the non-Unicode guard).
    @ObservationIgnored public var pendingEditAfterFormatChange: Data?
    @ObservationIgnored private var formatter: ValueDisplayFormatter
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var editOriginalText: String?
    @ObservationIgnored let loads = LoadTaskSlot()

    public init(context: KeyDetailsContext) {
        self.context = context
        self.formatter = KeyViewSupport(context: context).formatter
    }

    private var support: KeyViewSupport { KeyViewSupport(context: context) }
    private var service: HashService { HashService(session: context.session) }

    public var format: ValueFormat { formatter.format }
    public var supportsFieldTTL: Bool { context.session.capabilities.supportsHashFieldTTL }
    public var showsTTLColumn: Bool { supportsFieldTTL && showTTL }
    public var canLoadMore: Bool { nextCursor != 0 }
    public var keyDisplayName: String { support.keyDisplayName }

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

    /// First page for the current filter (also used by Refresh).
    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        formatter = support.formatter
        isLoading = true
        loadError = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let page = try await service.fields(context.key, match: appliedMatch, includeTTL: supportsFieldTTL)
            guard generation == loadGeneration else { return }
            total = page.total
            context.session.liveTips.reportHashLoaded(key: context.key, total: page.total)
            nextCursor = page.nextCursor
            rows = page.fields.map { Row(field: $0.field, value: $0.value, expire: $0.expire) }
            expanded.removeAll()
            expandedResults.removeAll()
            await computePreviews(generation: generation)
        } catch {
            guard generation == loadGeneration, !isCancellation(error) else { return }
            handleLoadError(error)
        }
    }

    public func loadMore() async {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        do {
            let page = try await service.fields(context.key, match: appliedMatch, cursor: nextCursor,
                                                includeTTL: supportsFieldTTL)
            guard generation == loadGeneration else { return }
            total = page.total
            nextCursor = page.nextCursor
            let known = Set(rows.map(\.field))
            rows += page.fields.filter { !known.contains($0.field) }
                .map { Row(field: $0.field, value: $0.value, expire: $0.expire) }
            await computePreviews(generation: generation)
        } catch {
            support.report(error)
        }
    }

    /// Applies `searchText` (glob via HSCAN MATCH, exact via HGET).
    public func applySearch() async {
        let text = searchText
        appliedMatch = text.isEmpty ? "*" : text
        await load()
    }

    public var isFiltered: Bool { appliedMatch != "*" }

    /// Re-renders previews after a format change; cancels edits and collapses rows.
    public func formatChanged() async {
        formatter = support.formatter
        expanded.removeAll()
        expandedResults.removeAll()
        let pending = pendingEditAfterFormatChange
        pendingEditAfterFormatChange = nil
        cancelEdit()
        for index in rows.indices {
            rows[index].fieldPreview = nil
            rows[index].valuePreview = nil
        }

        await computePreviews(generation: loadGeneration)
        if let pending, rows.contains(where: { $0.field == pending }) { beginEdit(pending) }
    }

    private func computePreviews(generation: Int) async {
        let formatter = self.formatter
        let pending = rows.enumerated().filter { $0.element.valuePreview == nil }.map { ($0.offset, $0.element.field, $0.element.value) }
        guard !pending.isEmpty else { return }
        let previews = await offMain {
            pending.map { (formatter.preview($0.1, columnTitle: "Field"), formatter.preview($0.2, columnTitle: "Value")) }
        }
        guard generation == loadGeneration, formatter == self.formatter else { return }
        for (i, item) in pending.enumerated() where item.0 < rows.count && rows[item.0].field == item.1 {
            rows[item.0].fieldPreview = previews[i].0
            rows[item.0].valuePreview = previews[i].1
        }
    }

    private func handleLoadError(_ error: Error) {
        if let keyError = error as? KeyOperationError, keyError == .keyNotFound {
            support.report(error)
            return
        }

        rows = []
        loadError = error.localizedDescription
    }

    // MARK: - Expand

    public func toggleExpanded(_ field: Data) async {
        if expanded.contains(field) {
            expanded.remove(field)
            expandedResults[field] = nil
            return
        }

        guard let row = rows.first(where: { $0.field == field }) else { return }
        expanded.insert(field)
        let formatter = self.formatter
        let results = await offMain { (formatter.result(row.field, expanded: true), formatter.result(row.value, expanded: true)) }
        if expanded.contains(field) { expandedResults[field] = results }
    }

    // MARK: - Value preview

    public private(set) var preview: ValuePreviewState?

    public func showPreview(_ field: Data) async {
        guard let row = rows.first(where: { $0.field == field }) else { return }
        let state = ValuePreviewState(title: "Value of “\(DisplayName.short(field))”", result: nil,
                                      copyText: copyText(value: row.value))
        preview = state
        let formatter = self.formatter
        let result = await offMain { formatter.result(row.value, expanded: true) }
        if preview?.id == state.id { preview?.result = result }
    }

    public func closePreview() {
        preview = nil
    }

    // MARK: - Value edit

    public func editBlockReason(_ row: Row) -> String? {
        let preview = row.valuePreview
        return ValueEditRules.editBlockReason(row.value, format: format, isValid: preview?.isValid ?? true,
                                              isCompressed: preview?.isCompressed ?? false)
    }

    public var needsNonUnicodeGuard: Bool { ValueEditRules.requiresNonUnicodeGuard(format) }

    public func beginEdit(_ field: Data) {
        guard let row = rows.first(where: { $0.field == field }), editBlockReason(row) == nil else { return }
        cancelTTLEdit()
        editDraft = ValueEditRules.editorText(row.value, format: format)
        editOriginalText = editDraft
        editingField = field
        RefreshLock.set(context.state, owner: "value", locked: true)
    }

    public func cancelEdit() {
        editingField = nil
        editDraft = ""
        editOriginalText = nil
        RefreshLock.set(context.state, owner: "value", locked: editingTTLField != nil)
    }

    /// Saves `editDraft` for the edited field, keeping the field TTL. An unchanged draft writes nothing.
    /// Returns true on success.
    @discardableResult
    public func saveEdit() async -> Bool {
        guard let field = editingField else { return false }
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
            try await service.setFields(context.key, [HashField(field: field, value: value)], applyExpire: false)
            let freshTTL = supportsFieldTTL ? await service.fieldTTLs(context.key, fields: [field]).first ?? nil : nil
            if let index = rows.firstIndex(where: { $0.field == field }) {
                rows[index].value = value
                rows[index].valuePreview = nil
                if supportsFieldTTL { rows[index].expire = freshTTL }
            }

            expandedResults[field] = nil
            if expanded.contains(field) {
                expanded.remove(field)
                await toggleExpanded(field)
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

    // MARK: - Field TTL

    public func beginTTLEdit(_ field: Data) {
        guard let row = rows.first(where: { $0.field == field }) else { return }
        cancelEdit()
        ttlDraft = (row.expire ?? -1) >= 0 ? String(row.expire ?? 0) : ""
        editingTTLField = field
        RefreshLock.set(context.state, owner: "value", locked: true)
    }

    public func cancelTTLEdit() {
        editingTTLField = nil
        ttlDraft = ""
        RefreshLock.set(context.state, owner: "value", locked: editingField != nil)
    }

    /// Empty -> HPERSIST; 0 -> field removed; else HEXPIRE.
    @discardableResult
    public func saveTTL() async -> Bool {
        guard let field = editingTTLField, let ttl = TTLInput.parse(ttlDraft) else { return false }
        let fieldName = DisplayName.short(field)
        let request = ttl == 0
            ? KeyConfirmations.removeItems("The field \(fieldName)", from: support.shortKeyName)
            : ConfirmationRequest(title: "Change Field TTL in Production?",
                                  message: "The TTL of field \(fieldName) will change. This database is marked as production.",
                                  actionID: KeyConfirmations.changeTTL, confirmButtonTitle: "Change TTL")
        guard await support.confirmProduction(request) else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.setFieldTTL(context.key, field: field, ttl: ttl)
            cancelTTLEdit()
            if ttl == 0 {
                await afterFieldsRemoved([field])
            } else {
                let fresh = await service.fieldTTLs(context.key, fields: [field])
                if let index = rows.firstIndex(where: { $0.field == field }) {
                    rows[index].expire = fresh.first ?? ttl
                }

                await support.refreshInfo()
            }

            return true
        } catch {
            support.report(error)
            return false
        }
    }

    // MARK: - Delete

    public var isLastItem: Bool { total <= 1 }

    public func deleteField(_ field: Data) async {
        do {
            let result = try await service.deleteFields(context.key, [field])
            if result.keyDeleted {
                support.keyWasDeleted()
                return
            }

            removeRows([field], removedCount: result.removed)
            await support.refreshInfo()
        } catch {
            support.report(error)
        }
    }

    private func afterFieldsRemoved(_ fields: [Data]) async {
        let exists = (try? await KeyOperations(session: context.session).exists(context.key)) ?? false
        if !exists {
            support.keyWasDeleted()
            return
        }

        removeRows(fields, removedCount: fields.count)
        await support.refreshInfo()
    }

    private func removeRows(_ fields: [Data], removedCount: Int) {
        let set = Set(fields)
        rows.removeAll { set.contains($0.field) }
        expanded.subtract(set)
        total = max(total - removedCount, 0)
    }

    // MARK: - Add fields

    public func openAddPanel() {
        addRows = [AddRow()]
        isAddPanelOpen = true
    }

    public func closeAddPanel() {
        isAddPanelOpen = false
        addRows = [AddRow()]
    }

    public var canSubmitAdd: Bool {
        addRows.contains { !$0.field.isEmpty || !$0.value.isEmpty }
    }

    /// Rows with content become fields (values in UTF-8, TTL when supported).
    public func draftFields() -> [HashField] {
        addRows.filter { !$0.field.isEmpty || !$0.value.isEmpty }.map { row in
            let ttl = supportsFieldTTL ? TTLInput.parse(row.ttl).flatMap { $0 > 0 ? $0 : nil } : nil
            return HashField(field: Data(row.field.utf8), value: Data(row.value.utf8), expire: ttl)
        }
    }

    @discardableResult
    public func submitAdd() async -> Bool {
        let fields = draftFields()
        guard !fields.isEmpty else { return false }
        let ok = await support.confirmProduction(
            title: "Add Fields in Production?",
            message: "\(fields.count) field(s) will be added to this hash. This database is marked as production.",
            actionID: KeyConfirmations.addHashFields, button: "Add fields")
        guard ok else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.setFields(context.key, fields, applyExpire: supportsFieldTTL)
            closeAddPanel()
            await load()
            await support.refreshInfo()
            return true
        } catch {
            support.report(error)
            return false
        }
    }

    // MARK: - Copy

    public func copyText(field: Data) -> String { formatter.copyText(field) }
    public func copyText(value: Data) -> String { formatter.copyText(value) }

    public func viewDidDisappear() {
        loads.cancel()
        RefreshLock.set(context.state, owner: "value", locked: false)
        if isAddPanelOpen { context.state.isAddPanelOpen = false }
    }
}
