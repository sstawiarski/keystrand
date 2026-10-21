import CommandSpecs
import Foundation
import Testing

struct RecentCommandSpecsTests {
    struct Expected: Sendable, CustomTestStringConvertible {
        var name: String
        var group: String
        var argumentCount: Int
        var keyFirst = true

        var testDescription: String { name }
    }

    static let expected: [Expected] = [
        Expected(name: "HEXPIRE", group: "hash", argumentCount: 4),
        Expected(name: "HEXPIREAT", group: "hash", argumentCount: 4),
        Expected(name: "HEXPIRETIME", group: "hash", argumentCount: 2),
        Expected(name: "HPEXPIRE", group: "hash", argumentCount: 4),
        Expected(name: "HPEXPIREAT", group: "hash", argumentCount: 4),
        Expected(name: "HPEXPIRETIME", group: "hash", argumentCount: 2),
        Expected(name: "HPERSIST", group: "hash", argumentCount: 2),
        Expected(name: "HTTL", group: "hash", argumentCount: 2),
        Expected(name: "HPTTL", group: "hash", argumentCount: 2),
        Expected(name: "HGETEX", group: "hash", argumentCount: 3),
        Expected(name: "HSETEX", group: "hash", argumentCount: 5),
        Expected(name: "HGETDEL", group: "hash", argumentCount: 2),
        Expected(name: "MSETEX", group: "string", argumentCount: 4, keyFirst: false),
        Expected(name: "DELIFEQ", group: "string", argumentCount: 2),
        Expected(name: "CLUSTERSCAN", group: "cluster", argumentCount: 5, keyFirst: false),
        Expected(name: "COMMANDLOG", group: "server", argumentCount: 0, keyFirst: false),
        Expected(name: "COMMANDLOG GET", group: "server", argumentCount: 2, keyFirst: false),
        Expected(name: "COMMANDLOG HELP", group: "server", argumentCount: 0, keyFirst: false),
        Expected(name: "COMMANDLOG LEN", group: "server", argumentCount: 1, keyFirst: false),
        Expected(name: "COMMANDLOG RESET", group: "server", argumentCount: 1, keyFirst: false),
        Expected(name: "VADD", group: "vector_set", argumentCount: 9),
        Expected(name: "VCARD", group: "vector_set", argumentCount: 1),
        Expected(name: "VDIM", group: "vector_set", argumentCount: 1),
        Expected(name: "VEMB", group: "vector_set", argumentCount: 3),
        Expected(name: "VGETATTR", group: "vector_set", argumentCount: 2),
        Expected(name: "VINFO", group: "vector_set", argumentCount: 1),
        Expected(name: "VISMEMBER", group: "vector_set", argumentCount: 2),
        Expected(name: "VLINKS", group: "vector_set", argumentCount: 3),
        Expected(name: "VRANDMEMBER", group: "vector_set", argumentCount: 2),
        Expected(name: "VRANGE", group: "vector_set", argumentCount: 4),
        Expected(name: "VREM", group: "vector_set", argumentCount: 2),
        Expected(name: "VSETATTR", group: "vector_set", argumentCount: 3),
        Expected(name: "VSIM", group: "vector_set", argumentCount: 11),
    ]

    static func flattened(_ arguments: [CommandArgument]) -> [CommandArgument] {
        arguments.flatMap { [$0] + flattened($0.arguments) }
    }

    @Test(arguments: expected)
    func loadsFromBundledCatalog(_ expected: Expected) throws {
        let spec = try #require(CommandCatalog.shared.spec(named: expected.name))
        #expect(!spec.summary.isEmpty)
        #expect(spec.since != nil)
        #expect(spec.provider == "main")
        #expect(spec.group == expected.group)
        #expect(spec.arguments.count == expected.argumentCount)
        if expected.keyFirst {
            #expect(spec.arguments.first?.type == .key)
            #expect(spec.arguments.first?.keySpecIndex == 0)
        }

        for argument in Self.flattened(spec.arguments) {
            if case .unknown(let raw) = argument.type {
                Issue.record("\(expected.name) \(argument.name) has unknown type '\(raw)'")
            }

            if argument.type != .key {
                #expect(argument.keySpecIndex == nil, "\(expected.name) \(argument.name) is not a key")
            }
        }
    }

    @Test func rendersHashFieldExpirationSyntax() throws {
        let catalog = CommandCatalog.shared
        let hexpire = try #require(catalog.spec(named: "HEXPIRE"))
        #expect(CommandSyntax.render(hexpire) == "HEXPIRE key seconds [NX | XX | GT | LT] FIELDS numfields field [field ...]")
        let hgetex = try #require(catalog.spec(named: "HGETEX"))
        #expect(CommandSyntax.render(hgetex) == "HGETEX key [EX seconds | PX milliseconds | EXAT unix-time-seconds | "
            + "PXAT unix-time-milliseconds | PERSIST] FIELDS numfields field [field ...]")
    }

    @Test func hsetexIsTheRedisAndValkeySuperset() throws {
        let hsetex = try #require(CommandCatalog.shared.spec(named: "HSETEX"))
        #expect(CommandSyntax.render(hsetex) == "HSETEX key [NX | XX] [FNX | FXX] [EX seconds | PX milliseconds | "
            + "EXAT unix-time-seconds | PXAT unix-time-milliseconds | KEEPTTL] FIELDS numfields field value [field value ...]")
    }

    @Test func msetexKeysAreInsideTheDataBlock() throws {
        let msetex = try #require(CommandCatalog.shared.spec(named: "MSETEX"))
        let keys = Self.flattened(msetex.arguments).filter { $0.type == .key }
        #expect(keys.count == 1)
        #expect(keys.first?.keySpecIndex == 0)
    }

    @Test func vectorSetValuesTakeACountAndDoubles() throws {
        let catalog = CommandCatalog.shared
        let vadd = try #require(catalog.spec(named: "VADD"))
        #expect(CommandSyntax.render(vadd) == "VADD key [REDUCE dim] FP32 vector | VALUES num value [value ...] element "
            + "[CAS] [NOQUANT | BIN | Q8] [EF build-exploration-factor] [SETATTR attributes] [M numlinks]")
        let vsim = try #require(catalog.spec(named: "VSIM"))
        #expect(CommandSyntax.render(vsim).hasPrefix("VSIM key ELE element | FP32 vector | VALUES num value [value ...] "
            + "[WITHSCORES]"))

        let afterCount = ArgumentWalker.walk(vadd.arguments, tokens: ["k", "VALUES", "3"])
        #expect(afterCount.expected?.name == "value")
        #expect(afterCount.expected?.type == .double)
        let afterValues = ArgumentWalker.walk(vadd.arguments, tokens: ["k", "VALUES", "3", "0.1", "0.2", "0.3"])
        #expect(afterValues.expected?.name == "element")
        let similar = ArgumentWalker.walk(vsim.arguments, tokens: ["k", "VALUES", "2", "1", "2"])
        #expect(similar.isSatisfied)
        #expect(similar.keywordSuggestions.contains("WITHSCORES"))
    }

    @Test func valkeyOnlyCommands() throws {
        let catalog = CommandCatalog.shared
        let delifeq = try #require(catalog.spec(named: "DELIFEQ"))
        #expect(CommandSyntax.render(delifeq) == "DELIFEQ key value")
        let scan = try #require(catalog.spec(named: "CLUSTERSCAN"))
        #expect(CommandSyntax.render(scan) == "CLUSTERSCAN cursor [MATCH match-pattern] [COUNT count] [TYPE type] [SLOT slot]")
        #expect(catalog.match(tokens: ["CLUSTERSCAN", "0"])?.name == "CLUSTERSCAN")
        let get = try #require(catalog.spec(named: "commandlog get"))
        #expect(CommandSyntax.render(get) == "COMMANDLOG GET count SLOW | LARGE-REQUEST | LARGE-REPLY")
        #expect(catalog.subcommands(of: "COMMANDLOG").map(\.name)
            == ["COMMANDLOG GET", "COMMANDLOG HELP", "COMMANDLOG LEN", "COMMANDLOG RESET"])
        #expect(catalog.match(tokens: ["COMMANDLOG", "LEN", "SLOW"])?.name == "COMMANDLOG LEN")
    }
}
