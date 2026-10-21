import Foundation

public enum ConnectionErrorCode: Int, Codable, Sendable, Hashable {
    case failed = 10900
    case timeout = 10901
    case unauthorized = 10902
    case clusterNodesUnavailable = 10903
    case unavailable = 10904
    case authUnsupported = 10905
    case sentinelMasterRequired = 10906
    case incorrectCertificate = 10907
    case defaultUserDisabled = 10908
    case sshConnection = 11600
    case tunnelLost = 11601
    case tunnelCreate = 11602
    case localServer = 11603
}

/// User-facing connection failure with a title and message.
public struct ConnectionError: Error, LocalizedError, Hashable, Sendable {
    public var code: ConnectionErrorCode
    public var title: String
    public var message: String

    public init(code: ConnectionErrorCode, title: String, message: String) {
        self.code = code
        self.title = title
        self.message = message
    }

    public var errorDescription: String? { message }
    public var failureReason: String? { title }

    public static func failed(_ detail: String) -> ConnectionError {
        ConnectionError(code: .failed, title: "Connection failed",
                        message: "Couldn't connect to the Redis server.\n\(detail)")
    }

    public static let timeout = ConnectionError(
        code: .timeout, title: "Connection timed out",
        message: "The connection timed out. Check the host, port, and network, or raise the timeout.")

    public static let unauthorized = ConnectionError(
        code: .unauthorized, title: "Authentication failed",
        message: "The server rejected the credentials. Check the username and password.")

    public static let sentinelMasterRequired = ConnectionError(
        code: .sentinelMasterRequired, title: "Sentinel master required",
        message: "Enter the name of the Sentinel primary group.")

    public static let authUnsupported = ConnectionError(
        code: .authUnsupported, title: "Authentication not supported",
        message: "This server has no AUTH command, so leave the username and password empty.")

    public static let clusterNodesUnavailable = ConnectionError(
        code: .clusterNodesUnavailable, title: "Cluster nodes unavailable",
        message: "Some cluster nodes couldn't be reached. Every node must be reachable from this Mac; check the network or raise the timeout.")

    public static let defaultUserDisabled = ConnectionError(
        code: .defaultUserDisabled, title: "Default user disabled",
        message: "The server's default user is disabled. Enter a username.")

    public static func unavailable(_ endpoint: RedisEndpoint) -> ConnectionError {
        ConnectionError(code: .unavailable, title: "Connection unavailable",
                        message: "Couldn't reach \(endpoint). Check the host, port, and network.")
    }

    public static func incorrectCertificate(_ endpoint: RedisEndpoint) -> ConnectionError {
        ConnectionError(code: .incorrectCertificate, title: "Certificate error",
                        message: "The TLS handshake with \(endpoint) failed. Check the CA and client certificates.")
    }

    public static func ssh(_ detail: String) -> ConnectionError {
        ConnectionError(code: .sshConnection, title: "SSH connection failed",
                        message: "Couldn't open the SSH tunnel. \(detail)")
    }

    /// Classifies transport and server errors for display.
    public static func classify(_ error: Error, endpoint: RedisEndpoint) -> ConnectionError {
        if let e = error as? ConnectionError { return e }
        if let e = error as? DatabaseFactoryError {
            switch e {
            case .connection(let inner): return inner
            case .sentinelMasterRequired: return .sentinelMasterRequired
            }
        }

        var detail = error.localizedDescription
        if let e = error as? RedisClientError {
            switch e {
            case .timeout: return .timeout
            case .authenticationFailed(let message):
                if message.localizedCaseInsensitiveContains("default user") { return .defaultUserDisabled }
                if message.contains("unknown command 'auth'") || message.contains("unknown command `auth`") {
                    return .authUnsupported
                }

                return .unauthorized
            case .tlsFailure: return .incorrectCertificate(endpoint)
            case .clusterNodeUnavailable: return .clusterNodesUnavailable
            case .ssh(let message): return .ssh(message)
            case .scriptFailed(let kind, let message):
                return ConnectionError(code: .failed, title: "\(kind.title) failed", message: message)
            case .connectionClosed: detail = "Server closed the connection."
            case .server(let reply): detail = reply.message
            case .connectionFailed(let message): detail = message
            default: break
            }
        }

        return classify(message: detail, endpoint: endpoint)
    }

    /// Maps an error message to a user-facing error by matching known server, socket and TLS error markers.
    public static func classify(message: String, endpoint: RedisEndpoint) -> ConnectionError {
        let lower = message.lowercased()
        if message.contains("SENTINEL_PARAMS_REQUIRED") { return .sentinelMasterRequired }
        if message.contains("ETIMEDOUT") || lower.contains("timed out") { return .timeout }
        if message.contains("WRONGPASS") || message.contains("NOAUTH") || message == "ERR invalid password" {
            return .unauthorized
        }

        if message == "ERR unknown command 'auth'" { return .authUnsupported }
        if message.contains("ClusterAllFailedError") { return .clusterNodesUnavailable }
        let unavailableMarkers = ["ECONNREFUSED", "ENOTFOUND", "EAI_AGAIN", "ECONNRESET", "EHOSTUNREACH", "ENETUNREACH"]
        if unavailableMarkers.contains(where: message.contains) || lower.contains("connection refused") {
            return .unavailable(endpoint)
        }

        let certificateMarkers = ["UNCERTAIN_STATE", "DEPTH_ZERO_SELF_SIGNED_CERT", "SELF_SIGNED_CERT_IN_CHAIN",
                                  "ERR_OSSL", "SSL", "errSSL", "ERR unencrypted connection is prohibited"]
        if certificateMarkers.contains(where: message.contains) || lower.contains("certificate") {
            return .incorrectCertificate(endpoint)
        }

        return .failed(message)
    }
}
