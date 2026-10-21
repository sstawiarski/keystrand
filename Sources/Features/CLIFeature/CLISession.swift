import Foundation
import RedisCore

/// The CLI's own Redis connection: tracks the logical DB, follows cluster MOVED/ASK like `redis-cli -c`,
/// and formats replies redis-cli style off the main actor.
public actor CLISession {
    /// An open connection and the logical DB it is on.
    public struct Link: Sendable {
        public var client: any RedisClient
        public var db: Int

        public init(client: any RedisClient, db: Int) {
            self.client = client
            self.db = db
        }
    }

    /// Opens a dedicated connection, to `node` when given (cluster redirects), else to the database.
    public typealias Connector = @Sendable (_ node: RedisEndpoint?) async throws -> Link

    public struct Reply: Hashable, Sendable {
        /// `-> Redirected to slot [N] located at host:port` lines, in order.
        public var redirects: [String]
        public var text: String
        public var isError: Bool
        /// Logical DB after the command.
        public var db: Int
        public var truncatedCharacters: Int
    }

    public static let defaultMaxReplyCharacters = 200_000
    public static let maxRedirections = 5

    private let connector: Connector
    private let isCluster: Bool
    private let defaultHost: String
    private let maxReplyCharacters: Int
    private var link: Link?
    private var node: RedisEndpoint?
    private var wantedDB: Int?
    /// Bumped by `close()`, so a connection that finishes opening after a close is discarded.
    private var closeGeneration = 0
    public private(set) var db: Int

    public init(connector: @escaping Connector, isCluster: Bool, defaultHost: String, initialDB: Int = 0,
                maxReplyCharacters: Int = CLISession.defaultMaxReplyCharacters) {
        self.connector = connector
        self.isCluster = isCluster
        self.defaultHost = defaultHost
        self.db = initialDB
        self.maxReplyCharacters = max(1, maxReplyCharacters)
    }

    public var isConnected: Bool { link != nil }

    /// Connects when needed (restoring the DB of the first connection or the one chosen with SELECT) and returns
    /// the current DB.
    @discardableResult
    public func connect() async throws -> Int {
        if link != nil { return db }
        let generation = closeGeneration
        let opened = try await restoringDB(connector(node), since: generation)
        if link != nil {
            await opened.client.close()
            return db
        }

        link = opened
        db = opened.db
        wantedDB = wantedDB ?? opened.db
        return db
    }

    /// Drops the current connection and opens a new one.
    @discardableResult
    public func reconnect() async throws -> Int {
        await dropLink()
        return try await connect()
    }

    /// Closes the connection; the next `execute` or `connect` opens a new one.
    public func close() async {
        closeGeneration += 1
        await dropLink()
    }

    /// Sends one command and formats the reply. Throws only on transport/connection failures.
    public func execute(_ args: [Data], commandLine: String) async throws -> Reply {
        try await connect()
        guard var current = link else { throw RedisClientError.notConnected }
        let arguments = args.map { RedisArgument.data($0) }
        var reply = try await current.client.send(arguments)
        var redirects: [String] = []
        while isCluster, case .error(let error) = reply,
              let redirect = ClusterRedirect(error, defaultHost: defaultHost) {
            guard redirects.count < Self.maxRedirections else {
                reply = .error(RESPError(RedisClientError.tooManyRedirections.localizedDescription))
                break
            }
            let slot: Int
            switch redirect {
            case .moved(let s, _), .ask(let s, _): slot = s
            }

            let target = redirect.endpoint
            redirects.append("-> Redirected to slot [\(slot)] located at \(target.host):\(target.port)")
            await dropLink()
            node = target
            let generation = closeGeneration
            current = try await restoringDB(connector(target), since: generation)
            link = current
            db = current.db
            if case .ask = redirect {
                _ = try await current.client.send(["ASKING"])
            }

            reply = try await current.client.send(arguments)
        }

        if !reply.isError, let selected = CLICommandPlanner.selectedDB(args: args) {
            db = selected
            wantedDB = selected
            link?.db = selected
        }

        let formatted = Self.format(reply, commandLine: commandLine, maxCharacters: maxReplyCharacters)
        return Reply(redirects: redirects, text: formatted.text, isError: reply.isError, db: db,
                     truncatedCharacters: formatted.truncated)
    }

    /// Restores the CLI's first connection DB or last successful `SELECT`, which can differ from the window's DB.
    /// This also applies to redirected connections on Valkey 9 clusters with numbered databases.
    private func restoringDB(_ opened: Link, since generation: Int) async throws -> Link {
        try await discardIfClosed(opened, since: generation)
        guard let wantedDB, wantedDB != opened.db else { return opened }
        var restored = opened
        let reply = try await opened.client.send(["SELECT", .int(Int64(wantedDB))])
        try await discardIfClosed(opened, since: generation)
        if !reply.isError { restored.db = wantedDB }
        return restored
    }

    private func discardIfClosed(_ opened: Link, since generation: Int) async throws {
        guard closeGeneration != generation else { return }
        await opened.client.close()
        throw RedisClientError.notConnected
    }

    private func dropLink() async {
        guard let old = link else { return }
        link = nil
        await old.client.close()
    }

    /// Formats replies with ASCII-escaped strings unless human-readable output is requested.
    public static func format(_ reply: RESPValue, commandLine: String,
                              maxCharacters: Int = defaultMaxReplyCharacters) -> (text: String, truncated: Int) {
        let text: String
        if case .error(let error) = reply {
            text = error.message
        } else {
            let node = (try? ReplyNodeBuilder.build(reply, mode: .ascii, command: commandLine)) ?? .null
            text = ReplyTextFormatter.text(node, command: commandLine)
        }

        let total = text.utf16.count
        guard total > maxCharacters else { return (text, 0) }
        let head = String(text.prefix(maxCharacters))
        return (head, total - head.utf16.count)
    }
}
