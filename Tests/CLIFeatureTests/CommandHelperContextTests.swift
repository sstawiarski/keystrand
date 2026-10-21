import Foundation
@testable import CLIFeature
import RedisCore
import Testing

@MainActor
struct CommandHelperContextTests {
    private func makeContext() -> CommandHelperContext {
        CommandHelperContext(catalog: .shared)
    }

    @Test func defaultStateShowsNothing() {
        let context = makeContext()
        #expect(!context.isLoading)
        #expect(context.displayedSpec == nil)
        #expect(!context.isSearching)
    }

    @Test func cliInputShowsMatchedCommand() {
        let context = makeContext()
        context.cliInputChanged("get mykey")
        #expect(context.displayedSpec?.name == "GET")
        context.cliInputChanged("client list ")
        #expect(context.displayedSpec?.name == "CLIENT LIST")
        context.cliInputChanged("client nosuchsub")
        #expect(context.displayedSpec?.name == "CLIENT")
        context.cliInputChanged("5 incr counter")
        #expect(context.displayedSpec?.name == "INCR")
        context.cliInputChanged("nosuchcommand")
        #expect(context.displayedSpec == nil)
    }

    @Test func deprecatedGraphCommandsAreHidden() {
        let context = makeContext()
        context.cliInputChanged("GRAPH.QUERY g q")
        #expect(context.displayedSpec == nil)
        context.setSearchText("graph.")
        #expect(context.searchResults.isEmpty)
        #expect(!context.visibleGroups.contains("graph"))
    }

    @Test func searchReplacesDetailsAndCLITypingClearsIt() {
        let context = makeContext()
        context.cliInputChanged("get k")
        context.setSearchText("zadd")
        #expect(context.isSearching)
        #expect(context.displayedSpec == nil)
        #expect(context.searchResults.map(\.name).contains("ZADD"))
        #expect(context.searchResults.allSatisfy { $0.name.contains("ZADD") })

        context.showDetails("ZADD")
        #expect(context.displayedSpec?.name == "ZADD")
        #expect(context.canGoBack)
        context.backToResults()
        #expect(context.isSearching)

        context.cliInputChanged("hset h f v")
        #expect(!context.isSearching)
        #expect(context.searchText.isEmpty)
        #expect(context.displayedSpec?.name == "HSET")
    }

    @Test func groupFilterTogglesAndCombinesWithSearch() {
        let context = makeContext()
        context.setGroupFilter("hash")
        #expect(context.isSearching)
        #expect(!context.searchResults.isEmpty)
        #expect(context.searchResults.allSatisfy { $0.group == "hash" })
        context.setSearchText("get")
        #expect(context.searchResults.allSatisfy { $0.group == "hash" && $0.name.contains("GET") })
        context.setGroupFilter("hash")
        #expect(context.groupFilter == nil)
        #expect(context.isSearching)
        context.setSearchText("")
        #expect(!context.isSearching)
        context.setSearchText("nothing-matches-this")
        #expect(context.searchResults.isEmpty)
    }

    @Test func emptySearchClearsBackToCLIMatch() {
        let context = makeContext()
        context.cliInputChanged("del k")
        context.setSearchText("set")
        context.setSearchText("")
        #expect(context.displayedSpec?.name == "DEL")
    }

    @Test func loadsCatalogInBackground() async throws {
        let context = CommandHelperContext()
        #expect(context.isLoading)
        context.loadIfNeeded()
        for _ in 0..<200 where context.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(context.catalog != nil)
        #expect(context.loadError == nil)
    }
}
