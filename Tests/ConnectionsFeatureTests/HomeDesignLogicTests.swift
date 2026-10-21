import AppKit
import Foundation
@testable import ConnectionsFeature
import RedisCore
import Testing

struct HomeDesignLogicTests {
    private let core = DatabaseTag(key: "team", value: "core")
    private let web = DatabaseTag(key: "app", value: "web")

    @Test func exclusiveRowsReplaceTheSelection() {
        #expect(DatabaseListLogic.resolveFilters(previous: [.all], proposed: [.all, .recents]) == [.recents])
        #expect(DatabaseListLogic.resolveFilters(previous: [.tag(core)], proposed: [.tag(core), .production])
            == [.production])
        #expect(DatabaseListLogic.resolveFilters(previous: [.recents], proposed: [.recents, .tag(core)]) == [.tag(core)])
        #expect(DatabaseListLogic.resolveFilters(previous: [.tag(core)], proposed: [.tag(core), .tag(web)])
            == [.tag(core), .tag(web)])
        #expect(DatabaseListLogic.resolveFilters(previous: [.tag(core)], proposed: []) == [.all])
        #expect(!DatabaseListLogic.isFiltering([.all]))
        #expect(DatabaseListLogic.isFiltering([.tag(core)]))
    }

    @Test func recentsAreTheTenMostRecentlyConnected() {
        let now = Date()
        let configs = (0..<12).map { index -> DatabaseConfig in
            var config = DatabaseConfig(name: "db\(index)")
            config.lastConnection = now.addingTimeInterval(TimeInterval(-index * 60))
            return config
        } + [DatabaseConfig(name: "never")]
        let recents = DatabaseListLogic.recents(configs)
        #expect(recents.count == 10)
        #expect(recents.contains(configs[0].id))
        #expect(!recents.contains(configs[10].id))
        #expect(!recents.contains(configs[12].id))
    }

    @Test func filterMatching() {
        var prod = DatabaseConfig(name: "p", tags: [core])
        prod.environment = .production
        let other = DatabaseConfig(name: "o", tags: [web])
        #expect(DatabaseListLogic.matches(prod, filters: [.production], recents: []))
        #expect(!DatabaseListLogic.matches(other, filters: [.production], recents: []))
        #expect(!DatabaseListLogic.matches(other, filters: [.development], recents: []))
        #expect(DatabaseListLogic.matches(other, filters: [.tag(core), .tag(web)], recents: []))
        #expect(DatabaseListLogic.matches(other, filters: [.recents], recents: [other.id]))
        #expect(DatabaseListLogic.matches(other, filters: [.all], recents: []))
        #expect(DatabaseListLogic.count(for: .tag(core), in: [prod, other], recents: []) == 1)
    }

    @Test func subtitleWording() {
        #expect(DatabaseListLogic.subtitle(total: 12, visible: 12, selected: 1, isNarrowed: false) == "12 databases")
        #expect(DatabaseListLogic.subtitle(total: 1, visible: 1, selected: 0, isNarrowed: false) == "1 database")
        #expect(DatabaseListLogic.subtitle(total: 12, visible: 3, selected: 0, isNarrowed: true) == "3 of 12 databases")
        #expect(DatabaseListLogic.subtitle(total: 12, visible: 3, selected: 2, isNarrowed: true) == "2 selected")
    }

    @Test func removalConfirmationText() {
        #expect(DatabaseListLogic.removalTitle(names: ["cache"]) == "Remove “cache”?")
        #expect(DatabaseListLogic.removalTitle(names: ["a", "b", "c"]) == "Remove 3 Databases?")
        #expect(DatabaseListLogic.removalMessage(names: ["cache"])
            == "The connection will be removed from Keystrand. Your data on the server is not affected.")
        let many = DatabaseListLogic.removalMessage(names: (1...12).map { "db\($0)" })
        #expect(many.contains("db10, and 2 more"))
        #expect(!many.contains("db11"))
    }

    @Test func environmentColumnAndSorting() {
        var prod = DatabaseConfig(name: "z")
        prod.environment = .production
        var dev = DatabaseConfig(name: "y")
        dev.environment = .development
        let plain = DatabaseConfig(name: "x")
        #expect(DatabaseListLogic.environmentLabel(.production) == "Production")
        #expect(DatabaseListLogic.environmentLabel(.unspecified) == nil)
        #expect(DatabaseListLogic.sort([plain, dev, prod], field: .environment, ascending: true).map(\.name)
            == ["z", "y", "x"])
        #expect(DatabaseListLogic.sort([plain, dev, prod], field: .environment, ascending: false).map(\.name)
            == ["x", "y", "z"])
        #expect(HomeSortField.environment.persisted == nil)
        #expect(HomeSortField(.tags) == .tags)
    }

    @Test func columnTitlesAndNameAlwaysShown() {
        #expect(HomeColumn.allCases.map(\.title)
            == ["Name", "Host:Port", "Type", "Environment", "Modules", "Last Connection", "Tags"])
        #expect(DatabaseListLogic.shownColumns(from: ["tags"]) == [.name, .tags])
        #expect(DatabaseListLogic.shownColumns(from: ["controls"]) == Set(HomeColumn.allCases))
    }

    @Test func discoverySummaries() {
        #expect(SentinelFlowModel.summary(added: 3, failed: 1, noun: "primary group") == "Added 3 primary groups. 1 failed.")
        #expect(SentinelFlowModel.summary(added: 1, failed: 0, noun: "database") == "Added 1 database.")
    }

    @Test func importResultRows() {
        let ok = DatabaseImportResult.Item(index: 2, status: .success, host: "h", port: 6379, errors: [])
        let bad = DatabaseImportResult.Item(index: 3, status: .fail, host: nil, port: nil, errors: ["Bad host", "No port"])
        #expect(ImportResultText.label(ok) == "#2 h:6379")
        #expect(ImportResultText.result(ok) == "Imported")
        #expect(ImportResultText.label(bad) == "#3")
        #expect(ImportResultText.result(bad) == "Bad host\nNo port")
    }

    @Test func designSymbolsExist() {
        let symbols = [HomeFilter.all, .recents, .production, .development, .tag(core)].map(\.systemImage)
            + SoftwareDatabase.Option.allCases.map(\.systemImage)
            + ["shield.lefthalf.filled", "building.2", "doc", "chevron.right", "minus.circle", "plus.circle",
               "xmark.octagon", "xmark.octagon.fill", "checkmark.circle.fill", "line.3.horizontal.decrease.circle",
               "square.and.arrow.up", "trash", "plus", "checkmark", "exclamationmark.shield.fill"]
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }
}
