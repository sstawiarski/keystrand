import Foundation
import RedisUI

struct VectorSetPage: Sendable {
    var total: Int
    var names: [Data]
    var attributes: [Data: String]
    var nextCursor: Data?
    var isPaginationSupported: Bool
}

struct VectorElementDetails: Sendable, Equatable {
    var vector: [Double]
    var attributes: String?
}

@MainActor
struct VectorSetService {
    let session: DatabaseSession
    let key: Data

    func info() async throws -> (total: Int, info: VectorSetInfo) {
        let replies = try await session.pipeline([["VCARD", .data(key)], ["VINFO", .data(key)]])
        guard replies.count == 2 else { throw KeyValueError.invalid("Unexpected reply") }
        let total = Reply.int(try Reply.checked(replies[0]))
        if total == 0 { throw KeyOperationError.keyNotFound }
        return (total, VectorSetCommands.parseInfo(replies[1]))
    }

    /// `VRANGE key start + count`, falling back to `VRANDMEMBER` on servers without VRANGE.
    func page(start: Data = Data("-".utf8), count: Int = VectorSetCommands.pageSize) async throws -> VectorSetPage {
        let total = Reply.int(try await session.execute(["VCARD", .data(key)]))
        if total == 0 { throw KeyOperationError.keyNotFound }
        var names: [Data]
        var supported = true
        do {
            names = Reply.items(try await session.execute(["VRANGE", .data(key), .data(start), "+", .int(Int64(count))]))
                .compactMap(\.dataValue)
        } catch where Reply.isUnknownCommand(error) {
            supported = false
            do {
                names = Reply.items(try await session.execute(["VRANDMEMBER", .data(key), .int(Int64(count))]))
                    .compactMap(\.dataValue)
            } catch where Reply.isUnknownCommand(error) {
                throw KeyValueError.invalid("Couldn't read the vector set's elements: both VRANGE and VRANDMEMBER failed.")
            }
        }

        let attributes = try await attributes(for: names)
        let next: Data? = supported && names.count == count && count > 0 ? names.last.map { Data("(".utf8) + $0 } : nil
        return VectorSetPage(total: total, names: names, attributes: attributes, nextCursor: next,
                             isPaginationSupported: supported)
    }

    func attributes(for names: [Data]) async throws -> [Data: String] {
        guard !names.isEmpty else { return [:] }
        let replies = try await session.pipeline(names.map { ["VGETATTR", .data(key), .data($0)] })
        var out: [Data: String] = [:]
        for (name, reply) in zip(names, replies) where !reply.isError {
            if let text = Reply.text(reply) { out[name] = text }
        }

        return out
    }

    func details(_ element: Data) async throws -> VectorElementDetails {
        let replies = try await session.pipeline([["VEMB", .data(key), .data(element)], ["VGETATTR", .data(key), .data(element)]])
        guard replies.count == 2 else { throw KeyValueError.invalid("Unexpected reply") }
        let embedding = try Reply.checked(replies[0])
        if embedding.isNull { throw KeyValueError.invalid("Element does not exist.") }
        return VectorElementDetails(vector: VectorSetCommands.parseEmbedding(embedding),
                                    attributes: replies[1].isError ? nil : Reply.text(replies[1]))
    }

    /// Sets (or clears, with an empty string) the attributes and returns the stored value.
    func setAttributes(_ element: Data, json: String) async throws -> String? {
        _ = try await session.execute(["VSETATTR", .data(key), .data(element), .string(json)])
        return Reply.text(try await session.execute(["VGETATTR", .data(key), .data(element)]))
    }

    func add(_ elements: [(name: Data, vector: VectorInput, attributes: String?)],
             create: VectorSetCreateOptions? = nil, targetKey: Data? = nil) async throws {
        let target = targetKey ?? key
        let commands = elements.map {
            VectorSetCommands.add(key: target, element: $0.name, vector: $0.vector, attributes: $0.attributes, create: create)
        }
        let replies = try await session.pipeline(commands)
        if let error = replies.compactMap(\.errorValue).first { throw RedisClientError.server(error) }
    }

    func remove(_ elements: [Data]) async throws -> (removed: Int, remaining: Int) {
        var commands: [[RedisArgument]] = elements.map { ["VREM", .data(key), .data($0)] }
        commands.append(["VCARD", .data(key)])
        let replies = try await session.pipeline(commands)
        if let error = replies.compactMap(\.errorValue).first { throw RedisClientError.server(error) }
        let removed = replies.dropLast().reduce(0) { $0 + Reply.int($1) }
        return (removed, Reply.int(replies.last))
    }

    func similarity(_ request: SimilarityRequest) async throws -> [SimilarityMatch] {
        let reply = try await session.execute(VectorSetCommands.similarity(request))
        var matches = VectorSetCommands.parseSimilarity(reply, withAttributes: request.withAttributes)
        if !request.withAttributes, !matches.isEmpty {
            let attributes = try await attributes(for: matches.map(\.name))
            for index in matches.indices { matches[index].attributes = attributes[matches[index].name] }
        }

        return matches
    }
}
