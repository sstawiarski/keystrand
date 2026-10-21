import Foundation
@testable import AnalyticsFeature
import RedisCore
import Testing

struct AnalysisAggregatorTests {
    func key(_ name: String, _ type: String, memory: Int? = 100, length: Int? = nil, ttl: Int = -1) -> AnalyzedKey {
        AnalyzedKey(name: Data(name.utf8), type: type, memory: memory, length: length, ttl: ttl)
    }

    @Test func namespaceUsesFirstDelimiterOccurrence() {
        let delimiter = Data(":".utf8)
        #expect(AnalysisAggregator.namespace(of: Data("a:b:c".utf8), delimiter: delimiter) == Data("a".utf8))
        #expect(AnalysisAggregator.namespace(of: Data("plain".utf8), delimiter: delimiter) == nil)
        #expect(AnalysisAggregator.namespace(of: Data(":leading".utf8), delimiter: delimiter) == nil)
        #expect(AnalysisAggregator.namespace(of: Data("a::b".utf8), delimiter: Data("::".utf8)) == Data("a".utf8))
        #expect(AnalysisAggregator.namespace(of: Data("a:b".utf8), delimiter: Data()) == nil)
    }

    @Test func namespaceIsBinarySafe() {
        let raw = Data([0xFF, 0x00, 0x3A, 0x41])
        #expect(AnalysisAggregator.namespace(of: raw, delimiter: Data(":".utf8)) == Data([0xFF, 0x00]))
    }

    @Test func summariesAndNamespaces() {
        let keys = [
            key("user:1", "hash", memory: 500, length: 3),
            key("user:2", "hash", memory: 300, length: 4),
            key("user:3", "string", memory: 50, length: 2),
            key("order:1", "list", memory: 2_000, length: 10),
            key("lonely", "set", memory: nil, length: 1),
        ]
        let result = AnalysisAggregator.aggregate(keys, delimiter: Data(":".utf8))
        #expect(result.totalKeys.total == 5)
        #expect(result.totalKeys.types.first?.type == "hash")
        #expect(result.totalKeys.types.first?.total == 2)
        #expect(result.totalMemory.total == 2_850)
        #expect(result.totalMemory.types.first?.type == "list")

        #expect(result.topKeysNsp.map(\.nsp) == [Data("user".utf8), Data("order".utf8)])
        #expect(result.topKeysNsp.first?.keys == 3)
        #expect(result.topKeysNsp.first?.types.map(\.type) == ["hash", "string"])
        #expect(result.topMemoryNsp.map(\.nsp) == [Data("order".utf8), Data("user".utf8)])
        #expect(result.topMemoryNsp.last?.memory == 850)

        #expect(result.topKeysMemory.first?.name == Data("order:1".utf8))
        #expect(result.topKeysMemory.last?.name == Data("lonely".utf8))
        #expect(result.topKeysLength.first?.length == 10)
    }

    @Test func topListsAreCappedAtFifteen() {
        let keys = (0..<40).map { (i: Int) in key("ns\(i):k", "string", memory: i, length: i) }
        let result = AnalysisAggregator.aggregate(keys, delimiter: Data(":".utf8))
        #expect(result.topKeysMemory.count == 15)
        #expect(result.topKeysMemory.first?.memory == 39)
        #expect(result.topKeysLength.count == 15)
        #expect(result.topMemoryNsp.count == 15)
        #expect(result.topKeysNsp.count == 15)
    }

    @Test func expirationBuckets() {
        let keys = [
            key("a", "string", memory: 1, ttl: -1),
            key("b", "string", memory: 2, ttl: -2),
            key("c", "string", memory: 4, ttl: 10),
            key("d", "string", memory: 8, ttl: 3_600),
            key("e", "string", memory: 16, ttl: 50_000),
            key("f", "string", memory: 32, ttl: 700_000),
            key("g", "string", memory: 64, ttl: 3_000_000),
        ]
        let groups = AnalysisAggregator.expirationGroups(keys)
        #expect(groups.map(\.label) == ["No Expiry", "<1 hr", "1-4 Hrs", "4-12 Hrs", "12-24 Hrs", "1-7 Days", ">7 Days", ">1 Month"])
        #expect(groups.map(\.total) == [3, 4, 8, 0, 16, 0, 32, 64])
    }

    @Test func extrapolationFormatting() {
        #expect(Extrapolation.keysText(100, factor: 2.5, enabled: true) == "~250")
        #expect(Extrapolation.keysText(100, factor: 2.5, enabled: false) == "100")
        #expect(Extrapolation.keysText(100, factor: 1, enabled: true) == "100")
        #expect(Extrapolation.bytesText(1024, factor: 2, enabled: true) == "~2 KB")
        let report = DatabaseAnalysisReport(databaseId: DatabaseID(), progress: AnalysisProgress(total: 30_000, scanned: 10_000, processed: 10_000))
        #expect(report.extrapolationFactor == 3)
        #expect(DatabaseAnalysisReport(databaseId: DatabaseID()).extrapolationFactor == 1)
    }
}

struct AnalyticsFormatTests {
    @Test func progressLines() {
        let done = AnalysisProgress(total: 8_213, scanned: 10_000, processed: 8_213)
        #expect(AnalyticsFormat.progressLine(done) == "Scanned 100% (8,213 of 8,213 keys)")
        #expect(AnalyticsFormat.liveProgressText(AnalysisProgress(total: 50, scanned: 40, processed: 0)) == "Scanning keys… 40 found")
        #expect(AnalyticsFormat.liveProgressText(AnalysisProgress(total: 50, scanned: 40, processed: 10)) == "Analyzing 10 of 40 sampled keys…")
        #expect(AnalyticsFormat.progressFraction(nil) == nil)
        #expect(AnalyticsFormat.progressFraction(AnalysisProgress(total: 5, scanned: 0, processed: 0)) == nil)
        #expect(AnalyticsFormat.progressFraction(AnalysisProgress(total: 5, scanned: 4, processed: 2)) == 0.5)
        #expect(SlowLogDurationUnit.milliseconds.shortLabel == "ms")
        #expect(SlowLogCount.max.menuTitle == "Show Max")
    }

    @Test func scannedPercentage() {
        #expect(AnalyticsFormat.scannedPercentage(processed: 0, total: 0) == "100%")
        #expect(AnalyticsFormat.scannedPercentage(processed: 5, total: 1_000) == "<1%")
        #expect(AnalyticsFormat.scannedPercentage(processed: 500, total: 1_000) == "50%")
        let text = AnalyticsFormat.progressText(AnalysisProgress(total: 8_213, scanned: 10_000, processed: 8_213))
        #expect(text.percentage == "Scanned 100%")
        #expect(text.counts == "(8,213/8,213 keys)")
    }

    @Test func bytes() {
        #expect(AnalyticsFormat.bytes(0) == "0 B")
        #expect(AnalyticsFormat.bytes(-1) == "-")
        #expect(AnalyticsFormat.bytes(1_536) == "1.5 KB")
        #expect(AnalyticsFormat.bytes(nil as Int?) == "-")
    }

    @Test func durations() {
        #expect(AnalyticsFormat.durationFull(seconds: 2_500_000) == "28 d, 22 h, 26 min, 40 s")
        #expect(AnalyticsFormat.durationFirstUnit(seconds: 18_000) == "5 h")
        #expect(AnalyticsFormat.ttl(nil) == "-")
        #expect(AnalyticsFormat.ttl(-1) == "No limit")
        #expect(AnalyticsFormat.ttl(90) == "1 min")
        #expect(AnalyticsFormat.ttlTooltip(90) == "Time to Live\n90 s\n(1 min, 30 s)")
    }

    @Test func slowLogDurations() {
        #expect(AnalyticsFormat.duration(microseconds: 12, unit: .milliseconds) == "0.012")
        #expect(AnalyticsFormat.duration(microseconds: 12_345_678, unit: .milliseconds) == "12,345.678")
        #expect(AnalyticsFormat.duration(microseconds: 12_345_678, unit: .microseconds) == "12,345,678")
        #expect(AnalyticsFormat.duration(microseconds: 10_000, unit: .milliseconds) == "10")
        #expect(AnalyticsFormat.decimal(0.9996, maxDecimals: 3) == "1")
    }

    @Test func keyNamesAndPrefixes() {
        #expect(AnalyticsFormat.keyName(Data([0x61, 0xFF])) == "a\\xff")
        #expect(AnalyticsFormat.truncated("abcdef", limit: 3) == "abc…")
        #expect(AnalyticsFormat.truncated("abc", limit: 3) == "abc")
        #expect(AnalyticsFormat.dbPrefix(0) == "")
        #expect(AnalyticsFormat.dbPrefix(nil) == "")
        #expect(AnalyticsFormat.dbPrefix(2) == "[db2] ")
    }
}
