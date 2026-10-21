import Foundation

public enum SearchIndexError: Error, LocalizedError, Sendable, Equatable {
    case indexNotFound
    case maxResultsTooLow(Int, setting: String = SearchIndexService.rediSearchMaxResultsSetting)
    case moduleMissing
    /// The query is empty and the index has no field to build a match-all query from.
    case queryRequired

    public var errorDescription: String? {
        switch self {
        case .indexNotFound: return "Index not found."
        case .maxResultsTooLow(let n, let setting): return "Set \(setting) to at least \(n)."
        case .moduleMissing: return "Required Redis Search module is not loaded."
        case .queryRequired: return "Enter a query to search this index."
        }
    }
}

/// RediSearch helpers shared by Browser, Workbench and Vector Search.
@MainActor
public struct SearchIndexService {
    public let session: DatabaseSession

    public nonisolated static let rediSearchMaxResultsSetting = "MAXSEARCHRESULTS"
    public nonisolated static let valkeySearchMaxResultsSetting = "search.max-nonvector-search-results-fetched"

    /// Boolean flags in `FT.INFO` attribute lists (no value follows them on RediSearch; valkey-search sends 0 or 1).
    nonisolated static let attributeFlags: Set<String> = [
        "SORTABLE", "NOINDEX", "CASESENSITIVE", "UNF", "NOSTEM", "WITHSUFFIXTRIE", "INDEXEMPTY", "INDEXMISSING",
    ]

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// `FT._LIST` on every primary, de-duplicated (binary-safe names).
    public func listIndexes() async throws -> [Data] {
        var seen = Set<Data>()
        var out: [Data] = []
        for node in try await session.nodes(role: .primary) {
            let reply = try await node.execute(["FT._LIST"])
            for name in (reply.arrayValue ?? []).compactMap(\.dataValue) where seen.insert(name).inserted {
                out.append(name)
            }
        }
        return out
    }

    /// `FT.INFO` parsed (standalone boolean flag tokens; `index_definition` filter/language first).
    public func info(_ index: Data) async throws -> SearchIndexInfo {
        do {
            let reply = try await session.execute(["FT.INFO", .data(index)])
            return Self.parseInfo(reply, name: index)
        } catch let error as RedisClientError {
            if let message = error.serverError?.message.lowercased(), Self.isIndexNotFound(message) {
                throw SearchIndexError.indexNotFound
            }

            throw error
        }
    }

    /// `FT.DROPINDEX` (documents are kept) and removes the index's Query Library entries.
    public func drop(_ index: Data) async throws {
        _ = try await session.execute(["FT.DROPINDEX", .data(index)])
        invalidateSummaries()
        try? await session.services.queryLibraryStore.deleteByIndex(databaseID: session.id,
                                                                     indexName: String(decoding: index, as: UTF8.self))
    }

    /// Forgets the cached index definitions used by `indexes(coveringKey:type:)`; call after creating, altering or
    /// dropping an index.
    public func invalidateSummaries() {
        summaryCache.entries.removeAll()
    }

    private var summaryCache: SearchIndexSummaryCache {
        session.scopedObject(SearchIndexSummaryCache.self) { SearchIndexSummaryCache() }
    }

    /// Indexes whose key type and prefixes cover `key`. Index definitions are cached per logical database for
    /// `SearchIndexSummaryCache.lifetime`; the ones not cached are read with one pipelined `FT.INFO` batch.
    public func indexes(coveringKey key: Data, type: KeyType) async throws -> [SearchIndexSummary] {
        guard session.capabilities.hasSearch else { return [] }
        let keyType: SearchIndexKeyType
        switch type {
        case .hash: keyType = .hash
        case .json: keyType = .json
        default: return []
        }

        let names = try await listIndexes()
        let summaries = try await summaries(for: names)
        return names.compactMap { name -> SearchIndexSummary? in
            guard let summary = summaries[name], summary.keyType == keyType else { return nil }
            let covers = summary.prefixes.isEmpty || summary.prefixes.contains { key.starts(with: Data($0.utf8)) }
            return covers ? summary : nil
        }
    }

    private func summaries(for names: [Data]) async throws -> [Data: SearchIndexSummary] {
        let cache = summaryCache
        let generation = session.dbGeneration
        let now = Date()
        cache.prune(generation: generation, now: now)
        let missing = names.filter { cache.entries[$0] == nil }
        if !missing.isEmpty {
            let replies = try await session.pipeline(missing.map { ["FT.INFO", .data($0)] })
            guard session.dbGeneration == generation else { return [:] }
            for (name, reply) in zip(missing, replies) where !reply.isError {
                let info = Self.parseInfo(reply, name: name)
                cache.entries[name] = SearchIndexSummaryCache.Entry(
                    summary: SearchIndexSummary(name: name, prefixes: info.prefixes, keyType: info.keyType),
                    generation: generation, loadedAt: now)
            }
        }

        return cache.entries.compactMapValues { $0.summary }
    }

    /// Name of the server setting that caps search results.
    public nonisolated static func maxResultsSetting(_ capabilities: DatabaseCapabilities) -> String {
        capabilities.searchFlavor == .valkeySearch ? valkeySearchMaxResultsSetting : rediSearchMaxResultsSetting
    }

    /// `FT.CONFIG GET MAXSEARCHRESULTS`, or `CONFIG GET search.max-nonvector-search-results-fetched` on
    /// valkey-search (cached per session; nil when unavailable or unlimited).
    public func maxSearchResults() async throws -> Int? {
        if let cached = session.cachedMaxSearchResults { return cached }
        var value: Int?
        if session.capabilities.searchFlavor == .valkeySearch {
            if let reply = try? await session.execute(["CONFIG", "GET", .string(Self.valkeySearchMaxResultsSetting)]) {
                value = Self.parseConfigNumber(reply)
            }
        } else {
            if let reply = try? await session.execute(["FT.CONFIG", "GET", .string(Self.rediSearchMaxResultsSetting)]) {
                value = Self.parseConfigNumber(reply)
            }
            if value == nil, let reply = try? await session.execute(["CONFIG", "GET", "search-max-search-results"]) {
                value = Self.parseConfigNumber(reply)
            }
        }
        session.cachedMaxSearchResults = .some(value)
        return value
    }

    /// Query that matches every document of `index`: `*`, or on valkey-search (which has no match-all query) a
    /// range over the first indexed NUMERIC attribute, which skips documents without that field. Attributes named
    /// with whitespace are skipped because the valkey-search query grammar cannot reference them. Nil when the
    /// index has no such attribute.
    public func matchAllQuery(index: Data) async throws -> String? {
        guard !session.capabilities.supportsSearchMatchAll else { return "*" }
        return Self.matchAllQuery(attributes: try await info(index).attributes, capabilities: session.capabilities)
    }

    public nonisolated static func matchAllQuery(attributes: [SearchIndexAttribute],
                                                 capabilities: DatabaseCapabilities) -> String? {
        guard !capabilities.supportsSearchMatchAll else { return "*" }
        let numeric = attributes.first {
            $0.fieldType == .numeric && !$0.flags.contains("NOINDEX")
                && $0.queryName.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        }
        return numeric.map { "@\($0.queryName):[-inf +inf]" }
    }

    /// The query lists every document: empty, or `*` where the server has no match-all query.
    public nonisolated static func needsMatchAll(_ query: String, capabilities: DatabaseCapabilities) -> Bool {
        query.isEmpty || (query == "*" && !capabilities.supportsSearchMatchAll)
    }

    /// `FT.SEARCH index query NOCONTENT LIMIT offset limit` for Browser's RediSearch mode. An empty query (or `*`
    /// where the server has no match-all query) runs `matchAllQuery(index:)`, and throws `queryRequired` when the
    /// index has none. The page's `keyType` is the TYPE of the first key (indexes are single-type).
    public func searchKeys(index: Data, query: String, offset: Int, limit: Int) async throws -> SearchKeysPage {
        var safeLimit = limit
        let setting = Self.maxResultsSetting(session.capabilities)
        let maxResults = try await maxSearchResults()
        if let max = maxResults {
            if offset >= max { throw SearchIndexError.maxResultsTooLow(offset + limit, setting: setting) }
            if offset + limit > max { safeLimit = max - offset }
        }

        var effectiveQuery = query
        if Self.needsMatchAll(query, capabilities: session.capabilities) {
            guard let matchAll = try await matchAllQuery(index: index) else { throw SearchIndexError.queryRequired }
            effectiveQuery = matchAll
        }

        let reply: RESPValue
        do {
            reply = try await session.execute(["FT.SEARCH", .data(index), .string(effectiveQuery),
                                               "NOCONTENT", "LIMIT", .int(Int64(offset)), .int(Int64(safeLimit))])
        } catch let error as RedisClientError {
            if let message = error.serverError?.message {
                if message.uppercased().contains("LIMIT") {
                    throw SearchIndexError.maxResultsTooLow(offset + limit, setting: setting)
                }

                if Self.isIndexNotFound(message.lowercased()) { throw SearchIndexError.indexNotFound }
            }

            throw error
        }

        let items = reply.arrayValue ?? []
        let total = items.first?.intValue.map(Int.init) ?? 0
        let keys = items.dropFirst().compactMap(\.dataValue)
        let end = offset + safeLimit
        // Stops paging at the result cap to avoid an empty `LIMIT max 0` request.
        let reachedMax = maxResults.map { end >= $0 } ?? false
        let next = end >= total || safeLimit <= 0 || reachedMax ? nil : end
        var page = SearchKeysPage(total: total, keys: keys, nextOffset: next)
        if let first = keys.first, let typeReply = try? await session.execute(["TYPE", .data(first)]) {
            page.keyType = typeReply.stringValue.flatMap(KeyType.init(typeReply:))
        }
        return page
    }

    // MARK: - Parsing

    /// RediSearch (`Unknown index name`, `no such index`) and valkey-search
    /// (`Index with name 'x' not found in database 4`) wordings.
    nonisolated static func isIndexNotFound(_ lowercasedMessage: String) -> Bool {
        ["unknown index", "no such index", "index not found"].contains { lowercasedMessage.contains($0) }
            || (lowercasedMessage.contains("index with name") && lowercasedMessage.contains("not found"))
    }

    nonisolated static func parseConfigNumber(_ reply: RESPValue) -> Int? {
        if let rows = reply.arrayValue, let row = rows.first?.arrayValue, row.count >= 2 {
            return parseLimit(row[1].stringValue)
        }

        return parseLimit(DatabaseInfoService.configValue(reply))
    }

    nonisolated static func parseLimit(_ text: String?) -> Int? {
        guard let text, let n = Int64(text) else { return nil }
        if n <= 0 || n >= Int64(Int32.max) { return nil }
        return Int(n)
    }

    /// Parses an `FT.INFO` reply from RediSearch or valkey-search.
    public nonisolated static func parseInfo(_ reply: RESPValue, name: Data) -> SearchIndexInfo {
        let top = reply.stringKeyedMap ?? [:]
        func map(_ key: String) -> [String: RESPValue] { top[key]?.stringKeyedMap ?? [:] }

        func double(_ key: String) -> Double? {
            guard let value = top[key] else { return nil }
            if let n = value.intValue { return Double(n) }
            return value.stringValue.flatMap { Double($0) }
        }

        func int(_ key: String) -> Int? {
            double(key).flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil }
        }

        let definition = map("index_definition")
        let options = map("index_options")
        var info = SearchIndexInfo(name: name)
        info.keyType = definition["key_type"]?.stringValue.flatMap { SearchIndexKeyType(rawValue: $0.uppercased()) }
        info.prefixes = (definition["prefixes"]?.arrayValue ?? []).compactMap(\.stringValue)
        info.filter = definition["filter"]?.stringValue ?? options["filter"]?.stringValue
        info.defaultLanguage = definition["default_language"]?.stringValue ?? options["default_lang"]?.stringValue
        info.attributes = (top["attributes"]?.arrayValue ?? []).map(parseAttribute)
        info.numDocs = int("num_docs") ?? 0
        info.maxDocId = int("max_doc_id")
        info.numRecords = int("num_records") ?? 0
        info.numTerms = int("num_terms") ?? 0
        info.state = top["state"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        info.backfillInProgress = int("backfill_in_progress").map { $0 != 0 }
        info.backfillCompleteFraction = double("backfill_complete_percent")
        info.raw = reply
        return info
    }

    nonisolated static func parseAttribute(_ value: RESPValue) -> SearchIndexAttribute {
        let tokens = value.arrayValue ?? []
        var raw: [String: String] = [:]
        var flags = Set<String>()
        var i = 0
        while i < tokens.count {
            let token = tokens[i].stringValue ?? ""
            if attributeFlags.contains(token.uppercased()) {
                let next = i + 1 < tokens.count ? tokens[i + 1].stringValue : nil
                if next == "0" || next == "1" {
                    if next == "1" { flags.insert(token.uppercased()) }
                    i += 2
                } else {
                    flags.insert(token.uppercased())
                    i += 1
                }

                continue
            }

            if i + 1 < tokens.count { raw[token] = tokens[i + 1].stringValue ?? "" }
            i += 2
        }

        func field(_ key: String) -> String? { raw[key] ?? raw[key.uppercased()] ?? raw[key.lowercased()] }
        return SearchIndexAttribute(identifier: field("identifier") ?? "", attribute: field("attribute") ?? "",
                                    type: (field("type") ?? "").lowercased(), weight: field("WEIGHT"),
                                    flags: flags, raw: raw)
    }
}

/// Index definitions (key type and prefixes) of one session, read by the key details "View Index" lookup.
@MainActor
final class SearchIndexSummaryCache {
    struct Entry {
        var summary: SearchIndexSummary
        var generation: Int
        var loadedAt: Date
    }

    /// Indexes changed from Workbench or the CLI are picked up after this long.
    static let lifetime: TimeInterval = 60

    var entries: [Data: Entry] = [:]

    func prune(generation: Int, now: Date) {
        entries = entries.filter { $0.value.generation == generation && now.timeIntervalSince($0.value.loadedAt) < Self.lifetime }
    }
}
