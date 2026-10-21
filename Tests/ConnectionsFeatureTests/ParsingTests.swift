import Foundation
@testable import ConnectionsFeature
import RedisCore
import Testing

struct ConnectionURLParserTests {
    @Test func parsesHostPort() throws {
        let parsed = try #require(ConnectionURLParser.parse("example.com:6380"))
        #expect(parsed.host == "example.com")
        #expect(parsed.port == 6380)
        #expect(parsed.scheme == "redis")
        #expect(parsed.hostname == "example.com:6380")
        #expect(!parsed.tls)
    }

    @Test func parsesFullRedisURL() throws {
        let parsed = try #require(ConnectionURLParser.parse("  redis://alice:s3cr:et@cache.local:7000/4 \n"))
        #expect(parsed.username == "alice")
        #expect(parsed.password == "s3cr:et")
        #expect(parsed.host == "cache.local")
        #expect(parsed.port == 7000)
        #expect(parsed.db == 4)
    }

    @Test func parsesRedissWithoutPortOrUser() throws {
        let parsed = try #require(ConnectionURLParser.parse("rediss://secure.example.com"))
        #expect(parsed.tls)
        #expect(parsed.port == nil)
        #expect(parsed.hostname == "secure.example.com")
        #expect(parsed.username.isEmpty)
    }

    @Test func parsesPasswordOnlyUserInfo() throws {
        let parsed = try #require(ConnectionURLParser.parse("redis://:pw@127.0.0.1:6390"))
        #expect(parsed.username.isEmpty)
        #expect(parsed.password == "pw")
    }

    @Test func parsesBracketedIPv6() throws {
        let plain = try #require(ConnectionURLParser.parse("[::1]:6390"))
        #expect(plain.host == "::1")
        #expect(plain.hostname == "[::1]:6390")
        let url = try #require(ConnectionURLParser.parse("redis://[fe80::1]:6379/2"))
        #expect(url.host == "fe80::1")
        #expect(url.db == 2)
    }

    @Test(arguments: ["http://example.com:80", "localhost", "redis://", "just text", "redis://host:port"])
    func rejectsUnsupported(_ text: String) {
        #expect(ConnectionURLParser.parse(text) == nil)
        #expect(!ConnectionURLParser.isAcceptable(text))
    }

    @Test func emptyIsAcceptableButNotParsed() {
        #expect(ConnectionURLParser.parse("   ") == nil)
        #expect(ConnectionURLParser.isAcceptable(""))
    }

    @Test func draftUsesDefaultConnectionValues() {
        let empty = ConnectionURLParser.draft(from: nil)
        #expect(empty.name == "127.0.0.1:6379")
        #expect(empty.host == "127.0.0.1")
        #expect(empty.port == 6379)
        #expect(empty.username == "default")
        #expect(empty.password == nil)
        #expect(empty.timeoutMs == 30_000)
        #expect(!empty.tls.enabled)

        let parsed = ConnectionURLParser.parse("rediss://bob:pw@db.example.com:6400/3")
        let draft = ConnectionURLParser.draft(from: parsed)
        #expect(draft.name == "db.example.com:6400")
        #expect(draft.username == "bob")
        #expect(draft.password == "pw")
        #expect(draft.db == 3)
        #expect(draft.tls.enabled)
    }
}

struct NetstatParserTests {
    @Test func extractsListeningPortsOnce() {
        let output = """
            Active Internet connections (including servers)
            Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
            tcp4       0      0  127.0.0.1.6390         *.*                    LISTEN
            tcp46      0      0  *.6390                 *.*                    LISTEN
            tcp6       0      0  ::1.8080               *.*                    LISTEN
            tcp4       0      0  192.168.1.4.52000      17.1.2.3.443           ESTABLISHED
            tcp4       0      0  *.22                   *.*                    LISTEN
            """
        #expect(NetstatParser.listeningPorts(output) == [6390, 8080, 22])
    }

    @Test func ignoresGarbage() {
        #expect(NetstatParser.listeningPorts("LISTEN\nfoo bar baz qux LISTEN\n").isEmpty)
    }
}

struct ImportPayloadTests {
    @Test func keepsPlainJSON() {
        let json = Data(#"[{"host":"a","port":1}]"#.utf8)
        #expect(ImportPayload.normalize(json) == json)
    }

    @Test func decodesBase64JSON() {
        let json = Data(#"[{"host":"a","port":1}]"#.utf8)
        let encoded = Data(json.base64EncodedString().utf8)
        #expect(ImportPayload.normalize(encoded) == json)
    }

    @Test func leavesUnparseableDataAlone() {
        let junk = Data("not json, not base64 !!!".utf8)
        #expect(ImportPayload.normalize(junk) == junk)
    }
}

struct TagValidationTests {
    @Test func sanitizesInput() {
        #expect(TagValidation.sanitizeInput("  Env") == "env")
        #expect(TagValidation.sanitizeInput("Team A") == "team a")
    }

    @Test func validatesKeys() {
        #expect(TagValidation.keyError("env", otherKeys: []) == nil)
        #expect(TagValidation.keyError("", otherKeys: []) == nil)
        #expect(TagValidation.keyError(String(repeating: "k", count: 65), otherKeys: []) == TagValidation.keyLengthMessage)
        #expect(TagValidation.keyError("bad/key", otherKeys: []) == TagValidation.charactersMessage)
        #expect(TagValidation.keyError("env", otherKeys: ["env"]) == TagValidation.uniqueKeyMessage)
        #expect(TagValidation.keyError("a-b_c.d@e:f+g h", otherKeys: []) == nil)
    }

    @Test func validatesValues() {
        #expect(TagValidation.valueError(String(repeating: "v", count: 128)) == nil)
        #expect(TagValidation.valueError(String(repeating: "v", count: 129)) == TagValidation.valueLengthMessage)
        #expect(TagValidation.valueError("ok?") == TagValidation.charactersMessage)
    }
}

@MainActor
struct TagEditorModelTests {
    @Test func editingAndSaving() {
        let model = TagEditorModel(databaseName: "db", tags: [DatabaseTag(key: "env", value: "prod")],
                                   knownTags: [DatabaseTag(key: "team", value: "core")])
        #expect(!model.canSave)
        model.addRow()
        let newRow = model.rows[1]
        #expect(!model.isValueEnabled(newRow))
        model.setKey("Team", for: newRow.id)
        #expect(model.rows[1].key == "team")
        #expect(model.isValueEnabled(model.rows[1]))
        #expect(model.valueSuggestions(for: model.rows[1]) == ["core"])
        #expect(!model.keySuggestions(for: model.rows[1]).contains("env"))
        model.setValue("Core", for: newRow.id)
        #expect(model.canSave)
        #expect(model.resultTags == [DatabaseTag(key: "env", value: "prod"), DatabaseTag(key: "team", value: "core")])
    }

    @Test func duplicateKeysBlockSaving() {
        let model = TagEditorModel(databaseName: "db", tags: [])
        let first = model.rows[0].id
        model.setKey("env", for: first)
        model.setValue("a", for: first)
        model.addRow()
        let second = model.rows[1].id
        model.setKey("env", for: second)
        #expect(model.keyError(for: model.rows[1]) == TagValidation.uniqueKeyMessage)
        #expect(!model.canSave)
    }

    @Test func emptyRowsAreDroppedAndRemovingLastRowKeepsOne() {
        let model = TagEditorModel(databaseName: "db", tags: [DatabaseTag(key: "a", value: "b")])
        model.addRow()
        #expect(model.resultTags.count == 1)
        model.removeRow(model.rows[0].id)
        model.removeRow(model.rows[0].id)
        #expect(model.rows.count == 1)
        #expect(model.resultTags.isEmpty)
        #expect(model.canSave)
    }
}

struct CertificateNameTests {
    @Test func sanitizesCertificateNames() {
        #expect(TLSFormModel.sanitizeCertificateName("My CA (prod) #1/é") == "My CA (prod) #1")
        #expect(TLSFormModel.sanitizeCertificateName(String(repeating: "a", count: 300)).count == 200)
    }
}

struct SoftwareAPIParseTests {
    @Test func parsesExternalEndpointsAndOptions() throws {
        let json = """
            [
              {"uid": 2, "name": "beta", "status": "active", "tls_mode": "enabled",
               "endpoints": [{"addr_type": "internal", "dns_name": "int", "addr": ["10.0.0.1"], "port": 1},
                             {"addr_type": "external", "dns_name": "beta.cluster", "addr": ["1.2.3.4"], "port": 12000}],
               "module_list": [{"module_name": "ReJSON", "semantic_version": "2.6.0"}, {"module_name": "gears"}],
               "data_persistence": "aof", "aof_policy": "appendfsync-every-sec", "shards_count": 2,
               "replication": true, "authentication_redis_pass": "pw",
               "tags": [{"key": "team", "value": "core"}]},
              {"uid": 1, "name": "alpha", "crdt": true, "crdt_replica_id": 3, "status": "active",
               "endpoints": [{"addr_type": "external", "dns_name": "alpha.cluster", "addr": ["5.6.7.8"], "port": 13000}],
               "replica_sources": [{"uri": "redis://:pw@beta.cluster:12000"}],
               "data_persistence": "snapshot", "snapshot_policy": [{"secs": 21600}]},
              {"uid": 3, "name": "hidden", "endpoints": [{"addr_type": "internal", "port": 1}]}
            ]
            """
        let databases = SoftwareAPI.parse(Data(json.utf8))
        #expect(databases.map(\.name) == ["alpha-3", "beta"])
        let alpha = databases[0]
        #expect(alpha.options.contains(.activeActive))
        #expect(alpha.options.contains(.replicaDestination))
        #expect(alpha.tooltip(for: .persistence) == "RDB snapshot every 6 hours")
        let beta = databases[1]
        #expect(beta.tls)
        #expect(beta.endpoint == "beta.cluster:12000")
        #expect(beta.password == "pw")
        #expect(beta.modules.map(\.name) == ["ReJSON", "rg"])
        #expect(beta.options.contains(.clustering))
        #expect(beta.options.contains(.replicaSource))
        #expect(beta.tooltip(for: .persistence) == "AOF, fsync every second")
        #expect(beta.tags == [DatabaseTag(key: "team", value: "core")])
    }

    @Test func invalidPayloadIsEmpty() {
        #expect(SoftwareAPI.parse(Data("{}".utf8)).isEmpty)
    }
}
