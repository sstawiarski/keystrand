import Foundation

public struct ClientKey: Hashable, Sendable {
    public var databaseID: DatabaseID
    public var context: ClientContext
    /// Separates clients of the same context (e.g. one CLI client per open CLI).
    public var uniqueID: String?
    /// Logical db (ignored for CLI, which tracks SELECT itself).
    public var db: Int?

    public init(databaseID: DatabaseID, context: ClientContext, uniqueID: String? = nil, db: Int? = nil) {
        self.databaseID = databaseID
        self.context = context
        self.uniqueID = uniqueID
        self.db = context == .cli ? nil : db
    }
}

/// Shared clients keyed by database + context + db. Idle clients (1 h) are closed by a 60 s sweep.
public actor ClientPool {
    private struct Entry {
        var client: any RedisClient
        var lastUsed: Date
    }

    private let factory: RedisClientFactory
    private let idleTimeout: TimeInterval
    private var entries: [ClientKey: Entry] = [:]
    private var inFlight: [ClientKey: Task<any RedisClient, Error>] = [:]
    /// Bumped by `invalidate`; a client whose creation started under an older generation is discarded.
    private var generations: [DatabaseID: Int] = [:]
    private var sweeper: Task<Void, Never>?

    public init(factory: RedisClientFactory = RedisClientFactory(), idleTimeout: TimeInterval = 3600) {
        self.factory = factory
        self.idleTimeout = idleTimeout
    }

    /// Returns the pooled client for `key`, creating it from `descriptor` when missing.
    /// Throws `RedisClientError.cancelled` when the database was invalidated while the client was connecting.
    public func client(for key: ClientKey, descriptor: RedisClientDescriptor) async throws -> any RedisClient {
        try await client(for: key) { descriptor }
    }

    /// Returns the pooled client for `key`. `makeDescriptor` is called only when a new client must be opened.
    public func client(for key: ClientKey,
                       makeDescriptor: @escaping @Sendable () async throws -> RedisClientDescriptor) async throws -> any RedisClient {
        if var entry = entries[key] {
            entry.lastUsed = Date()
            entries[key] = entry
            return entry.client
        }

        let generation = generations[key.databaseID, default: 0]
        let task: Task<any RedisClient, Error>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let factory = self.factory
            task = Task { try await factory.makeClient(try await makeDescriptor()) }
            inFlight[key] = task
        }

        let client: any RedisClient
        do {
            client = try await task.value
        } catch {
            if inFlight[key] == task { inFlight[key] = nil }
            throw error
        }

        if inFlight[key] == task { inFlight[key] = nil }
        guard generations[key.databaseID, default: 0] == generation else {
            await client.close()
            throw RedisClientError.cancelled
        }
        if let raced = entries[key] {
            if raced.client !== client { await client.close() }
            return raced.client
        }

        entries[key] = Entry(client: client, lastUsed: Date())
        startSweepingIfNeeded()
        return client
    }

    public func remove(_ key: ClientKey) async {
        guard let entry = entries.removeValue(forKey: key) else { return }
        await entry.client.close()
    }

    /// Closes every client of a database (after edit, delete, or certificate removal). Clients still connecting are
    /// cancelled, which stops their pre-connect script, SSH tunnel and handshake, and closed if they finish anyway.
    public func invalidate(databaseID: DatabaseID) async {
        generations[databaseID, default: 0] += 1
        for (key, task) in inFlight where key.databaseID == databaseID {
            task.cancel()
            inFlight[key] = nil
        }

        let keys = entries.keys.filter { $0.databaseID == databaseID }
        for key in keys { await remove(key) }
    }

    public func sweepIdle(now: Date = Date()) async {
        let stale = entries.filter { now.timeIntervalSince($0.value.lastUsed) > idleTimeout }.map(\.key)
        for key in stale { await remove(key) }
    }

    public func closeAll() async {
        for key in Array(entries.keys) { await remove(key) }
    }

    public var count: Int { entries.count }

    private func startSweepingIfNeeded() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.sweepIdle()
            }
        }
    }
}
