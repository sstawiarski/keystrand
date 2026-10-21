import Foundation
import RedisClient
import Testing

struct RedisClientSmokeTests {
    @Test func clusterSlotsMatchRedis() {
        #expect(ClusterSlot.slot(for: "foo") == 12182)
        #expect(ClusterSlot.slot(for: "{user1000}.following") == ClusterSlot.slot(for: "{user1000}.followers"))
    }

    @Test func mockClientReturnsScriptedReplies() async throws {
        let client = MockRedisClient(responses: ["PING": .simpleString("PONG")])
        #expect(try await client.execute("PING") == .simpleString("PONG"))
        #expect(await client.executedCommands.count == 1)
    }
}
