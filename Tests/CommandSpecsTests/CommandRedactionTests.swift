@testable import CommandSpecs
import Testing

struct CommandRedactionTests {
    @Test(arguments: [
        ("AUTH secret", "AUTH ******"),
        ("auth default secret", "auth default ******"),
        ("3 AUTH secret", "3 AUTH ******"),
        (#"AUTH "pass word""#, "AUTH ******"),
        ("HELLO 2 AUTH alice secret SETNAME cli", "HELLO 2 AUTH alice ****** SETNAME cli"),
        ("ACL SETUSER alice on >secret ~* +@all", "ACL SETUSER alice on >****** ~* +@all"),
        ("ACL SETUSER bob <old #abc123", "ACL SETUSER bob <****** #******"),
        ("CONFIG SET requirepass secret", "CONFIG SET requirepass ******"),
        ("config set maxmemory 1mb masterauth secret", "config set maxmemory 1mb masterauth ******"),
        ("MIGRATE h 6379 k 0 5000 AUTH secret", "MIGRATE h 6379 k 0 5000 AUTH ******"),
        ("MIGRATE h 6379 k 0 5000 AUTH2 user secret KEYS a", "MIGRATE h 6379 k 0 5000 AUTH2 user ****** KEYS a"),
        ("SENTINEL SET mymaster auth-pass secret", "SENTINEL SET mymaster auth-pass ******"),
        ("SENTINEL CONFIG SET sentinel-pass secret", "SENTINEL CONFIG SET sentinel-pass ******"),
    ])
    func masksSecrets(input: String, expected: String) {
        #expect(CommandRedaction.redact(input) == expected)
    }

    @Test(arguments: [
        "GET auth", "SET requirepass secret", "CONFIG GET requirepass", "ACL WHOAMI", "HELLO 3", "AUTH", "",
        "CONFIG SET maxmemory 1mb",
    ])
    func leavesOtherCommandsUnchanged(input: String) {
        #expect(CommandRedaction.redact(input) == input)
    }

    @Test func multilineCommandKeepsItsLayout() {
        #expect(CommandRedaction.redact("CONFIG SET\n  requirepass secret") == "CONFIG SET\n  requirepass ******")
        #expect(CommandRedaction.redactLines("AUTH a\r\nPING\r\nAUTH u b") == "AUTH ******\r\nPING\r\nAUTH u ******")
    }

    @Test func newBlockingCommandsAreRefused() {
        for line in ["BLMPOP 0 1 l LEFT", "BZMPOP 0 1 z MIN", "WAIT 1 0", "WAITAOF 1 0 0"] {
            #expect(CommandRules.isBlocking(line), "\(line)")
        }

        #expect(CommandRules.workbenchUnsupportedMatch("WAITAOF 1 0 0") == "waitaof")
        #expect(CommandRules.workbenchUnsupportedMatch("XREADGROUP GROUP g c STREAMS s >") == "xreadgroup")
    }
}
