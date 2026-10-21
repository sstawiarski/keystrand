import Darwin
import Foundation
import RESP
import Synchronization

public enum SSHTunnelAuth: Hashable, Sendable {
    case password(String)
    case privateKey(pem: String, passphrase: String?)
}

public struct SSHTunnelOptions: Hashable, Sendable {
    public var sshHost: String
    public var sshPort: Int
    public var username: String
    public var auth: SSHTunnelAuth
    /// Redis host/port as seen from the SSH server.
    public var remoteHost: String
    public var remotePort: Int
    /// Seconds.
    public var connectTimeout: TimeInterval

    public init(sshHost: String, sshPort: Int = 22, username: String, auth: SSHTunnelAuth,
                remoteHost: String, remotePort: Int, connectTimeout: TimeInterval = 30) {
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.username = username
        self.auth = auth
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.connectTimeout = connectTimeout
    }

    public func with(remote: RedisEndpoint) -> SSHTunnelOptions {
        var copy = self
        copy.remoteHost = remote.host
        copy.remotePort = remote.port
        return copy
    }
}

/// Local port forward via `/usr/bin/ssh -N -L 127.0.0.1:<free port>:remoteHost:remotePort`.
/// Passwords/passphrases are supplied with `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force`;
/// private keys are written to a 0600 temp file removed on `stop()`.
public actor SSHTunnel {
    public static let executablePath = "/usr/bin/ssh"
    static let secretEnvironmentKey = "KEYSTRAND_SSH_SECRET"

    public let options: SSHTunnelOptions
    public private(set) var localPort: Int?

    private var process: Process?
    private var workDirectory: URL?
    private let stderrBuffer = OutputBuffer()

    public init(options: SSHTunnelOptions) {
        self.options = options
    }

    /// True while the ssh process is alive.
    public var isRunning: Bool { process?.isRunning ?? false }

    /// Starts ssh, waits until the local port accepts connections, and returns it.
    @discardableResult
    public func start() async throws -> Int {
        if let localPort, isRunning { return localPort }
        var lastError: Error = RedisClientError.ssh("The SSH tunnel did not start.")
        for _ in 0..<3 {
            do {
                return try await launchOnce()
            } catch let error as RedisClientError {
                lastError = error
                await stop()
                // Retry only when the chosen local port was taken in the meantime.
                guard case .ssh(let message) = error, message.contains("Address already in use") || message.contains("forwarding") else {
                    throw error
                }
            }
        }

        throw lastError
    }

    public func stop() async {
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        process = nil
        localPort = nil
        if let workDirectory {
            // Deletes the private key and askpass helper directly so secrets cannot linger in the Trash.
            try? FileManager.default.removeItem(at: workDirectory)
        }

        workDirectory = nil
    }

    public var localEndpoint: RedisEndpoint? {
        localPort.map { RedisEndpoint(host: "127.0.0.1", port: $0) }
    }

    // MARK: - Launch

    private func launchOnce() async throws -> Int {
        let port = try Self.pickFreePort()
        let directory = try Self.makePrivateDirectory()
        workDirectory = directory

        var keyPath: String?
        var secret: String?
        switch options.auth {
        case .password(let password):
            secret = password
        case .privateKey(let pem, let passphrase):
            let url = directory.appendingPathComponent("id_key")
            var text = pem.replacingOccurrences(of: "\r\n", with: "\n")
            if !text.hasSuffix("\n") { text += "\n" }
            guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw RedisClientError.ssh("Couldn't write the private key to a temporary file.")
            }
            keyPath = url.path
            if let passphrase, !passphrase.isEmpty { secret = passphrase }
        }

        var environment = ProcessInfo.processInfo.environment
        var askpassPath: String?
        if let secret {
            let url = directory.appendingPathComponent("askpass.sh")
            let script = "#!/bin/sh\nprintf '%s\\n' \"$\(Self.secretEnvironmentKey)\"\n"
            guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8),
                                                 attributes: [.posixPermissions: 0o700]) else {
                throw RedisClientError.ssh("Couldn't write the askpass helper.")
            }
            askpassPath = url.path
            environment[Self.secretEnvironmentKey] = secret
        }

        environment.merge(Self.environment(askpassPath: askpassPath)) { _, new in new }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = Self.arguments(options: options, localPort: port, keyPath: keyPath,
                                           usesAskpass: askpassPath != nil)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let buffer = stderrBuffer
        buffer.reset()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }
        do {
            try process.run()
        } catch {
            throw RedisClientError.ssh("Couldn't launch ssh: \(error.localizedDescription)")
        }

        self.process = process

        let deadline = Date().addingTimeInterval(max(options.connectTimeout, 1) + 2)
        while true {
            if !process.isRunning {
                let message = Self.sanitize(buffer.text)
                throw RedisClientError.ssh("The SSH tunnel did not start. \(message.isEmpty ? "ssh exited with status \(process.terminationStatus)" : message)")
            }

            if Self.canConnect(port: port) {
                localPort = port
                return port
            }

            if Date() > deadline {
                throw RedisClientError.ssh("Timed out waiting for the SSH tunnel.")
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Pure helpers (unit tested)

    /// Arguments for `/usr/bin/ssh`. Secrets never appear here.
    public static func arguments(options: SSHTunnelOptions, localPort: Int, keyPath: String?, usesAskpass: Bool) -> [String] {
        let remoteHost = options.remoteHost.contains(":") ? "[\(options.remoteHost)]" : options.remoteHost
        var args = [
            "-N", "-T",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(options.remotePort)",
            "-p", String(options.sshPort),
            "-l", options.username,
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=\(max(1, Int(options.connectTimeout.rounded(.up))))",
            "-o", "BatchMode=\(usesAskpass ? "no" : "yes")",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        switch options.auth {
        case .password:
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        case .privateKey:
            if let keyPath {
                args += ["-i", keyPath, "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey"]
            }
        }

        args += ["--", options.sshHost]
        return args
    }

    static func environment(askpassPath: String?) -> [String: String] {
        guard let askpassPath else { return [:] }
        return ["SSH_ASKPASS": askpassPath, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]
    }

    /// Binds `127.0.0.1:0`, reads the kernel-assigned port, and releases it.
    public static func pickFreePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RedisClientError.ssh("No local port could be opened for the tunnel: socket() failed") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw RedisClientError.ssh("No local port could be opened for the tunnel: bind() failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw RedisClientError.ssh("No local port could be opened for the tunnel: getsockname() failed") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Non-blocking TCP probe of `127.0.0.1:port`, with a default timeout of 200 ms.
    public static func canConnect(port: Int, timeoutMs: Int32 = 200) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    static func makePrivateDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keystrand-ssh-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw RedisClientError.ssh("No local port could be opened for the tunnel: \(error.localizedDescription)")
        }

        return url
    }

    /// Last meaningful stderr line(s), with addresses stripped.
    static func sanitize(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        guard var message = lines.suffix(2).joined(separator: " ").nilIfEmpty else { return "" }
        if message.count > 500 { message = String(message.suffix(500)) }
        return message
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

final class OutputBuffer: Sendable {
    private let data = Mutex(Data())
    private let limit: Int

    init(limit: Int = 64 * 1024) { self.limit = limit }

    func append(_ chunk: Data) {
        data.withLock { data in
            data.append(chunk)
            if data.count > limit { data = Data(data.suffix(limit)) }
        }
    }

    func reset() {
        data.withLock { $0.removeAll() }
    }

    var text: String {
        data.withLock { String(decoding: $0, as: UTF8.self) }
    }
}
