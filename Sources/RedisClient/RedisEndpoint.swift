import Foundation

public struct RedisEndpoint: Hashable, Codable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// `host:port`, with IPv6 literals bracketed.
    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public enum NodeRole: String, Codable, Sendable, Hashable {
    case primary
    case replica
}

public struct ClusterNode: Hashable, Sendable, Identifiable {
    public var id: String
    /// Address as announced by the cluster (before any NAT mapping).
    public var endpoint: RedisEndpoint
    public var role: NodeRole
    public var primaryID: String?
    public var slots: [ClosedRange<Int>]
    public var flags: [String]

    public init(id: String, endpoint: RedisEndpoint, role: NodeRole, primaryID: String? = nil,
                slots: [ClosedRange<Int>] = [], flags: [String] = []) {
        self.id = id
        self.endpoint = endpoint
        self.role = role
        self.primaryID = primaryID
        self.slots = slots
        self.flags = flags
    }
}
