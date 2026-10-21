import Foundation
@testable import ConnectionsFeature
import RedisCore
import Testing

struct DatabaseListLogicTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func config(_ name: String, host: String = "127.0.0.1", port: Int = 6379, db: Int? = nil,
                        type: ConnectionType = .standalone, last: TimeInterval? = nil,
                        tags: [DatabaseTag] = [], modules: [RedisModuleInfo] = []) -> DatabaseConfig {
        DatabaseConfig(name: name, host: host, port: port, db: db, connectionType: type,
                       lastConnection: last.map { now.addingTimeInterval(-$0) }, modules: modules, tags: tags)
    }

    @Test func displayNameAddsDbSuffixAndTruncates() {
        #expect(DatabaseListLogic.displayName(config("cache")) == "cache")
        #expect(DatabaseListLogic.displayName(config("cache", db: 0)) == "cache")
        #expect(DatabaseListLogic.displayName(config("cache", db: 3)) == "cache [db3]")
        let long = String(repeating: "x", count: 300)
        #expect(DatabaseListLogic.displayName(config(long)).count == 200)
        #expect(DatabaseListLogic.fullDisplayName(config(long, db: 1)) == long + " [db1]")
    }

    @Test func connectionTypeLabels() {
        #expect(DatabaseListLogic.connectionTypeLabel(.standalone) == "Standalone")
        #expect(DatabaseListLogic.connectionTypeLabel(.cluster) == "OSS Cluster")
        #expect(DatabaseListLogic.connectionTypeLabel(.sentinel) == "Sentinel")
        #expect(DatabaseListLogic.connectionTypeLabel(.notConnected) == "Not Connected")
    }

    @Test func confirmationNameKeepsTail() {
        let name = String(repeating: "a", count: 60) + "0123456789"
        let short = DatabaseListLogic.confirmationName(name)
        #expect(short.count <= 53)
        #expect(short.hasSuffix("0123456789"))
        #expect(short.contains("..."))
        #expect(DatabaseListLogic.confirmationName("short") == "short")
    }

    static let relativeCases: [(TimeInterval?, String)] = [
        (nil, "Never"),
        (10, "less than a minute ago"),
        (60, "1 minute ago"),
        (5 * 60, "5 minutes ago"),
        (60 * 60, "about 1 hour ago"),
        (2 * 3600, "about 2 hours ago"),
        (30 * 3600, "1 day ago"),
        (5 * 86_400, "5 days ago"),
        (40 * 86_400, "about 1 month ago"),
        (100 * 86_400, "3 months ago"),
        (400 * 86_400, "about 1 year ago"),
        (930 * 86_400, "over 2 years ago"),
    ]

    @Test(arguments: relativeCases)
    func relativeTime(_ ago: TimeInterval?, _ expected: String) {
        let date = ago.map { now.addingTimeInterval(-$0) }
        #expect(DatabaseListLogic.lastConnectionText(date, now: now) == expected)
    }

    @Test func lastConnectionAscendingIsMostRecentFirstNeverLast() {
        let a = config("a", last: 3600)
        let b = config("b", last: 60)
        let c = config("c")
        let sorted = DatabaseListLogic.sort([c, a, b], by: HomeSorting(field: .lastConnection, direction: .asc))
        #expect(sorted.map(\.name) == ["b", "a", "c"])
        let reversed = DatabaseListLogic.sort([c, a, b], by: HomeSorting(field: .lastConnection, direction: .desc))
        #expect(reversed.map(\.name) == ["a", "b", "c"])
    }

    @Test func sortsByNameHostTypeAndTags() {
        let x = config("Beta", host: "B.host", port: 2, type: .cluster, tags: [DatabaseTag(key: "z", value: "1")])
        let y = config("alpha", host: "a.host", port: 10, type: .standalone, tags: [DatabaseTag(key: "a", value: "1")])
        let z = config("gamma", host: "a.host", port: 9, type: .sentinel)
        #expect(DatabaseListLogic.sort([x, y, z], by: HomeSorting(field: .name, direction: .asc)).map(\.name)
            == ["alpha", "Beta", "gamma"])
        #expect(DatabaseListLogic.sort([x, y, z], by: HomeSorting(field: .name, direction: .desc)).map(\.name)
            == ["gamma", "Beta", "alpha"])
        #expect(DatabaseListLogic.sort([x, y, z], by: HomeSorting(field: .host, direction: .asc)).map(\.name)
            == ["gamma", "alpha", "Beta"])
        #expect(DatabaseListLogic.sort([x, y, z], by: HomeSorting(field: .connectionType, direction: .asc)).map(\.name)
            == ["Beta", "gamma", "alpha"])
        #expect(DatabaseListLogic.sort([x, y, z], by: HomeSorting(field: .tags, direction: .asc)).map(\.name)
            == ["gamma", "alpha", "Beta"])
    }

    @Test func searchCoversEveryColumnCaseInsensitively() {
        let db = config("Orders Cache", host: "Redis.Example.com", port: 6380, type: .cluster, last: 300,
                        tags: [DatabaseTag(key: "env", value: "prod")],
                        modules: [RedisModuleInfo(name: "ReJSON", version: 20_811)])
        for query in ["orders", "redis.example", "6380", "oss cluster", "json", "5 minutes", "env:prod", "  CACHE "] {
            #expect(DatabaseListLogic.matches(db, query: query, now: now), "query \(query)")
        }

        #expect(!DatabaseListLogic.matches(db, query: "nothing-like-this", now: now))
        #expect(DatabaseListLogic.matches(db, query: "", now: now))
    }

    @Test func tagFilterMatchesAnySelectedTag() {
        let prod = DatabaseTag(key: "env", value: "prod")
        let dev = DatabaseTag(key: "env", value: "dev")
        let a = config("a", tags: [prod])
        let b = config("b", tags: [dev])
        let c = config("c")
        #expect(DatabaseListLogic.filter([a, b, c], query: "", tagFilter: [], now: now).count == 3)
        #expect(DatabaseListLogic.filter([a, b, c], query: "", tagFilter: [prod], now: now).map(\.name) == ["a"])
        #expect(DatabaseListLogic.filter([a, b, c], query: "", tagFilter: [prod, dev], now: now).map(\.name) == ["a", "b"])
        #expect(DatabaseListLogic.filter([a, b, c], query: "b", tagFilter: [prod, dev], now: now).map(\.name) == ["b"])
        #expect(DatabaseListLogic.allTags([a, b, c, a]) == [dev, prod])
    }

    @Test func modulesFollowDisplayOrder() {
        let modules = [
            RedisModuleInfo(name: "vectorset"),
            RedisModuleInfo(name: "custom"),
            RedisModuleInfo(name: "ReJSON", version: 20_811, semanticVersion: "2.8.11"),
            RedisModuleInfo(name: "search", semanticVersion: "8.2.0"),
        ]
        let ordered = DatabaseListLogic.orderedModules(modules).map(\.name)
        #expect(ordered == ["search", "ReJSON", "vectorset", "custom"])
        let tooltip = DatabaseListLogic.moduleTooltip(modules)
        #expect(tooltip.contains("JSON v. 2.8.11"))
        #expect(tooltip.split(separator: "\n").count == 4)
    }

    @Test func columnPersistence() {
        #expect(DatabaseListLogic.shownColumns(from: []) == Set(HomeColumn.allCases))
        #expect(DatabaseListLogic.shownColumns(from: ["name", "bogus"]) == [.name])
        #expect(DatabaseListLogic.persistedColumns(Set(HomeColumn.allCases)).isEmpty)
        #expect(DatabaseListLogic.persistedColumns([.tags, .name]) == ["name", "tags"])
    }

    @Test func exportFileNameUsesEpochMillis() {
        #expect(DatabaseListLogic.exportFileName(now: Date(timeIntervalSince1970: 1.5)) == "Keystrand_connections_1500.json")
    }

    @Test func requiredFieldsTooltipListsFiveThenEllipsis() {
        #expect(DatabaseFormModel.requiredFieldsTooltip([]) == nil)
        let text = DatabaseFormModel.requiredFieldsTooltip(["A", "B", "C", "D", "E", "F"]) ?? ""
        #expect(text == "Fill in the required fields (6):\nA\nB\nC\nD\nE\n…")
        #expect(DatabaseFormModel.requiredFieldsMessage(["Host", "Port"]) == "Fill in the required fields: Host, Port.")
        #expect(DatabaseFormModel.requiredFieldsMessage(["A", "B", "C", "D", "E", "F", "G"])
            == "Fill in the required fields: A, B, C, D, E, and 2 more.")
    }
}
