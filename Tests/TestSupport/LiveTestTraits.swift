import Darwin
import Foundation
import RedisCore
import Testing

public extension Tag {
    /// Tests that need a running Redis or Valkey server. Pair it with `RedisTestServer.live(_:modules:)`.
    @Tag static var live: Self
}

public extension RedisTestServer {
    /// The servers `scripts/test-servers.sh` starts.
    enum LiveServer: Sendable {
        case redis
        case valkey
        case valkeyCluster

        public var endpoint: RedisEndpoint {
            switch self {
            case .redis: RedisTestServer.endpoint
            case .valkey: RedisTestServer.valkey
            case .valkeyCluster: RedisTestServer.valkeyCluster[0]
            }
        }

        public var name: String {
            switch self {
            case .redis: "Redis"
            case .valkey: "Valkey"
            case .valkeyCluster: "the Valkey cluster"
            }
        }

        public var isAvailable: Bool {
            switch self {
            case .redis: RedisTestServer.isAvailable
            case .valkey: RedisTestServer.isValkeyAvailable
            case .valkeyCluster: RedisTestServer.isValkeyClusterAvailable
            }
        }
    }

    /// Server modules a test can depend on. Redis 8 and the Valkey bundle use different names for some of them.
    enum Module: String, Sendable, CaseIterable {
        case search
        case json
        case timeSeries
        case bloom
        case vectorSet

        /// Lowercased `MODULE LIST` names that provide the module.
        public var names: Set<String> {
            switch self {
            case .search: ["search"]
            case .json: ["rejson", "json"]
            case .timeSeries: ["timeseries"]
            case .bloom: ["bf", "bloom"]
            case .vectorSet: ["vectorset"]
            }
        }
    }

    /// `KEYSTRAND_SKIP_LIVE=1` disables every live test, so a run without servers neither probes nor fails.
    static let skipLiveEnvironmentKey = "KEYSTRAND_SKIP_LIVE"

    static let skipsLive: Bool = ProcessInfo.processInfo.environment[skipLiveEnvironmentKey] == "1"

    /// Gate for a live suite or test: the server answers, live tests are not skipped, and `modules` are loaded.
    /// Always pair it with `.tags(.live)`: `@Suite(.tags(.live), RedisTestServer.live(.redis, modules: .json))`.
    static func live(_ server: LiveServer = .redis, modules: Module...) -> ConditionTrait {
        .enabled(if: server.isAvailable && hasModules(modules, on: server), requirement(server, modules))
    }

    /// Extra gate for one test of a live suite that needs server modules the rest of the suite does not.
    static func needs(_ modules: Module..., on server: LiveServer = .redis) -> ConditionTrait {
        .enabled(if: hasModules(modules, on: server), requirement(server, modules))
    }

    private static func requirement(_ server: LiveServer, _ modules: [Module]) -> Comment {
        let names = modules.map(\.rawValue).joined(separator: ", ")
        return Comment(rawValue: modules.isEmpty ? "Needs \(server.name)" : "Needs \(server.name) with \(names)")
    }

    /// True when `server` loads every module in `modules`. An unreachable server counts as having them only
    /// with `KEYSTRAND_REQUIRE_LIVE=1`, so a missing server fails its tests instead of skipping them.
    static func hasModules(_ modules: [Module], on server: LiveServer = .redis) -> Bool {
        guard !modules.isEmpty else { return true }
        guard let loaded = loadedModules(server) else { return requiresLive }
        return modules.allSatisfy { !$0.names.isDisjoint(with: loaded) }
    }

    /// True when `server` loads `module`.
    static func hasModule(_ module: Module, on server: LiveServer = .redis) -> Bool {
        hasModules([module], on: server)
    }

    /// Lowercased module names from `MODULE LIST`, or nil when the server does not answer.
    static func modules(at endpoint: RedisEndpoint, timeoutMs: Int32 = 500) -> Set<String>? {
        guard let reply = inlineCommand("MODULE LIST", at: endpoint, timeoutMs: timeoutMs) else { return nil }
        guard let entries = reply.arrayValue else { return [] }
        var names: Set<String> = []
        for entry in entries {
            let fields: [RESPValue] = switch entry {
            case .map(let pairs): pairs.flatMap { [$0.0, $0.1] }
            default: entry.arrayValue ?? []
            }
            var index = 0
            while index + 1 < fields.count {
                if fields[index].stringValue == "name", let name = fields[index + 1].stringValue {
                    names.insert(name.lowercased())
                }

                index += 2
            }
        }

        return names
    }
}

private enum ModuleCache {
    static let redis = RedisTestServer.modules(at: RedisTestServer.LiveServer.redis.endpoint)
    static let valkey = RedisTestServer.modules(at: RedisTestServer.LiveServer.valkey.endpoint)
    static let valkeyCluster = RedisTestServer.modules(at: RedisTestServer.LiveServer.valkeyCluster.endpoint)
}

extension RedisTestServer {
    /// Module names per server, probed once per process.
    static func loadedModules(_ server: LiveServer) -> Set<String>? {
        switch server {
        case .redis: ModuleCache.redis
        case .valkey: ModuleCache.valkey
        case .valkeyCluster: ModuleCache.valkeyCluster
        }
    }

    /// Sends one inline command on a fresh socket and parses the reply, or nil when the server does not answer.
    static func inlineCommand(_ command: String, at endpoint: RedisEndpoint, timeoutMs: Int32) -> RESPValue? {
        guard let fd = connectedSocket(host: endpoint.host, port: endpoint.port, timeoutMs: timeoutMs) else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array("\(command)\r\n".utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { return nil }
        var parser = RESPParser()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var received = 0
        while received < 1 << 20 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            received += count
            parser.feed(Array(buffer[0..<count]))
            do {
                if let value = try parser.next() { return value }
            } catch {
                return nil
            }
        }

        return nil
    }
}
