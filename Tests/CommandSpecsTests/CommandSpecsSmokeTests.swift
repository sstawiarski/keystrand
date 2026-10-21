import CommandSpecs
import Foundation
import Testing

struct CommandSpecsSmokeTests {
    @Test func loadsBundledCatalog() throws {
        let catalog = try CommandCatalog.loadBundled()
        #expect(catalog.commands.count > 300)
        #expect(catalog.spec(named: "client list")?.group == "connection")
        #expect(catalog.spec(named: "FT.SEARCH")?.provider == "redisearch")
        #expect(catalog.match(tokens: ["CLIENT", "KILL", "ID", "1"])?.name == "CLIENT KILL")
        #expect(catalog.spec(named: "GET").map(CommandSyntax.render) == "GET key")
    }

    @Test func everyProviderIsLoaded() throws {
        let catalog = CommandCatalog.shared
        let providers = Set(catalog.commands.values.map(\.provider))
        #expect(providers.isSuperset(of: ["main", "redisearch", "redisjson", "redistimeseries", "redisbloom", "redisgraph"]))
        #expect(catalog.spec(named: "json.set")?.provider == "redisjson")
        #expect(catalog.spec(named: "TS.ADD")?.group == "timeseries")
        #expect(catalog.spec(named: "bf.add")?.group == "bf")
    }
}
