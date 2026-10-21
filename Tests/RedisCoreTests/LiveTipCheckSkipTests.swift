import Foundation
@testable import RedisCore
import Synchronization
import Testing

@MainActor
struct LiveTipCheckSkipTests {
    @Test func stringCheckSkippedOnceReported() async {
        let signals = LiveTipSignals()
        let calls = Mutex(0)
        let check: @Sendable (Data) -> Bool = { value in
            calls.withLock { $0 += 1 }
            return LiveTipRules.isJSONContainer(value)
        }
        await signals.reportStringLoaded(key: Data("a".utf8), value: Data("[1]".utf8), isJSON: check)
        await signals.reportStringLoaded(key: Data("b".utf8), value: Data("[2]".utf8), isJSON: check)
        #expect(calls.withLock { $0 } == 1)
        #expect(signals.reportedNames.contains(.stringToJson))
    }

    @Test func zsetCheckSamplesFirstMembersAndSkipsOnceReported() async {
        let signals = LiveTipSignals()
        let sampled = Mutex<[Int]>([])
        let check: @Sendable ([(member: Data, score: String)]) -> Bool = { members in
            sampled.withLock { $0.append(members.count) }
            return LiveTipRules.looksLikeTimeSeries(members)
        }
        let plain = (0..<500).map { (member: Data("m\($0)".utf8), score: "\($0)") }
        await signals.reportZSetLoaded(key: Data("z".utf8), members: plain, looksLikeTimeSeries: check)
        #expect(!signals.reportedNames.contains(.rts))
        let stamped = [(member: Data("2024-08-02T00:00:00.000Z".utf8), score: "1")]
        await signals.reportZSetLoaded(key: Data("z".utf8), members: stamped, looksLikeTimeSeries: check)
        await signals.reportZSetLoaded(key: Data("z".utf8), members: stamped, looksLikeTimeSeries: check)
        #expect(sampled.withLock { $0 } == [LiveTipRules.timeSeriesSampleSize, 1])
        #expect(signals.reportedNames.contains(.rts))
    }

    @Test func jsonContainerNeedsMatchingClosingBracket() {
        #expect(!LiveTipRules.isJSONContainer(Data("{\"a\": 1} trailing".utf8)))
        #expect(LiveTipRules.isJSONContainer(Data("\n[1, 2]\n".utf8)))
    }

    @Test func datePrefilterRejectsLongAndDigitlessText() {
        #expect(!TimestampDetector.isTimestamp(String(repeating: "x", count: 10_000)))
        #expect(!TimestampDetector.isTimestamp("Jan 1, 12"))
        #expect(TimestampDetector.isTimestamp("Jan 1, 2024"))
    }
}
