import Foundation
import Observation
import RedisUI

enum ArrayTab: String, CaseIterable, Identifiable {
    case view = "View"
    case search = "Search"
    case aggregate = "Aggregate"
    var id: String { rawValue }
}

struct ArrayRow: Identifiable, Hashable {
    var element: ArrayElement
    var formatted: FormatResult?
    var collapsed: String?
    var id: String { element.index }
}

/// An edit whose text is not valid in the view format, waiting for "Save as Unicode?".
struct ArrayPendingSave: Equatable, Identifiable {
    var index: String
    var text: String
    var id: String { index }
}

struct ArrayContextBand: Hashable {
    var center: String
    var rows: [ArrayRow]
}

struct ArraySearchDisplayRow: Identifiable, Hashable {
    var row: ArrayRow
    var isContext: Bool
    var isCenter: Bool
    var id: String { isContext ? "context:" + row.id : row.id }

    /// Matches in order, with the context band (when any) inserted after its center match.
    static func rows(results: [ArrayRow], band: ArrayContextBand?) -> [ArraySearchDisplayRow] {
        var out: [ArraySearchDisplayRow] = []
        for result in results {
            out.append(ArraySearchDisplayRow(row: result, isContext: false, isCenter: band?.center == result.id))
            if let band, band.center == result.id {
                out += band.rows.map { ArraySearchDisplayRow(row: $0, isContext: true, isCenter: $0.id == band.center) }
            }
        }

        return out
    }
}

@MainActor
@Observable
final class ArrayViewModel {
    let context: KeyDetailsContext
    private var service: ArrayService { ArrayService(session: context.session, key: context.key) }
    private(set) var formatContext: ValueFormatContext

    var tab: ArrayTab = .view

    // MARK: View tab

    var startText = "0"
    var endText = "9"
    var showEmpty = true
    var showsViewPreview = false
    private(set) var rows: [ArrayRow] = []
    private(set) var isViewLoading = false
    private(set) var viewError: String?
    private(set) var hasLoadedView = false
    private var lastView: (start: UInt64, end: UInt64, showEmpty: Bool)?
    var selection: Set<String> = []
    var editingIndex: String? { didSet { syncRefreshDisabled() } }
    var editText = ""
    private var editOriginal: String?
    private(set) var isSavingEdit = false
    var pendingUnicodeSave: ArrayPendingSave?
    /// Index whose editor opens once "Change to Unicode" has switched the view format.
    var pendingEditAfterFormatChange: String?

    // MARK: Add panel

    var isAddPanelOpen = false { didSet { context.state.isAddPanelOpen = isAddPanelOpen } }
    var addIndexText = ""
    var addValue = ""
    var moveToAdded = true
    private(set) var isAdding = false

    // MARK: Search tab

    var predicates: [ArrayGrepPredicate] = [ArrayGrepPredicate()]
    var combineWithAnd = false
    var showsSearchOptions = false
    var searchRangeStart = ""
    var searchRangeEnd = ""
    var noCase = false
    var withValues = true
    var limitEnabled = false
    var limitText = "10"
    var showsSearchPreview = false
    var contextEnabled = false
    var contextSize = 2
    private(set) var searchRows: [ArrayRow] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var hasSearched = false
    private var lastSearch: ArrayGrepRequest?
    private(set) var contextBand: ArrayContextBand?

    // MARK: Aggregate tab

    var aggStartText = "0"
    var aggEndText = "9"
    var aggOp: ArrayAggregateOp = .sum
    var aggValue = ""
    var showsAggregatePreview = false
    private(set) var aggResult: String?
    private(set) var aggResultIsNil = false
    private(set) var aggError: String?
    private(set) var isAggregating = false
    private(set) var hasAggregated = false
    private var lastAggregate: (start: UInt64, end: UInt64, op: ArrayAggregateOp, value: String?)?

    init(context: KeyDetailsContext) {
        self.context = context
        self.formatContext = ValueFormatContext.current(context.session)
    }

    // MARK: View validation

    var viewValidationError: String? {
        guard let start = ArrayIndex.parse(startText), let end = ArrayIndex.parse(endText) else { return ArrayIndex.indexError }
        if showEmpty, ArrayIndex.span(start, end) > ArrayIndex.maxSpan { return ArrayError.rangeTooLarge.localizedDescription }
        return nil
    }

    var viewPreview: String {
        guard let start = ArrayIndex.parse(startText), let end = ArrayIndex.parse(endText) else { return "" }
        return ArrayCommands.preview(showEmpty ? ArrayCommands.range(key: context.key, start: start, end: end)
                                               : ArrayCommands.scan(key: context.key, start: start, end: end))
    }

    // MARK: Loading

    func load() async {
        await runView()
    }

    func refresh() async {
        guard editingIndex == nil else { return }
        formatContext = ValueFormatContext.current(context.session)
        if let lastView { await loadView(start: lastView.start, end: lastView.end, showEmpty: lastView.showEmpty) }
        if let lastSearch { await performSearch(lastSearch) }
        if let lastAggregate {
            await performAggregate(start: lastAggregate.start, end: lastAggregate.end, op: lastAggregate.op, value: lastAggregate.value)
        }
    }

    func runView() async {
        guard viewValidationError == nil, let start = ArrayIndex.parse(startText), let end = ArrayIndex.parse(endText) else { return }
        await loadView(start: start, end: end, showEmpty: showEmpty)
    }

    func resetView() async {
        startText = "0"
        endText = "9"
        showEmpty = true
        await runView()
    }

    private func loadView(start: UInt64, end: UInt64, showEmpty: Bool) async {
        isViewLoading = true
        defer { isViewLoading = false }
        formatContext = ValueFormatContext.current(context.session)
        do {
            let elements = try await service.range(start: start, end: end, showEmpty: showEmpty)
            if elements.isEmpty, !hasLoadedView, !(try await service.exists()) { throw KeyOperationError.keyNotFound }
            lastView = (start, end, showEmpty)
            rows = await makeRows(elements)
            let indexes = Set(rows.map(\.id))
            selection = selection.intersection(indexes)
            viewError = nil
            hasLoadedView = true
        } catch is CancellationError {
        } catch {
            if KeyOperationError.isKeyNotFound(error) {
                context.report(error)
            } else {
                viewError = error.localizedDescription
                hasLoadedView = true
            }
        }
    }

    func formatChanged() async {
        let current = ValueFormatContext.current(context.session)
        guard current != formatContext else { return }
        formatContext = current
        editingIndex = nil
        pendingUnicodeSave = nil
        rows = await makeRows(rows.map(\.element))
        searchRows = await makeRows(searchRows.map(\.element))
        if let band = contextBand { contextBand = ArrayContextBand(center: band.center, rows: await makeRows(band.rows.map(\.element))) }
        if let pending = pendingEditAfterFormatChange {
            pendingEditAfterFormatChange = nil
            if let row = rows.first(where: { $0.id == pending }) { beginEditing(row) }
        }
    }

    private func makeRows(_ elements: [ArrayElement]) async -> [ArrayRow] {
        let present = elements.compactMap(\.value)
        let formatted = await formatContext.formatAll(present)
        let collapsed = await FormattedValueCell.collapsedTexts(formatted)
        var iterator = zip(formatted, collapsed).makeIterator()
        return elements.map { element in
            guard element.value != nil, let (result, text) = iterator.next() else { return ArrayRow(element: element) }
            return ArrayRow(element: element, formatted: result, collapsed: text)
        }
    }

    // MARK: Editing

    var needsNonUnicodeGuard: Bool { formatContext.requiresNonUnicodeGuard }

    func beginEditing(_ row: ArrayRow) {
        let editable = formatContext.editableText(row.element.value ?? Data())
        guard let text = editable.text else {
            context.session.toasts.error(editable.reason ?? "This value cannot be edited")
            return
        }
        editText = text
        editOriginal = text
        editingIndex = row.id
    }

    func editReason(_ row: ArrayRow) -> String? {
        formatContext.editableText(row.element.value ?? Data()).reason
    }

    /// Saves the Edit Value sheet. Unchanged text closes it without writing.
    @discardableResult
    func saveEdit() async -> Bool {
        guard let index = editingIndex else { return false }
        return await save(index: index, text: editText, closesEditor: true, original: editOriginal)
    }

    @discardableResult
    func save(index: String, text: String) async -> Bool {
        await save(index: index, text: text, closesEditor: false, original: nil)
    }

    @discardableResult
    func confirmUnicodeSave() async -> Bool {
        guard let pending = pendingUnicodeSave else { return false }
        pendingUnicodeSave = nil
        return await save(index: pending.index, text: pending.text, closesEditor: editingIndex == pending.index,
                          original: nil, allowUnicodeFallback: true)
    }

    func cancelUnicodeSave() {
        pendingUnicodeSave = nil
    }

    private func save(index: String, text: String, closesEditor: Bool, original: String?,
                      allowUnicodeFallback: Bool = false) async -> Bool {
        if let original, original == text {
            if closesEditor { editingIndex = nil }
            return true
        }

        let value: Data
        do {
            value = try formatContext.parseEditedStrictly(text)
        } catch FormatterError.invalidInput {
            guard allowUnicodeFallback else {
                pendingUnicodeSave = ArrayPendingSave(index: index, text: text)
                return false
            }
            do {
                value = try formatContext.parseEdited(text)
            } catch {
                context.session.toasts.error(error)
                return false
            }
        } catch {
            context.session.toasts.error(error)
            return false
        }

        guard await context.confirmWrite(title: "Edit Element in Production?",
                                         message: "The array element will be overwritten. This database is marked as production.",
                                         button: "Save", actionID: KeyConfirmations.editArrayElement) else { return false }
        isSavingEdit = true
        defer { isSavingEdit = false }
        do {
            try await service.set(index: index, value: value)
            editingIndex = nil
            await refreshAllViews()
            return true
        } catch {
            context.report(error)
            return false
        }
    }

    // MARK: Deleting

    func delete(indexes: [String]) async {
        guard !indexes.isEmpty else { return }
        do {
            _ = try await service.delete(indexes: Array(indexes.prefix(1_000_000)))
            guard try await afterDelete() else { return }
            selection.subtract(indexes)
        } catch {
            context.report(error)
        }
    }

    func deleteViewRange() async {
        guard let start = ArrayIndex.parse(startText), let end = ArrayIndex.parse(endText) else { return }
        do {
            _ = try await service.deleteRange(start: start, end: end)
            guard try await afterDelete() else { return }
        } catch {
            context.report(error)
        }
    }

    private func afterDelete() async throws -> Bool {
        guard try await service.exists() else {
            context.keyWasDeleted()
            return false
        }
        await refreshAllViews()
        return true
    }

    private func refreshAllViews() async {
        await context.valueChanged()
        if let lastView { await loadView(start: lastView.start, end: lastView.end, showEmpty: lastView.showEmpty) }
        if let lastSearch { await performSearch(lastSearch) }
        if let lastAggregate {
            await performAggregate(start: lastAggregate.start, end: lastAggregate.end, op: lastAggregate.op, value: lastAggregate.value)
        }
    }

    // MARK: Adding

    var addIndexError: String? {
        let trimmed = addIndexText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return ArrayIndex.parse(trimmed) == nil ? ArrayIndex.addIndexError : nil
    }

    var isAddValid: Bool { addIndexError == nil }

    func openAddPanel() {
        addIndexText = ""
        addValue = ""
        moveToAdded = true
        isAddPanelOpen = true
    }

    func saveAdd() async {
        guard isAddValid else { return }
        guard await context.confirmWrite(title: "Add Element in Production?",
                                         message: "One element will be added to this array. This database is marked as production.",
                                         button: "Add Element", actionID: KeyConfirmations.addArrayElement) else { return }
        isAdding = true
        defer { isAdding = false }
        let value = Data(addValue.utf8)
        let explicit = addIndexText.trimmingCharacters(in: .whitespaces)
        do {
            let index: String
            if explicit.isEmpty {
                index = try await service.append(value)
            } else {
                try await service.set(index: explicit, value: value)
                index = explicit
            }

            isAddPanelOpen = false
            if moveToAdded, let added = UInt64(index), !isInView(added) {
                let window = ArrayIndex.revealWindow(for: added)
                startText = String(window.start)
                endText = String(window.end)
                showEmpty = true
                tab = .view
                await context.valueChanged()
                await runView()
                if let lastSearch { await performSearch(lastSearch) }
            } else {
                await refreshAllViews()
            }
        } catch {
            context.report(error)
        }
    }

    private func isInView(_ index: UInt64) -> Bool {
        guard let lastView else { return false }
        let low = min(lastView.start, lastView.end)
        let high = max(lastView.start, lastView.end)
        return index >= low && index <= high
    }

    // MARK: Search

    var limitError: String? {
        guard limitEnabled else { return nil }
        guard let value = Int(limitText.trimmingCharacters(in: .whitespaces)), (1...1_000_000).contains(value) else {
            return "Enter a limit from 1 to 1,000,000"
        }
        return nil
    }

    var searchRangeError: String? {
        for text in [searchRangeStart, searchRangeEnd] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "-" || trimmed == "+" { continue }
            if ArrayIndex.parse(trimmed) == nil { return ArrayIndex.indexError }
        }

        return nil
    }

    var searchRequest: ArrayGrepRequest? {
        guard limitError == nil, searchRangeError == nil, !predicates.isEmpty else { return nil }
        let limit = limitEnabled ? Int(limitText.trimmingCharacters(in: .whitespaces)) : nil
        return ArrayGrepRequest(start: searchRangeStart, end: searchRangeEnd, predicates: predicates,
                                combineWithAnd: combineWithAnd, noCase: noCase, withValues: withValues, limit: limit)
    }

    var searchPreview: String {
        searchRequest.map { ArrayCommands.preview(ArrayCommands.grep(key: context.key, request: $0)) } ?? ""
    }

    func runSearch() async {
        guard let request = searchRequest else { return }
        await performSearch(request)
    }

    func resetSearch() {
        predicates = [ArrayGrepPredicate()]
        combineWithAnd = false
        searchRangeStart = ""
        searchRangeEnd = ""
        noCase = false
        withValues = true
        limitEnabled = false
        limitText = "10"
        searchRows = []
        searchError = nil
        hasSearched = false
        lastSearch = nil
        contextBand = nil
    }

    private func performSearch(_ request: ArrayGrepRequest) async {
        isSearching = true
        defer { isSearching = false }
        formatContext = ValueFormatContext.current(context.session)
        do {
            let elements = try await service.grep(request)
            searchRows = await makeRows(elements)
            lastSearch = request
            searchError = nil
            contextBand = nil
        } catch is CancellationError {
        } catch {
            searchError = error.localizedDescription
            searchRows = []
        }

        hasSearched = true
    }

    var searchDisplayRows: [ArraySearchDisplayRow] {
        ArraySearchDisplayRow.rows(results: searchRows, band: contextBand)
    }

    func toggleContext(for row: ArrayRow) async {
        guard contextEnabled, let center = UInt64(row.id) else { return }
        if contextBand?.center == row.id {
            contextBand = nil
            return
        }

        let size = UInt64(min(max(contextSize, 0), 50))
        let start = center >= size ? center - size : 0
        let end = ArrayIndex.maxIndex - center >= size ? center + size : ArrayIndex.maxIndex
        do {
            let elements = try await service.range(start: start, end: end, showEmpty: true)
            contextBand = ArrayContextBand(center: row.id, rows: await makeRows(elements))
        } catch {
            context.report(error)
        }
    }

    // MARK: Aggregate

    var aggregateValidationError: String? {
        guard let start = ArrayIndex.parse(aggStartText), let end = ArrayIndex.parse(aggEndText) else { return ArrayIndex.indexError }
        if ArrayIndex.span(start, end) > ArrayIndex.maxSpan { return ArrayError.aggregateRangeTooLarge.localizedDescription }
        return nil
    }

    var aggregatePreview: String {
        guard let start = ArrayIndex.parse(aggStartText), let end = ArrayIndex.parse(aggEndText) else { return "" }
        return ArrayCommands.preview(ArrayCommands.aggregate(key: context.key, start: start, end: end, op: aggOp,
                                                             value: aggOp == .match ? aggValue : nil))
    }

    func runAggregate() async {
        guard aggregateValidationError == nil, let start = ArrayIndex.parse(aggStartText),
              let end = ArrayIndex.parse(aggEndText) else { return }
        await performAggregate(start: start, end: end, op: aggOp, value: aggOp == .match ? aggValue : nil)
    }

    func resetAggregate() {
        aggStartText = "0"
        aggEndText = "9"
        aggOp = .sum
        aggValue = ""
        aggResult = nil
        aggResultIsNil = false
        aggError = nil
        hasAggregated = false
        lastAggregate = nil
    }

    private func performAggregate(start: UInt64, end: UInt64, op: ArrayAggregateOp, value: String?) async {
        isAggregating = true
        defer { isAggregating = false }
        do {
            let result = try await service.aggregate(start: start, end: end, op: op, value: value)
            aggResult = result
            aggResultIsNil = result == nil
            aggError = nil
            lastAggregate = (start, end, op, value)
        } catch is CancellationError {
        } catch {
            aggError = error.localizedDescription
            aggResult = nil
            aggResultIsNil = false
        }

        hasAggregated = true
    }

    private func syncRefreshDisabled() {
        context.state.isRefreshDisabled = editingIndex != nil
    }
}
