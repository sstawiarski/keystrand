import Foundation

/// Saved and sample queries per database + index (`QueryLibrary.json`, `{"schemaVersion": n, "items": [...]}`).
public actor QueryLibraryStore {
    static let currentSchemaVersion = 1

    private let paths: AppPaths
    private var cache: [QueryLibraryItem]?

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// Sorted by `createdAt` ascending.
    public func list(databaseID: DatabaseID, indexName: String? = nil) -> [QueryLibraryItem] {
        load().filter { $0.databaseId == databaseID && (indexName == nil || $0.indexName == indexName) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func create(_ item: QueryLibraryItem) throws -> QueryLibraryItem {
        var all = load()
        all.append(item)
        try save(all)
        return item
    }

    public func update(_ item: QueryLibraryItem) throws {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == item.id && $0.databaseId == item.databaseId }) else { return }
        var updated = item
        updated.updatedAt = Date()
        all[index] = updated
        try save(all)
    }

    public func delete(_ id: UUID, databaseID: DatabaseID) throws {
        try save(load().filter { !($0.id == id && $0.databaseId == databaseID) })
    }

    public func deleteByIndex(databaseID: DatabaseID, indexName: String) throws {
        try save(load().filter { !($0.databaseId == databaseID && $0.indexName == indexName) })
    }

    public func deleteAll(databaseID: DatabaseID) throws {
        try save(load().filter { $0.databaseId != databaseID })
    }

    /// Adds SAMPLE items whose name is not already a SAMPLE item for the same database + index.
    public func seed(_ items: [QueryLibraryItem]) throws {
        var all = load()
        for item in items {
            let exists = all.contains {
                $0.databaseId == item.databaseId && $0.indexName == item.indexName && $0.type == .sample && $0.name == item.name
            }
            if !exists { all.append(item) }
        }

        try save(all)
    }

    private func load() -> [QueryLibraryItem] {
        if let cache { return cache }
        let loaded = VersionedArrayFile<QueryLibraryItem>.load(from: paths.queryLibraryFile,
                                                               currentVersion: Self.currentSchemaVersion)
        cache = loaded
        return loaded
    }

    private func save(_ items: [QueryLibraryItem]) throws {
        try JSONFile.save(VersionedArrayFile(items: items, schemaVersion: Self.currentSchemaVersion),
                          to: paths.queryLibraryFile)
        cache = items
    }
}
