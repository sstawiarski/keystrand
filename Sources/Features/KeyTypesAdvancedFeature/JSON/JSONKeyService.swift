import Foundation
import RedisUI

enum JSONNodeType: String, Sendable {
    case object, array, string, integer, number, boolean, null

    init(reply: String) {
        self = JSONNodeType(rawValue: reply.lowercased()) ?? .string
    }

    var containerKind: JSONContainerKind? {
        switch self {
        case .object: return .object
        case .array: return .array
        default: return nil
        }
    }
}

enum JSONCommands {
    /// Containers with at most this many children are always fetched whole.
    static let forceRetrieveLength = 200
    /// Containers smaller than this (JSON.DEBUG MEMORY bytes) are fetched whole.
    static let lazySizeThreshold = 1024
    static let pipelineChunk = 2_000

    /// JSONPath (`$…`) replies wrap results in an array; legacy replies do not.
    static func unwrap(_ value: RESPValue, jsonPath: Bool) -> RESPValue? {
        guard jsonPath else { return value.isNull ? nil : value }
        guard let first = Reply.items(value).first, !first.isNull else { return nil }
        return first
    }

    static func typeName(_ value: RESPValue, jsonPath: Bool) -> String? {
        var current = unwrap(value, jsonPath: jsonPath)
        while let inner = current, let items = inner.arrayValue {
            current = items.first
        }

        return current.flatMap(Reply.text)
    }

    /// Parses `JSON.GET` text. JSONPath replies are arrays of matches; the first match is the value.
    static func parseGet(_ text: String, jsonPath: Bool) throws -> JSONValue {
        let value = try JSONParser.parse(text)
        guard jsonPath else { return value }
        guard case .array(let matches) = value, let first = matches.first else {
            throw KeyValueError.invalid("There is no such path.")
        }
        return first
    }

    static func mapError(_ error: Error) -> Error {
        if Reply.isUnknownCommand(error) { return KeyValueError.moduleNotLoaded("JSON") }
        if let message = Reply.serverMessage(error)?.lowercased(), message.contains("out of range") || message.contains("does not exist") && message.contains("path") {
            return KeyValueError.invalid("There is no such path.")
        }

        return error
    }
}

/// Loads large RedisJSON containers lazily.
@MainActor
struct JSONKeyService {
    let session: DatabaseSession
    let key: Data

    private var jsonPath: Bool { session.capabilities.supportsJSONPath }

    private func redisPath(_ path: JSONPath) -> String { path.redisPath(jsonPath: jsonPath) }

    /// Type and cardinality of the node at `path` (nil when the key or path does not exist).
    func describe(_ path: JSONPath) async throws -> (type: JSONNodeType, length: Int)? {
        do {
            let typeReply = try await session.execute(["JSON.TYPE", .data(key), .string(redisPath(path))])
            guard let name = JSONCommands.typeName(typeReply, jsonPath: jsonPath) else { return nil }
            let type = JSONNodeType(reply: name)
            let length: Int
            switch type {
            case .object:
                length = Reply.int(JSONCommands.unwrap(try await session.execute(["JSON.OBJLEN", .data(key), .string(redisPath(path))]), jsonPath: jsonPath))
            case .array:
                length = Reply.int(JSONCommands.unwrap(try await session.execute(["JSON.ARRLEN", .data(key), .string(redisPath(path))]), jsonPath: jsonPath))
            default:
                length = 1
            }

            return (type, length)
        } catch {
            throw JSONCommands.mapError(error)
        }
    }

    func fetchValue(_ path: JSONPath) async throws -> JSONValue {
        let text = try await fetchText(path)
        let jsonPath = self.jsonPath
        return try await Task.detached(priority: .userInitiated) {
            try JSONCommands.parseGet(text, jsonPath: jsonPath)
        }.value
    }

    func fetchText(_ path: JSONPath) async throws -> String {
        do {
            let reply = try await session.execute(["JSON.GET", .data(key), .string(redisPath(path))])
            guard let text = Reply.text(reply) else {
                throw KeyValueError.invalid("There is no such path: \(path.dotted)")
            }
            return text
        } catch {
            throw JSONCommands.mapError(error)
        }
    }

    /// Downloadable JSON for the whole document (pretty, 2-space).
    func fetchDocumentText() async throws -> String {
        let value = try await fetchValue(.root)
        return await Task.detached(priority: .userInitiated) { JSONLiteral.pretty(value, indent: 2) }.value
    }

    /// Loads the node at `path`: whole when small, otherwise its direct children (containers stay unloaded). Only the
    /// first `fetchCount` children are summarized; the rest stay `.pending` until the tree shows more.
    func loadNode(_ path: JSONPath, type: JSONNodeType, length: Int,
                  fetchCount: Int = JSONTreeFlattener.defaultPageSize) async throws -> (node: JSONTreeNode, isFull: Bool) {
        guard let kind = type.containerKind, length > JSONCommands.forceRetrieveLength else {
            return (.value(try await fetchValue(path)), true)
        }
        let memoryPath = path.isRoot ? "." : redisPath(path)
        let memoryReply = try? await session.execute(["JSON.DEBUG", "MEMORY", .data(key), .string(memoryPath)])
        let memory = memoryReply.flatMap { reply -> Int? in
            if let int = reply.intValue { return Int(clamping: int) }
            return Reply.items(reply).first?.intValue.map { Int(clamping: $0) }
        }
        if let memory, memory <= JSONCommands.lazySizeThreshold {
            return (.value(try await fetchValue(path)), true)
        }

        do {
            switch kind {
            case .object:
                let keysReply = try await session.execute(["JSON.OBJKEYS", .data(key), .string(redisPath(path))])
                let keys = Reply.items(JSONCommands.unwrap(keysReply, jsonPath: jsonPath)).compactMap(Reply.text)
                let fetched = min(keys.count, max(fetchCount, 0))
                let nodes = try await childNodes(keys[..<fetched].map { path.appending(key: $0) })
                let members = keys.enumerated().map { index, key in
                    JSONTreeMember(key: key, node: index < fetched ? nodes[index] : .pending)
                }
                return (.object(members), false)
            case .array:
                let fetched = min(length, max(fetchCount, 0))
                let nodes = try await childNodes((0..<fetched).map { path.appending(index: $0) })
                return (.array(nodes + Array(repeating: .pending, count: length - fetched)), false)
            }
        } catch {
            throw JSONCommands.mapError(error)
        }
    }

    /// Children summaries, one per path: containers as `.unloaded(kind, count)`, scalars with their value.
    func childNodes(_ paths: [JSONPath]) async throws -> [JSONTreeNode] {
        var nodes: [JSONTreeNode] = []
        nodes.reserveCapacity(paths.count)
        for start in stride(from: 0, to: paths.count, by: JSONCommands.pipelineChunk) {
            try Task.checkCancellation()
            let chunk = Array(paths[start..<min(start + JSONCommands.pipelineChunk, paths.count)])
            let types = try await session.pipeline(chunk.map { ["JSON.TYPE", .data(key), .string(redisPath($0))] })
            let kinds = types.map { JSONNodeType(reply: JSONCommands.typeName($0, jsonPath: jsonPath) ?? "null") }
            let details: [[RedisArgument]] = zip(chunk, kinds).map { path, type in
                switch type {
                case .object: return ["JSON.OBJLEN", .data(key), .string(redisPath(path))]
                case .array: return ["JSON.ARRLEN", .data(key), .string(redisPath(path))]
                default: return ["JSON.GET", .data(key), .string(redisPath(path))]
                }
            }
            let replies = try await session.pipeline(details)
            let jsonPath = self.jsonPath
            let built: [JSONTreeNode] = try await Task.detached(priority: .userInitiated) {
                try zip(kinds, replies).map { type, reply in
                    try Reply.checked(reply)
                    if let kind = type.containerKind {
                        return .unloaded(kind, count: Reply.int(JSONCommands.unwrap(reply, jsonPath: jsonPath)))
                    }

                    guard let text = Reply.text(reply) else { return .value(.null) }
                    return .value(try JSONCommands.parseGet(text, jsonPath: jsonPath))
                }
            }.value
            nodes += built
        }

        return nodes
    }

    func set(_ path: JSONPath, json: String) async throws {
        do {
            let reply = try await session.execute(["JSON.SET", .data(key), .string(redisPath(path)), .string(json)])
            if reply.isNull { throw KeyValueError.invalid("There is no such path.") }
        } catch let error as KeyValueError {
            throw error
        } catch {
            throw JSONCommands.mapError(error)
        }
    }

    func append(_ path: JSONPath, json: String) async throws {
        do {
            let reply = try await session.execute(["JSON.ARRAPPEND", .data(key), .string(redisPath(path)), .string(json)])
            if jsonPath, let first = Reply.items(reply).first, first.intValue == nil {
                throw KeyValueError.invalid("ERR Path \(path.dotted) does not exist or not an array")
            }
        } catch let error as KeyValueError {
            throw error
        } catch {
            throw JSONCommands.mapError(error)
        }
    }

    func delete(_ path: JSONPath) async throws -> Int {
        do {
            return Reply.int(try await session.execute(["JSON.DEL", .data(key), .string(redisPath(path))]))
        } catch {
            throw JSONCommands.mapError(error)
        }
    }
}
