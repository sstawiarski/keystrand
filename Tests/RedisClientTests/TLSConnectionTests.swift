import Foundation
import Network
import RedisClient
import RESP
import Security
import Synchronization
import Testing

/// Minimal in-process TLS server that answers every RESP command with `+PONG` (PING) or `+OK`.
// @unchecked: `connections` is only touched on `queue`.
private final class FakeTLSRedis: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "rgtest.fake-tls")
    private var connections: [NWConnection] = []
    private let peerFlag = LockedFlag()
    var sawClientCertificate: Bool { peerFlag.value }

    init(identity: SecIdentity, requireClientCertificate: Bool) throws {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, sec_identity_create(identity)!)
        if requireClientCertificate {
            sec_protocol_options_set_peer_authentication_required(sec, true)
            let flag = peerFlag
            sec_protocol_options_set_verify_block(sec, { metadata, _, complete in
                var count = 0
                sec_protocol_metadata_access_peer_certificate_chain(metadata) { _ in count += 1 }
                flag.value = count > 0
                complete(count > 0)
            }, queue)
        }

        listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func start() async throws -> Int {
        try await startListener(listener, on: queue)
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        PingResponder(connection: connection).receive()
    }
}

/// Plain TCP server that never answers, so a TLS client stays in its handshake.
// @unchecked: `connections` is only touched on `queue`.
private final class SilentServer: @unchecked Sendable {
    let listener: NWListener
    let accepted = LockedFlag()
    let peerClosed = LockedFlag()
    private let queue = DispatchQueue(label: "rgtest.silent")
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func start() async throws -> Int {
        try await startListener(listener, on: queue)
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        accepted.value = true
        discardUntilClosed(connection)
    }

    private func discardUntilClosed(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.peerClosed.value = true
            } else {
                self?.discardUntilClosed(connection)
            }
        }
    }
}

private func startListener(_ listener: NWListener, on queue: DispatchQueue) async throws -> Int {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
        let resumed = LockedFlag()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                if resumed.claim() { cont.resume(returning: Int(listener.port?.rawValue ?? 0)) }
            case .failed(let error):
                if resumed.claim() { cont.resume(throwing: error) }
            default: break
            }
        }
        listener.start(queue: queue)
    }
}

private func eventually(within timeout: Duration, _ condition: @Sendable () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(20))
    }

    return true
}

/// Answers every RESP command on one connection with `+PONG` (PING) or `+OK`.
private final class PingResponder: Sendable {
    private let connection: NWConnection
    private let parser = Mutex(RESPParser(allowInline: true))

    init(connection: NWConnection) {
        self.connection = connection
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data {
                let out = parser.withLock { parser in
                    parser.feed(data)
                    var out = Data()
                    while let value = try? parser.next() {
                        let name = value.arrayValue?.first?.stringValue?.uppercased()
                        out.append(Data((name == "PING" ? "+PONG\r\n" : "+OK\r\n").utf8))
                    }

                    return out
                }
                if !out.isEmpty { connection.send(content: out, completion: .idempotent) }
            }

            if error == nil && !isComplete { receive() }
        }
    }
}

private final class LockedFlag: Sendable {
    private let state = Mutex(false)

    var value: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// Sets the flag and returns true only for the first caller.
    func claim() -> Bool {
        state.withLock { flag in
            guard !flag else { return false }
            flag = true
            return true
        }
    }
}

/// Self-signed certificate; `names` become the subject alternative names (`IP:` or `DNS:` entries).
private func makeCertificate(cn: String, names: [String] = [],
                             newKey: [String] = ["-newkey", "rsa:2048"]) throws -> (cert: String, key: String)? {
    let openssl = "/usr/bin/openssl"
    guard FileManager.default.isExecutableFile(atPath: openssl) else { return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rgtest-tls-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let keyPath = dir.appendingPathComponent("key.pem").path
    let certPath = dir.appendingPathComponent("cert.pem").path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: openssl)
    var arguments = ["req", "-x509"] + newKey + ["-nodes", "-keyout", keyPath, "-out", certPath,
                                                 "-days", "2", "-subj", "/CN=\(cn)", "-addext", "extendedKeyUsage=serverAuth"]
    if !names.isEmpty { arguments += ["-addext", "subjectAltName=" + names.joined(separator: ",")] }
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return (try String(contentsOfFile: certPath, encoding: .utf8), try String(contentsOfFile: keyPath, encoding: .utf8))
}

@Suite(.serialized)
struct TLSConnectionTests {
    @Test func tlsWithoutVerification() async throws {
        guard let server = try makeCertificate(cn: "rg-server") else { return }
        let fake = try FakeTLSRedis(identity: try PEMSecurity.identity(certificatePEM: server.cert, privateKeyPEM: server.key),
                                    requireClientCertificate: false)
        let port = try await fake.start()
        defer { fake.stop() }
        let config = RedisConnectionConfig(host: "127.0.0.1", port: port, tls: TLSConfig(verifyServerCertificate: false),
                                           connectTimeout: 5, readyCheck: false, retry: .none)
        let connection = try await RedisConnection.connect(config: config)
        #expect(try await connection.ping())
        await connection.close()
    }

    @Test func tlsVerificationWithCustomCA() async throws {
        guard let server = try makeCertificate(cn: "rg-server", names: ["IP:127.0.0.1"]),
              let other = try makeCertificate(cn: "rg-other", names: ["IP:127.0.0.1"]) else { return }
        let fake = try FakeTLSRedis(identity: try PEMSecurity.identity(certificatePEM: server.cert, privateKeyPEM: server.key),
                                    requireClientCertificate: false)
        let port = try await fake.start()
        defer { fake.stop() }

        var config = RedisConnectionConfig(host: "127.0.0.1", port: port, connectTimeout: 5, readyCheck: false, retry: .none)
        config.tls = TLSConfig(caCertificatePEM: server.cert, verifyServerCertificate: true)
        let trusted = try await RedisConnection.connect(config: config)
        #expect(try await trusted.ping())
        await trusted.close()

        config.tls = TLSConfig(caCertificatePEM: other.cert, verifyServerCertificate: true)
        do {
            _ = try await RedisConnection.connect(config: config)
            Issue.record("expected certificate failure")
        } catch let error as RedisClientError {
            switch error {
            case .tlsFailure, .connectionFailed, .connectionClosed: break
            default: Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func verificationChecksTheHostName() async throws {
        guard let server = try makeCertificate(cn: "rg-server", names: ["DNS:redis.internal"]) else { return }
        let fake = try FakeTLSRedis(identity: try PEMSecurity.identity(certificatePEM: server.cert, privateKeyPEM: server.key),
                                    requireClientCertificate: false)
        let port = try await fake.start()
        defer { fake.stop() }

        var config = RedisConnectionConfig(host: "127.0.0.1", port: port, connectTimeout: 5, readyCheck: false, retry: .none)
        config.tls = TLSConfig(caCertificatePEM: server.cert, verifyServerCertificate: true)
        await #expect(throws: RedisClientError.self, "the certificate does not name 127.0.0.1") {
            _ = try await RedisConnection.connect(config: config)
        }

        config.tls = TLSConfig(caCertificatePEM: server.cert, verifyServerCertificate: true, serverName: "redis.internal")
        let named = try await RedisConnection.connect(config: config)
        #expect(try await named.ping())
        await named.close()

        config.tls = TLSConfig(caCertificatePEM: server.cert, verifyServerCertificate: false)
        let unverified = try await RedisConnection.connect(config: config)
        #expect(try await unverified.ping())
        await unverified.close()
    }

    @Test(arguments: [["-newkey", "rsa:2048"], ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-pkeyopt", "ec_param_enc:named_curve"]])
    func mutualTLS(clientKey: [String]) async throws {
        guard let server = try makeCertificate(cn: "rg-server"),
              let client = try makeCertificate(cn: "rg-client", newKey: clientKey) else { return }
        let fake = try FakeTLSRedis(identity: try PEMSecurity.identity(certificatePEM: server.cert, privateKeyPEM: server.key),
                                    requireClientCertificate: true)
        let port = try await fake.start()
        defer { fake.stop() }
        let config = RedisConnectionConfig(
            host: "127.0.0.1", port: port,
            tls: TLSConfig(clientCertificatePEM: client.cert, clientKeyPEM: client.key, verifyServerCertificate: false,
                           serverName: "redis.internal"),
            connectTimeout: 5, readyCheck: false, retry: .none)
        let connection = try await RedisConnection.connect(config: config)
        #expect(try await connection.ping())
        #expect(fake.sawClientCertificate)
        await connection.close()
    }

    @Test func closeDuringHandshakeCancelsTheSocket() async throws {
        let server = try SilentServer()
        let port = try await server.start()
        defer { server.stop() }
        let config = RedisConnectionConfig(host: "127.0.0.1", port: port, tls: TLSConfig(), connectTimeout: 20,
                                           readyCheck: false, retry: .none)
        let connection = RedisConnection(config: config)
        let connecting = Task { try await connection.connect() }
        try #require(try await eventually(within: .seconds(5)) { server.accepted.value })

        let closedAt = ContinuousClock.now
        await connection.close()
        do {
            try await connecting.value
            Issue.record("expected close() to stop the connect")
        } catch RedisClientError.cancelled {
        } catch {
            Issue.record("unexpected \(error)")
        }

        #expect(ContinuousClock.now - closedAt < .seconds(5))
        #expect(try await eventually(within: .seconds(5)) { server.peerClosed.value })
        #expect(await !connection.isConnected)
    }
}
