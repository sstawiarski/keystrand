import Foundation
@testable import ConnectionsFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct SecretInputTests {
    @Test func storedSecretIsKeptUntilEdited() {
        var secret = SecretInput(stored: "hunter2")
        #expect(secret.isStored)
        #expect(secret.text.isEmpty)
        #expect(secret.value == "hunter2")
        secret.beginEditing()
        #expect(!secret.isStored)
        #expect(secret.value == "hunter2")
        #expect(!secret.isEdited)
        secret.text = "new"
        #expect(secret.isEdited)
        #expect(secret.value == "new")
    }

    @Test func emptyStoredSecretIsNotStored() {
        #expect(!SecretInput(stored: "").isStored)
        #expect(!SecretInput(stored: nil).isStored)
        #expect(SecretInput(stored: nil).isEmpty)
    }
}

@MainActor
struct DatabaseFormModelTests {
    private func services() -> AppServices { RedisTestServer.makeServices() }

    @Test func addModeDefaults() {
        let model = DatabaseFormModel(mode: .add, services: services())
        #expect(model.title == "Connection Settings")
        #expect(model.submitTitle == "Add Database")
        #expect(model.host == "127.0.0.1")
        #expect(model.port == "6379")
        #expect(model.username == "default")
        #expect(model.timeoutMs == 30_000)
        #expect(model.missingFields == ["Alias"])
        #expect(model.requiredFieldsMessage == "Fill in the required fields: Alias.")
        #expect(!model.isValid)
        model.name = "Local"
        #expect(model.isValid)
        #expect(model.requiredFieldsTooltip == nil)
    }

    @Test func validationCoversPortsTimeoutSSHAndTLS() {
        let model = DatabaseFormModel(mode: .add, services: services())
        model.name = "x"
        model.host = "  my host  "
        #expect(model.host == "myhost")
        model.port = "70000"
        model.timeoutSeconds = "0"
        model.useSSH = true
        model.sshAuthMode = .privateKey
        model.tls.enabled = true
        model.tls.verifyServerCert = true
        model.tls.useSNI = true
        model.tls.servername = ""
        model.tls.requiresClientAuth = true
        let missing = model.missingFields
        for field in ["Port", "Timeout", "SSH Host", "SSH Username", "SSH Private Key", "Server Name",
                      "Client Certificate Name", "Client Certificate", "Private Key"] {
            #expect(missing.contains(field), "\(field) missing")
        }

        #expect(!missing.contains("SSH Port"))
        #expect(!missing.contains("CA Certificate"), "verification without a CA uses the system roots")
    }

    @Test func sniTogglePrefillsHost() {
        let model = DatabaseFormModel(mode: .add, services: services())
        model.host = "redis.example.com"
        model.tls.enabled = true
        model.tls.useSNI = true
        #expect(model.tls.servername == "redis.example.com")
        #expect(model.tls.settings.servername == "redis.example.com")
    }

    @Test func applyParsedURL() throws {
        let model = DatabaseFormModel(mode: .add, services: services())
        model.apply(try #require(ConnectionURLParser.parse("rediss://bob:pw@cache.example.com:6400/5")))
        #expect(model.name == "cache.example.com:6400")
        #expect(model.host == "cache.example.com")
        #expect(model.port == "6400")
        #expect(model.username == "bob")
        #expect(model.password.value == "pw")
        #expect(model.tls.enabled)
        #expect(model.selectLogicalDatabase)
        #expect(model.dbIndexValue == 5)
    }

    @Test func pastingURLIntoHostAutofills() {
        let model = DatabaseFormModel(mode: .add, services: services())
        model.useSSH = true
        let old = model.host
        model.host = "redis://alice:secret@10.0.0.5:7000"
        #expect(model.hostChanged(from: old, to: model.host))
        #expect(model.host == "10.0.0.5")
        #expect(model.port == "7000")
        #expect(model.username == "alice")
        #expect(model.password.value == "secret")
        #expect(model.name == "10.0.0.5:7000")
        #expect(!model.useSSH)
    }

    @Test func typingDoesNotAutofill() {
        let model = DatabaseFormModel(mode: .add, services: services())
        #expect(!model.hostChanged(from: "127.0.0.", to: "127.0.0.1"))
    }

    @Test func uncheckingLogicalDatabaseClearsIndex() {
        let model = DatabaseFormModel(mode: .add, services: services())
        model.selectLogicalDatabase = true
        model.dbIndex = "4"
        #expect(model.dbIndexValue == 4)
        model.selectLogicalDatabase = false
        #expect(model.dbIndex.isEmpty)
        #expect(model.dbIndexValue == nil)
    }

    @Test func buildDraftForAdd() {
        let model = DatabaseFormModel(mode: .add, services: services())
        model.name = "Primary"
        model.host = "db.local"
        model.port = "6390"
        model.username = ""
        model.password = SecretInput(text: "pw")
        model.timeoutSeconds = "5"
        model.selectLogicalDatabase = true
        model.dbIndex = "2"
        model.forceStandalone = true
        model.environment = .production
        model.decompressionEnabled = true
        model.compressor = .zstd
        model.keyNameFormat = .hex
        model.useSSH = true
        model.sshHost = "bastion"
        model.sshUsername = "me"
        model.sshAuthMode = .privateKey
        model.sshPrivateKey = SecretInput(text: "-----BEGIN OPENSSH PRIVATE KEY-----")
        model.sshPassphrase = SecretInput(text: "phrase")
        let draft = model.buildDraft()
        #expect(draft.name == "Primary")
        #expect(draft.host == "db.local")
        #expect(draft.port == 6390)
        #expect(draft.username == nil)
        #expect(draft.password == "pw")
        #expect(draft.timeoutMs == 5000)
        #expect(draft.db == 2)
        #expect(draft.forceStandalone)
        #expect(draft.environment == .production)
        #expect(draft.compressor == .zstd)
        #expect(draft.keyNameFormat == .hex)
        #expect(draft.ssh == SSHOptions(host: "bastion", port: 22, username: "me",
                                        auth: .privateKey(pem: "-----BEGIN OPENSSH PRIVATE KEY-----",
                                                          passphrase: "phrase")))
    }

    @Test func editKeepsStoredSecretsAndSyncsDefaultName() {
        let original = DatabaseConfig(name: "old.host:6379", host: "old.host", port: 6379, db: 3, password: "stored",
                                      connectionType: .standalone, isNew: false,
                                      ssh: SSHOptions(host: "jump", username: "u", auth: .password("sshpw")))
        let model = DatabaseFormModel(mode: .edit(original), services: services())
        #expect(model.title == "Edit Database")
        #expect(model.submitTitle == "Save")
        #expect(!model.showsLogicalDatabase)
        #expect(model.password.isStored)
        #expect(model.sshPassword.isStored)
        var draft = model.buildDraft()
        #expect(draft.id == original.id)
        #expect(draft.password == "stored")
        #expect(draft.ssh == original.ssh)
        #expect(draft.db == 3)
        #expect(!DatabaseFormModel.connectionFieldsChanged(original, draft))

        model.host = "new.host"
        draft = model.buildDraft()
        #expect(draft.name == "new.host:6379")
        #expect(DatabaseFormModel.connectionFieldsChanged(original, draft))

        model.environment = .development
        model.host = "old.host"
        draft = model.buildDraft()
        #expect(!DatabaseFormModel.connectionFieldsChanged(original, draft))
        #expect(draft.environment == .development)
    }

    @Test func turningOffSSHAndTLSClearsThem() {
        let original = DatabaseConfig(name: "x", connectionType: .standalone,
                                      tls: TLSSettings(enabled: true, verifyServerCert: true, caCertID: "ca1"),
                                      ssh: SSHOptions(host: "jump", username: "u"))
        let model = DatabaseFormModel(mode: .edit(original), services: services())
        #expect(model.tls.caChoice == .existing("ca1"))
        model.useSSH = false
        model.tls.enabled = false
        let draft = model.buildDraft()
        #expect(draft.ssh == nil)
        #expect(draft.tls == TLSSettings())
    }

    @Test func scriptsRoundTripAndBlankScriptsAreDropped() {
        let original = DatabaseConfig(name: "src", connectionType: .standalone,
                                      preConnectScript: "open-tunnel", postDisconnectScript: "close-tunnel")
        let model = DatabaseFormModel(mode: .edit(original), services: services())
        #expect(model.preConnectScript == "open-tunnel")
        #expect(model.postDisconnectScript == "close-tunnel")
        #expect(model.buildDraft().postDisconnectScript == "close-tunnel")
        model.postDisconnectScript = " \n "
        #expect(model.buildDraft().postDisconnectScript == nil)
        model.postDisconnectScript = String(repeating: "x", count: 10_001)
        #expect(model.postDisconnectScript.count == 10_000)
    }

    @Test func cloneGetsNewIdentity() {
        let original = DatabaseConfig(name: "src", db: 1, connectionType: .standalone,
                                      lastConnection: Date(), isNew: false)
        let model = DatabaseFormModel(mode: .edit(original), services: services())
        model.switchToClone()
        #expect(model.kind == .clone)
        #expect(model.title == "Clone Database")
        #expect(model.showsLogicalDatabase)
        let draft = model.buildDraft()
        #expect(draft.id != original.id)
        #expect(draft.isNew)
        #expect(draft.lastConnection == nil)
        #expect(draft.db == 1)
        model.switchToEdit()
        #expect(model.kind == .edit)
    }

    @Test func sentinelDatabaseRequiresPrimaryGroup() {
        let original = DatabaseConfig(name: "s", port: 26379, connectionType: .sentinel,
                                      sentinelMaster: SentinelMasterConfig(name: "mymaster", password: "mpw"))
        let model = DatabaseFormModel(mode: .edit(original), services: services())
        #expect(model.isSentinelDatabase)
        #expect(model.sentinelMasterPassword.isStored)
        #expect(model.buildDraft().sentinelMaster == original.sentinelMaster)
        model.sentinelMasterName = ""
        #expect(model.missingFields.contains("Primary Group Name"))
    }

    @Test func newCertificateRequirements() {
        let tls = TLSFormModel()
        tls.enabled = true
        tls.caChoice = .addNew
        #expect(tls.missingFields == ["CA Certificate Name", "CA certificate"])
        tls.newCAName = "My/CA"
        #expect(tls.newCAName == "MyCA")
        tls.newCACertificate = "-----BEGIN CERTIFICATE-----"
        #expect(tls.missingFields.isEmpty)
        #expect(tls.hasNewCertificates)
        tls.certificateDeleted(id: "other", isCA: true)
        #expect(tls.caChoice == .addNew)
        tls.caChoice = .existing("abc")
        tls.certificateDeleted(id: "abc", isCA: true)
        #expect(tls.caChoice == .none)
    }

    @Test func duplicateNewCertificateNameIsRejected() async throws {
        let services = services()
        _ = try await services.certificateStore.addCA(CACertificate(name: "Root", certificate: "-----BEGIN CERTIFICATE-----"))
        let catalog = CertificateCatalog(services: services)
        await catalog.load()
        #expect(catalog.caCertificates.map(\.name) == ["Root"])
        let tls = TLSFormModel()
        tls.enabled = true
        tls.caChoice = .addNew
        tls.newCAName = "Root"
        tls.newCACertificate = "pem"
        await #expect(throws: CertificateStoreError.duplicateCAName) {
            _ = try await tls.resolveCertificates(services, catalog: catalog)
        }
        tls.newCAName = "Second"
        let resolved = try await tls.resolveCertificates(services, catalog: catalog)
        let settings = try await tls.persistNewCertificates(services, ca: resolved.ca, client: resolved.client)
        #expect(settings.caCertID == resolved.ca?.id)
        await catalog.load()
        #expect(catalog.caCertificates.map(\.name) == ["Root", "Second"])
        let deleted = await catalog.delete(id: try #require(settings.caCertID), isCA: true)
        #expect(deleted)
        #expect(catalog.caCertificates.map(\.name) == ["Root"])
    }
}
