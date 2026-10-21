import Foundation
@testable import AnalyticsFeature
import RedisCore
import TestSupport
import Testing

struct SlowLogPartialFailureTests {
    private let entry: RESPValue = .array([.array([.integer(1), .integer(5), .integer(9), .bulkArray(["GET", "x"])])])

    @Test func failingNodeKeepsTheOtherNodesEntries() async throws {
        let healthy = MockRedisClient(responses: ["SLOWLOG": entry])
        let down = MockRedisClient()
        await down.setTransportError(.connectionClosed)
        let nodes = [NodeClient(endpoint: RedisEndpoint(host: "10.0.0.1", port: 7000), role: .primary, client: healthy),
                     NodeClient(endpoint: RedisEndpoint(host: "10.0.0.2", port: 7001), role: .primary, client: down)]
        let result = try await SlowLogService.fetchPerNode(nodes: nodes, count: 10, labelNodes: true)
        #expect(result.entries.map(\.args) == ["GET x"])
        #expect(result.failures.map(\.node) == ["10.0.0.2:7001"])
        #expect(result.failureMessage?.contains("10.0.0.2:7001") == true)
    }

    @Test func everyNodeFailingThrows() async throws {
        let down = MockRedisClient()
        await down.setTransportError(.connectionClosed)
        let nodes = [NodeClient(endpoint: RedisEndpoint(host: "10.0.0.1", port: 7000), role: .primary, client: down)]
        await #expect(throws: RedisClientError.self) {
            _ = try await SlowLogService.fetchPerNode(nodes: nodes, count: 10, labelNodes: true)
        }
    }
}
