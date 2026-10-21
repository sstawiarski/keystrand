import Foundation
import Network
import Security

enum TransportEvent: Sendable {
    case data(Data)
    case closed(RedisClientError?)
}

/// Thin async wrapper over `NWConnection`. Network.framework requires a dispatch queue for callbacks;
/// everything else is surfaced as an ordered `AsyncStream` of events.
// @unchecked: the mutable state is guarded by `lock`; everything else is immutable or thread-safe.
final class NWTransport: @unchecked Sendable {
    let connection: NWConnection
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var isClosed = false
    private var isCancelled = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private let endpointDescription: String

    init(config: RedisConnectionConfig) throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.port)), config.port > 0, config.port <= 65_535 else {
            throw RedisClientError.invalidConfiguration("Invalid port \(config.port)")
        }
        let host = config.host.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !host.isEmpty else { throw RedisClientError.invalidConfiguration("Host is empty") }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = max(1, Int(config.connectTimeout.rounded(.up)))

        let parameters: NWParameters
        if let tls = config.tls {
            parameters = NWParameters(tls: try TLSOptionsBuilder.make(tls, host: host), tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }

        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            switch config.family {
            case .ipv4: ip.version = .v4
            case .ipv6: ip.version = .v6
            case .auto: break
            }
        }

        endpointDescription = RedisEndpoint(host: host, port: config.port).description
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        queue = DispatchQueue(label: "keystrand.transport.\(endpointDescription)")
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    /// Cancels the socket if its owner releases the transport without closing it.
    deinit {
        continuation.finish()
        connection.cancel()
    }

    /// Opens the connection and waits until it is ready, fails, or the timeout elapses.
    /// Cancelling the task or calling `close` while waiting cancels the socket and throws `cancelled`.
    func start(timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !isClosed else {
                    lock.unlock()
                    cont.resume(throwing: RedisClientError.cancelled)
                    return
                }
                startContinuation = cont
                connection.stateUpdateHandler = { [weak self] state in self?.handle(state: state) }
                connection.start(queue: queue)
                lock.unlock()
                queue.asyncAfter(deadline: .now() + max(0.05, timeout)) { [weak self] in
                    self?.finishStart(.failure(RedisClientError.timeout))
                }
            }
        } onCancel: {
            close(nil)
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        lock.lock()
        let cont = startContinuation
        startContinuation = nil
        if case .success = result { isReady = true }
        lock.unlock()
        guard let cont else { return }
        switch result {
        case .success:
            cont.resume()
            receiveNext()
        case .failure(let error):
            close(nil)
            cont.resume(throwing: error)
        }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            finishStart(.success(()))
        case .waiting(let error), .failed(let error):
            let mapped = Self.map(error, endpoint: endpointDescription)
            lock.lock()
            let ready = isReady
            lock.unlock()
            if ready { close(mapped) } else { finishStart(.failure(mapped)) }
        case .cancelled:
            close(nil)
            finishCancel()
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.continuation.yield(.data(data)) }
            if let error {
                self.close(Self.map(error, endpoint: self.endpointDescription))
            } else if isComplete {
                self.close(.connectionClosed)
            } else {
                self.receiveNext()
            }
        }
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.close(Self.map(error, endpoint: self.endpointDescription))
        })
    }

    /// Idempotent. Emits `.closed(error)` once, cancels the socket, and fails a pending `start`.
    func close(_ error: RedisClientError?) {
        lock.lock()
        let already = isClosed
        isClosed = true
        let pendingStart = startContinuation
        startContinuation = nil
        lock.unlock()
        guard !already else { return }
        continuation.yield(.closed(error))
        continuation.finish()
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.finishCancel() }
        }
        connection.cancel()
        pendingStart?.resume(throwing: error ?? RedisClientError.cancelled)
    }

    /// Waits until Network.framework reports the socket cancelled after `close`, or `timeout` passes.
    func waitUntilCancelled(timeout: TimeInterval = 2) async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                waiter.resume()
                return
            }
            cancelWaiters.append(waiter)
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finishCancel() }
        }
    }

    private func finishCancel() {
        lock.lock()
        isCancelled = true
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    static func map(_ error: NWError, endpoint: String) -> RedisClientError {
        switch error {
        case .posix(let code):
            switch code {
            case .ETIMEDOUT: return .timeout
            case .ECONNREFUSED: return .connectionFailed("connect ECONNREFUSED \(endpoint)")
            case .ECONNRESET: return .connectionFailed("read ECONNRESET")
            case .EHOSTUNREACH: return .connectionFailed("connect EHOSTUNREACH \(endpoint)")
            case .ENETUNREACH: return .connectionFailed("connect ENETUNREACH \(endpoint)")
            case .EPIPE: return .connectionClosed
            case .ECANCELED: return .cancelled
            default: return .connectionFailed("\(code) \(error.localizedDescription)")
            }
        case .dns(let code):
            return .connectionFailed("getaddrinfo ENOTFOUND \(endpoint) (\(code))")
        case .tls(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return .tlsFailure("\(message) (\(status))")
        default:
            return .connectionFailed(error.localizedDescription)
        }
    }
}

enum TLSOptionsBuilder {
    static func make(_ tls: TLSConfig, host: String) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions

        if let name = tls.serverName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            sec_protocol_options_set_tls_server_name(sec, name)
        } else if isDNSName(host) {
            sec_protocol_options_set_tls_server_name(sec, host)
        }

        if let certPEM = tls.clientCertificatePEM, !certPEM.isEmpty, let keyPEM = tls.clientKeyPEM, !keyPEM.isEmpty {
            let identity: SecIdentity
            do {
                identity = try PEMSecurity.identity(certificatePEM: certPEM, privateKeyPEM: keyPEM)
            } catch {
                throw RedisClientError.tlsFailure(error.localizedDescription)
            }

            guard let secIdentity = sec_identity_create(identity) else {
                throw RedisClientError.tlsFailure("Could not use the client certificate.")
            }
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }

        var anchors: [SecCertificate] = []
        if let ca = tls.caCertificatePEM, !ca.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                anchors = try PEMSecurity.certificates(fromPEM: ca)
            } catch {
                throw RedisClientError.tlsFailure(error.localizedDescription)
            }
        }

        let verify = tls.verifyServerCertificate
        let expectedHost = verificationHost(tls, host: host)
        let verifyQueue = DispatchQueue(label: "keystrand.tls.verify")
        sec_protocol_options_set_verify_block(sec, { _, trustRef, complete in
            guard verify else { complete(true); return }
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, expectedHost as CFString))
            // Without a custom CA the system roots apply.
            if !anchors.isEmpty {
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
            }

            var error: CFError?
            complete(SecTrustEvaluateWithError(trust, &error))
        }, verifyQueue)
        return options
    }

    /// Certificate host matching prefers the explicit verification host, then the SNI name, then the connected host.
    static func verificationHost(_ tls: TLSConfig, host: String) -> String {
        for candidate in [tls.verificationHost, tls.serverName] {
            if let name = candidate?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        }

        return host
    }

    static func isDNSName(_ host: String) -> Bool {
        if host.contains(":") { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return false }
        return host.rangeOfCharacter(from: .letters) != nil
    }
}
