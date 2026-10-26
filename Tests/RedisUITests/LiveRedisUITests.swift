import Foundation
import Testing
import TestSupport
@testable import RedisUI

@Suite("RedisUI against live Redis", .serialized, .tags(.live), RedisTestServer.live(.redis))
struct LiveRedisUITests {
    static let db = RedisTestServer.DB.redisUI

    @Test func serverCommandsHighlightAsKeywords() async throws {
        let connection = try await RedisTestServer.makeConnection(db: Self.db)
        let reply = try await connection.execute(["COMMAND", "LIST"])
        await connection.close()
        let names = Set((reply.arrayValue ?? []).compactMap(\.stringValue).map { $0.uppercased() })
        #expect(names.contains("GET"))

        let script = "set a 1\n  ex 10\njson.set k $ 1\n// note\n3 hget h f"
        let tokens = RedisSyntaxHighlighter.tokenizeRedis(script, keywords: names)
        let keywords = tokens.filter { $0.kind == .keyword }.map { (script as NSString).substring(with: $0.range) }
        #expect(keywords == (names.contains("JSON.SET") ? ["set", "json.set", "hget"] : ["set", "hget"]))

        if !CommandCatalog.shared.commands.isEmpty {
            for core in ["GET", "SET", "HSET", "ZADD", "XADD", "JSON.SET", "FT.SEARCH"] where names.contains(core) {
                #expect(RedisSyntaxHighlighter.defaultKeywords.contains(core), "bundled catalog lacks \(core)")
            }
        }
    }

    @Test(RedisTestServer.needs(.json)) func pathsAddressRealDocuments() async throws {
        let connection = try await RedisTestServer.freshConnection(db: Self.db)
        defer { Task { await connection.close() } }
        let key = RedisTestServer.uniquePrefix("ui") + "doc"
        _ = try await connection.execute(["JSON.SET", .string(key), "$", .string(Self.document)])

        let checks: [(JSONPath, JSONValue)] = [
            (JSONPath([.key("a"), .key("b c"), .index(0)]), .number("10")),
            (JSONPath([.key("a"), .key("b c"), .index(1), .key(#"q"k"#)]), .string("v")),
            (JSONPath([.key("it's")]), .bool(true)),
            (JSONPath([.key("both ' and \"")]), .null),
            (JSONPath([.key("x.y")]), .number("7")),
        ]
        for (path, expected) in checks {
            #expect(try await Self.get(connection, key, path) == expected, "path \(path.bracketed)")
        }
    }

    @Test(RedisTestServer.needs(.json)) func lazyLoadingRebuildsTheFullDocument() async throws {
        let connection = try await RedisTestServer.freshConnection(db: Self.db)
        defer { Task { await connection.close() } }
        let key = RedisTestServer.uniquePrefix("ui") + "lazy"
        _ = try await connection.execute(["JSON.SET", .string(key), "$", .string(Self.document)])
        let full = try #require(try await Self.get(connection, key, .root))

        let model = await JSONTreeModel(root: .unloaded(.object, count: full.childCountForTest))
        var guardCount = 0
        while let path = await Self.firstUnloaded(in: model.root, at: .root), guardCount < 50 {
            let node = try await Self.load(connection, key, path)
            await model.replaceNode(at: path, with: node)
            guardCount += 1
        }

        #expect(await model.root.fullValue == full)
        if case .value = await model.root {} else { Issue.record("fully loaded root should collapse to .value") }
    }

    @Test(RedisTestServer.needs(.json)) func localEditsMatchServerState() async throws {
        let connection = try await RedisTestServer.freshConnection(db: Self.db)
        defer { Task { await connection.close() } }
        let key = RedisTestServer.uniquePrefix("ui") + "edit"
        _ = try await connection.execute(["JSON.SET", .string(key), "$", .string(Self.document)])
        let model = await JSONTreeModel(value: try #require(try await Self.get(connection, key, .root)))

        let scalar = JSONPath([.key("a"), .key("b c"), .index(0)])
        _ = try await connection.execute(["JSON.SET", .string(key), .string(scalar.bracketed), "\"changed\""])
        await model.replaceNode(at: scalar, with: .value(.string("changed")))

        let array = JSONPath([.key("a"), .key("b c")])
        _ = try await connection.execute(["JSON.ARRAPPEND", .string(key), .string(array.bracketed), "42"])
        await model.addNode(.value(.number("42")), key: nil, under: array)

        _ = try await connection.execute(["JSON.SET", .string(key), .string(JSONPath([.key("new key")]).bracketed), "[]"])
        await model.addNode(.value(.array([])), key: "new key", under: .root)

        let removed = JSONPath([.key("both ' and \"")])
        _ = try await connection.execute(["JSON.DEL", .string(key), .string(removed.bracketed)])
        await model.removeNode(at: removed)

        let server = try await Self.get(connection, key, .root)
        // RedisJSON may reuse a deleted member's slot, so compare objects without member order.
        let local = await model.root.fullValue
        #expect(local.map(Self.sortedMembers) == server.map(Self.sortedMembers))
    }

    // MARK: Helpers

    static let document = #"{"a":{"b c":[10,{"q\"k":"v"}]},"it's":true,"both ' and \"":null,"x.y":7,"list":[[1,2],{"z":[]}]}"#

    static func get(_ connection: RedisConnection, _ key: String, _ path: JSONPath) async throws -> JSONValue? {
        let reply = try await connection.execute(["JSON.GET", .string(key), .string(path.bracketed)])
        guard let text = reply.stringValue, case .array(let items) = try JSONParser.parse(text) else { return nil }
        return items.first
    }

    static func sortedMembers(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let members):
            return .object(members.map { JSONMember(key: $0.key, value: sortedMembers($0.value)) }.sorted { $0.key < $1.key })
        case .array(let items):
            return .array(items.map(sortedMembers))
        default:
            return value
        }
    }

    static func firstString(_ value: RESPValue) -> String? {
        if let string = value.stringValue { return string }
        return value.arrayValue?.lazy.compactMap(firstString).first
    }

    static func firstInt(_ value: RESPValue) -> Int? {
        if let int = value.intValue { return Int(int) }
        return value.arrayValue?.lazy.compactMap(firstInt).first
    }

    /// Loads container children lazily and scalar children eagerly.
    static func load(_ connection: RedisConnection, _ key: String, _ path: JSONPath) async throws -> JSONTreeNode {
        let type = firstString(try await connection.execute(["JSON.TYPE", .string(key), .string(path.bracketed)]))
        switch type {
        case "object":
            let reply = try await connection.execute(["JSON.OBJKEYS", .string(key), .string(path.bracketed)])
            let keys = (reply.arrayValue?.first?.arrayValue ?? []).compactMap(\.stringValue)
            var members: [JSONTreeMember] = []
            for childKey in keys {
                members.append(JSONTreeMember(key: childKey, node: try await child(connection, key, path.appending(key: childKey))))
            }

            return .object(members)
        case "array":
            let count = firstInt(try await connection.execute(["JSON.ARRLEN", .string(key), .string(path.bracketed)])) ?? 0
            var items: [JSONTreeNode] = []
            for index in 0..<count {
                items.append(try await child(connection, key, path.appending(index: index)))
            }

            return .array(items)
        default:
            return .value(try await get(connection, key, path) ?? .null)
        }
    }

    static func child(_ connection: RedisConnection, _ key: String, _ path: JSONPath) async throws -> JSONTreeNode {
        let type = firstString(try await connection.execute(["JSON.TYPE", .string(key), .string(path.bracketed)]))
        switch type {
        case "object":
            let count = firstInt(try await connection.execute(["JSON.OBJLEN", .string(key), .string(path.bracketed)])) ?? 0
            return .unloaded(.object, count: count)
        case "array":
            let count = firstInt(try await connection.execute(["JSON.ARRLEN", .string(key), .string(path.bracketed)])) ?? 0
            return .unloaded(.array, count: count)
        default:
            return .value(try await get(connection, key, path) ?? .null)
        }
    }

    static func firstUnloaded(in node: JSONTreeNode, at path: JSONPath) -> JSONPath? {
        if !node.isLoaded { return path }
        guard node.isContainer else { return nil }
        if case .value = node { return nil }
        for (component, child) in node.children(in: 0..<node.childCount) {
            if let found = firstUnloaded(in: child, at: path.appending(component)) { return found }
        }

        return nil
    }
}

private extension JSONValue {
    var childCountForTest: Int {
        switch self {
        case .object(let members): return members.count
        case .array(let items): return items.count
        default: return 0
        }
    }
}
