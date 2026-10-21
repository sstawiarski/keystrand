import Foundation
import RedisCore
import TestSupport
@testable import SettingsFeature
import Testing

struct OverviewFormattingTests {
    @Test func compactCountFloorsToUnit() {
        #expect(OverviewFormatting.compactCount(0) == "0")
        #expect(OverviewFormatting.compactCount(999) == "999")
        #expect(OverviewFormatting.compactCount(1_000) == "1 K")
        #expect(OverviewFormatting.compactCount(1_999) == "1 K")
        #expect(OverviewFormatting.compactCount(100_000) == "100 K")
        #expect(OverviewFormatting.compactCount(3_400_000) == "3 M")
        #expect(OverviewFormatting.compactCount(2_000_000_001) == "2 B")
    }

    @Test func cpuDisplayAndTooltip() {
        #expect(OverviewFormatting.cpuDisplay(0) == "0 %")
        #expect(OverviewFormatting.cpuDisplay(12) == "12 %")
        #expect(OverviewFormatting.cpuDisplay(0.123456) == "0.12 %")
        #expect(OverviewFormatting.cpuDisplay(0.2) == "0.20 %")
        #expect(OverviewFormatting.cpuTooltip(0.123456, max: nil) == "0.1235%")
        #expect(OverviewFormatting.cpuTooltip(0.123456, max: 100) == "0.1235%")
        #expect(OverviewFormatting.cpuTooltip(150.5, max: 400) == "150.5000% / 400%")
    }

    @Test func memoryUsesBase1024() {
        #expect(OverviewFormatting.memory(0) == "0 B")
        #expect(OverviewFormatting.memory(512) == "512 B")
        #expect(OverviewFormatting.memory(1_048_576) == "1 MB")
        #expect(OverviewFormatting.memory(1_600_000) == "2 MB")
        #expect(OverviewFormatting.memoryTooltip(1_600_000) == "1.526 MB")
        #expect(OverviewFormatting.memoryTooltip(1_048_576) == "1 MB")
    }

    @Test func networkUsesBase1000LowercaseUnits() {
        #expect(OverviewFormatting.network(kbps: nil) == "0 b/s")
        #expect(OverviewFormatting.network(kbps: 0) == "0 b/s")
        #expect(OverviewFormatting.network(kbps: 0.5) == "500 b/s")
        #expect(OverviewFormatting.network(kbps: 1.234) == "1.234 kb/s")
        #expect(OverviewFormatting.network(kbps: 2_500) == "2.5 mb/s")
    }

    @Test func connectedClientsMedianIsApproximate() {
        #expect(OverviewFormatting.connectedClients(3) == "3")
        #expect(OverviewFormatting.connectedClients(3.5) == "~4")
        #expect(OverviewFormatting.connectedClients(2.4) == "~2")
    }

    @Test func groupedNumbers() {
        #expect(NumberFormatting.grouped(12_345) == "12,345")
        #expect(NumberFormatting.grouped(100) == "100")
    }

    @Test func bytesHandlesInvalidInput() {
        #expect(OverviewFormatting.bytes(-1, decimals: 2) == "-")
        #expect(OverviewFormatting.bytes(.nan, decimals: 2) == "-")
        #expect(OverviewFormatting.bytes(1536, decimals: 2) == "1.5 KB")
    }
}

struct OverviewMetricsBuilderTests {
    @Test func emptyOverviewShowsNothing() {
        #expect(OverviewMetricsBuilder.metrics(from: DatabaseOverview(), dbIndex: 0).isEmpty)
    }

    @Test func fullOverviewInMetricOrder() {
        let overview = DatabaseOverview(version: "8.10.0", totalKeys: 12_345, totalKeysPerDb: ["db2": 100],
                                        usedMemory: 1_048_576, connectedClients: 3, opsPerSecond: 42,
                                        networkInKbps: 1.5, networkOutKbps: 0.25,
                                        cpuUsagePercentage: .some(0.5), maxCpuUsagePercentage: 400)
        let metrics = OverviewMetricsBuilder.metrics(from: overview, dbIndex: 2)
        #expect(metrics.map(\.kind) == [.cpu, .commands, .memory, .keys, .clients])
        #expect(metrics[0].value == "0.50 %")
        #expect(metrics[0].tooltip.contains("0.5000% / 400%"))
        #expect(metrics[1].value == "42")
        #expect(metrics[1].details.map(\.label) == ["Commands/s", "Network Input", "Network Output"])
        #expect(metrics[1].details[1].value == "1.5 kb/s")
        #expect(metrics[1].details[2].value == "250 b/s")
        #expect(metrics[2].value == "1 MB")
        #expect(metrics[3].value == "12 K")
        #expect(metrics[3].details.map(\.value) == ["12,345", "100"])
        #expect(metrics[3].details[1].label == "db2")
        #expect(metrics[4].value == "3")
    }

    @Test func cpuCalculatingState() {
        let overview = DatabaseOverview(cpuUsagePercentage: .some(nil))
        let metrics = OverviewMetricsBuilder.metrics(from: overview, dbIndex: 0)
        #expect(metrics.count == 1)
        #expect(metrics[0].isLoading)
        #expect(metrics[0].value == "Calculating…")
        #expect(metrics[0].tooltip.contains("Calculating in progress"))
    }

    @Test func perDbKeysOnlyWhenSmallerThanTotal() {
        let same = DatabaseOverview(totalKeys: 10, totalKeysPerDb: ["db0": 10])
        #expect(OverviewMetricsBuilder.metrics(from: same, dbIndex: 0)[0].details.count == 1)
        let other = DatabaseOverview(totalKeys: 10, totalKeysPerDb: ["db1": 4])
        #expect(OverviewMetricsBuilder.metrics(from: other, dbIndex: 0)[0].details.count == 1)
    }

    @Test func unavailableTexts() {
        #expect(OverviewMetricsBuilder.unavailableText(.cpu) == "CPU is not available")
        #expect(OverviewMetricsBuilder.unavailableText(.commands) == "Commands/s are not available")
        #expect(OverviewMetricsBuilder.unavailableText(.memory) == "Total Memory is not available")
        #expect(OverviewMetricsBuilder.unavailableText(.keys) == "Total Keys are not available")
        #expect(OverviewMetricsBuilder.unavailableText(.clients) == "Connected Clients are not available")
    }
}

struct DateFormatValidatorTests {
    @Test func presetsAreSupported() {
        for format in AppSettings.presetDateFormats {
            #expect(DateFormatValidator.isSupported(format), "\(format)")
            #expect(DateFormatValidator.error(for: format) == nil)
        }
    }

    @Test func tooLongFormat() {
        let format = String(repeating: "y", count: 51)
        #expect(DateFormatValidator.error(for: format) == "Format should not exceed 50 characters")
        #expect(!DateFormatValidator.canSave(format))
    }

    @Test func unsupportedLettersAndQuotes() {
        #expect(DateFormatValidator.error(for: "HH:mm f") == "This format is not supported.")
        #expect(DateFormatValidator.error(for: "yyyy 'open") == "This format is not supported.")
        #expect(DateFormatValidator.error(for: "yyyy 'at' HH") == nil)
        #expect(DateFormatValidator.error(for: "yyyy ''") == nil)
    }

    @Test func emptyHasNoErrorButCannotSave() {
        #expect(DateFormatValidator.error(for: "") == nil)
        #expect(!DateFormatValidator.canSave("   "))
    }

    @Test func previewFormatsInTimeZone() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(DateFormatValidator.preview("yyyy-MM-dd HH:mm:ss", timeZone: utc, date: date) == "2023-11-14 22:13:20")
        #expect(DateFormatValidator.preview("HH:mm:ss d MMM yyyy", timeZone: utc, date: date) == "22:13:20 14 Nov 2023")
        #expect(DateFormatValidator.preview("yyyy-MM-dd HH:mm:ss.sss", timeZone: utc, date: date) == "2023-11-14 22:13:20.020")
        #expect(DateFormatValidator.preview("bad f", timeZone: utc, date: date) == "Invalid Format")
        #expect(DateFormatValidator.preview("", timeZone: utc, date: date) == "Invalid Format")
    }
}

struct NumericSettingParserTests {
    @Test func digitsOnly() {
        #expect(NumericSettingParser.digitsOnly("1a2 3-") == "123")
        #expect(NumericSettingParser.digitsOnly("١٢") == "")
    }

    @Test func scanThresholdRules() {
        #expect(NumericSettingParser.scanThreshold(from: "") == 10_000)
        #expect(NumericSettingParser.scanThreshold(from: "0") == 10_000)
        #expect(NumericSettingParser.scanThreshold(from: "100") == 500)
        #expect(NumericSettingParser.scanThreshold(from: "500") == 500)
        #expect(NumericSettingParser.scanThreshold(from: "25000") == 25_000)
        #expect(NumericSettingParser.scanThreshold(from: "99999999999999999999") == 999_999_999)
    }

    @Test func pipelineBatchSizeRules() {
        #expect(NumericSettingParser.pipelineBatchSize(from: "") == 5)
        #expect(NumericSettingParser.pipelineBatchSize(from: "0") == 0)
        #expect(NumericSettingParser.pipelineBatchSize(from: "1") == 1)
        #expect(NumericSettingParser.pipelineBatchSize(from: "250") == 250)
    }

    @Test func refreshRateClamps() {
        #expect(NumericSettingParser.refreshRate(from: "abc") == nil)
        #expect(NumericSettingParser.refreshRate(from: "0.2") == 1.0)
        #expect(NumericSettingParser.refreshRate(from: "2,5") == 2.5)
        #expect(NumericSettingParser.refreshRate(from: "5000") == 999.9)
    }
}

struct AppVersionInfoTests {
    @Test func versionLineAndDiagnostics() {
        let info = AppVersionInfo(version: "1.2.3", build: "45", osVersion: "macOS 15.1.0", architecture: "arm64")
        #expect(info.versionLine == "Keystrand v1.2.3 (45)")
        let lines = info.diagnostics.split(separator: "\n").map(String.init)
        #expect(lines.first == "```")
        #expect(lines.last == "```")
        #expect(lines[1] == "Keystrand diagnostics")
        #expect(lines[2] == "App version:   1.2.3")
        #expect(lines[3] == "Build:         45")
        #expect(lines[4] == "OS:            macOS 15.1.0 (arm64)")
    }

    @Test func currentReadsBundle() {
        let info = AppVersionInfo.current()
        #expect(!info.version.isEmpty)
        #expect(!info.build.isEmpty)
        #expect(info.osVersion.hasPrefix("macOS "))
    }
}

struct ShortcutCatalogTests {
    @Test func containsDesignGroups() {
        let workbench = ShortcutCatalog.groups.first { $0.title == "Workbench" }
        #expect(workbench?.items.first?.description == "Run commands")
        #expect(workbench?.items.contains { $0.keys == "⌃Space" } == true)
        #expect(workbench?.items.contains { $0.keys == "⌘Space" } == false)
    }

    @Test func idsAreUniqueWithinGroups() {
        for group in ShortcutCatalog.groups {
            #expect(Set(group.items.map(\.id)).count == group.items.count, "\(group.title)")
        }
    }

    @Test func filterMatchesDescriptionsKeysAndTitles() {
        let clear = ShortcutCatalog.filtered("clear the")
        #expect(clear.map(\.title) == ["CLI"])
        #expect(clear.first?.items.count == 1)
        #expect(ShortcutCatalog.filtered("⇧⌘H").first?.items.first?.description == "Command Helper")
        #expect(ShortcutCatalog.filtered("workbench").contains { $0.title == "Workbench" && $0.items.count > 1 })
        #expect(ShortcutCatalog.filtered("zzz-nothing").isEmpty)
        #expect(ShortcutCatalog.filtered("  ").count == ShortcutCatalog.groups.count)
    }
}

struct OverviewSummaryTests {
    static func overview() -> DatabaseOverview {
        var overview = DatabaseOverview()
        overview.version = "8.10.2"
        overview.cpuUsagePercentage = .some(0.42)
        overview.opsPerSecond = 132
        overview.networkInKbps = 1.5
        overview.networkOutKbps = 2.5
        overview.usedMemory = 5_347_737
        overview.totalKeys = 73
        overview.connectedClients = 1
        return overview
    }

    @Test func compactTextMatchesTheDesign() {
        let parts = OverviewSummary.parts(overview: Self.overview(), version: nil, dbIndex: 0)
        #expect(OverviewSummary.text(parts) == "Redis 8.10.2 · CPU 0.4% · 132 ops/s · 5.1 MB · 73 keys · 1 client")
        #expect(parts.first { $0.kind == .commands }?.help.contains("Network Input") == true)
    }

    @Test func missingMetricsAreOmitted() {
        var overview = DatabaseOverview()
        overview.usedMemory = 1024
        let parts = OverviewSummary.parts(overview: overview, version: "7.2.4", dbIndex: 0)
        #expect(OverviewSummary.text(parts) == "Redis 7.2.4 · 1 KB")
        #expect(OverviewSummary.parts(overview: nil, version: nil, dbIndex: 0).isEmpty)
        #expect(OverviewSummary.text(OverviewSummary.parts(overview: nil, version: "7.0.0", dbIndex: 0)) == "Redis 7.0.0")
    }

    @Test func versionPartNamesTheServer() {
        var valkey = DatabaseOverview()
        valkey.version = "9.1.2"
        valkey.usedMemory = 1024
        let parts = OverviewSummary.parts(overview: valkey, version: "7.2.4", flavor: .valkey, dbIndex: 0)
        #expect(OverviewSummary.text(parts) == "Valkey 9.1.2 · 1 KB")
        #expect(parts.first?.help == "Valkey version 9.1.2")
        let fallback = OverviewSummary.parts(overview: nil, version: "9.1.2", flavor: .valkey, dbIndex: 0)
        #expect(OverviewSummary.text(fallback) == "Valkey 9.1.2")

        var redis = DatabaseOverview()
        redis.version = "8.0.3"
        let redisParts = OverviewSummary.parts(overview: redis, version: nil, dbIndex: 0)
        #expect(OverviewSummary.text(redisParts) == "Redis 8.0.3")
        #expect(redisParts.first?.help == "Redis version 8.0.3")
    }

    @Test func calculatingCPUIsOmitted() {
        var overview = DatabaseOverview()
        overview.cpuUsagePercentage = .some(nil)
        overview.usedMemory = 1024
        #expect(OverviewSummary.text(OverviewSummary.parts(overview: overview, version: nil, dbIndex: 0)) == "1 KB")
    }

    @Test func variantsDropClientsKeysOpsThenCPU() {
        let parts = OverviewSummary.parts(overview: Self.overview(), version: nil, dbIndex: 0)
        let texts = OverviewSummary.variants(parts).map(OverviewSummary.text)
        #expect(texts == [
            "Redis 8.10.2 · CPU 0.4% · 132 ops/s · 5.1 MB · 73 keys · 1 client",
            "Redis 8.10.2 · CPU 0.4% · 132 ops/s · 5.1 MB · 73 keys",
            "Redis 8.10.2 · CPU 0.4% · 132 ops/s · 5.1 MB",
            "Redis 8.10.2 · CPU 0.4% · 5.1 MB",
            "Redis 8.10.2 · 5.1 MB",
        ])
    }

    @Test func countsUseSingularAndCompactForms() {
        #expect(OverviewSummary.keysText(1) == "1 key")
        #expect(OverviewSummary.keysText(8_213) == "8,213 keys")
        #expect(OverviewSummary.keysText(1_200_000) == "1.2M keys")
        #expect(OverviewSummary.clientsText(1) == "1 client")
        #expect(OverviewSummary.clientsText(2.6) == "~3 clients")
    }

    @Test func infoMetricsRows() {
        let rows = DatabaseInfoMetrics.rows(overview: Self.overview(), dbIndex: 0)
        #expect(rows.map(\.label) == ["CPU", "Commands/s", "Network Input", "Network Output", "Memory", "Keys", "Clients"])
        #expect(DatabaseInfoMetrics.rows(overview: nil, dbIndex: 0).isEmpty)
    }
}

struct DatabaseInfoDetailsTests {
    static let infoText = """
    # Server\r
    redis_version:8.10.0\r
    redis_mode:standalone\r
    os:Linux 6.10.14-linuxkit aarch64\r
    process_id:1\r
    uptime_in_seconds:3725\r
    # Clients\r
    connected_clients:3\r
    # Memory\r
    used_memory:1048576\r
    used_memory_peak:2097152\r
    total_system_memory:8589934592\r
    maxmemory:0\r
    maxmemory_policy:noeviction\r
    # Replication\r
    role:master\r
    # Keyspace\r
    db0:keys=10,expires=1,avg_ttl=0\r
    db13:keys=5,expires=0,avg_ttl=0\r
    db2:keys=7,expires=2,avg_ttl=100\r

    """

    @Test func buildsAllSections() {
        let info = ServerInfoParser.parse(Self.infoText)
        let modules = [RedisModuleInfo(name: "search", version: 21_012, semanticVersion: "2.10.12"),
                       RedisModuleInfo(name: "ReJSON", version: 80_000)]
        let details = DatabaseInfoDetails.make(name: "Local", hostPort: "127.0.0.1:6390", connectionKind: .standalone,
                                               username: nil, info: info, modules: modules, databaseCount: 16, currentDb: 13)
        #expect(details.version == "8.10.0")
        #expect(details.user == "Default")
        #expect(details.connectionType == "Standalone")
        #expect(details.showsLogicalDatabasesHint)
        let server = Dictionary(uniqueKeysWithValues: details.server.map { ($0.label, $0.value) })
        #expect(server["Mode"] == "Standalone")
        #expect(server["Role"] == "Master")
        #expect(server["OS"] == "Linux 6.10.14-linuxkit aarch64")
        #expect(server["Uptime"] == "1 h 2 min 5 s")
        #expect(server["Logical databases"] == "16")
        let memory = Dictionary(uniqueKeysWithValues: details.memory.map { ($0.label, $0.value) })
        #expect(memory["Used memory"] == "1 MB")
        #expect(memory["Used memory peak"] == "2 MB")
        #expect(memory["Total system memory"] == "8 GB")
        #expect(memory["Max memory"] == "No limit")
        #expect(details.keyspace.map(\.db) == [0, 2, 13])
        #expect(details.keyspace.first { $0.db == 13 }?.isCurrent == true)
        #expect(details.keyspace.first { $0.db == 2 }?.expires == 2)
        #expect(details.modules.map(\.text) == ["JSON v. 8.0.0", "Redis Search v. 2.10.12"])
        #expect(details.plainText.contains("db13: keys=5, expires=0"))
    }

    @Test func namesTheServerInTheVersionRow() {
        let valkeyInfo = ServerInfoParser.parse(
            ValkeyFixtures.serverInfo + "server_mode:standalone\r\n")
        let valkey = DatabaseInfoDetails.make(name: "V", hostPort: "h:1", connectionKind: .standalone, username: nil,
                                              info: valkeyInfo, modules: [], databaseCount: 16, currentDb: 0)
        #expect(valkey.version == "9.1.2")
        #expect(valkey.versionLabel == "Valkey Version")
        #expect(valkey.plainText.contains("Valkey version: 9.1.2"))
        #expect(valkey.server.first { $0.label == "Mode" }?.value == "Standalone")

        let redisInfo = ServerInfoParser.parse("# Server\r\nredis_version:8.0.3\r\n")
        let redis = DatabaseInfoDetails.make(name: "R", hostPort: "h:1", connectionKind: .standalone, username: nil,
                                             info: redisInfo, modules: [], databaseCount: 16, currentDb: 0)
        #expect(redis.version == "8.0.3")
        #expect(redis.versionLabel == "Redis Version")
        #expect(redis.plainText.contains("Redis version: 8.0.3"))
    }

    @Test func handlesMissingInfo() {
        let details = DatabaseInfoDetails.make(name: "X", hostPort: "h:1", connectionKind: .cluster, username: "alice",
                                               info: nil, modules: [], databaseCount: 0, currentDb: 0)
        #expect(details.user == "alice")
        #expect(details.connectionType == "Cluster")
        #expect(details.databaseCount == 1)
        #expect(!details.showsLogicalDatabasesHint)
        #expect(details.keyspace.isEmpty)
        #expect(details.memory.isEmpty)
        #expect(details.version == nil)
    }
}
