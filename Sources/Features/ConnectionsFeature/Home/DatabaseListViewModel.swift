import Foundation
import Observation
import RedisCore

/// Home window state: saved databases, sidebar filters, search, sorting, columns and table selection.
@MainActor
@Observable
public final class DatabaseListViewModel {
    public private(set) var databases: [DatabaseConfig] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public var loadError: String?

    public var searchText = "" {
        didSet { if searchText != oldValue { pruneSelection() } }
    }

    /// Sidebar selection normalized to keep exclusive filters separate from tags.
    public var filters: Set<HomeFilter> = [.all] {
        didSet {
            let resolved = DatabaseListLogic.resolveFilters(previous: oldValue, proposed: filters)
            if resolved != filters { filters = resolved } else if filters != oldValue { pruneSelection() }
        }
    }

    /// Table selection: the target of Open, Edit, Export and Remove. Only rows that are shown stay selected.
    public var selection: Set<DatabaseID> = []
    public private(set) var connecting: Set<DatabaseID> = []
    public private(set) var isAutoDiscovering = false
    /// Environment sorting is not persisted (`HomeSorting` has no such field).
    private var transientSortField: HomeSortField?
    private var transientAscending = true

    @ObservationIgnored public let services: AppServices
    @ObservationIgnored private let autoDiscovery: LocalAutoDiscovery?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = Date.init

    /// - Parameter autoDiscovery: First-run local discovery; `nil` disables it.
    public init(services: AppServices, autoDiscovery: LocalAutoDiscovery? = nil) {
        self.services = services
        self.autoDiscovery = autoDiscovery
    }

    // MARK: - Settings-backed state

    public var sorting: HomeSorting {
        get { services.settings.ui.homeSorting }
        set { services.settings.ui.homeSorting = newValue }
    }

    public var sortField: HomeSortField { transientSortField ?? HomeSortField(sorting.field) }

    public var sortAscending: Bool { transientSortField == nil ? sorting.direction == .asc : transientAscending }

    public func setSort(_ field: HomeSortField, ascending: Bool) {
        if let persisted = field.persisted {
            transientSortField = nil
            sorting = HomeSorting(field: persisted, direction: ascending ? .asc : .desc)
        } else {
            transientSortField = field
            transientAscending = ascending
        }
    }

    /// Clicking a header: same field flips direction, another field starts ascending.
    public func sort(by field: HomeSortField) {
        setSort(field, ascending: field == sortField ? !sortAscending : true)
    }

    public var shownColumns: Set<HomeColumn> {
        get { DatabaseListLogic.shownColumns(from: services.settings.ui.homeShownColumns) }
        set {
            let persisted = DatabaseListLogic.persistedColumns(newValue)
            if persisted != services.settings.ui.homeShownColumns { services.settings.ui.homeShownColumns = persisted }
        }
    }

    public func setColumn(_ column: HomeColumn, shown: Bool) {
        var columns = shownColumns
        if shown { columns.insert(column) } else { columns.remove(column) }
        shownColumns = columns
    }

    // MARK: - Derived lists

    public var recents: Set<DatabaseID> { DatabaseListLogic.recents(databases) }

    public var visibleDatabases: [DatabaseConfig] {
        let recents = recents
        let query = searchText
        let now = now()
        let matching = databases.filter {
            DatabaseListLogic.matches($0, filters: filters, recents: recents)
                && DatabaseListLogic.matches($0, query: query, now: now)
        }
        return DatabaseListLogic.sort(matching, field: sortField, ascending: sortAscending)
    }

    public var allTags: [DatabaseTag] { DatabaseListLogic.allTags(databases) }

    public var hasProduction: Bool { databases.contains { $0.environment == .production } }
    public var hasDevelopment: Bool { databases.contains { $0.environment == .development } }

    public func count(for filter: HomeFilter) -> Int {
        DatabaseListLogic.count(for: filter, in: databases, recents: recents)
    }

    public var isNarrowed: Bool {
        DatabaseListLogic.isFiltering(filters) || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var subtitle: String {
        DatabaseListLogic.subtitle(total: databases.count, visible: visibleDatabases.count, selected: selection.count,
                                   isNarrowed: isNarrowed)
    }

    public var showsEmptyState: Bool { hasLoaded && !isLoading && databases.isEmpty && !isAutoDiscovering }

    public func database(_ id: DatabaseID) -> DatabaseConfig? {
        databases.first { $0.id == id }
    }

    /// Selected databases that are shown, in list order (targets of toolbar, menu and keyboard actions).
    public var actionTargets: [DatabaseConfig] {
        visibleDatabases.filter { selection.contains($0.id) }
    }

    private func pruneSelection() {
        guard !selection.isEmpty else { return }
        let visible = Set(visibleDatabases.map(\.id))
        if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
    }

    public func databases(_ ids: Set<DatabaseID>) -> [DatabaseConfig] {
        databases.filter { ids.contains($0.id) }
    }

    // MARK: - Loading

    /// Loads the list and keeps it in sync with store changes.
    public func start() async {
        await reload()
        await runAutoDiscoveryIfNeeded()
        guard changesTask == nil else { return }
        let stream = await services.databaseStore.changes()
        changesTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.reload()
            }
        }
    }

    public func stop() {
        changesTask?.cancel()
        changesTask = nil
    }

    public func reload() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            databases = try await services.databaseStore.list()
            loadError = nil
            let tags = Set(allTags)
            let kept = filters.filter { filter in
                switch filter {
                case .tag(let tag): return tags.contains(tag)
                case .production: return hasProduction
                case .development: return hasDevelopment
                case .all, .recents: return true
                }
            }
            if kept != filters { filters = kept.isEmpty ? [.all] : kept }
            pruneSelection()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// First launch with no databases: add local standalone servers found by the injected discovery.
    public func runAutoDiscoveryIfNeeded() async {
        guard let autoDiscovery, databases.isEmpty, !services.settings.ui.didRunAutoDiscovery else { return }
        services.settings.ui.didRunAutoDiscovery = true
        isAutoDiscovering = true
        defer { isAutoDiscovering = false }
        let found = await autoDiscovery.discover(excluding: Set(databases.map(\.endpoint)))
        for config in found {
            try? await services.saveDatabase(config)
        }

        if !found.isEmpty { await reload() }
    }

    // MARK: - Opening

    /// Connects, then calls `onOpen` with the refreshed config. A failed connection opens the window too, where it
    /// shows the same Failed state (Try Again, Edit Database…) as a restored window.
    public func open(_ id: DatabaseID, onOpen: @MainActor (DatabaseConfig) -> Void) async {
        guard !connecting.contains(id) else { return }
        connecting.insert(id)
        defer { connecting.remove(id) }
        let existing = services.sessions.existingSession(for: id)
        if let existing, existing.state == .connected || existing.state == .connecting {
            onOpen(existing.config)
            return
        }

        do {
            let session = try await services.sessions.session(for: id)
            if case .failed = session.state {
                await session.reconnect()
            } else if session.state != .connected {
                await session.connect()
            }

            onOpen(session.config)
        } catch {
            services.toasts.error(error, title: "Unable to Open Database")
        }
    }

    /// What a deep link with full credentials would do, for the user to confirm before `connect`.
    public func confirmation(for link: DatabaseDeepLink) async -> DeepLinkConfirmation {
        if !hasLoaded { await reload() }
        return DeepLinkConfirmation(link: link, match: link.matchingDatabase(in: databases))
    }

    /// Opens the saved database the user confirmed, or creates the linked one (type detected) and opens it.
    public func connect(_ confirmed: DeepLinkConfirmation, onOpen: @MainActor (DatabaseConfig) -> Void) async {
        if let id = confirmed.matchID {
            await open(id, onOpen: onOpen)
            return
        }

        let draft = confirmed.link.draft()
        do {
            var detected = try await DatabaseFactory(clientFactory: services.clientFactory).createDetected(draft)
            detected.isNew = true
            try await services.saveDatabase(detected)
            await reload()
            await open(detected.id, onOpen: onOpen)
        } catch {
            let failure = DatabaseFormModel.connectionError(error, endpoint: draft.endpoint)
            services.toasts.error(failure.message, title: failure.title)
        }
    }

    // MARK: - Mutations

    /// Deletes databases (store, secrets, settings, sessions) and reports the ids.
    @discardableResult
    public func delete(_ ids: [DatabaseID]) async -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            try await services.deleteDatabases(ids)
            selection.subtract(ids)
            await reload()
            return true
        } catch {
            services.toasts.error(error, title: "Unable to Delete")
            return false
        }
    }

    /// RedisInsight-compatible export JSON.
    public func exportData(_ ids: [DatabaseID], includePasswords: Bool) async throws -> Data {
        try await services.databaseStore.export(ids: ids, includeSecrets: includePasswords)
    }

    /// Replaces the tags of one database (non-secret fields only, open sessions keep their clients).
    public func saveTags(_ tags: [DatabaseTag], for id: DatabaseID) async -> Bool {
        guard await Self.saveTags(tags, for: id, services: services) else { return false }
        await reload()
        return true
    }

    /// Saves tags and reports success or failure.
    static func saveTags(_ tags: [DatabaseTag], for id: DatabaseID, services: AppServices) async -> Bool {
        do {
            try await services.databaseStore.modify(id) { $0.tags = tags }
            return true
        } catch {
            services.toasts.error(error, title: "Unable to Update Tags")
            return false
        }
    }

    /// Full config (secrets included) for edit / clone.
    public func fullConfig(_ id: DatabaseID) async -> DatabaseConfig? {
        do {
            return try await services.databaseStore.get(id)
        } catch {
            services.toasts.error(error, title: "Unable to Load Database")
            return nil
        }
    }
}
