import Foundation

public enum IPFamily: String, Codable, Sendable, Hashable {
    case auto
    case ipv4
    case ipv6
}

public enum RESPProtocolVersion: Int, Codable, Sendable, Hashable {
    case resp2 = 2
    case resp3 = 3
}

public struct TLSConfig: Hashable, Codable, Sendable {
    public var caCertificatePEM: String?
    public var clientCertificatePEM: String?
    public var clientKeyPEM: String?
    public var verifyServerCertificate: Bool
    /// SNI server name; `nil` = use host.
    public var serverName: String?
    /// Certificate host name or IP if it cannot be sent as SNI, such as an IP reached through a tunnel.
    /// If nil, uses `serverName`, then the connected host.
    public var verificationHost: String?

    public init(caCertificatePEM: String? = nil, clientCertificatePEM: String? = nil, clientKeyPEM: String? = nil,
                verifyServerCertificate: Bool = false, serverName: String? = nil, verificationHost: String? = nil) {
        self.caCertificatePEM = caCertificatePEM
        self.clientCertificatePEM = clientCertificatePEM
        self.clientKeyPEM = clientKeyPEM
        self.verifyServerCertificate = verifyServerCertificate
        self.serverName = serverName
        self.verificationHost = verificationHost
    }
}

/// Reconnects after `min(attempt * stepMs, capMs)` milliseconds.
public struct RetryPolicy: Hashable, Codable, Sendable {
    public var maxAttempts: Int
    public var stepMs: Int
    public var capMs: Int

    public init(maxAttempts: Int = 3, stepMs: Int = 500, capMs: Int = 2000) {
        self.maxAttempts = maxAttempts
        self.stepMs = stepMs
        self.capMs = capMs
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 0)

    public func delayMs(forAttempt attempt: Int) -> Int { min(attempt * stepMs, capMs) }
}

/// Everything needed to open one TCP(+TLS) connection to one Redis node.
public struct RedisConnectionConfig: Hashable, Codable, Sendable {
    /// Per-command timeout in seconds for pooled connections without blocking commands.
    /// An unanswered request drops the socket so the next command reconnects.
    public static let defaultCommandTimeout: TimeInterval = 30

    public var host: String
    public var port: Int
    public var family: IPFamily
    public var username: String?
    public var password: String?
    /// Logical database selected during the connection handshake.
    public var dbIndex: Int
    public var tls: TLSConfig?
    /// Seconds.
    public var connectTimeout: TimeInterval
    /// Seconds; `nil` = no per-command timeout. An expired request fails with `timeout` and drops the socket.
    public var commandTimeout: TimeInterval?
    /// Sent with `CLIENT SETNAME` after connect (errors ignored).
    public var clientName: String?
    /// Run `INFO` after connect and wait until `loading:0`.
    public var readyCheck: Bool
    public var retry: RetryPolicy
    public var protocolVersion: RESPProtocolVersion

    public init(host: String = "127.0.0.1", port: Int = 6379, family: IPFamily = .auto,
                username: String? = nil, password: String? = nil, dbIndex: Int = 0, tls: TLSConfig? = nil,
                connectTimeout: TimeInterval = 30, commandTimeout: TimeInterval? = nil,
                clientName: String? = nil, readyCheck: Bool = true, retry: RetryPolicy = .default,
                protocolVersion: RESPProtocolVersion = .resp2) {
        self.host = host
        self.port = port
        self.family = family
        self.username = username
        self.password = password
        self.dbIndex = dbIndex
        self.tls = tls
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
        self.clientName = clientName
        self.readyCheck = readyCheck
        self.retry = retry
        self.protocolVersion = protocolVersion
    }

    public var endpoint: RedisEndpoint {
        get { RedisEndpoint(host: host, port: port) }
        set { host = newValue.host; port = newValue.port }
    }

    /// Copy of this config pointed at another node (cluster / sentinel / SSH local port).
    public func with(endpoint: RedisEndpoint) -> RedisConnectionConfig {
        var copy = self
        copy.endpoint = endpoint
        return copy
    }
}
