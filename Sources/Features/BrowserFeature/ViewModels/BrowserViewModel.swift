import Foundation
import Observation
import RedisCore

public enum BrowserRightPanel: Equatable, Sendable {
    case none
    case details
}

/// Sheets presented over the Browser.
public enum BrowserSheet: String, Identifiable, Sendable {
    case newKey
    case bulkActions
    case renameKey
    case setTTL

    public var id: String { rawValue }
}

/// The key to open (nil closes the details) once the user discards the open key's unsaved edits.
public struct PendingSelection: Identifiable, Sendable {
    public let id = UUID()
    public let key: Data?
}

/// Outcome of a rename started from the key list.
public enum KeyRenameOutcome: Equatable, Sendable {
    case renamed
    /// The new name exists; ask before replacing it.
    case nameInUse
    case cancelled
    case failed
}

public struct KeyListSort: Equatable, Sendable {
    public enum Field: Equatable, Sendable, CaseIterable {
        case name
        case ttl
        case size
    }

    public var field: Field
    public var order: RedisCore.SortOrder

    public init(field: Field, order: RedisCore.SortOrder) {
        self.field = field
        self.order = order
    }
}

/// State and logic of the Browser section (key list/tree, filters, search, selection, right panel).
/// Lives in `session.scopedObject` so it survives section switches.
@MainActor
@Observable
public final class BrowserViewModel: SessionScopedObject {
    public static let listScanCount = 500
    public static let treeScanCount = 10_000
    public static let searchPageSize = 500
    public static let infiniteLoadThreshold = 50
    static let metadataDebounce: Duration = .milliseconds(100)
    static let wheelScanDelay: Duration = .milliseconds(100)
    static let scrollAnchorDebounce: Duration = .milliseconds(150)

    public let session: DatabaseSession

    // MARK: Per-database settings

    public private(set) var treeOptions = KeyTreeOptions()
    public private(set) var shownColumns: Set<BrowserColumn> = [.size, .ttl]
    public private(set) var history: [SearchHistoryItem] = []
    @ObservationIgnored private var didLoadSettings = false

    // MARK: Search

    public var patternText = ""
    public private(set) var appliedPattern = "*"
    public private(set) var typeFilter: KeyType?
    public var queryText = ""
    public private(set) var appliedQuery = ""
    public private(set) var indexes: [Data] = []
    public private(set) var selectedIndex: Data?
    public private(set) var isLoadingIndexes = false
    public private(set) var indexesError: String?

    // MARK: Keys

    public private(set) var keys: [KeyListItem] = []
    @ObservationIgnored private var keyIndex: [Data: Int] = [:]
    public private(set) var total: Int?
    public private(set) var scanned = 0
    public private(set) var isComplete = false
    public private(set) var hasStarted = false
    public private(set) var isLoading = false
    public private(set) var isScanningMore = false
    public private(set) var errorMessage: String?
    public private(set) var lastRefresh: Date?
    /// New keys found by the last scan / scan more.
    public private(set) var lastBatchCount = 0

    public var sort: KeyListSort? {
        didSet { sortCache = nil }
    }

    @ObservationIgnored private var scanState: KeyScanState?
    @ObservationIgnored private var searchNextOffset: Int?
    @ObservationIgnored private var searchKeyType: KeyType?
    /// The server's search result cap (`MAXSEARCHRESULTS`, or its valkey-search setting); nil when unknown or
    /// unlimited.
    public private(set) var searchMaxResults: Int?
    /// The search query is empty and the selected index has no match-all query (valkey-search without an indexed
    /// NUMERIC attribute).
    public private(set) var searchNeedsQuery = false
    /// The query run in place of an empty one where the server has no match-all query (`@price:[-inf +inf]` on
    /// valkey-search). It lists only documents that have that field, so the summary shows it.
    public private(set) var searchGeneratedQuery: String?
    /// `matchAllQuery` of an index, reused for its pages until the index or the DB changes.
    @ObservationIgnored private var matchAllCache: (index: Data, generation: Int, query: String?)?
    @ObservationIgnored private var loadToken = 0
    /// Keys with a row delete in flight; a details load that finds one of them gone is not an error.
    @ObservationIgnored private var deletingKeys: Set<Data> = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Bumped when keys are added, removed or reordered.
    @ObservationIgnored private var membershipVersion = 0
    /// Bumped when a row's type, TTL or size changes.
    @ObservationIgnored private var metadataVersion = 0
    @ObservationIgnored private var sortOrder: SortOrderCache?
    @ObservationIgnored private var sortCache: (membership: Int, metadata: Int, sort: KeyListSort, rows: [KeyListItem])?
    @ObservationIgnored private var sortTask: Task<Void, Never>?
    /// Bumped when a detached sort finishes, so the list re-reads `displayedKeys`.
    private var sortRevision = 0

    // MARK: Metadata

    @ObservationIgnored private var visibleKeys = Set<Data>()
    @ObservationIgnored private var pendingMetadata = Set<Data>()
    @ObservationIgnored private var inFlightMetadata = Set<Data>()
    @ObservationIgnored private var loadedMetadata = Set<Data>()
    @ObservationIgnored private var metadataDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextMetadataTaskID = 0
    @ObservationIgnored private var loadedGeneration: Int?

    // MARK: Tree

    public private(set) var treeRoots: [KeyTreeNode] = []
    public private(set) var expandedFolders: Set<String> = []
    public private(set) var isBuildingTree = false
    public var treeSelection: KeyTreeNodeID?
    @ObservationIgnored private var treeTask: Task<Void, Never>?

    // MARK: Scrolling

    @ObservationIgnored private var wheelScanTask: Task<Void, Never>?
    @ObservationIgnored private var visibleTreeRows = Set<KeyTreeNodeID>()
    @ObservationIgnored private var listScrollAnchors: [SearchMode: Data] = [:]
    @ObservationIgnored private var treeScrollAnchors: [SearchMode: KeyTreeNodeID] = [:]
    @ObservationIgnored private var isTrackingScroll = false
    @ObservationIgnored private var scrollAnchorTask: Task<Void, Never>?

    // MARK: Selection and right panel

    public private(set) var selectedKey: Data?
    public private(set) var details: KeyDetailsState?
    public private(set) var detailsType: KeyType?
    public private(set) var detailsError: String?
    public private(set) var rightPanel: BrowserRightPanel = .none
    @ObservationIgnored private var cachedDetailsContext: KeyDetailsContext?
    public var sheet: BrowserSheet?
    /// Key the Rename / Set TTL sheet acts on.
    public private(set) var sheetKey: Data?
    /// Key waiting for the delete confirmation.
    public var pendingDeleteKey: Data?
    /// Selection change waiting for "Discard Changes?" because the open key has unsaved edits.
    public var pendingSelection: PendingSelection?
    /// View Options popover (⌘J).
    public var isViewOptionsPresented = false
    public private(set) var addKey: AddKeyViewModel?
    public private(set) var bulkActions: BulkActionsViewModel?
    public private(set) var isLoadingSampleData = false

    public init(session: DatabaseSession) {
        self.session = session
    }

    public func sessionWillClose() async {
        loadTask?.cancel()
        treeTask?.cancel()
        metadataDebounceTask?.cancel()
        metadataTasks.values.forEach { $0.cancel() }
        wheelScanTask?.cancel()
        scrollAnchorTask?.cancel()
        bulkActions?.cancelAll()
    }

    // MARK: - Derived state

    var settings: SettingsStore { session.services.settings }

    public var keyNameFormat: KeyNameFormat { session.config.keyNameFormat }

    public var isTreeAvailable: Bool { keyNameFormat != .hex }

    /// SCAN MATCH text for the applied filter. While key names show as HEX, a hex filter (`6b6579*`) is read as bytes.
    var scanPattern: String {
        let pattern = appliedPattern.isEmpty ? "*" : appliedPattern
        guard keyNameFormat == .hex else { return pattern }
        return KeyPattern.fromHexFilter(pattern) ?? pattern
    }

    public var viewType: KeyViewType { isTreeAvailable ? settings.browser.viewType : .list }

    public var isSearchAvailable: Bool { session.capabilities.hasSearch && !isSearchVersionTooOld }

    private var isSearchVersionTooOld: Bool { session.capabilities.isRediSearch(below: 20_000) }

    public var searchMode: SearchMode { isSearchAvailable ? settings.browser.searchMode : .pattern }

    /// Nil when search by values is available.
    public var searchUnavailableReason: SearchUnavailableReason? {
        if !session.capabilities.hasSearch { return .moduleNotLoaded }
        if isSearchVersionTooOld { return .versionTooOld }
        return nil
    }

    public var isTypeFilterSupported: Bool {
        session.capabilities.redisVersion == nil || session.capabilities.isVersion(atLeast: "6.0.0")
    }

    /// Pattern or type filter is active (pattern mode).
    public var isFiltered: Bool {
        (appliedPattern != "*" && !appliedPattern.isEmpty) || typeFilter != nil
    }

    public var scanCount: Int { viewType == .tree ? Self.treeScanCount : Self.listScanCount }

    public var canScanMore: Bool { hasStarted && !isComplete && !isLoading && !isScanningMore }

    /// Shows Scan More when filtered, in tree view, or when the total is unknown.
    public var showsScanMoreButton: Bool {
        guard hasStarted, !isComplete else { return false }
        if searchMode == .redisearch {
            return searchNextOffset != nil && (searchMaxResults.map { keys.count < $0 } ?? true)
        }

        return isFiltered || viewType == .tree || total == nil
    }

    /// Shown when RediSearch paging stopped at `MAXSEARCHRESULTS` while the index has more matches.
    public var searchLimitNotice: String? {
        guard searchMode == .redisearch, let max = searchMaxResults, let total, total > max, keys.count >= max else {
            return nil
        }
        return "Results stop at the server's \(SearchIndexService.maxResultsSetting(session.capabilities)) limit. Raise it to see more matches."
    }

    /// Next RediSearch offset, or nil when paging is done. Paging stops at `maxResults`: past it the server returns
    /// no keys, so another page would repeat an empty query.
    nonisolated static func searchNextOffset(_ next: Int?, maxResults: Int?) -> Int? {
        guard let next else { return nil }
        if let maxResults, next >= maxResults { return nil }
        return next
    }

    public var summaryText: String {
        if searchMode == .redisearch {
            guard selectedIndex != nil, hasStarted, !searchNeedsQuery else { return "" }
            return BrowserFormatting.searchSummary(found: keys.count, total: total, generatedQuery: searchGeneratedQuery)
        }

        return BrowserFormatting.summary(found: keys.count, total: total, scanned: scanned, isComplete: isComplete,
                                         isFiltered: isFiltered, isTree: viewType == .tree, isLoading: isLoading,
                                         hasStarted: hasStarted)
    }

    public var isDatabaseEmpty: Bool {
        searchMode == .pattern && hasStarted && !isFiltered && total == 0 && keys.isEmpty
    }

    /// The delete popover shows only in the Unspecified environment; Production asks with its own confirmation.
    public var deleteRequiresConfirmation: Bool { session.environment == .unspecified }

    public var historyItems: [SearchHistoryItem] { SearchHistory.items(history, mode: searchMode) }

    /// Effective columns (user choice; Size hidden by default on production until configured).
    public var showsSize: Bool { shownColumns.contains(.size) }
    public var showsTTL: Bool { shownColumns.contains(.ttl) }

    /// Columns hidden because the pane is too narrow; saved column settings stay unchanged.
    public private(set) var narrowPaneHides: Set<BrowserColumn> = []
    public var showsSizeCell: Bool { showsSize && !narrowPaneHides.contains(.size) }
    public var showsTTLCell: Bool { showsTTL && !narrowPaneHides.contains(.ttl) }

    /// Below 500 pt the list hides Size, below 400 pt Size and TTL. Zero (not laid out yet) hides nothing.
    nonisolated static func columnsHidden(atWidth width: CGFloat) -> Set<BrowserColumn> {
        guard width > 0 else { return [] }
        if width < 400 { return [.size, .ttl] }
        if width < 500 { return [.size] }
        return []
    }

    public func keyListWidthChanged(_ width: CGFloat) {
        let hidden = Self.columnsHidden(atWidth: width)
        if hidden != narrowPaneHides { narrowPaneHides = hidden }
    }

    public func item(for name: Data) -> KeyListItem? {
        guard let index = keyIndex[name], index < keys.count else { return nil }
        return keys[index]
    }

    public func displayName(_ name: Data) -> String {
        BrowserFormatting.keyDisplayName(name, format: keyNameFormat)
    }

    /// Lists up to this size are sorted on the main actor; larger ones off it, showing the previous order meanwhile.
    nonisolated static let mainActorSortLimit = 5_000

    private struct SortOrderCache {
        var membership: Int
        var metadata: Int
        var sort: KeyListSort
        var names: [Data]

        /// A name sort ignores TTL and size changes.
        func isCurrent(for sort: KeyListSort, membership: Int, metadata: Int) -> Bool {
            self.sort == sort && self.membership == membership && (sort.field == .name || self.metadata == metadata)
        }
    }

    /// List rows in display order (client-side sort when set). Metadata batches re-sort only a TTL or Size sort.
    public var displayedKeys: [KeyListItem] {
        _ = sortRevision
        guard let sort else { return keys }
        if let cache = sortCache, cache.membership == membershipVersion, cache.metadata == metadataVersion,
           cache.sort == sort {
            return cache.rows
        }

        let rows = rows(in: sortedNames(for: sort))
        sortCache = (membershipVersion, metadataVersion, sort, rows)
        return rows
    }

    private func sortedNames(for sort: KeyListSort) -> [Data] {
        if let cached = sortOrder, cached.isCurrent(for: sort, membership: membershipVersion, metadata: metadataVersion) {
            return cached.names
        }

        if keys.count <= Self.mainActorSortLimit {
            let names = Self.sorted(keys, by: sort, format: keyNameFormat).map(\.name)
            sortOrder = SortOrderCache(membership: membershipVersion, metadata: metadataVersion, sort: sort, names: names)
            return names
        }

        scheduleSort(sort)
        return sortOrder?.sort == sort ? sortOrder?.names ?? [] : []
    }

    /// Current rows in `names` order; rows the order does not know yet follow in scan order.
    private func rows(in names: [Data]) -> [KeyListItem] {
        var rows: [KeyListItem] = []
        rows.reserveCapacity(keys.count)
        var placed = Set<Data>(minimumCapacity: names.count)
        for name in names {
            guard let index = keyIndex[name], index < keys.count, placed.insert(name).inserted else { continue }
            rows.append(keys[index])
        }

        if rows.count < keys.count {
            rows += keys.filter { !placed.contains($0.name) }
        }

        return rows
    }

    private func scheduleSort(_ sort: KeyListSort) {
        guard sortTask == nil else { return }
        let keys = keys
        let format = keyNameFormat
        let membership = membershipVersion
        let metadata = metadataVersion
        sortTask = Task { [weak self] in
            let names = await Task.detached(priority: .userInitiated) {
                Self.sorted(keys, by: sort, format: format).map(\.name)
            }.value
            guard let self else { return }
            self.sortTask = nil
            guard self.sort == sort else { return }
            self.sortOrder = SortOrderCache(membership: membership, metadata: metadata, sort: sort, names: names)
            self.sortCache = nil
            self.sortRevision += 1
        }
    }

    nonisolated static func sorted(_ keys: [KeyListItem], by sort: KeyListSort, format: KeyNameFormat) -> [KeyListItem] {
        let ascending = sort.order == .asc
        switch sort.field {
        case .name:
            let decorated = keys.map { ($0, RedisKeyName($0.name).displayString(format: format)) }
            return decorated.sorted { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }.map(\.0)
        case .ttl, .size:
            func value(_ item: KeyListItem) -> Int? {
                let raw = sort.field == .ttl ? item.ttl : item.size
                guard let raw, raw >= 0 else { return nil }
                return raw
            }

            return keys.sorted { a, b in
                switch (value(a), value(b)) {
                case let (x?, y?): return ascending ? x < y : x > y
                case (.some, .none): return true
                default: return false
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Every appearance: loads per-database settings, applies a pending navigation request, and loads the first page
    /// unless keys are already loaded for the current logical database.
    public func start(navigation: DatabaseNavigationRequest? = nil) async {
        await ensureSettingsLoaded()
        if let navigation {
            handleNavigation(navigation)
            return
        }

        if let loadedGeneration, loadedGeneration != session.dbGeneration {
            databaseChanged()
            return
        }

        if !hasStarted && !isLoading {
            if searchMode == .redisearch { await loadIndexes() }
            await loadKeys()
        }
    }

    public func ensureSettingsLoaded() async {
        guard !didLoadSettings else { return }
        didLoadSettings = true
        let stored = await session.services.databaseSettingsStore.settings(for: session.id)
        let delimiters = stored.treeViewDelimiters.filter { !$0.isEmpty }
        treeOptions = KeyTreeOptions(delimiters: delimiters.isEmpty ? [":"] : delimiters,
                                     prefixLength: min(max(stored.treeViewDelimiterPrefixLength, 0), KeyTreeBuilder.maxPrefixLength),
                                     sort: stored.treeViewSort)
        if session.isProduction && !stored.didUserConfigureColumns {
            shownColumns = [.ttl]
        } else {
            shownColumns = Set(stored.browserShownColumns)
        }

        history = stored.searchHistory
    }

    private func persist(_ change: @escaping @Sendable (inout DatabaseSettings) -> Void) {
        let store = session.services.databaseSettingsStore
        let id = session.id
        let toasts = session.toasts
        Task {
            do { try await store.update(id, change) } catch { toasts.error(error) }
        }
    }

    // MARK: - Loading keys

    /// Rescans from the start (refresh).
    public func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadKeys(reset: true) }
    }

    /// Waits for the running reload or scan.
    public func waitForLoad() async {
        await loadTask?.value
    }

    /// Continues the scan (or the RediSearch page) and appends keys.
    public func scanMore() {
        guard canScanMore else { return }
        loadTask = Task { [weak self] in await self?.loadKeys(reset: false) }
    }

    public func loadKeys(reset: Bool = true) async {
        await ensureSettingsLoaded()
        loadToken += 1
        let token = loadToken
        if reset { isLoading = true } else { isScanningMore = true }
        defer {
            if token == loadToken {
                isLoading = false
                isScanningMore = false
            }
        }
        do {
            switch searchMode {
            case .pattern:
                let request = ScanRequest(match: scanPattern, type: typeFilter, count: scanCount)
                var state = try await KeyScanner(session: session).scan(request, continuing: reset ? nil : scanState)
                guard token == loadToken else { return }
                let found = state.keys
                state.keys = []
                scanState = state
                total = state.total
                scanned = state.scanned
                isComplete = state.isComplete
                apply(found, reset: reset)
                if !KeyPattern.isGlob(request.match) {
                    for row in found where row.type != nil { loadedMetadata.insert(row.name) }
                }
            case .redisearch:
                guard let index = selectedIndex else {
                    clearKeys()
                    return
                }
                let offset = reset ? 0 : (searchNextOffset ?? 0)
                let service = SearchIndexService(session: session)
                let maxResults = (try? await service.maxSearchResults()) ?? nil
                let query = try await searchQuery(index: index, service: service)
                let page = try await service.searchKeys(index: index, query: query, offset: offset,
                                                        limit: Self.searchPageSize)
                guard token == loadToken else { return }
                searchGeneratedQuery = query == appliedQuery || query == "*" ? nil : query
                let next = Self.searchNextOffset(page.nextOffset, maxResults: maxResults)
                searchMaxResults = maxResults
                searchKeyType = page.keyType
                searchNextOffset = next
                total = page.total
                scanned = offset + page.keys.count
                isComplete = next == nil
                apply(page.keys.map { KeyListItem(name: $0, type: page.keyType) }, reset: reset)
            }

            hasStarted = true
            errorMessage = nil
            searchNeedsQuery = false
            lastRefresh = Date()
            loadedGeneration = session.dbGeneration
            if reset && keys.isEmpty && rightPanel == .details { closeDetails() }
        } catch is CancellationError {
            return
        } catch {
            guard token == loadToken else { return }
            if case SearchIndexError.queryRequired = error {
                clearKeys()
                hasStarted = true
                errorMessage = nil
                searchNeedsQuery = true
                return
            }

            if case SearchIndexError.indexNotFound = error {
                selectedIndex = nil
                clearKeys()
                session.toasts.error(error)
                await loadIndexes()
                return
            }

            if reset {
                clearKeys()
                hasStarted = true
                errorMessage = error.localizedDescription
            } else {
                session.toasts.error(error)
            }
        }
    }

    /// `appliedQuery`, or the index's match-all query when it lists every document.
    private func searchQuery(index: Data, service: SearchIndexService) async throws -> String {
        guard SearchIndexService.needsMatchAll(appliedQuery, capabilities: session.capabilities) else {
            return appliedQuery
        }
        let generation = session.dbGeneration
        let query: String?
        if let cached = matchAllCache, cached.index == index, cached.generation == generation {
            query = cached.query
        } else {
            query = try await service.matchAllQuery(index: index)
            matchAllCache = (index, generation, query)
        }

        guard let query else { throw SearchIndexError.queryRequired }
        return query
    }

    private func apply(_ found: [KeyListItem], reset: Bool) {
        if reset {
            var merged: [KeyListItem] = []
            merged.reserveCapacity(found.count)
            var seen = Set<Data>()
            for var row in found where seen.insert(row.name).inserted {
                if let old = item(for: row.name) {
                    row.type = row.type ?? old.type
                    row.ttl = row.ttl ?? old.ttl
                    row.size = row.size ?? old.size
                }

                merged.append(row)
            }

            keys = merged
            loadedMetadata.removeAll()
            lastBatchCount = merged.count
        } else {
            var added = 0
            for item in found where keyIndex[item.name] == nil {
                keyIndex[item.name] = keys.count
                keys.append(item)
                added += 1
            }

            lastBatchCount = added
        }

        keysDidChange()
        requestVisibleMetadata()
    }

    private func clearKeys() {
        keys = []
        total = nil
        scanned = 0
        isComplete = false
        hasStarted = false
        scanState = nil
        searchNextOffset = nil
        searchNeedsQuery = false
        searchGeneratedQuery = nil
        lastBatchCount = 0
        loadedMetadata.removeAll()
        keysDidChange()
    }

    private func keysDidChange() {
        membershipVersion += 1
        sortCache = nil
        rebuildKeyIndex()
        rebuildTree()
    }

    private func rebuildKeyIndex() {
        var index: [Data: Int] = [:]
        index.reserveCapacity(keys.count)
        for (offset, item) in keys.enumerated() { index[item.name] = offset }
        keyIndex = index
    }

    // MARK: - Filters and search

    /// Applies the pattern typed in the search field (Enter / search button).
    public func applyPattern() {
        let text = patternText.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchMode == .redisearch {
            appliedQuery = text
            if !text.isEmpty { addHistory(SearchHistoryItem(mode: .redisearch, match: text)) }
        } else {
            appliedPattern = text.isEmpty ? "*" : text
            addHistory(SearchHistoryItem(mode: .pattern, match: appliedPattern, type: typeFilter))
        }

        reload()
    }

    /// Text typed in the search field. Emptying it shows every key again; programmatic changes to
    /// `patternText` do not.
    public func searchFieldEdited(_ text: String) {
        let wasEmpty = patternText.isEmpty
        patternText = text
        if text.isEmpty && !wasEmpty { searchFieldCleared() }
    }

    /// The search field was emptied (its clear button or deleting the text): show every key again.
    public func searchFieldCleared() {
        let isApplied = searchMode == .redisearch ? !appliedQuery.isEmpty : appliedPattern != "*"
        guard isApplied else { return }
        applyPattern()
    }

    public func setTypeFilter(_ type: KeyType?) {
        guard type != typeFilter else { return }
        typeFilter = type
        reload()
    }

    /// Reset (×): clears pattern and type filter and rescans.
    public func resetFilters() {
        patternText = ""
        appliedPattern = "*"
        appliedQuery = ""
        typeFilter = nil
        reload()
    }

    public func setSearchMode(_ mode: SearchMode) {
        guard mode != searchMode, mode == .pattern || isSearchAvailable else { return }
        settings.browser.searchMode = mode
        patternText = mode == .redisearch ? appliedQuery : (appliedPattern == "*" ? "" : appliedPattern)
        closeDetails()
        clearKeys()
        Task { [weak self] in
            guard let self else { return }
            if mode == .redisearch && self.indexes.isEmpty { await self.loadIndexes() }
            await self.loadKeys()
        }
    }

    public func setViewType(_ type: KeyViewType) {
        guard type != viewType, type == .list || isTreeAvailable else { return }
        settings.browser.viewType = type
        expandedFolders = []
        treeRoots = []
        sort = nil
        reload()
    }

    public func loadIndexes() async {
        guard isSearchAvailable else { return }
        isLoadingIndexes = true
        defer { isLoadingIndexes = false }
        do {
            indexes = try await SearchIndexService(session: session).listIndexes()
            indexesError = nil
            if let selectedIndex, !indexes.contains(selectedIndex) { self.selectedIndex = nil }
        } catch {
            indexesError = error.localizedDescription
            session.toasts.error(error)
        }
    }

    public func selectIndex(_ index: Data?) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        matchAllCache = nil
        if index == nil {
            clearKeys()
        } else {
            reload()
        }
    }

    // MARK: - Search history

    private func addHistory(_ item: SearchHistoryItem) {
        let updated = SearchHistory.adding(item, to: history)
        guard updated != history else { return }
        history = updated
        persist { $0.searchHistory = updated }
    }

    public func applyHistory(_ item: SearchHistoryItem) {
        patternText = item.match
        if item.mode == .pattern { typeFilter = item.type }
        applyPattern()
    }

    public func removeHistory(_ id: UUID) {
        history = SearchHistory.removing(id: id, from: history)
        let updated = history
        persist { $0.searchHistory = updated }
    }

    public func clearHistory() {
        history = SearchHistory.clearing(mode: searchMode, in: history)
        let updated = history
        persist { $0.searchHistory = updated }
    }

    // MARK: - Columns and sorting

    public func setColumn(_ column: BrowserColumn, shown: Bool) {
        if shown { shownColumns.insert(column) } else { shownColumns.remove(column) }
        if !shown, let sort, (sort.field == .ttl && column == .ttl) || (sort.field == .size && column == .size) {
            self.sort = nil
        }

        let columns = BrowserColumn.allCases.filter { shownColumns.contains($0) }
        persist {
            $0.browserShownColumns = columns
            $0.didUserConfigureColumns = true
        }
        if shown {
            loadedMetadata.removeAll()
            requestVisibleMetadata()
        }
    }

    /// Clicking the active sort clears it.
    public func toggleSort(_ field: KeyListSort.Field, order: RedisCore.SortOrder) {
        let next = KeyListSort(field: field, order: order)
        sort = sort == next ? nil : next
    }

    // MARK: - Metadata (lazy, visible rows)

    public func rowAppeared(_ name: Data) {
        visibleKeys.insert(name)
        if !loadedMetadata.contains(name) && !inFlightMetadata.contains(name) {
            pendingMetadata.insert(name)
            scheduleMetadata()
        }

        if viewType == .list { scheduleScrollAnchorUpdate() }
    }

    public func rowDisappeared(_ name: Data) {
        visibleKeys.remove(name)
        if viewType == .list { scheduleScrollAnchorUpdate() }
    }

    public func treeRowAppeared(_ id: KeyTreeNodeID) {
        visibleTreeRows.insert(id)
        scheduleScrollAnchorUpdate()
    }

    public func treeRowDisappeared(_ id: KeyTreeNodeID) {
        visibleTreeRows.remove(id)
        scheduleScrollAnchorUpdate()
    }

    /// Scans more after 100 ms if scrolling toward the end of a filtered list whose last batch found nothing.
    public func listScrolledDown() {
        guard wantsWheelScanMore else { return }
        wheelScanTask?.cancel()
        wheelScanTask = Task { [weak self] in
            try? await Task.sleep(for: Self.wheelScanDelay)
            guard !Task.isCancelled, let self, self.wantsWheelScanMore else { return }
            self.scanMore()
        }
    }

    var wantsWheelScanMore: Bool {
        viewType == .list && canScanMore && lastBatchCount == 0 && (isFiltered || searchMode == .redisearch)
    }

    /// Waits for a pending wheel scan and the load it starts.
    public func waitForWheelScan() async {
        await wheelScanTask?.value
        await loadTask?.value
    }

    // MARK: - Scroll position (K18)

    /// Row the list should scroll back to for the current search mode, when that key is still loaded.
    public func listScrollAnchor() -> Data? {
        guard let anchor = listScrollAnchors[searchMode], keyIndex[anchor] != nil else { return nil }
        return anchor
    }

    /// Row the tree should scroll back to for the current search mode, when that row is still visible.
    public func treeScrollAnchor() -> KeyTreeNodeID? {
        guard let anchor = treeScrollAnchors[searchMode], treeRows.contains(where: { $0.id == anchor }) else { return nil }
        return anchor
    }

    /// The list or tree is about to restore its position or is going away: visibility changes must not move the anchor.
    public func pauseScrollTracking() {
        isTrackingScroll = false
        scrollAnchorTask?.cancel()
    }

    public func resumeScrollTracking() {
        isTrackingScroll = true
        scheduleScrollAnchorUpdate()
    }

    private func scheduleScrollAnchorUpdate() {
        guard isTrackingScroll else { return }
        scrollAnchorTask?.cancel()
        scrollAnchorTask = Task { [weak self] in
            try? await Task.sleep(for: Self.scrollAnchorDebounce)
            guard !Task.isCancelled, let self, self.isTrackingScroll else { return }
            self.updateScrollAnchor()
        }
    }

    /// Records the topmost visible row for the current search mode and view.
    func updateScrollAnchor() {
        switch viewType {
        case .list:
            guard !visibleKeys.isEmpty, let top = displayedKeys.first(where: { visibleKeys.contains($0.name) }) else { return }
            listScrollAnchors[searchMode] = top.name
        case .tree:
            guard !visibleTreeRows.isEmpty, let top = treeRows.first(where: { visibleTreeRows.contains($0.id) }) else { return }
            treeScrollAnchors[searchMode] = top.id
        }
    }

    /// Loads more keys when one of the last `infiniteLoadThreshold` list rows appears.
    public func listEndApproached() {
        guard viewType == .list, canScanMore else { return }
        guard !isFiltered || lastBatchCount > 0 || searchMode == .redisearch else { return }
        scanMore()
    }

    private func requestVisibleMetadata() {
        let needed = visibleKeys.filter { keyIndex[$0] != nil && !loadedMetadata.contains($0) }
        guard !needed.isEmpty else { return }
        pendingMetadata.formUnion(needed)
        scheduleMetadata()
    }

    private func scheduleMetadata() {
        metadataDebounceTask?.cancel()
        metadataDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.metadataDebounce)
            guard !Task.isCancelled, let self else { return }
            let names = self.pendingMetadata.filter {
                self.keyIndex[$0] != nil && self.visibleKeys.contains($0) && !self.loadedMetadata.contains($0)
            }
            self.pendingMetadata.removeAll()
            guard !names.isEmpty else { return }
            let id = self.nextMetadataTaskID
            self.nextMetadataTaskID += 1
            self.metadataTasks[id] = Task<Void, Never> { [weak self] in
                await self?.loadMetadata(Array(names))
                self?.metadataTasks[id] = nil
            }
        }
    }

    /// Loads type/TTL/size for `names` and patches the rows.
    public func loadMetadata(_ names: [Data]) async {
        let names = names.filter { !inFlightMetadata.contains($0) }
        guard !names.isEmpty else { return }
        inFlightMetadata.formUnion(names)
        defer { inFlightMetadata.subtract(names) }
        let knownType: KeyType? = searchMode == .redisearch ? searchKeyType : typeFilter
        let generation = session.dbGeneration
        do {
            let items = try await KeyMetadataService(session: session)
                .metadata(for: names, includeSize: showsSize, includeTTL: showsTTL, knownType: knownType)
            guard generation == session.dbGeneration else { return }
            var changed = false
            var gone: [Data] = []
            var typeless: [Data] = []
            for item in items {
                guard let index = keyIndex[item.name], index < keys.count else { continue }
                if item.ttl == -2 {
                    gone.append(item.name)
                    continue
                }

                if knownType == nil && item.type == nil {
                    typeless.append(item.name)
                    continue
                }

                loadedMetadata.insert(item.name)
                var row = keys[index]
                row.type = item.type ?? row.type
                if showsTTL { row.ttl = item.ttl }
                if showsSize { row.size = item.size }
                if row != keys[index] {
                    keys[index] = row
                    changed = true
                }
            }

            if changed {
                metadataVersion += 1
            }

            if !typeless.isEmpty {
                gone += await missingKeys(typeless)
                guard generation == session.dbGeneration else { return }
            }

            removeKeysLocally(gone)
        } catch {
            // Background metadata: rows keep their empty cells; the next visibility change retries.
            loadedMetadata.subtract(names)
        }
    }

    /// `names` that `EXISTS` reports as gone. A TYPE reply of `none` and an error reply (ACL, timeout) look alike in
    /// the metadata, so this check keeps rows that still exist; those are marked loaded and are not retried.
    private func missingKeys(_ names: [Data]) async -> [Data] {
        guard let replies = try? await session.pipeline(names.map { ["EXISTS", .data($0)] }),
              replies.count == names.count else {
            loadedMetadata.formUnion(names)
            return []
        }
        var missing: [Data] = []
        for (name, reply) in zip(names, replies) {
            if reply.intValue == 0 {
                missing.append(name)
            } else {
                loadedMetadata.insert(name)
            }
        }

        return missing
    }

    /// Drops rows for keys that expired or were deleted after the scan.
    private func removeKeysLocally(_ names: [Data]) {
        let targets = Set(names).filter { keyIndex[$0] != nil }
        guard !targets.isEmpty else { return }
        keys.removeAll { targets.contains($0.name) }
        if let total { self.total = max(total - targets.count, 0) }
        scanned = max(scanned - targets.count, 0)
        loadedMetadata.subtract(targets)
        visibleKeys.subtract(targets)
        if case .leaf(let key) = treeSelection, targets.contains(key) { treeSelection = nil }
        keysDidChange()
    }

    // MARK: - Tree

    private func rebuildTree() {
        treeTask?.cancel()
        guard viewType == .tree else {
            isBuildingTree = false
            return
        }
        let names = keys.map(\.name)
        let options = treeOptions
        let format = keyNameFormat
        isBuildingTree = true
        treeTask = Task { [weak self] in
            let roots = await Task.detached(priority: .userInitiated) {
                KeyTreeBuilder.build(names.map { name in
                    let key = RedisKeyName(name)
                    return KeyTreeInput(name: name, display: key.displayString(format: format), isPrintable: key.isPrintable)
                }, options: options)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.treeRoots = roots
            self.isBuildingTree = false
            self.autoExpand()
        }
    }

    /// Waits for the current tree build.
    public func waitForTree() async {
        await treeTask?.value
    }

    private func autoExpand() {
        if expandedFolders.isEmpty, treeRoots.count == 1, let only = treeRoots.first, !only.isLeaf {
            expandedFolders.formUnion(KeyTreeBuilder.singleChildChain(from: only))
        }

        if let selectedKey { expandParents(of: selectedKey) }
    }

    private func expandParents(of key: Data) {
        let display = BrowserFormatting.keyDisplayName(key, format: keyNameFormat)
        let parents = KeyTreeBuilder.parentFolderPaths(of: display, options: treeOptions)
        if !expandedFolders.isSuperset(of: parents) { expandedFolders.formUnion(parents) }
    }

    /// Rows of the expanded tree in display order. Built on demand: only scroll anchoring needs them.
    public var treeRows: [KeyTreeRow] {
        KeyTreeBuilder.flatten(treeRoots, expanded: expandedFolders)
    }

    public func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else if let node = KeyTreeBuilder.find(.folder(path), in: treeRoots) {
            expandedFolders.formUnion(KeyTreeBuilder.singleChildChain(from: node))
        } else {
            expandedFolders.insert(path)
        }
    }

    /// Expand All / Collapse All on a folder and every folder below it.
    public func setFolderSubtree(_ path: String, expanded: Bool) {
        guard let node = KeyTreeBuilder.find(.folder(path), in: treeRoots) else { return }
        var paths: [String] = []

        func collect(_ node: KeyTreeNode) {
            guard let folder = node.folderPath else { return }
            paths.append(folder)
            node.children.forEach(collect)
        }

        collect(node)
        if expanded { expandedFolders.formUnion(paths) } else { expandedFolders.subtract(paths) }
    }

    public func folderNode(_ path: String) -> KeyTreeNode? {
        KeyTreeBuilder.find(.folder(path), in: treeRoots)
    }

    public func setFolder(_ path: String, expanded: Bool) {
        guard expandedFolders.contains(path) != expanded else { return }
        toggleFolder(path)
    }

    public func applyTreeSettings(delimiters: [String], prefixLength: Int, sort: RedisCore.SortOrder) {
        let cleaned = delimiters.filter { !$0.isEmpty }
        let options = KeyTreeOptions(delimiters: cleaned.isEmpty ? [":"] : cleaned,
                                     prefixLength: min(max(prefixLength, 0), KeyTreeBuilder.maxPrefixLength), sort: sort)
        guard options != treeOptions else { return }
        treeOptions = options
        expandedFolders = []
        persist {
            $0.treeViewDelimiters = options.delimiters
            $0.treeViewDelimiterPrefixLength = options.prefixLength
            $0.treeViewSort = options.sort
        }
        rebuildTree()
    }

    /// Tree selection binding: leaves open details, folders only highlight.
    public func selectTreeRow(_ id: KeyTreeNodeID?) {
        treeSelection = id
        if case .leaf(let key) = id { select(key) }
    }

    /// Bulk delete pattern for a folder: `<escaped fullName><delimiter>*`.
    public func folderPattern(_ node: KeyTreeNode) -> String {
        KeyPattern.escape(node.fullName) + KeyPattern.escape(treeOptions.delimiterView) + "*"
    }

    public func canDeleteFolder(_ node: KeyTreeNode) -> Bool {
        treeOptions.delimiters.count == 1 && node.isPrintable && !node.fullName.contains("\u{FFFD}")
    }

    // MARK: - Selection and details

    public func select(_ name: Data?) {
        if let details, details.hasUnsavedChanges, name != details.key {
            pendingSelection = PendingSelection(key: name)
            treeSelection = .leaf(details.key)
            return
        }

        guard let name else {
            closeDetails()
            return
        }
        if selectedKey == name, details?.key == name, rightPanel == .details { return }
        let wasFullScreen = details?.isFullScreen ?? false
        selectedKey = name
        treeSelection = .leaf(name)
        let state = KeyDetailsState(key: name)
        state.isFullScreen = wasFullScreen
        details = state
        detailsType = item(for: name)?.type
        detailsError = nil
        rightPanel = .details
        if viewType == .tree { expandParents(of: name) }
        Task { [weak self] in await self?.refreshKeyInfo(for: state) }
    }

    /// "Discard Changes?" answered with Discard: drops the open key's edits and finishes the selection change.
    public func discardChanges(_ pending: PendingSelection) {
        pendingSelection = nil
        details?.hasUnsavedChanges = false
        select(pending.key)
    }

    public func closeDetails() {
        selectedKey = nil
        if case .leaf = treeSelection { treeSelection = nil }
        details = nil
        detailsType = nil
        detailsError = nil
        if rightPanel == .details { rightPanel = .none }
    }

    /// Reloads header info and syncs the row; closes details if the key is gone.
    public func refreshKeyInfo(for state: KeyDetailsState) async {
        do {
            let hint = state.info?.type ?? keyIndex[state.key].flatMap { $0 < keys.count ? keys[$0].type : nil }
            let info = try await KeyMetadataService(session: session).keyInfo(state.key, includeSize: showsSize,
                                                                              typeHint: hint)
            guard details === state else { return }
            state.info = info
            if detailsType != info.type { detailsType = info.type }
            detailsError = nil
            syncRow(from: info)
        } catch let error as KeyOperationError where error == .keyNotFound {
            guard details === state, !deletingKeys.contains(state.key) else { return }
            handleKeyNotFound(state.key)
        } catch {
            guard details === state else { return }
            if detailsType == nil { detailsError = error.localizedDescription } else { session.toasts.error(error) }
        }
    }

    public func refreshDetails() {
        guard let state = details else { return }
        state.requestRefresh()
        Task { [weak self] in await self?.refreshKeyInfo(for: state) }
    }

    /// Patches the list row from header info (TTL / size / type).
    public func syncRow(from info: KeyInfo) {
        guard let index = keyIndex[info.name], index < keys.count else { return }
        var row = keys[index]
        row.type = info.type
        row.ttl = info.ttl
        if let size = info.size, size >= 0 { row.size = size }
        guard row != keys[index] else { return }
        keys[index] = row
        metadataVersion += 1
    }

    /// Reports a key deleted elsewhere.
    public func handleKeyNotFound(_ name: Data) {
        session.toasts.error(KeyOperationError.keyNotFound.localizedDescription)
        removeKeyLocally(name)
        if selectedKey == name { closeDetails() }
    }

    /// The context for the open key, built once per details state and type so the details view is not rebuilt.
    public var detailsContext: KeyDetailsContext? {
        guard let state = details, let type = detailsType, rightPanel == .details else { return nil }
        if let cached = cachedDetailsContext, cached.state === state, cached.type == type { return cached }
        let context = makeDetailsContext(state: state, type: type)
        cachedDetailsContext = context
        return context
    }

    private func makeDetailsContext(state: KeyDetailsState, type: KeyType) -> KeyDetailsContext {
        let key = state.key
        return KeyDetailsContext(
            session: session, key: key, type: type, state: state,
            onKeyRenamed: { [weak self] newName in self?.keyRenamed(from: key, to: newName) },
            onKeyDeleted: { [weak self] in self?.keyDeleted(key) },
            onKeyChanged: { [weak self] in self?.keyChanged(key) },
            onClose: { [weak self] in self?.closeDetails() },
            onToggleFullScreen: { [weak self] in self?.toggleFullScreen() },
            refreshKeyInfo: { [weak self] in await self?.refreshKeyInfo(for: state) })
    }

    /// Hides the key list while a key is open in full screen.
    public var isListHidden: Bool {
        rightPanel == .details && (details?.isFullScreen ?? false)
    }

    public func toggleFullScreen() {
        guard rightPanel == .details else { return }
        details?.isFullScreen.toggle()
    }

    // MARK: - Key changes

    public func keyRenamed(from old: Data, to new: Data) {
        if let index = keyIndex[old], index < keys.count {
            if keyIndex[new] != nil {
                keys.remove(at: index)
            } else {
                keys[index].name = new
            }

            loadedMetadata.remove(old)
            keysDidChange()
        }

        guard selectedKey == old else { return }
        let info = details?.info.map { info -> KeyInfo in
            var copy = info
            copy.name = new
            return copy
        }
        let fullScreen = details?.isFullScreen ?? false
        selectedKey = new
        treeSelection = .leaf(new)
        let state = KeyDetailsState(key: new, info: info)
        state.isFullScreen = fullScreen
        details = state
    }

    public func keyDeleted(_ name: Data) {
        removeKeyLocally(name)
        if selectedKey == name { closeDetails() }
    }

    public func keyChanged(_ name: Data) {
        guard keyIndex[name] != nil else { return }
        loadedMetadata.remove(name)
        Task { [weak self] in await self?.loadMetadata([name]) }
    }

    /// Confirms deletion with a popover for Unspecified and production confirmation for Production.
    /// Development deletes immediately.
    public func requestDelete(_ name: Data) {
        if deleteRequiresConfirmation {
            pendingDeleteKey = name
        } else {
            Task { await deleteKey(name) }
        }
    }

    /// Deletes the key and removes its row.
    public func deleteKey(_ name: Data) async {
        let shortName = BrowserFormatting.shortName(displayName(name))
        guard await session.confirm(KeyConfirmations.deleteKey(shortName)) else { return }
        deletingKeys.insert(name)
        defer { deletingKeys.remove(name) }
        do {
            try await KeyOperations(session: session).delete([name])
            keyDeleted(name)
        } catch let error as KeyOperationError where error == .keyNotFound {
            handleKeyNotFound(name)
        } catch {
            session.toasts.error(error, title: "Delete Key Failed")
        }
    }

    func removeKeyLocally(_ name: Data) {
        guard let index = keyIndex[name], index < keys.count else { return }
        keys.remove(at: index)
        if let total { self.total = max(total - 1, 0) }
        scanned = max(scanned - 1, 0)
        loadedMetadata.remove(name)
        if treeSelection == .leaf(name) { treeSelection = nil }
        keysDidChange()
    }

    /// Inserts the new key at the top if it matches the current filter, then selects it.
    public func keyAdded(_ name: Data, type: KeyType) {
        addKey = nil
        if sheet == .newKey { sheet = nil }
        if searchMode == .pattern, appliedPattern == "*" || appliedPattern.isEmpty,
           typeFilter == nil || typeFilter == type, keyIndex[name] == nil {
            keys.insert(KeyListItem(name: name, type: type), at: 0)
            total = (total ?? 0) + 1
            scanned += 1
            hasStarted = true
            keysDidChange()
        }

        select(name)
    }

    // MARK: - Panels

    public func openAddKey() {
        if addKey == nil {
            addKey = AddKeyViewModel(session: session)
        }

        sheet = .newKey
    }

    public func closeAddKey() {
        addKey = nil
        if sheet == .newKey { sheet = nil }
    }

    public func openBulkActions(filter: BulkActionFilter? = nil, tab: BulkActionsViewModel.Tab = .delete) {
        let model = bulkActions ?? BulkActionsViewModel(session: session)
        bulkActions = model
        if !model.isRunning {
            model.filterOverride = filter
            model.tab = filter != nil ? .delete : tab
        }

        sheet = .bulkActions
    }

    public func closeBulkActions() {
        if let bulkActions, !bulkActions.isRunning { self.bulkActions = nil }
        if sheet == .bulkActions { sheet = nil }
    }

    /// Presentation binding helper: the sheet was dismissed by the system (Esc, Cancel).
    public func sheetDismissed() {
        switch sheet {
        case .newKey: closeAddKey()
        case .bulkActions: closeBulkActions()
        case .renameKey, .setTTL:
            sheet = nil
            sheetKey = nil
        case nil: break
        }
    }

    // MARK: - Rename and TTL from the key list

    public func openRename(_ key: Data) {
        sheetKey = key
        sheet = .renameKey
    }

    public func openSetTTL(_ key: Data) {
        sheetKey = key
        sheet = .setTTL
    }

    /// Text placed in the Rename field (HEX names stay HEX).
    public func renameDraft(_ key: Data) -> String {
        keyNameFormat == .hex ? displayName(key) : String(decoding: key, as: UTF8.self)
    }

    /// Rename is disabled for names that do not survive a UTF-8 round trip (unless names are shown as HEX).
    public func canRename(_ key: Data) -> Bool {
        keyNameFormat == .hex || FormatterRegistry.isPrintable(key)
    }

    /// Parses the typed name in the database's key-name format.
    public func parseKeyName(_ text: String) -> Data? {
        guard !text.isEmpty else { return nil }
        if keyNameFormat == .hex { return try? FormatterRegistry.parseEdited(text, as: .hex) }
        return Data(text.utf8)
    }

    /// RENAME (or RENAME over an existing key when `overwrite`), then updates the list and the selection.
    public func renameKey(_ key: Data, to newName: Data, overwrite: Bool = false) async -> KeyRenameOutcome {
        guard newName != key else { return .renamed }
        if !overwrite {
            let request = KeyConfirmations.rename(BrowserFormatting.shortName(displayName(key)),
                                                  to: BrowserFormatting.shortName(displayName(newName)))
            guard await session.confirm(request) else { return .cancelled }
        }

        do {
            try await KeyOperations(session: session).rename(key, to: newName, overwrite: overwrite)
            keyRenamed(from: key, to: newName)
            if sheetKey == key { sheetKey = newName }
            return .renamed
        } catch let error as KeyOperationError where error == .newNameInUse {
            return .nameInUse
        } catch let error as KeyOperationError where error == .keyNotFound {
            handleKeyNotFound(key)
            return .failed
        } catch {
            session.toasts.error(error)
            return .failed
        }
    }

    /// Current TTL draft for the Set TTL sheet ("" = no limit).
    public func ttlDraft(_ key: Data) -> String {
        let ttl = details?.key == key ? details?.info?.ttl : item(for: key)?.ttl
        guard let ttl, ttl >= 0 else { return "" }
        return String(ttl)
    }

    /// `seconds < 0` persists the key; 0 deletes it (callers confirm first).
    @discardableResult
    public func setTTL(_ key: Data, seconds: Int) async -> Bool {
        let request = KeyConfirmations.changeTTL(BrowserFormatting.shortName(displayName(key)), seconds: seconds)
        guard await session.confirm(request) else { return false }
        do {
            try await KeyOperations(session: session).setTTL(key, seconds: seconds)
            if seconds == 0 {
                keyDeleted(key)
                return true
            }

            keyChanged(key)
            if selectedKey == key { refreshDetails() }
            return true
        } catch let error as KeyOperationError where error == .keyNotFound {
            handleKeyNotFound(key)
            return false
        } catch {
            session.toasts.error(error)
            return false
        }
    }

    /// Filter used by Bulk Actions > Delete (folder override or the current pattern + type).
    public var currentBulkFilter: BulkActionFilter {
        bulkActions?.filterOverride ?? BulkActionFilter(match: scanPattern, type: typeFilter)
    }

    /// After a completed bulk delete: rescan so the list reflects the deleted keys.
    public func bulkDeleteFinished() {
        closeDetailsIfMissing()
        reload()
    }

    private func closeDetailsIfMissing() {
        guard let selectedKey else { return }
        Task { [weak self] in
            guard let self else { return }
            let exists = (try? await KeyOperations(session: self.session).exists(selectedKey)) ?? true
            if !exists, self.selectedKey == selectedKey { self.closeDetails() }
        }
    }

    // MARK: - Sample data

    public func loadSampleData(modules: [RedisModuleInfo]? = nil) async {
        guard !session.isProduction, !isLoadingSampleData else { return }
        isLoadingSampleData = true
        defer { isLoadingSampleData = false }
        do {
            let script = try SampleDataLoader.script(for: modules ?? session.capabilities.modules)
            let summary = await CommandFileImporter(session: session).importAll(script)
            if summary.failed > 0 {
                session.toasts.error(SampleDataError.commandsFailed(failed: summary.failed, total: summary.processed,
                                                                    firstError: summary.errors.first),
                                     title: "Load Sample Data Failed")
            }

            if isTreeAvailable { settings.browser.viewType = .tree }
            expandedFolders = []
            await loadKeys()
        } catch {
            session.toasts.error(error, title: "Load Sample Data Failed")
        }
    }

    // MARK: - Navigation and reloads

    /// Applies a `.browser` / `.browseIndex` navigation request.
    public func handleNavigation(_ request: DatabaseNavigationRequest) {
        switch request {
        case .browser(let browse):
            if searchMode != .pattern { settings.browser.searchMode = .pattern }
            let pattern = browse.pattern.isEmpty ? "*" : browse.pattern
            appliedPattern = pattern
            patternText = pattern == "*" ? "" : pattern
            typeFilter = browse.typeFilter
            if browse.switchToTreeView, isTreeAvailable { settings.browser.viewType = .tree }
            if let delimiter = browse.treeDelimiter, !delimiter.isEmpty, treeOptions.delimiters != [delimiter] {
                treeOptions.delimiters = [delimiter]
                expandedFolders = []
                let delimiters = treeOptions.delimiters
                persist { $0.treeViewDelimiters = delimiters }
            }

            if let key = browse.selectedKey { select(key) }
            reload()
        case .browseIndex(let index):
            guard isSearchAvailable else { return }
            settings.browser.searchMode = .redisearch
            selectedIndex = index
            matchAllCache = nil
            appliedQuery = "*"
            patternText = ""
            closeDetails()
            clearKeys()
            Task { [weak self] in
                await self?.loadIndexes()
                await self?.loadKeys()
            }
        default:
            break
        }
    }

    /// The logical database changed (`session.dbGeneration`).
    public func databaseChanged() {
        loadedGeneration = session.dbGeneration
        listScrollAnchors = [:]
        treeScrollAnchors = [:]
        closeDetails()
        if sheet == .newKey { closeAddKey() }
        if sheet == .renameKey || sheet == .setTTL { sheetDismissed() }
        clearKeys()
        expandedFolders = []
        selectedIndex = nil
        indexes = []
        Task { [weak self] in
            guard let self else { return }
            if self.searchMode == .redisearch { await self.loadIndexes() }
            await self.loadKeys()
        }
    }
}
