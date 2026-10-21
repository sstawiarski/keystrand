import Foundation
import Observation
import RedisCore

public enum DatabaseFormTab: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case security = "Security"
    case decompression = "Decompression & Formatters"

    public var id: String { rawValue }
}

public enum SSHAuthMode: String, CaseIterable, Identifiable, Sendable {
    case password = "Password"
    case privateKey = "Private Key"

    public var id: String { rawValue }
}

/// A secret input that can show the stored value as a mask. Only typing (or an explicit `replace()`) changes
/// the value; focusing or tabbing through the field keeps the stored secret.
public struct SecretInput: Equatable, Sendable {
    public static let mask = "••••••••••••"

    public var text: String {
        didSet {
            guard text != oldValue else { return }
            isStored = false
            isEdited = true
        }
    }

    /// The field shows the mask for a stored value.
    public private(set) var isStored: Bool
    /// The user typed or explicitly replaced the value.
    public private(set) var isEdited: Bool
    private var storedValue: String?

    public init(stored: String?) {
        let hasValue = !(stored ?? "").isEmpty
        self.text = ""
        self.isStored = hasValue
        self.isEdited = false
        self.storedValue = hasValue ? stored : nil
    }

    public init(text: String) {
        self.text = text
        self.isStored = false
        self.isEdited = !text.isEmpty
        self.storedValue = nil
    }

    /// Focusing a masked field hides the mask for re-entry; the stored value is kept until the user types.
    public mutating func beginEditing() {
        guard isStored else { return }
        isStored = false
    }

    /// Leaving the field without typing shows the mask again.
    public mutating func endEditing() {
        guard !isEdited, storedValue != nil else { return }
        isStored = true
    }

    /// Discards the stored value so a new one can be entered (an empty field then clears the secret).
    public mutating func replace() {
        text = ""
        isStored = false
        isEdited = true
    }

    /// The value to connect with / save (`nil` when empty).
    public var value: String? {
        guard isEdited else { return storedValue }
        return text.isEmpty ? nil : text
    }

    public var isEmpty: Bool { value == nil }
}

/// Which secret inputs the user changed; untouched secrets keep their stored Keychain values on save.
public struct SecretEdits: Equatable, Sendable {
    public var password = false
    public var sentinelPassword = false
    public var sshPassword = false
    public var sshPrivateKey = false
    public var sshPassphrase = false

    public init(password: Bool = false, sentinelPassword: Bool = false, sshPassword: Bool = false,
                sshPrivateKey: Bool = false, sshPassphrase: Bool = false) {
        self.password = password
        self.sentinelPassword = sentinelPassword
        self.sshPassword = sshPassword
        self.sshPrivateKey = sshPrivateKey
        self.sshPassphrase = sshPassphrase
    }
}

/// Outcome of submitting the form.
public enum DatabaseFormOutcome: Sendable {
    case saved(DatabaseConfig)
    /// The endpoint is a Sentinel: continue with discovery using this draft (name and db stripped).
    case sentinelRequired(DatabaseConfig)
    case failed
}

/// State and logic of the Add / Edit / Clone connection settings form.
@MainActor
@Observable
public final class DatabaseFormModel {
    public enum Kind: Sendable, Equatable { case add, edit, clone }

    public private(set) var kind: Kind
    /// Database being edited or cloned (secrets filled in when available).
    public private(set) var original: DatabaseConfig?

    public var tab: DatabaseFormTab = .general

    public var name = "" { didSet { let v = InputRules.limited(name, 500); if v != name { name = v } } }
    public var host = "" { didSet { let v = InputRules.compact(host, 200); if v != host { host = v } } }
    public var port = "6379"
    public var connectionFamily: ConnectionFamily = .auto
    public var username = "" { didSet { let v = InputRules.limited(username, 200); if v != username { username = v } } }
    public var password = SecretInput(text: "")
    public var timeoutSeconds = "30"
    public var selectLogicalDatabase = false { didSet { if !selectLogicalDatabase { dbIndex = "" } } }
    public var dbIndex = ""
    public var forceStandalone = false
    public var environment: DatabaseEnvironment = .unspecified

    public var sentinelMasterName = ""
    public var sentinelMasterUsername = ""
    public var sentinelMasterPassword = SecretInput(text: "")

    public let tls = TLSFormModel()
    public var useSSH = false
    public var sshHost = "" { didSet { let v = InputRules.compact(sshHost, 200); if v != sshHost { sshHost = v } } }
    public var sshPort = "22"
    public var sshUsername = "" { didSet { let v = InputRules.compact(sshUsername, 200); if v != sshUsername { sshUsername = v } } }
    public var sshAuthMode: SSHAuthMode = .password
    public var sshPassword = SecretInput(text: "")
    public var sshPrivateKey = SecretInput(text: "")
    public var sshPassphrase = SecretInput(text: "")

    public var preConnectScript = "" {
        didSet { let v = InputRules.limited(preConnectScript, 10_000); if v != preConnectScript { preConnectScript = v } }
    }

    public var postDisconnectScript = "" {
        didSet {
            let v = InputRules.limited(postDisconnectScript, 10_000)
            if v != postDisconnectScript { postDisconnectScript = v }
        }
    }

    public var decompressionEnabled = false
    public var compressor: Compressor = .gzip
    public var keyNameFormat: KeyNameFormat = .unicode

    public private(set) var isWorking = false
    public private(set) var isTesting = false
    public var error: ConnectionError?
    private var testedDraft: DatabaseConfig?
    /// Edit / clone: the stored secrets have been read (or reading failed). Saving waits for it.
    public private(set) var isPrepared: Bool
    /// Edit / clone: the stored secrets could not be read, so saving is blocked to keep them intact.
    public private(set) var secretsLoadError: ConnectionError?

    public let certificates: CertificateCatalog
    @ObservationIgnored public let services: AppServices
    @ObservationIgnored private var factory: DatabaseFactory

    public init(mode: DatabaseFormMode, services: AppServices) {
        self.services = services
        self.certificates = CertificateCatalog(services: services)
        self.factory = DatabaseFactory(clientFactory: services.clientFactory)
        if case .add = mode { isPrepared = true } else { isPrepared = false }
        switch mode {
        case .add:
            kind = .add
            original = nil
            name = ""
            host = "127.0.0.1"
            port = "6379"
            username = "default"
        case .edit(let config):
            kind = .edit
            original = config
            load(config)
        case .clone(let config):
            kind = .clone
            original = config
            load(config)
        }

        tls.sniDefault = { [weak self] in self?.host ?? "" }
    }

    // MARK: - Loading

    private func resetToDefaults() {
        name = ""
        host = ""
        port = "6379"
        connectionFamily = .auto
        username = ""
        password = SecretInput(text: "")
        timeoutSeconds = "30"
        selectLogicalDatabase = false
        dbIndex = ""
        forceStandalone = false
        environment = .unspecified
        sentinelMasterName = ""
        sentinelMasterUsername = ""
        sentinelMasterPassword = SecretInput(text: "")
        useSSH = false
        sshHost = ""
        sshPort = "22"
        sshUsername = ""
        sshAuthMode = .password
        sshPassword = SecretInput(text: "")
        sshPrivateKey = SecretInput(text: "")
        sshPassphrase = SecretInput(text: "")
        preConnectScript = ""
        postDisconnectScript = ""
        decompressionEnabled = false
        compressor = .gzip
        keyNameFormat = .unicode
        tls.load(TLSSettings())
    }

    private func load(_ config: DatabaseConfig) {
        resetToDefaults()
        name = config.name
        host = config.host
        port = String(config.port)
        connectionFamily = config.connectionFamily
        username = config.username ?? ""
        password = SecretInput(stored: config.password)
        timeoutSeconds = String(max(1, config.timeoutMs / 1000))
        selectLogicalDatabase = config.db != nil
        dbIndex = config.db.map(String.init) ?? ""
        forceStandalone = config.forceStandalone
        environment = config.environment
        if let master = config.sentinelMaster {
            sentinelMasterName = master.name
            sentinelMasterUsername = master.username ?? ""
            sentinelMasterPassword = SecretInput(stored: master.password)
        }

        tls.load(config.tls)
        if let ssh = config.ssh {
            useSSH = true
            sshHost = ssh.host
            sshPort = String(ssh.port)
            sshUsername = ssh.username
            switch ssh.auth {
            case .password(let value):
                sshAuthMode = .password
                sshPassword = SecretInput(stored: value)
            case .privateKey(let pem, let passphrase):
                sshAuthMode = .privateKey
                sshPrivateKey = SecretInput(stored: pem)
                sshPassphrase = SecretInput(stored: passphrase)
            }
        }

        preConnectScript = config.preConnectScript ?? ""
        postDisconnectScript = config.postDisconnectScript ?? ""
        decompressionEnabled = config.compressor != .none
        compressor = config.compressor == .none ? .gzip : config.compressor
        keyNameFormat = config.keyNameFormat
    }

    /// Loads certificates and stored secrets for edit or clone. Test and save wait for completion.
    public func prepare() async {
        await certificates.load()
        await loadStoredSecrets()
    }

    /// Reads the database's secrets from the store into every secret input the user has not changed.
    /// A failure blocks saving, so an unreadable Keychain item is never overwritten with an empty value.
    public func loadStoredSecrets() async {
        guard kind != .add, let original else {
            isPrepared = true
            return
        }
        do {
            if let full = try await storedDatabase(original.id) {
                self.original = full
                applyStoredSecrets(full)
            }
            if let secretsLoadError, error == secretsLoadError { error = nil }

            secretsLoadError = nil
        } catch {
            let loadError = Self.secretsLoadError(error)
            secretsLoadError = loadError
            self.error = loadError
        }

        isPrepared = true
    }

    /// The saved database with its secrets. A clone of an unsaved config (a prefilled deep link) has none.
    private func storedDatabase(_ id: DatabaseID) async throws -> DatabaseConfig? {
        do {
            return try await services.databaseStore.get(id)
        } catch DatabaseStoreError.notFound where kind == .clone {
            return nil
        }
    }

    private func applyStoredSecrets(_ full: DatabaseConfig) {
        if !password.isEdited { password = SecretInput(stored: full.password) }
        if !sentinelMasterPassword.isEdited, let master = full.sentinelMaster {
            sentinelMasterPassword = SecretInput(stored: master.password)
        }

        switch full.ssh?.auth {
        case .password(let value):
            if !sshPassword.isEdited { sshPassword = SecretInput(stored: value) }
        case .privateKey(let pem, let passphrase):
            if !sshPrivateKey.isEdited { sshPrivateKey = SecretInput(stored: pem) }
            if !sshPassphrase.isEdited { sshPassphrase = SecretInput(stored: passphrase) }
        case nil:
            break
        }
    }

    static func secretsLoadError(_ error: Error) -> ConnectionError {
        ConnectionError(code: .failed, title: "Stored Credentials Unavailable",
                        message: "The saved passwords could not be read (\(error.localizedDescription)). "
                            + "Saving is disabled so they are not overwritten. Retry to read them again.")
    }

    /// Switches an edit form to clone mode (values reset to the database's).
    public func switchToClone() {
        guard let original else { return }
        kind = .clone
        load(original)
        error = nil
        testedDraft = nil
    }

    /// Returns from clone mode to edit mode.
    public func switchToEdit() {
        guard let original else { return }
        kind = .edit
        load(original)
        error = nil
        testedDraft = nil
    }

    // MARK: - Derived state

    /// The last Test Connection succeeded and no field that affects the connection has changed since.
    public var testSucceeded: Bool {
        testedDraft.map { !Self.connectionFieldsChanged($0, buildDraft()) } ?? false
    }

    /// Sentinel-managed database (edit / clone show the Sentinel layout).
    public var isSentinelDatabase: Bool {
        guard kind != .add, let original else { return false }
        return original.connectionType == .sentinel || original.sentinelMaster != nil
    }

    public var title: String {
        switch kind {
        case .add: return "Connection Settings"
        case .edit: return "Edit Database"
        case .clone: return "Clone Database"
        }
    }

    public var submitTitle: String {
        switch kind {
        case .add: return "Add Database"
        case .edit: return "Save"
        case .clone: return "Clone Database"
        }
    }

    /// Logical database editing is offered when adding and cloning; edit shows it read-only.
    public var showsLogicalDatabase: Bool { kind != .edit }

    public var portValue: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (0...65_535).contains(value) else { return nil }
        return value
    }

    public var sshPortValue: Int? {
        guard let value = Int(sshPort.trimmingCharacters(in: .whitespaces)), (0...65_535).contains(value) else { return nil }
        return value
    }

    /// Timeout in ms (empty = 30000); nil when outside 1…1,000,000 seconds.
    public var timeoutMs: Int? {
        let text = timeoutSeconds.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 30_000 }
        guard let seconds = Int(text), (1...1_000_000).contains(seconds) else { return nil }
        return seconds * 1000
    }

    public var dbIndexValue: Int? {
        guard selectLogicalDatabase else { return nil }
        let text = dbIndex.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let value = Int(text), value >= 0 else { return nil }
        return value
    }

    /// Required fields by display name.
    public var missingFields: [String] {
        var missing: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("Alias") }
        if host.isEmpty { missing.append("Host") }
        if portValue == nil { missing.append("Port") }
        if timeoutMs == nil { missing.append("Timeout") }
        if selectLogicalDatabase && dbIndexValue == nil { missing.append("Database Index") }
        if isSentinelDatabase && sentinelMasterName.isEmpty { missing.append("Primary Group Name") }
        missing += tls.missingFields
        if useSSH {
            if sshHost.isEmpty { missing.append("SSH Host") }
            if sshPortValue == nil { missing.append("SSH Port") }
            if sshUsername.isEmpty { missing.append("SSH Username") }
            if sshAuthMode == .privateKey && sshPrivateKey.isEmpty { missing.append("SSH Private Key") }
        }

        return missing
    }

    public var isValid: Bool { missingFields.isEmpty }

    /// Test and save are allowed: the form is valid and the stored secrets are loaded.
    public var canSubmit: Bool { isValid && isPrepared && secretsLoadError == nil }

    /// Why Test Connection and the submit button are disabled, or nil.
    public var actionDisabledReason: String? {
        if let tooltip = requiredFieldsTooltip { return tooltip }
        if !isPrepared { return "Loading the stored credentials…" }
        if secretsLoadError != nil { return "The stored credentials could not be read. Retry before saving." }
        return nil
    }

    /// The secret inputs the user changed.
    public var secretEdits: SecretEdits {
        SecretEdits(password: password.isEdited, sentinelPassword: sentinelMasterPassword.isEdited,
                    sshPassword: sshPassword.isEdited, sshPrivateKey: sshPrivateKey.isEdited,
                    sshPassphrase: sshPassphrase.isEdited)
    }

    /// "Enter a value for required fields (N):" + up to five names.
    public var requiredFieldsTooltip: String? {
        Self.requiredFieldsTooltip(missingFields)
    }

    /// Footer warning: "Fill in the required fields: Host, Port." (up to five names).
    public var requiredFieldsMessage: String? {
        Self.requiredFieldsMessage(missingFields)
    }

    nonisolated public static func requiredFieldsMessage(_ missing: [String]) -> String? {
        guard !missing.isEmpty else { return nil }
        let listed = missing.prefix(5).joined(separator: ", ")
        let more = missing.count > 5 ? ", and \(missing.count - 5) more" : ""
        return "Fill in the required fields: \(listed)\(more)."
    }

    nonisolated public static func requiredFieldsTooltip(_ missing: [String]) -> String? {
        guard !missing.isEmpty else { return nil }
        var lines = ["Fill in the required fields (\(missing.count)):"]
        lines += missing.prefix(5)
        if missing.count > 5 { lines.append("…") }
        return lines.joined(separator: "\n")
    }

    // MARK: - URL autofill

    /// Prefills the form from a parsed connection URL (start screen "Connection settings").
    public func apply(_ parsed: ParsedRedisURL) {
        name = parsed.hostname
        host = parsed.host
        port = String(parsed.port ?? 6379)
        username = parsed.username.isEmpty ? "default" : parsed.username
        password = SecretInput(text: parsed.password)
        tls.enabled = parsed.tls
        if let db = parsed.db {
            selectLogicalDatabase = true
            dbIndex = String(db)
        }
    }

    /// Handles a connection URL pasted into Host. Returns true if the text was a URL.
    @discardableResult
    public func hostChanged(from old: String, to new: String) -> Bool {
        guard new.count - old.count > 1, new.contains(":") else { return false }
        let pasted = new.hasPrefix(old) ? String(new.dropFirst(old.count)) : new
        guard let parsed = ConnectionURLParser.parse(pasted) ?? ConnectionURLParser.parse(new) else { return false }
        name = parsed.hostname
        host = parsed.host
        port = String(parsed.port ?? Int(port) ?? 6379)
        if !parsed.username.isEmpty { username = parsed.username }
        if !parsed.password.isEmpty { password = SecretInput(text: parsed.password) }
        tls.enabled = parsed.tls
        if let db = parsed.db, kind != .edit {
            selectLogicalDatabase = true
            dbIndex = String(db)
        }

        useSSH = false
        return true
    }

    // MARK: - Building

    /// The config described by the form (secrets included, new certificates not yet referenced).
    public func buildDraft() -> DatabaseConfig {
        var config = original ?? DatabaseConfig(connectionType: .notConnected)
        if kind == .clone {
            config.id = DatabaseID()
            config.createdAt = Date()
            config.isNew = true
            config.lastConnection = nil
        }

        config.name = name.trimmingCharacters(in: .whitespaces)
        config.host = host
        config.port = portValue ?? config.port
        config.connectionFamily = connectionFamily
        config.username = username.isEmpty ? nil : username
        config.password = password.value
        config.timeoutMs = timeoutMs ?? 30_000
        if kind != .edit { config.db = dbIndexValue }
        config.forceStandalone = forceStandalone
        config.environment = environment
        if isSentinelDatabase {
            config.sentinelMaster = SentinelMasterConfig(
                name: sentinelMasterName, username: sentinelMasterUsername.isEmpty ? nil : sentinelMasterUsername,
                password: sentinelMasterPassword.value)
        }

        config.tls = tls.settings
        if useSSH {
            let auth: SSHAuth = sshAuthMode == .password
                ? .password(sshPassword.value)
                : .privateKey(pem: sshPrivateKey.value, passphrase: sshPassphrase.value)
            config.ssh = SSHOptions(host: sshHost, port: sshPortValue ?? 22, username: sshUsername, auth: auth)
        } else {
            config.ssh = nil
        }

        config.preConnectScript = ConnectionScriptRunner.runnable(preConnectScript) == nil ? nil : preConnectScript
        config.postDisconnectScript = ConnectionScriptRunner.runnable(postDisconnectScript) == nil ? nil : postDisconnectScript
        config.compressor = decompressionEnabled ? compressor : .none
        config.keyNameFormat = keyNameFormat
        if kind == .edit, let original, original.name == original.hostPort, config.name == original.name,
           config.endpoint != original.endpoint {
            config.name = config.hostPort
        }

        return config
    }

    /// Fills secrets the user did not touch (and that the draft lacks) from the stored database.
    nonisolated public static func mergingUntouchedSecrets(_ draft: DatabaseConfig, stored: DatabaseConfig,
                                                           edits: SecretEdits) -> DatabaseConfig {
        var merged = draft
        if !edits.password, merged.password == nil { merged.password = stored.password }
        if !edits.sentinelPassword, merged.sentinelMaster != nil, merged.sentinelMaster?.password == nil {
            merged.sentinelMaster?.password = stored.sentinelMaster?.password
        }

        if var ssh = merged.ssh {
            switch (ssh.auth, stored.ssh?.auth) {
            case (.password(nil), .password(let value)?) where !edits.sshPassword:
                ssh.auth = .password(value)
            case (.privateKey(let pem, let passphrase), .privateKey(let storedPEM, let storedPassphrase)?):
                ssh.auth = .privateKey(pem: pem ?? (edits.sshPrivateKey ? nil : storedPEM),
                                       passphrase: passphrase ?? (edits.sshPassphrase ? nil : storedPassphrase))
            default:
                break
            }

            merged.ssh = ssh
        }

        return merged
    }

    /// True when a field that affects how the client connects differs from the original (or there is no original).
    public static func connectionFieldsChanged(_ original: DatabaseConfig?, _ draft: DatabaseConfig) -> Bool {
        guard let original else { return true }
        return original.host != draft.host || original.port != draft.port
            || original.connectionFamily != draft.connectionFamily || original.db != draft.db
            || original.username != draft.username || original.password != draft.password
            || original.tls != draft.tls || original.sentinelMaster != draft.sentinelMaster
            || original.ssh != draft.ssh || original.preConnectScript != draft.preConnectScript
            || original.forceStandalone != draft.forceStandalone
    }

    // MARK: - Actions

    /// Connects with the form values (no save). Sentinel endpoints without master count as success.
    public func testConnection() async {
        guard canSubmit, !isWorking else { return }
        isWorking = true
        isTesting = true
        error = nil
        testedDraft = nil
        defer {
            isWorking = false
            isTesting = false
        }
        let draft = buildDraft()
        do {
            let certs = try await tls.resolveCertificates(services, catalog: certificates)
            try await factory.test(draft, caCertificate: certs.ca, clientCertificate: certs.client)
            testedDraft = draft
        } catch {
            self.error = Self.connectionError(error, endpoint: draft.endpoint)
        }
    }

    /// Detects the type, saves the database, and returns the saved config.
    public func submit() async -> DatabaseFormOutcome {
        guard canSubmit, !isWorking else { return .failed }
        isWorking = true
        error = nil
        defer { isWorking = false }
        var draft = buildDraft()
        do {
            if kind != .add, let original, let stored = try await storedDatabase(original.id) {
                draft = Self.mergingUntouchedSecrets(draft, stored: stored, edits: secretEdits)
            }
            let certs = try await tls.resolveCertificates(services, catalog: certificates)
            let needsDetection = kind == .add || tls.hasNewCertificates
                || Self.connectionFieldsChanged(original, draft)
            if needsDetection {
                if let original, original.endpoint != draft.endpoint { draft.provider = nil }
                draft = try await factory.createDetected(draft, caCertificate: certs.ca, clientCertificate: certs.client)
            }
            draft.tls = try await tls.persistNewCertificates(services, ca: certs.ca, client: certs.client)
            if kind != .edit { draft.isNew = true }
            try await services.saveDatabase(draft)
            original = kind == .edit ? draft : original
            return .saved(draft)
        } catch DatabaseFactoryError.sentinelMasterRequired where kind == .add {
            var sentinel = draft
            sentinel.db = nil
            return .sentinelRequired(sentinel)
        } catch {
            self.error = Self.connectionError(error, endpoint: draft.endpoint)
            return .failed
        }
    }

    static func connectionError(_ error: Error, endpoint: RedisEndpoint) -> ConnectionError {
        if let store = error as? CertificateStoreError {
            return ConnectionError(code: .failed, title: "Certificate Error", message: store.localizedDescription)
        }

        if let store = error as? DatabaseStoreError {
            return ConnectionError(code: .failed, title: "Error", message: store.localizedDescription)
        }

        if error is SecretStoreError {
            return ConnectionError(code: .failed, title: "Keychain Error", message: error.localizedDescription)
        }

        return ConnectionError.classify(error, endpoint: endpoint)
    }
}

/// Assign normalized values only if they changed, or observable `didSet` handlers recurse.
enum InputRules {
    static func limited(_ value: String, _ max: Int) -> String {
        value.count > max ? String(value.prefix(max)) : value
    }

    static func compact(_ value: String, _ max: Int) -> String {
        String(value.filter { !$0.isWhitespace }.prefix(max))
    }
}
