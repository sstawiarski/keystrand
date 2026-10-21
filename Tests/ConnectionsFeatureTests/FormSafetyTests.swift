import Foundation
@testable import ConnectionsFeature
import RedisCore
import Synchronization
import TestSupport
import Testing

/// Secret store whose reads can be made to fail (a denied Keychain prompt).
private final class FlakySecretStore: SecretStore, Sendable {
    private struct State {
        var values: [String: String] = [:]
        var failing = false
    }

    private let state = Mutex(State())

    var failReads: Bool {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }

    func secret(for account: String) throws -> String? {
        try state.withLock { state in
            if state.failing { throw SecretStoreError.keychain(-25293) }
            return state.values[account]
        }
    }

    func setSecret(_ value: String?, for account: String) throws {
        state.withLock { $0.values[account] = value }
    }
}

@MainActor
struct SecretFieldBehaviorTests {
    @Test func focusingAndLeavingKeepsStoredSecret() {
        var secret = SecretInput(stored: "hunter2")
        secret.beginEditing()
        #expect(!secret.isStored)
        #expect(secret.value == "hunter2")
        secret.endEditing()
        #expect(secret.isStored)
        #expect(secret.value == "hunter2")
        #expect(!secret.isEdited)
    }

    @Test func typingThenDeletingClearsDeliberately() {
        var secret = SecretInput(stored: "hunter2")
        secret.beginEditing()
        secret.text = "a"
        secret.text = ""
        secret.endEditing()
        #expect(!secret.isStored)
        #expect(secret.isEdited)
        #expect(secret.value == nil)
    }

    @Test func replaceDiscardsStoredValue() {
        var secret = SecretInput(stored: "-----BEGIN KEY-----")
        secret.replace()
        #expect(secret.isEdited)
        #expect(secret.value == nil)
        secret.endEditing()
        #expect(!secret.isStored)
    }

    @Test func emptyInputIsUntouched() {
        #expect(!SecretInput(text: "").isEdited)
        #expect(SecretInput(text: "pw").isEdited)
    }

    @Test func savedSecretFieldKeepsValueUntilTyping() {
        let stored = SecretInput(stored: "hunter2")
        let untouched = StoredSecretField.updated(stored, typed: "")
        #expect(untouched.isStored)
        #expect(untouched.value == "hunter2")
        let typed = StoredSecretField.updated(stored, typed: "x")
        #expect(!typed.isStored)
        #expect(typed.value == "x")
        let cleared = StoredSecretField.updated(typed, typed: "")
        #expect(cleared.isEdited)
        #expect(cleared.value == nil)
        #expect(StoredSecretField.updated(SecretInput(text: ""), typed: "pw").value == "pw")
    }
}

@MainActor
@Suite(.serialized)
struct EditFormSecretSafetyTests {
    private func services(_ secrets: any SecretStore) -> AppServices {
        AppServices(paths: .temporary(), secrets: secrets)
    }

    private func storedConfig() -> DatabaseConfig {
        DatabaseConfig(name: "Secure", host: "10.9.9.9", port: 6400, password: "db-pw", connectionType: .standalone,
                       isNew: false, ssh: SSHOptions(host: "jump", username: "me", auth: .password("ssh-pw")))
    }

    @Test func editWaitsForStoredSecretsBeforeSaving() async throws {
        let services = services(InMemorySecretStore())
        try await services.databaseStore.create(storedConfig())
        let listed = try #require(try await services.databaseStore.list().first)
        let model = DatabaseFormModel(mode: .edit(listed), services: services)
        #expect(!model.isPrepared)
        #expect(!model.canSubmit)
        #expect(model.actionDisabledReason == "Loading the stored credentials…")
        guard case .failed = await model.submit() else {
            Issue.record("submit must wait for prepare")
            return
        }
        #expect(try await services.databaseStore.get(listed.id).password == "db-pw")
    }

    @Test func aliasOnlyEditKeepsEverySecret() async throws {
        let services = services(InMemorySecretStore())
        let config = storedConfig()
        try await services.databaseStore.create(config)
        let listed = try #require(try await services.databaseStore.list().first)
        let model = DatabaseFormModel(mode: .edit(listed), services: services)
        await model.prepare()
        #expect(model.isPrepared)
        #expect(model.canSubmit)
        #expect(model.password.isStored)
        #expect(model.sshPassword.isStored)
        model.password.beginEditing()
        model.password.endEditing()
        model.name = "Renamed"
        guard case .saved = await model.submit() else {
            Issue.record("save failed: \(String(describing: model.error))")
            return
        }
        let stored = try await services.databaseStore.get(config.id)
        #expect(stored.name == "Renamed")
        #expect(stored.password == "db-pw")
        #expect(stored.ssh?.auth == .password("ssh-pw"))
    }

    @Test func unreadableSecretsBlockSavingUntilRetried() async throws {
        let secrets = FlakySecretStore()
        let services = services(secrets)
        let config = storedConfig()
        try await services.databaseStore.create(config)
        let listed = try #require(try await services.databaseStore.list().first)
        secrets.failReads = true
        let model = DatabaseFormModel(mode: .edit(listed), services: services)
        await model.prepare()
        #expect(model.isPrepared)
        #expect(model.secretsLoadError != nil)
        #expect(model.error == model.secretsLoadError)
        #expect(!model.canSubmit)
        model.name = "Changed"
        guard case .failed = await model.submit() else {
            Issue.record("submit must be blocked")
            return
        }
        secrets.failReads = false
        #expect(try await services.databaseStore.get(config.id).password == "db-pw")
        #expect(try await services.databaseStore.get(config.id).name == "Secure")

        await model.loadStoredSecrets()
        #expect(model.secretsLoadError == nil)
        #expect(model.error == nil)
        #expect(model.canSubmit)
        #expect(model.password.value == "db-pw")
        #expect(model.name == "Changed")
    }

    @Test func untouchedSecretsAreMergedFromStore() {
        let stored = DatabaseConfig(name: "s", password: "pw", connectionType: .sentinel,
                                    sentinelMaster: SentinelMasterConfig(name: "m", password: "mpw"),
                                    ssh: SSHOptions(host: "h", username: "u", auth: .privateKey(pem: "PEM", passphrase: "pp")))
        var draft = stored
        draft.password = nil
        draft.sentinelMaster?.password = nil
        draft.ssh?.auth = .privateKey(pem: nil, passphrase: nil)

        let merged = DatabaseFormModel.mergingUntouchedSecrets(draft, stored: stored, edits: SecretEdits())
        #expect(merged.password == "pw")
        #expect(merged.sentinelMaster?.password == "mpw")
        #expect(merged.ssh?.auth == .privateKey(pem: "PEM", passphrase: "pp"))

        let cleared = DatabaseFormModel.mergingUntouchedSecrets(
            draft, stored: stored,
            edits: SecretEdits(password: true, sentinelPassword: true, sshPrivateKey: true, sshPassphrase: true))
        #expect(cleared.password == nil)
        #expect(cleared.sentinelMaster?.password == nil)
        #expect(cleared.ssh?.auth == .privateKey(pem: nil, passphrase: nil))

        var typed = draft
        typed.password = "new"
        #expect(DatabaseFormModel.mergingUntouchedSecrets(typed, stored: stored, edits: SecretEdits()).password == "new")

        var switched = draft
        switched.ssh?.auth = .password(nil)
        #expect(DatabaseFormModel.mergingUntouchedSecrets(switched, stored: stored, edits: SecretEdits()).ssh?.auth
            == .password(nil))
    }

    @Test func cloneOfUnsavedConfigKeepsItsSecrets() async throws {
        let services = services(InMemorySecretStore())
        let unsaved = DatabaseConfig(name: "Prefilled", host: "10.1.1.1", port: 6379, password: "given",
                                     connectionType: .standalone)
        let model = DatabaseFormModel(mode: .clone(unsaved), services: services)
        await model.prepare()
        #expect(model.secretsLoadError == nil)
        #expect(model.canSubmit)
        guard case .saved(let saved) = await model.submit() else {
            Issue.record("save failed: \(String(describing: model.error))")
            return
        }
        #expect(try await services.databaseStore.get(saved.id).password == "given")
    }

    @Test func editOfMissingDatabaseBlocksSaving() async {
        let model = DatabaseFormModel(mode: .edit(DatabaseConfig(name: "gone", connectionType: .standalone)),
                                      services: services(InMemorySecretStore()))
        await model.prepare()
        #expect(model.secretsLoadError != nil)
        #expect(!model.canSubmit)
    }

    @Test func addModeIsReadyImmediately() {
        let model = DatabaseFormModel(mode: .add, services: services(InMemorySecretStore()))
        #expect(model.isPrepared)
        model.name = "x"
        #expect(model.canSubmit)
        #expect(model.actionDisabledReason == nil)
    }
}

@MainActor
struct FormModeSwitchResetTests {
    @Test func cloneAndBackResetUnsavedSecurityEdits() {
        let original = DatabaseConfig(name: "plain", host: "db", port: 6379, connectionType: .standalone, isNew: false)
        let model = DatabaseFormModel(mode: .edit(original), services: RedisTestServer.makeServices())
        model.useSSH = true
        model.sshHost = "bastion"
        model.sshUsername = "me"
        model.sshAuthMode = .privateKey
        model.sshPrivateKey = SecretInput(text: "KEY")
        model.tls.enabled = true
        model.tls.caChoice = .addNew
        model.tls.newCAName = "Root"
        model.tls.newCACertificate = "pem"
        model.sentinelMasterName = "leak"

        model.switchToClone()
        #expect(!model.useSSH)
        #expect(model.sshHost.isEmpty)
        #expect(model.sshUsername.isEmpty)
        #expect(model.sshAuthMode == .password)
        #expect(model.sshPrivateKey.isEmpty)
        #expect(!model.tls.enabled)
        #expect(model.tls.caChoice == .none)
        #expect(model.tls.newCAName.isEmpty)
        #expect(model.tls.newCACertificate.isEmpty)
        #expect(model.sentinelMasterName.isEmpty)
        #expect(model.buildDraft().ssh == nil)

        model.useSSH = true
        model.sshHost = "clone-only"
        model.switchToEdit()
        #expect(!model.useSSH)
        #expect(model.sshHost.isEmpty)
        #expect(model.buildDraft().ssh == nil)
    }
}

@MainActor
struct SentinelAddFailureTests {
    @Test func certificateFailureStaysOnDiscovery() async throws {
        let services = RedisTestServer.makeServices()
        _ = try await services.certificateStore.addCA(CACertificate(name: "Root", certificate: "pem"))
        let model = SentinelFlowModel(services: services)
        await model.certificates.load()
        model.tls.enabled = true
        model.tls.caChoice = .addNew
        model.tls.newCAName = "Root"
        model.tls.newCACertificate = "pem"
        model.rows = [SentinelFlowModel.Row(id: "1", master: SentinelMasterInfo(name: "alpha", host: "10.0.0.1", port: 6379)),
                      SentinelFlowModel.Row(id: "2", master: SentinelMasterInfo(name: "beta", host: "10.0.0.2", port: 6379))]
        model.rows[0].isSelected = true
        model.stage = .discovery

        await model.addSelected()
        #expect(model.stage == .discovery)
        #expect(model.error?.title == "Certificate Error")
        #expect(model.rows.count == 2)
        #expect(model.rows.allSatisfy { $0.result == nil })
        #expect(try await services.databaseStore.list().isEmpty)
    }
}

@MainActor
struct HomeSidebarFilterTests {
    @Test func sidebarFiltersNarrowTheTable() async throws {
        let services = RedisTestServer.makeServices()
        let core = DatabaseTag(key: "team", value: "core")
        let web = DatabaseTag(key: "app", value: "web")
        var alpha = DatabaseConfig(name: "alpha", connectionType: .standalone, tags: [core])
        alpha.environment = .production
        alpha.lastConnection = Date()
        var beta = DatabaseConfig(name: "beta", connectionType: .standalone, tags: [web])
        beta.environment = .development
        let gamma = DatabaseConfig(name: "gamma", connectionType: .standalone)
        for config in [alpha, beta, gamma] { try await services.databaseStore.create(config) }
        let model = DatabaseListViewModel(services: services)
        await model.reload()
        #expect(model.subtitle == "3 databases")
        #expect(model.count(for: .recents) == 1)
        #expect(model.count(for: .production) == 1)
        #expect(model.hasProduction && model.hasDevelopment)

        model.filters = [.all, .production]
        #expect(model.filters == [.production])
        #expect(model.visibleDatabases.map(\.name) == ["alpha"])
        #expect(model.subtitle == "1 of 3 databases")

        model.filters = [.production, .tag(core)]
        #expect(model.filters == [.tag(core)])
        model.filters = [.tag(core), .tag(web)]
        #expect(Set(model.visibleDatabases.map(\.name)) == ["alpha", "beta"])

        model.filters = []
        #expect(model.filters == [.all])
        model.selection = Set(model.databases.prefix(2).map(\.id))
        #expect(model.subtitle == "2 selected")
        #expect(model.actionTargets.count == 2)

        model.selection = Set(model.databases.map(\.id))
        model.filters = [.production]
        #expect(model.selection == [alpha.id])
        #expect(model.actionTargets.map(\.name) == ["alpha"])
        model.filters = [.all]
        model.selection = Set(model.databases.map(\.id))
        model.searchText = "gam"
        #expect(model.actionTargets.map(\.name) == ["gamma"])
        #expect(model.selection == [gamma.id])
    }

    @Test func environmentSortStaysOutOfSettings() async throws {
        let services = RedisTestServer.makeServices()
        var prod = DatabaseConfig(name: "b-prod", connectionType: .standalone)
        prod.environment = .production
        let plain = DatabaseConfig(name: "a-plain", connectionType: .standalone)
        for config in [prod, plain] { try await services.databaseStore.create(config) }
        let model = DatabaseListViewModel(services: services)
        await model.reload()
        let saved = services.settings.ui.homeSorting
        model.setSort(.environment, ascending: true)
        #expect(model.visibleDatabases.map(\.name) == ["b-prod", "a-plain"])
        #expect(services.settings.ui.homeSorting == saved)
        model.sort(by: .environment)
        #expect(!model.sortAscending)
        #expect(model.visibleDatabases.map(\.name) == ["a-plain", "b-prod"])
        model.setSort(.name, ascending: true)
        #expect(model.sortField == .name)
        #expect(services.settings.ui.homeSorting == HomeSorting(field: .name, direction: .asc))
    }

    @Test func comparatorFollowsListLogic() {
        let a = DatabaseConfig(name: "a")
        let b = DatabaseConfig(name: "b")
        #expect(HomeComparator(field: .name).compare(a, b) == .orderedAscending)
        #expect(HomeComparator(field: .name, order: .reverse).compare(a, b) == .orderedDescending)
    }
}

@MainActor
struct DeepLinkTests {
    private func link(_ string: String) throws -> DatabaseDeepLink {
        let url = try #require(URL(string: string))
        return try #require(DatabaseDeepLink.parse(url))
    }

    @Test func parsesConnectLink() throws {
        let url = try #require(URL(string:
            "keystrand://databases/connect?redisUrl=redis%3A%2F%2Fbob%3Apw%40cache.example.com%3A6400%2F2&databaseAlias=Cache&redirect=workbench"))
        let link = try #require(DatabaseDeepLink.parse(url))
        #expect(link.redisURL.host == "cache.example.com")
        #expect(link.redisURL.port == 6400)
        #expect(link.redisURL.username == "bob")
        #expect(link.redisURL.password == "pw")
        #expect(link.alias == "Cache")
        #expect(link.redirect == "workbench")
        #expect(link.canAutoConnect)
        let draft = link.draft()
        #expect(draft.name == "Cache")
        #expect(draft.db == 2)
        #expect(draft.password == "pw")
        #expect(HomeCommandCenter.canHandle(url))
    }

    @Test func rejectsOtherLinks() throws {
        #expect(DatabaseDeepLink.parse(URL(string: "keystrand://open?redirect=x")!) == nil)
        #expect(DatabaseDeepLink.parse(URL(string: "https://databases/connect?redisUrl=redis://a:b@h:1")!) == nil)
        #expect(DatabaseDeepLink.parse(URL(string: "keystrand://databases/connect?redisUrl=ftp://x")!) == nil)
    }

    @Test func missingCredentialsOrTLSPrefillTheForm() throws {
        let noPassword = try link("keystrand://databases/connect?redisUrl=redis://default@h.example:6379")
        #expect(!noPassword.canAutoConnect)
        #expect(noPassword.databaseName == "h.example:6379")

        let tlsLink = try link("keystrand://databases/connect?redisUrl=redis://u:p@secure.example:6380&requiredTls=true&requiredCaCert=true&requiredClientCert=true")
        #expect(tlsLink.requiresCertificateFields)
        #expect(!tlsLink.canAutoConnect)

        let flow = AddDatabaseFlowModel(services: RedisTestServer.makeServices(), initialScreen: .form, deepLink: tlsLink)
        #expect(flow.screen == .form)
        let form = flow.form
        #expect(form.name == "secure.example:6380")
        #expect(form.host == "secure.example")
        #expect(form.port == "6380")
        #expect(form.username == "u")
        #expect(form.password.value == "p")
        #expect(form.tls.enabled)
        #expect(form.tls.caChoice == .addNew)
        #expect(form.tls.requiresClientAuth)
        #expect(form.tls.clientChoice == .addNew)
    }

    @Test func matchesExistingDatabase() throws {
        let deepLink = try link("keystrand://databases/connect?redisUrl=redis://default:pw@Cache.Example:6379")
        let same = DatabaseConfig(name: "x", host: "cache.example", port: 6379, username: "default")
        let otherDB = DatabaseConfig(name: "y", host: "cache.example", port: 6379, db: 3, username: "default")
        #expect(deepLink.matchingDatabase(in: [otherDB, same])?.id == same.id)
        #expect(deepLink.matchingDatabase(in: [otherDB]) == nil)
    }

    @Test func newDatabaseLinkConfirmationDescribesTheLink() throws {
        let link = try link("keystrand://databases/connect?redisUrl=rediss://u:p@cache.example:6380/4&databaseAlias=Cache&redirect=workbench")
        let confirmation = DeepLinkConfirmation(link: link, match: nil)
        #expect(!confirmation.isSaved)
        #expect(!confirmation.runsScript)
        #expect(confirmation.usesTLS)
        #expect(confirmation.databaseName == "Cache")
        #expect(confirmation.endpoint == "cache.example:6380 (database 4)")
        #expect(confirmation.redirect == "workbench")
        #expect(confirmation.title == "Connect to “Cache”?")
        #expect(confirmation.message == "This link adds a database at cache.example:6380 (database 4) and connects to it. "
            + "The connection uses TLS. Then it opens “workbench”. Connect only if you trust where the link came from.")
    }

    @Test func savedDatabaseWithScriptConfirmationWarnsAboutTheScript() throws {
        let link = try link("keystrand://databases/connect?redisUrl=redis://default:pw@cache.example:6379&databaseAlias=Other")
        var saved = DatabaseConfig(name: "Saved Cache", host: "cache.example", port: 6379, username: "default")
        saved.preConnectScript = "ssh -fN tunnel"
        let confirmation = DeepLinkConfirmation(link: link, match: link.matchingDatabase(in: [saved]))
        #expect(confirmation.isSaved)
        #expect(confirmation.matchID == saved.id)
        #expect(confirmation.runsScript)
        #expect(!confirmation.usesTLS)
        #expect(confirmation.databaseName == "Saved Cache")
        #expect(confirmation.endpoint == "cache.example:6379")
        #expect(confirmation.redirect == nil)
        #expect(confirmation.message.contains("opens the saved database at cache.example:6379"))
        #expect(confirmation.message.contains("runs a connection script"))
        #expect(confirmation.message.contains("does not use TLS"))

        saved.preConnectScript = "  \n"
        saved.postDisconnectScript = "echo done"
        #expect(DeepLinkConfirmation(link: link, match: saved).runsScript)
        saved.postDisconnectScript = nil
        #expect(!DeepLinkConfirmation(link: link, match: saved).runsScript)
    }

    @Test func linkCannotCarryConnectionScriptsOrSSH() throws {
        let link = try link("keystrand://databases/connect?redisUrl=redis://u:p@h.example:6379"
            + "&preConnectScript=touch%20%2Ftmp%2Fx&postDisconnectScript=touch%20%2Ftmp%2Fy&ssh=true&sshHost=evil")
        let draft = link.draft()
        #expect(draft.preConnectScript == nil)
        #expect(draft.postDisconnectScript == nil)
        #expect(draft.ssh == nil)
        #expect(!DeepLinkConfirmation(link: link, match: nil).runsScript)
    }

    @Test func certificateLinkOnlyPrefillsTheForm() async throws {
        let services = RedisTestServer.makeServices()
        let link = try link("keystrand://databases/connect?redisUrl=redis://u:p@127.0.0.1:1&requiredTls=true")
        #expect(!link.canAutoConnect)
        let flow = AddDatabaseFlowModel(services: services, initialScreen: .form, deepLink: link)
        #expect(flow.screen == .form)
        #expect(!flow.isTesting && !flow.isAdding && !flow.form.isWorking)
        #expect(flow.form.preConnectScript.isEmpty && flow.form.postDisconnectScript.isEmpty)
        #expect(try await services.databaseStore.list().isEmpty)
    }

    @Test func providerLabels() {
        #expect(DatabaseListLogic.providerLabel(nil) == nil)
        #expect(DatabaseListLogic.providerLabel(.unknown) == nil)
        #expect(DatabaseListLogic.providerLabel(.awsElastiCache) == "AWS ElastiCache")
        for provider in HostingProvider.allCases where provider != .unknown {
            #expect(DatabaseListLogic.providerLabel(provider)?.isEmpty == false)
        }
    }
}

@MainActor
@Suite(.tags(.live), RedisTestServer.live(.redis), .serialized)
struct LiveDeepLinkTests {
    @Test func deepLinkCreatesThenReusesDatabase() async throws {
        let services = RedisTestServer.makeServices()
        let url = try #require(URL(string:
            "keystrand://databases/connect?redisUrl=redis://default@127.0.0.1:\(RedisTestServer.port)/\(RedisTestServer.DB.connections)&databaseAlias=Linked"))
        let link = try #require(DatabaseDeepLink.parse(url))
        let model = DatabaseListViewModel(services: services)
        var opened: [DatabaseConfig] = []
        let first = await model.confirmation(for: link)
        #expect(!first.isSaved)
        await model.connect(first, onOpen: { opened.append($0) })
        let created = try #require(opened.first)
        #expect(created.name == "Linked")
        #expect(created.connectionType == .standalone)
        #expect(created.db == RedisTestServer.DB.connections)

        let second = await model.confirmation(for: link)
        #expect(second.matchID == created.id)
        await model.connect(second, onOpen: { opened.append($0) })
        #expect(opened.count == 2)
        #expect(opened.last?.id == created.id)
        #expect(try await services.databaseStore.list().count == 1)
        #expect(services.toasts.toasts.isEmpty)
        await services.sessions.close(created.id)
    }
}
