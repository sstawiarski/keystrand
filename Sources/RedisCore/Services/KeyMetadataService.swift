import Foundation

/// TYPE, TTL, MEMORY USAGE and length pipelines for keys.
@MainActor
public struct KeyMetadataService {
    public let session: DatabaseSession
    /// Keys per pipeline batch for list rows.
    public nonisolated static let batchSize = 1_000
    /// Size is skipped (-1) above this length when the Size column is hidden.
    public nonisolated static let sizeLengthLimit = 50_000
    public nonisolated static let jsonSizeLengthLimit = 100

    public init(session: DatabaseSession) {
        self.session = session
    }

    /// Rows for the key list. `knownType` skips TYPE when the list is filtered by type.
    public func metadata(for keys: [Data], includeSize: Bool, includeTTL: Bool,
                         knownType: KeyType? = nil) async throws -> [KeyListItem] {
        guard !keys.isEmpty else { return [] }
        var perKey = 0
        if knownType == nil { perKey += 1 }
        if includeTTL { perKey += 1 }
        if includeSize { perKey += 1 }
        guard perKey > 0 else { return keys.map { KeyListItem(name: $0, type: knownType) } }

        let batches = stride(from: 0, to: keys.count, by: Self.batchSize).map {
            Array(keys[$0..<min($0 + Self.batchSize, keys.count)])
        }
        let session = session
        let commandBatches = batches.map {
            Self.rowCommands($0, knownType: knownType, includeTTL: includeTTL, includeSize: includeSize)
        }
        var batchReplies: [[RESPValue]] = []
        batchReplies.reserveCapacity(commandBatches.count)
        for start in stride(from: 0, to: commandBatches.count, by: Self.concurrentBatches) {
            try Task.checkCancellation()
            let window = commandBatches[start..<min(start + Self.concurrentBatches, commandBatches.count)]
            let sends = window.map { commands in Task { try await session.pipeline(commands) } }
            for send in sends { batchReplies.append(try await send.value) }
        }

        var items: [KeyListItem] = []
        items.reserveCapacity(keys.count)
        for (batch, replies) in zip(batches, batchReplies) {
            for (index, key) in batch.enumerated() {
                var offset = index * perKey
                var item = KeyListItem(name: key, type: knownType)
                if knownType == nil {
                    item.type = Self.reply(replies, offset).stringValue.flatMap(KeyType.init(typeReply:))
                    offset += 1
                }

                if includeTTL {
                    item.ttl = Self.reply(replies, offset).intValue.map(Int.init)
                    offset += 1
                }

                if includeSize {
                    item.size = Self.reply(replies, offset).intValue.map(Int.init)
                }

                items.append(item)
            }
        }

        await reportSearchJSON(items)
        return items
    }

    /// Pipelines in flight at once for a long key list.
    nonisolated static let concurrentBatches = 4

    /// TYPE / TTL / MEMORY USAGE per row. Rows use the server's default sampling, which keeps large collections
    /// cheap; the key details header measures exactly.
    nonisolated static func rowCommands(_ keys: [Data], knownType: KeyType?, includeTTL: Bool,
                                        includeSize: Bool) -> [[RedisArgument]] {
        var commands: [[RedisArgument]] = []
        for key in keys {
            if knownType == nil { commands.append(["TYPE", .data(key)]) }
            if includeTTL { commands.append(["TTL", .data(key)]) }
            if includeSize { commands.append(["MEMORY", "USAGE", .data(key)]) }
        }

        return commands
    }

    /// JSON keys in the list and no search index yet: suggest indexing JSON.
    private func reportSearchJSON(_ items: [KeyListItem]) async {
        guard let jsonKey = items.first(where: { $0.type == .json })?.name,
              session.liveTips.beginCheck(.searchJSON) else { return }
        if let indexes = try? await session.execute(["FT._LIST"]), !(indexes.arrayValue ?? []).isEmpty { return }
        session.liveTips.report(.searchJSON, key: jsonKey)
    }

    /// TYPE-dependent header commands, and whether MEMORY USAGE runs without checking the length first.
    private struct InfoPlan {
        var type: KeyType
        var lengthCommands: [[RedisArgument]] = []
        var sizeAlways: Bool
        var sizeLimit = KeyMetadataService.sizeLengthLimit

        init(_ type: KeyType, key k: RedisArgument, includeSize: Bool) {
            self.type = type
            sizeAlways = includeSize
            switch type {
            case .string: lengthCommands = [["STRLEN", k]]; sizeAlways = true
            case .hash: lengthCommands = [["HLEN", k]]
            case .list: lengthCommands = [["LLEN", k]]
            case .set: lengthCommands = [["SCARD", k]]
            case .zset: lengthCommands = [["ZCARD", k]]
            case .stream: lengthCommands = [["XLEN", k]]
            case .vectorSet: lengthCommands = [["VCARD", k], ["VINFO", k]]
            case .json: lengthCommands = [["JSON.TYPE", k]]; sizeLimit = KeyMetadataService.jsonSizeLengthLimit
            case .timeSeries: lengthCommands = [["TS.INFO", k]]; sizeAlways = true
            case .graph: lengthCommands = [["GRAPH.QUERY", k, "MATCH (r) RETURN count(r)", "--compact"]]; sizeAlways = true
            case .array: lengthCommands = [["ARLEN", k], ["ARCOUNT", k]]
            case .unknown: sizeAlways = true
            }
        }
    }

    /// Header info for one key. Throws `KeyOperationError.keyNotFound` when TYPE is `none`. With `typeHint` (the
    /// type the key list shows), TYPE, TTL and the length commands share one round trip.
    public func keyInfo(_ key: Data, includeSize: Bool = true, typeHint: KeyType? = nil) async throws -> KeyInfo {
        let k = RedisArgument.data(key)
        let memory: [RedisArgument] = ["MEMORY", "USAGE", k, "SAMPLES", "0"]
        let hinted = typeHint.map { InfoPlan($0, key: k, includeSize: includeSize) }
        var head: [[RedisArgument]] = [["TYPE", k], ["TTL", k]] + (hinted?.lengthCommands ?? [])
        let memoryInHead = hinted?.sizeAlways ?? includeSize
        if memoryInHead { head.append(memory) }
        let first = try await session.pipeline(head)
        guard let type = Self.reply(first, 0).stringValue.flatMap(KeyType.init(typeReply:)) else {
            if let error = first.first?.errorValue { throw RedisClientError.server(error) }
            throw KeyOperationError.keyNotFound
        }
        var info = KeyInfo(name: key, type: type)
        info.ttl = Self.reply(first, 1).intValue.map(Int.init) ?? -1
        if info.ttl == -2 { throw KeyOperationError.keyNotFound }
        if memoryInHead, first.count == head.count {
            info.size = Self.reply(first, head.count - 1).intValue.map(Int.init)
        }

        let plan: InfoPlan
        let lengthReplies: [RESPValue]
        if let hinted, hinted.type == type {
            plan = hinted
            lengthReplies = (0..<hinted.lengthCommands.count).map { Self.reply(first, 2 + $0) }
        } else {
            plan = InfoPlan(type, key: k, includeSize: includeSize)
            var commands = plan.lengthCommands
            let measure = plan.sizeAlways && !memoryInHead
            if measure { commands.append(memory) }
            let replies = commands.isEmpty ? [] : try await session.pipeline(commands)
            lengthReplies = (0..<plan.lengthCommands.count).map { Self.reply(replies, $0) }
            if measure, replies.count == commands.count {
                info.size = Self.reply(replies, commands.count - 1).intValue.map(Int.init)
            }
        }

        let sizeAlways = plan.sizeAlways || memoryInHead
        let sizeLimit = plan.sizeLimit

        switch type {
        case .vectorSet:
            info.length = lengthReplies.first?.intValue.map(Int.init)
            if let fields = lengthReplies.dropFirst().first?.stringKeyedMap {
                info.quantType = fields["quant-type"]?.stringValue
                info.vectorDim = fields["vector-dim"]?.intValue.map(Int.init)
            }
        case .json:
            info.length = try await jsonLength(key, typeReply: lengthReplies.first)
        case .timeSeries:
            info.length = lengthReplies.first?.stringKeyedMap?["totalSamples"]?.intValue.map(Int.init)
        case .graph:
            info.length = lengthReplies.first.flatMap(Self.graphCount)
        case .array:
            info.lengthString = lengthReplies.first?.stringValue
            info.count = lengthReplies.dropFirst().first?.stringValue
            info.length = info.lengthString.flatMap { Int($0) }
        default:
            info.length = lengthReplies.first?.intValue.map(Int.init)
        }

        if !sizeAlways {
            let measure: Int?
            if type == .array { measure = info.count.flatMap { Int($0) } ?? info.length } else { measure = info.length }
            if let measure, measure >= sizeLimit {
                info.size = -1
            } else if let reply = try? await session.pipeline([memory]).first {
                info.size = reply.intValue.map(Int.init)
            }
        }
        session.liveTips.reportKeyInfo(info)
        return info
    }

    private func jsonLength(_ key: Data, typeReply: RESPValue?) async throws -> Int? {
        var typeName = typeReply?.stringValue
        if typeName == nil, let items = typeReply?.arrayValue { typeName = items.first?.stringValue }
        let k = RedisArgument.data(key)
        let command: [RedisArgument]
        switch typeName?.lowercased() {
        case "object": command = ["JSON.OBJLEN", k]
        case "array": command = ["JSON.ARRLEN", k]
        case "string": command = ["JSON.STRLEN", k]
        default: return 1
        }

        guard let reply = try await session.pipeline([command]).first else { return nil }
        if let n = reply.intValue { return Int(n) }
        return reply.arrayValue?.first?.intValue.map(Int.init)
    }

    /// `GRAPH.QUERY ... --compact` -> reply[1][0][0][1].
    static func graphCount(_ reply: RESPValue) -> Int? {
        guard let items = reply.arrayValue, items.count > 1, let rows = items[1].arrayValue,
              let row = rows.first?.arrayValue, let cell = row.first?.arrayValue, cell.count > 1 else { return nil }
        return cell[1].intValue.map(Int.init)
    }

    static func reply(_ replies: [RESPValue], _ index: Int) -> RESPValue {
        guard index < replies.count else { return .null }
        if replies[index].isError { return .null }
        return replies[index]
    }
}
