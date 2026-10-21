import Foundation
import RESP

public enum RedisClientError: Error, LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case connectionClosed
    case timeout
    /// Redis answered with an error reply.
    case server(RESPError)
    case protocolError(String)
    case authenticationFailed(String)
    case tlsFailure(String)
    case tooManyRedirections
    case clusterNodeUnavailable(RedisEndpoint)
    case sentinelMasterNotFound(String)
    case ssh(String)
    case scriptFailed(ConnectionScriptKind, String)
    case invalidConfiguration(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        case .connectionFailed(let detail): return "Connection failed. \(detail)"
        case .connectionClosed: return "Server closed the connection."
        case .timeout: return "The connection timed out. Check the host, port, and network, or raise the timeout."
        case .server(let e): return e.message
        case .protocolError(let detail): return "Protocol error: \(detail)"
        case .authenticationFailed(let detail): return "The server rejected the credentials. Check the username and password. \(detail)"
        case .tlsFailure(let detail): return "TLS error: \(detail)"
        case .tooManyRedirections: return "Too many cluster redirections."
        case .clusterNodeUnavailable(let e): return "Cluster node \(e) is unavailable."
        case .sentinelMasterNotFound(let name): return "The Sentinel has no primary group named \(name)."
        case .ssh(let detail): return "SSH tunnel error: \(detail)"
        case .scriptFailed(let kind, let detail): return "\(kind.title) failed: \(detail)"
        case .invalidConfiguration(let detail): return "Invalid configuration: \(detail)"
        case .cancelled: return "Cancelled."
        }
    }

    /// The server error reply, if this error wraps one.
    public var serverError: RESPError? {
        if case .server(let e) = self { return e }
        return nil
    }
}
