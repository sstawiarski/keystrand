import Foundation
import RedisUI

@MainActor
struct StreamService {
    let session: DatabaseSession
    let key: Data

    func info() async throws -> StreamInfo {
        let replies = try await session.pipeline([["EXISTS", .data(key)], ["XINFO", "STREAM", .data(key)]])
        guard replies.count == 2 else { throw KeyValueError.invalid("Unexpected reply") }
        if Reply.int(try Reply.checked(replies[0])) == 0 { throw KeyOperationError.keyNotFound }
        return StreamCommands.parseInfo(try Reply.checked(replies[1]))
    }

    func entries(start: String, end: String, order: KeySortOrder, count: Int = StreamCommands.pageSize) async throws -> [StreamEntry] {
        let reply = try await session.execute(StreamCommands.entries(key: key, start: start, end: end, order: order, count: count))
        return StreamCommands.parseEntries(reply)
    }

    func add(id: String, fields: [StreamField]) async throws -> String {
        do {
            let reply = try await session.execute(StreamCommands.add(key: key, id: id, fields: fields))
            return reply.stringValue ?? id
        } catch {
            if let message = Reply.serverMessage(error), message.contains("equal or smaller") {
                throw KeyValueError.invalid("Must be greater than the last ID")
            }

            throw error
        }
    }

    func delete(ids: [String]) async throws -> Int {
        Reply.int(try await session.execute([.string("XDEL"), .data(key)] + ids.map { .string($0) }))
    }

    func groups() async throws -> [ConsumerGroup] {
        let exists = Reply.int(try await session.execute(["EXISTS", .data(key)]))
        if exists == 0 { throw KeyOperationError.keyNotFound }
        var groups = StreamCommands.parseGroups(try await session.execute(["XINFO", "GROUPS", .data(key)]))
        guard !groups.isEmpty else { return [] }
        let summaries = try await session.pipeline(groups.map { ["XPENDING", .data(key), .data($0.name)] })
        for (index, summary) in summaries.enumerated() where index < groups.count {
            let parts = Reply.items(summary)
            guard parts.count >= 3 else { continue }
            groups[index].smallestPendingId = Reply.text(parts[1])
            groups[index].greatestPendingId = Reply.text(parts[2])
        }

        return groups
    }

    func createGroup(name: Data, id: String) async throws {
        do {
            _ = try await session.execute(["XGROUP", "CREATE", .data(key), .data(name), .string(id)])
        } catch {
            if let message = Reply.serverMessage(error), message.hasPrefix("BUSYGROUP") {
                throw KeyValueError.invalid("Consumer Group with such name already exists.")
            }

            throw error
        }
    }

    func setGroupId(group: Data, id: String) async throws {
        do {
            _ = try await session.execute(["XGROUP", "SETID", .data(key), .data(group), .string(id)])
        } catch {
            if let message = Reply.serverMessage(error), message.hasPrefix("NOGROUP") {
                throw KeyValueError.invalid("No consumer group has this name.")
            }

            throw error
        }
    }

    func deleteGroup(_ group: Data) async throws {
        _ = try await session.execute(["XGROUP", "DESTROY", .data(key), .data(group)])
    }

    func consumers(group: Data) async throws -> [StreamConsumer] {
        do {
            return StreamCommands.parseConsumers(try await session.execute(["XINFO", "CONSUMERS", .data(key), .data(group)]))
        } catch {
            if let message = Reply.serverMessage(error), message.hasPrefix("NOGROUP") {
                throw KeyValueError.invalid("No consumer group has this name.")
            }

            throw error
        }
    }

    func deleteConsumer(group: Data, consumer: Data) async throws {
        _ = try await session.execute(["XGROUP", "DELCONSUMER", .data(key), .data(group), .data(consumer)])
    }

    func pending(group: Data, consumer: Data, start: String = "-", count: Int = StreamCommands.pageSize) async throws -> [PendingEntry] {
        StreamCommands.parsePending(try await session.execute(
            StreamCommands.pending(key: key, group: group, consumer: consumer, start: start, count: count)))
    }

    func ack(group: Data, ids: [String]) async throws -> Int {
        Reply.int(try await session.execute([.string("XACK"), .data(key), .data(group)] + ids.map { .string($0) }))
    }

    func claim(group: Data, ids: [String], options: ClaimOptions) async throws -> [String] {
        let reply = try await session.execute(StreamCommands.claim(key: key, group: group, ids: ids, options: options))
        return Reply.items(reply).compactMap(\.stringValue)
    }

    func autoClaim(group: Data, consumer: Data, minIdleMs: Int, start: String, count: Int) async throws -> (next: String, ids: [String]) {
        StreamCommands.parseAutoClaim(try await session.execute(
            StreamCommands.autoClaim(key: key, group: group, consumer: consumer, minIdleMs: minIdleMs, start: start, count: count)))
    }
}
