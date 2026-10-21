import Foundation
import Observation
import RedisUI

struct VectorElementRow: Identifiable, Hashable {
    var name: Data
    var formatted: FormatResult
    var collapsed: String
    var attributes: String?
    var id: Data { name }
}

struct VectorElementInput: Identifiable, Hashable {
    let id = UUID()
    var name = ""
    var vector = ""
    var attributes = ""
    var showsAttributes = false
}

extension SimilarityMatch {
    var nameText: String { Bytes.text(name) }
    var sortScore: Double { score.isFinite ? score : -.infinity }
}

enum SimilaritySortField: Hashable {
    case rank, element, similarity
    case attribute(String)
}

struct FormattedElementName: Hashable {
    var result: FormatResult
    var collapsed: String
}

struct ElementDetailsState: Equatable {
    var name: Data
    var vectorText = ""
    var vectorValues: [Double] = []
    var isTruncated = false
    var attributes = ""
    var draftAttributes = ""
    var isEditingAttributes = false
    var isLoading = true
    var isSaving = false
    var error: String?
}

@MainActor
@Observable
final class VectorSetViewModel {
    let context: KeyDetailsContext
    private var service: VectorSetService { VectorSetService(session: context.session, key: context.key) }

    private(set) var total = 0
    private(set) var info = VectorSetInfo()
    private(set) var rows: [VectorElementRow] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var isPaginationSupported = true
    private(set) var nextCursor: Data?
    private(set) var isLoadingMore = false
    /// Bumped by every reload from the start; older page results are dropped.
    @ObservationIgnored private var listGeneration = 0
    private(set) var formatContext: ValueFormatContext
    /// Attribute keys seen in listed elements and results (autocomplete, columns).
    private(set) var knownAttributeKeys: [String] = []

    // MARK: Search form

    var mode: SimilarityMode = .vector { didSet { previewInputsChanged() } }
    var queryText = "" { didSet { previewInputsChanged() } }
    var resultCount = 10 { didSet { previewInputsChanged() } }
    var filter = "" { didSet { previewInputsChanged() } }
    var efText = "" { didSet { previewInputsChanged() } }
    var epsilonText = "" { didSet { previewInputsChanged() } }
    /// Caret in `filter` as a UTF-16 offset (nil = end of text).
    var filterCaret: Int?
    private(set) var debouncedPreview: String?
    private(set) var isBuildingPreview = false
    @ObservationIgnored private let previewDebouncer = Debouncer(.milliseconds(600))
    var showsPreview = false
    var showsAdvanced = false
    private(set) var results: [SimilarityMatch]? { didSet { resultsChanged() } }
    private(set) var resultRows: [Data: FormattedElementName] = [:]
    /// Top-level attribute values of each result by key, parsed once per result change.
    private(set) var resultAttributes: [Data: [String: String]] = [:]
    /// `results` in the current sort order, recomputed only when the results or the sort change.
    private(set) var sortedResults: [SimilarityMatch] = []
    private(set) var isSearching = false
    var resultSort: SimilaritySortField = .similarity { didSet { sortResults() } }
    var resultSortAscending = false { didSet { sortResults() } }

    // MARK: Details + add

    var details: ElementDetailsState? { didSet { syncRefreshDisabled() } }
    var isAddPanelOpen = false { didSet { context.state.isAddPanelOpen = isAddPanelOpen } }
    var drafts: [VectorElementInput] = [VectorElementInput()]
    private(set) var isSaving = false

    init(context: KeyDetailsContext) {
        self.context = context
        self.formatContext = ValueFormatContext.current(context.session)
    }

    // MARK: Loading

    func load() async {
        await reload(count: VectorSetCommands.pageSize)
    }

    func refresh() async {
        guard details?.isEditingAttributes != true else { return }
        await reload(count: max(rows.count, VectorSetCommands.pageSize))
        if results != nil { await search() }
    }

    func reload(count: Int) async {
        listGeneration += 1
        let generation = listGeneration
        isLoading = true
        defer { if generation == listGeneration { isLoading = false } }
        formatContext = ValueFormatContext.current(context.session)
        do {
            let summary = try await service.info()
            let page = try await service.page(count: count)
            guard generation == listGeneration else { return }
            total = summary.total
            info = summary.info
            isPaginationSupported = page.isPaginationSupported
            nextCursor = page.nextCursor
            rows = await makeRows(page.names, attributes: page.attributes)
            mergeAttributeKeys(Array(page.attributes.values))
            if !isBuildingPreview { debouncedPreview = commandPreview }
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard generation == listGeneration else { return }
            if !hasLoaded, !KeyOperationError.isKeyNotFound(error) { errorMessage = error.localizedDescription }
            context.report(error)
        }
    }

    var canLoadMore: Bool { isPaginationSupported && nextCursor != nil }

    func loadMore() {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        Task { @MainActor in await loadNextPage() }
    }

    func loadNextPage() async {
        guard canLoadMore, !isLoadingMore, !isLoading, let cursor = nextCursor else { return }
        let generation = listGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.page(start: cursor)
            guard generation == listGeneration else { return }
            let known = Set(rows.map(\.name))
            let fresh = page.names.filter { !known.contains($0) }
            let newRows = await makeRows(fresh, attributes: page.attributes)
            guard generation == listGeneration else { return }
            total = page.total
            nextCursor = page.nextCursor
            rows += newRows
            mergeAttributeKeys(Array(page.attributes.values))
        } catch is CancellationError {
        } catch {
            guard generation == listGeneration else { return }
            nextCursor = nil
            context.report(error)
        }
    }

    var listStatusText: String {
        let shown = NumberFormatting.grouped(rows.count)
        let all = NumberFormatting.grouped(total)
        return isPaginationSupported ? "Showing \(shown) of \(all)" : "Previewing \(shown) of \(all)"
    }

    func formatChanged() async {
        let current = ValueFormatContext.current(context.session)
        guard current != formatContext else { return }
        formatContext = current
        rows = await makeRows(rows.map(\.name), attributes: Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.attributes ?? "") }))
        if let results { await formatResults(results) }
    }

    private func makeRows(_ names: [Data], attributes: [Data: String]) async -> [VectorElementRow] {
        let formatted = await formatContext.formatAll(names, names: true)
        let collapsed = await FormattedValueCell.collapsedTexts(formatted)
        return zip(names, zip(formatted, collapsed)).map { name, display in
            let attrs = attributes[name].flatMap { $0.isEmpty ? nil : $0 }
            return VectorElementRow(name: name, formatted: display.0, collapsed: display.1, attributes: attrs)
        }
    }

    func mergeAttributeKeys(_ attributes: [String]) {
        let keys = VectorSetCommands.attributeKeys(attributes)
        knownAttributeKeys = Array(Set(knownAttributeKeys).union(keys)).sorted()
    }

    // MARK: Similarity search

    var queryError: String? {
        guard mode == .vector, !queryText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if case .failure(let error) = VectorParser.parse(queryText, expectedDimension: info.inputDimension) {
            return error.localizedDescription
        }

        return nil
    }

    var request: SimilarityRequest? {
        let query: SimilarityQueryInput
        switch mode {
        case .element:
            guard !queryText.isEmpty else { return nil }
            query = .element(Data(queryText.utf8))
        case .vector:
            guard case .success(let vector) = VectorParser.parse(queryText, expectedDimension: info.inputDimension) else { return nil }
            query = .vector(vector)
        }

        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return SimilarityRequest(key: context.key, query: query,
                                 count: min(max(resultCount, 1), VectorSetCommands.maxSimilarityCount),
                                 filter: trimmedFilter.isEmpty ? nil : trimmedFilter,
                                 ef: Int(efText.trimmingCharacters(in: .whitespaces)),
                                 epsilon: Double(epsilonText.trimmingCharacters(in: .whitespaces)),
                                 withAttributes: context.session.capabilities.supportsVsimWithAttribs)
    }

    var commandPreview: String? {
        request.map(VectorSetCommands.similarityPreview)
    }

    private func previewInputsChanged() {
        isBuildingPreview = true
        previewDebouncer.schedule { [weak self] in self?.rebuildPreview() }
    }

    func rebuildPreview() {
        previewDebouncer.cancel()
        debouncedPreview = commandPreview
        isBuildingPreview = false
    }

    var filterSuggestions: [String] {
        guard VectorSetCommands.filterToken(in: filter, caret: filterCaret) != nil else { return [] }
        return VectorSetCommands.filterSuggestions(text: filter, caret: filterCaret, keys: knownAttributeKeys)
    }

    var filterCompletions: [(suggestion: String, text: String)] {
        filterSuggestions.compactMap { suggestion in
            VectorSetCommands.applySuggestion(suggestion, to: filter, caret: filterCaret).map { (suggestion, $0.text) }
        }
    }

    /// Replaces the token at the caret with `suggestion`; returns the new caret (UTF-16 offset).
    @discardableResult
    func applySuggestion(_ suggestion: String) -> Int? {
        guard let applied = VectorSetCommands.applySuggestion(suggestion, to: filter, caret: filterCaret) else { return nil }
        filter = applied.text
        filterCaret = applied.caret
        return applied.caret
    }

    func search() async {
        guard let request else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let matches = try await service.similarity(request)
            mergeAttributeKeys(matches.compactMap(\.attributes))
            await formatResults(matches)
            results = matches
        } catch {
            context.report(error)
        }
    }

    private func formatResults(_ matches: [SimilarityMatch]) async {
        let names = matches.map(\.name)
        let formatted = await formatContext.formatAll(names, names: true)
        let collapsed = await FormattedValueCell.collapsedTexts(formatted)
        let display = zip(formatted, collapsed).map { FormattedElementName(result: $0, collapsed: $1) }
        resultRows = Dictionary(zip(names, display), uniquingKeysWith: { first, _ in first })
    }

    private func resultsChanged() {
        resultAttributes = Dictionary((results ?? []).map { ($0.name, VectorSetCommands.attributeValues($0.attributes)) },
                                      uniquingKeysWith: { first, _ in first })
        sortResults()
    }

    private func sortResults() {
        sortedResults = Self.sorted(results ?? [], by: resultSort, ascending: resultSortAscending,
                                    attributes: resultAttributes)
    }

    nonisolated static func sorted(_ results: [SimilarityMatch], by field: SimilaritySortField, ascending: Bool,
                                   attributes: [Data: [String: String]]) -> [SimilarityMatch] {
        func ordered(_ keys: [String]) -> [SimilarityMatch] {
            zip(results, keys).sorted { a, b in
                (ascending ? a.1.localizedStandardCompare(b.1) : b.1.localizedStandardCompare(a.1)) == .orderedAscending
            }.map(\.0)
        }

        switch field {
        case .rank:
            return results.sorted { ascending ? $0.rank < $1.rank : $1.rank < $0.rank }
        case .similarity:
            return results.sorted { ascending ? $0.sortScore < $1.sortScore : $1.sortScore < $0.sortScore }
        case .element:
            return ordered(results.map(\.nameText))
        case .attribute(let key):
            return ordered(results.map { attributes[$0.name]?[key] ?? "" })
        }
    }

    func sort(by field: SimilaritySortField) {
        if resultSort == field {
            resultSortAscending.toggle()
        } else {
            resultSort = field
            resultSortAscending = field == .rank || field == .element
        }
    }

    func setResultSort(_ field: SimilaritySortField, ascending: Bool) {
        resultSort = field
        resultSortAscending = ascending
    }

    func clearResults() {
        results = nil
        resultRows = [:]
    }

    func resetForm() {
        mode = .vector
        queryText = ""
        resultCount = 10
        filter = ""
        filterCaret = nil
        efText = ""
        epsilonText = ""
        rebuildPreview()
    }

    func findSimilar(to name: Data) {
        mode = .element
        queryText = Bytes.text(name)
    }

    // MARK: Details

    func openDetails(_ name: Data) async {
        details = ElementDetailsState(name: name)
        do {
            let loaded = try await service.details(name)
            guard details?.name == name else { return }
            let display = VectorSetCommands.embeddingText(loaded.vector)
            details?.vectorValues = loaded.vector
            details?.vectorText = display.text
            details?.isTruncated = display.truncated
            details?.attributes = loaded.attributes ?? ""
            details?.draftAttributes = loaded.attributes ?? ""
            details?.isEditingAttributes = false
            details?.isLoading = false
        } catch {
            guard details?.name == name else { return }
            details?.isLoading = false
            details?.error = error.localizedDescription
        }
    }

    /// Edits the attributes draft; the element counts as being edited (refresh paused) while the draft differs.
    func updateDraftAttributes(_ text: String) {
        guard var state = details else { return }
        state.draftAttributes = text
        state.isEditingAttributes = text != state.attributes
        details = state
    }

    func revertDraftAttributes() {
        guard let attributes = details?.attributes else { return }
        updateDraftAttributes(attributes)
    }

    var draftAttributesWarning: String? {
        guard let draft = details?.draftAttributes, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return JSONParser.isValid(draft) ? nil : "Similarity-search filters work only on attributes stored as JSON."
    }

    func saveAttributes() async {
        guard let state = details, state.draftAttributes != state.attributes else { return }
        let name = state.name
        let draft = state.draftAttributes
        guard await context.confirmWrite(title: "Edit Attributes in Production?",
                                         message: "The element's attributes will be overwritten. This database is marked as production.",
                                         button: "Save", actionID: KeyConfirmations.editVectorAttributes) else { return }
        guard details?.name == name else { return }
        details?.isSaving = true
        do {
            let stored = try await service.setAttributes(name, json: draft)
            if details?.name == name {
                details?.attributes = stored ?? ""
                details?.draftAttributes = stored ?? ""
                details?.isEditingAttributes = false
                details?.isSaving = false
            }

            if let index = rows.firstIndex(where: { $0.name == name }) { rows[index].attributes = stored }
            if let stored { mergeAttributeKeys([stored]) }
            if var current = results, let index = current.firstIndex(where: { $0.name == name }) {
                current[index].attributes = stored
                results = current
            }
        } catch {
            if details?.name == name { details?.isSaving = false }
            context.report(error)
        }
    }

    func vectorDownloadText() -> String {
        guard let values = details?.vectorValues else { return "[]" }
        return "[" + values.map { RedisArgument.format($0) }.joined(separator: ", ") + "]"
    }

    // MARK: Writes

    func remove(_ name: Data) async {
        do {
            let result = try await service.remove([name])
            if result.remaining == 0 {
                context.keyWasDeleted()
                return
            }

            total = result.remaining
            rows.removeAll { $0.name == name }
            if results != nil { results?.removeAll { $0.name == name } }
            if details?.name == name { details = nil }
            await context.valueChanged()
        } catch {
            context.report(error)
        }
    }

    func lastItemWarning() -> String? {
        total <= 1 ? "Removing the last item deletes the key." : nil
    }

    func openAddPanel() {
        drafts = [VectorElementInput()]
        isAddPanelOpen = true
    }

    /// Dimension later rows must match: the set's dimension, else the first valid draft vector.
    func expectedDimension(forDraftAt index: Int) -> Int? {
        if let dimension = info.inputDimension, dimension > 0 { return dimension }
        for draft in drafts.prefix(index) {
            if case .success(let vector) = VectorParser.parse(draft.vector) { return vector.dimension }
        }

        return nil
    }

    var isAddValid: Bool {
        !drafts.isEmpty && drafts.indices.allSatisfy { index in
            let draft = drafts[index]
            guard !draft.name.isEmpty else { return false }
            guard case .success = VectorParser.parse(draft.vector, expectedDimension: expectedDimension(forDraftAt: index)) else {
                return false
            }
            return true
        }
    }

    func saveDrafts() async {
        guard isAddValid else { return }
        var elements: [(name: Data, vector: VectorInput, attributes: String?)] = []
        for (index, draft) in drafts.enumerated() {
            guard case .success(let vector) = VectorParser.parse(draft.vector, expectedDimension: expectedDimension(forDraftAt: index)) else { return }
            let attributes = draft.attributes.trimmingCharacters(in: .whitespacesAndNewlines)
            elements.append((Data(draft.name.utf8), vector, attributes.isEmpty ? nil : attributes))
        }

        guard await context.confirmWrite(title: "Add Elements in Production?",
                                         message: "\(elements.count) element(s) will be added to this vector set. This database is marked as production.",
                                         button: "Add Elements", actionID: KeyConfirmations.addVectorElements) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.add(elements, create: info.addOptions)
            isAddPanelOpen = false
            await reload(count: max(rows.count, VectorSetCommands.pageSize))
            await context.valueChanged()
        } catch {
            context.report(error)
        }
    }

    private func syncRefreshDisabled() {
        context.state.isRefreshDisabled = details?.isEditingAttributes == true
    }
}
