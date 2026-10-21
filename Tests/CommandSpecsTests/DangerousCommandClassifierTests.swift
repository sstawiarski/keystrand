import CommandSpecs
import Foundation
import Testing

struct DangerousCommandClassifierTests {
    /// `ACL CAT dangerous` on Redis 8 lists subcommands only in pipe form, never a bare `config`, `acl` or `client`.
    let redis8List: Set<String> = ["config|set", "config|get", "acl|setuser", "client|kill", "client|pause",
                                   "cluster|reset", "module|load", "flushdb", "flushall", "keys"]

    @Test func subcommandsMatchPipeFormsOfTheServerList() {
        let classifier = DangerousCommandClassifier(serverList: redis8List, catalog: .shared)
        #expect(classifier.dangerousVerb(["CONFIG", "SET", "maxmemory", "1"]) == "CONFIG")
        #expect(classifier.dangerousVerb(["acl", "setuser", "u"]) == "ACL")
        #expect(classifier.dangerousVerb(["CLIENT", "KILL", "ID", "1"]) == "CLIENT")
        #expect(classifier.dangerousVerb(["flushdb"]) == "FLUSHDB")
        #expect(classifier.dangerousVerb(["CONFIG"]) == nil)
        #expect(classifier.dangerousVerb(["CONFIG", "RESETSTAT"]) == nil)
        #expect(classifier.dangerousVerb(["GET", "k"]) == nil)
        #expect(classifier.dangerousVerb([]) == nil)
    }

    @Test func bareNamesInTheServerListStillMatch() {
        let classifier = DangerousCommandClassifier(serverList: ["config", "debug"], catalog: nil)
        #expect(classifier.dangerousVerb(["config", "rewrite"]) == "CONFIG")
        #expect(classifier.dangerousVerb(["DEBUG", "SLEEP", "0"]) == "DEBUG")
    }

    @Test func catalogAppliesOnlyWhenTheServerListIsEmpty() {
        let fallback = DangerousCommandClassifier(serverList: [], catalog: .shared)
        #expect(fallback.dangerousVerb(["config", "set", "maxmemory", "1"]) == "CONFIG")
        #expect(fallback.dangerousVerb(["FLUSHALL"]) == "FLUSHALL")
        #expect(fallback.dangerousVerb(["GET", "k"]) == nil)
        #expect(DangerousCommandClassifier(serverList: [], catalog: nil).dangerousVerb(["FLUSHALL"]) == nil)
        #expect(DangerousCommandClassifier(serverList: ["keys"], catalog: .shared).dangerousVerb(["FLUSHALL"]) == nil)
    }

    @Test func verbsAreDistinctInOrder() {
        let classifier = DangerousCommandClassifier(serverList: redis8List, catalog: nil)
        let commands = [["keys", "*"], ["GET", "a"], ["CONFIG", "SET", "x", "y"], ["KEYS", "a*"], ["config", "get", "x"]]
        #expect(classifier.dangerousVerbs(in: commands) == ["KEYS", "CONFIG"])
        #expect(DangerousCommandClassifier.flushVerbs(in: [["set", "a", "1"], ["flushall"], ["FLUSHDB", "ASYNC"],
                                                           ["FLUSHALL"], ["GET", "flushdb"]]) == ["FLUSHALL", "FLUSHDB"])
    }
}
