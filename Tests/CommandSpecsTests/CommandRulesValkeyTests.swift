import CommandSpecs
import Foundation
import Testing

struct CommandRulesValkeyTests {
    let catalog = CommandCatalog.shared
    let valkeyModules = ["json", CommandModuleRequirement.bloomFilterOnlyModule, "search"]

    @Test func valkeyJSONModuleSatisfiesJSON() {
        let json = CommandModuleRequirement.requirement(for: "JSON.GET k $")
        #expect(json == .json)
        #expect(json?.isSatisfied(by: ["json"]) == true)
        #expect(json?.isSatisfied(by: ["ReJSON"]) == true)
        #expect(json?.isSatisfied(by: ["search"]) == false)
    }

    @Test func bloomOnlyModuleSatisfiesBFButNotTheRestOfTheSuite() {
        let bf = CommandModuleRequirement.requirement(for: "bf.add k a")
        #expect(bf == .bloomFilter)
        #expect(bf?.isSatisfied(by: valkeyModules) == true)
        #expect(bf?.isSatisfied(by: ["bf"]) == true)
        #expect(bf?.isSatisfied(by: []) == false)
        for command in ["CF.ADD k a", "CMS.INITBYDIM k 1 1", "TOPK.ADD k a", "TDIGEST.CREATE k"] {
            let requirement = CommandModuleRequirement.requirement(for: command)
            #expect(requirement == .probabilistic)
            #expect(requirement?.isSatisfied(by: valkeyModules) == false)
            #expect(requirement?.isSatisfied(by: ["bf"]) == true)
        }

        #expect(CommandModuleRequirement.bloomFilter.title == CommandModuleRequirement.probabilistic.title)
    }

    @Test func completionsIncludeValkeyModuleCommands() {
        let available = catalog.available(CommandAvailability(modules: valkeyModules))
        #expect(available.contains { $0.name == "JSON.GET" })
        #expect(available.contains { $0.name == "BF.ADD" })
        #expect(available.contains { $0.name == "FT.SEARCH" })
        #expect(!available.contains { $0.name.hasPrefix("TS.") })
        #expect(!available.contains { $0.name.hasPrefix("CF.") })
    }

    @Test func cliTabCompletionFollowsServerAvailability() {
        func cycle(_ input: String, _ availability: CommandAvailability) -> [String] {
            var completer = CommandLineCompleter(catalog: catalog, availability: availability)
            var seen: [String] = []
            var current = completer.complete(input)
            while current != input && !seen.contains(current) {
                seen.append(current)
                current = completer.complete(current)
            }

            return seen
        }

        let valkey = CommandAvailability(modules: valkeyModules, includesVectorSets: false)
        #expect(cycle("VA", valkey).isEmpty)
        #expect(cycle("CF.", valkey).isEmpty)
        #expect(cycle("TS.", valkey).isEmpty)
        #expect(cycle("BF.AD", valkey).contains("BF.ADD"))
        #expect(cycle("JSON.G", valkey).contains("JSON.GET"))
        #expect(cycle("HEXP", valkey).contains("HEXPIRE"))
        #expect(cycle("VA", .unrestricted).contains("VADD"))
        #expect(cycle("CF.AD", .unrestricted).contains("CF.ADD"))
    }
}
