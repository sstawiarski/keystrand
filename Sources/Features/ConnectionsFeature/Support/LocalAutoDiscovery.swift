import Foundation
import RedisCore

/// Where auto-discovery gets candidate local ports from (injectable so tests never probe real ports).
public protocol LocalPortSource: Sendable {
    func candidatePorts() async -> [Int]
}

/// A fixed list of candidate ports.
public struct FixedPortSource: LocalPortSource {
    public let ports: [Int]

    public init(_ ports: [Int]) {
        self.ports = ports
    }

    public func candidatePorts() async -> [Int] { ports }
}

/// Listening TCP ports reported by `netstat -anvp tcp`.
public struct NetstatPortSource: LocalPortSource {
    public init() {}

    public func candidatePorts() async -> [Int] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            process.arguments = ["-anvp", "tcp"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return []
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return NetstatParser.listeningPorts(String(decoding: data, as: UTF8.self))
        }.value
    }
}

public enum NetstatParser {
    /// Distinct local ports of LISTEN sockets, in first-seen order.
    public static func listeningPorts(_ output: String) -> [Int] {
        var seen = Set<Int>()
        var ports: [Int] = []
        for line in output.split(whereSeparator: \.isNewline) where line.contains("LISTEN") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count > 3 else { continue }
            let local = columns[3]
            guard let separator = local.lastIndex(where: { $0 == "." || $0 == ":" }),
                  let port = Int(local[local.index(after: separator)...]), port > 0, port <= 65_535 else { continue }
            if seen.insert(port).inserted { ports.append(port) }
        }

        return ports
    }
}

/// First-run discovery of local standalone Redis servers (`127.0.0.1:<port>`).
public struct LocalAutoDiscovery: Sendable {
    public var portSource: any LocalPortSource
    public var host: String
    public var probeTimeout: TimeInterval

    public init(portSource: any LocalPortSource = NetstatPortSource(), host: String = "127.0.0.1",
                probeTimeout: TimeInterval = 1) {
        self.portSource = portSource
        self.host = host
        self.probeTimeout = probeTimeout
    }

    /// The app's discovery (netstat ports), or nil when disabled by `KEYSTRAND_DISABLE_AUTODISCOVERY` or under a
    /// test runner.
    public static var appDefault: LocalAutoDiscovery? {
        let environment = ProcessInfo.processInfo.environment
        let process = ProcessInfo.processInfo.processName.lowercased()
        let underTests = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || process.contains("xctest") || process.contains("swiftpm-testing-helper")
        guard environment["KEYSTRAND_DISABLE_AUTODISCOVERY"] == nil, !underTests else { return nil }
        return LocalAutoDiscovery()
    }

    /// Standalone servers that answer PING, excluding endpoints already saved.
    public func discover(excluding existing: Set<RedisEndpoint> = []) async -> [DatabaseConfig] {
        let ports = await portSource.candidatePorts().filter { !existing.contains(RedisEndpoint(host: host, port: $0)) }
        let host = self.host
        let timeout = probeTimeout
        let found = await withTaskGroup(of: (Int, DatabaseConfig?).self) { group in
            for port in ports {
                group.addTask { (port, await Self.probe(host: host, port: port, timeout: timeout)) }
            }

            var results: [(Int, DatabaseConfig?)] = []
            for await result in group { results.append(result) }
            return results
        }
        return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
    }

    static func probe(host: String, port: Int, timeout: TimeInterval) async -> DatabaseConfig? {
        let config = RedisConnectionConfig(host: host, port: port, connectTimeout: timeout, commandTimeout: timeout,
                                           clientName: "keystrand-auto-discovery", readyCheck: false, retry: .none)
        guard let connection = try? await RedisConnection.connect(config: config) else { return nil }
        defer { Task { await connection.close() } }
        guard let pong = try? await connection.execute(["PING"], timeout: timeout),
              pong.stringValue?.uppercased() == "PONG" else { return nil }
        guard let info = try? await DatabaseInfoService(client: connection).info(section: "server"),
              info.redisMode == "standalone" else { return nil }
        return DatabaseConfig(name: "\(host):\(port)", host: host, port: port, connectionType: .standalone,
                              provider: info.serverFlavor == .valkey ? .valkey : .localhost,
                              version: info.serverVersion)
    }
}
