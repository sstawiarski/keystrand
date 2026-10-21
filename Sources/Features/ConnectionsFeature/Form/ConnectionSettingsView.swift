import RedisUI
import SwiftUI

struct ConnectionSettingsView: View {
    @Bindable var model: DatabaseFormModel
    var focusEnvironment = false
    /// Back to the Add Database start page (add mode only).
    var onBack: (@MainActor () -> Void)?
    let onCancel: @MainActor () -> Void
    let onSaved: @MainActor (DatabaseConfig) -> Void
    var onSentinelRequired: @MainActor (DatabaseConfig) -> Void = { _ in }

    @State private var startedAsEdit = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case alias, host, environment }

    static let idealHeight: CGFloat = 640

    static let forceStandaloneHelp =
        "Skips cluster and Sentinel detection and treats this endpoint as a single standalone server."

    static let environmentHelp = """
        Unspecified: the usual confirmations. \
        Production: also confirms every data change and asks you to type the database name before dangerous \
        commands. Development: data changes skip the usual confirmations.
        """

    static let preConnectHelp =
        "A shell command run in your login shell before connecting. If it exits with a nonzero status, the connection is not attempted."

    static let postDisconnectHelp = """
        Runs in your login shell after Keystrand closes its connections to this database, for example when you \
        disconnect, close the window, or test the connection. It runs even if the connection failed.
        """

    var body: some View {
        SheetForm(title: model.title, primaryTitle: model.submitTitle, isPrimaryDisabled: !model.canSubmit,
                  isWorking: model.isWorking && !model.isTesting, errorMessage: errorMessage,
                  successMessage: model.testSucceeded ? AddDatabaseFlowModel.testSucceededMessage : nil,
                  onCancel: onCancel, onPrimary: submit) {
            VStack(spacing: 0) {
                Picker("Page", selection: $model.tab) {
                    ForEach(DatabaseFormTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                Form {
                    switch model.tab {
                    case .general: generalPage
                    case .security: securityPage
                    case .decompression: decompressionPage
                    }
                }
                .formStyle(.grouped)
                .defaultScrollAnchor(focusEnvironment ? .bottom : .top)
                .disabled(model.isTesting)
                notices
            }
        } leadingActions: {
            if let backAction {
                Button("Back", action: backAction)
            }

            Button {
                Task { await model.testConnection() }
            } label: {
                WorkingLabel(title: "Test Connection", isWorking: model.isTesting)
            }
            .disabled(!model.canSubmit || model.isWorking)
            if model.kind == .edit {
                Button("Clone Database…") { model.switchToClone() }
                    .disabled(model.isWorking)
                    .help("Create a copy of this database connection")
            }
        }
        .task {
            startedAsEdit = model.kind == .edit
            await model.prepare()
            if focusEnvironment {
                model.tab = .general
                focus = .environment
            } else if model.kind == .add {
                focus = .alias
            } else if !model.isSentinelDatabase {
                focus = .host
            }
        }
    }

    private var errorMessage: String? {
        guard let error = model.error, error != model.secretsLoadError else { return nil }
        return "\(error.title): \(error.message)"
    }

    @ViewBuilder
    private var notices: some View {
        if model.secretsLoadError != nil {
            SheetNotice(text: "Saving is disabled until the stored credentials can be read.") {
                Button("Retry") { Task { await model.loadStoredSecrets() } }
            }
        }

        if let missing = model.requiredFieldsMessage {
            SheetNotice(missing)
        }
    }

    private var backAction: (@MainActor () -> Void)? {
        switch model.kind {
        case .add: return onBack
        case .clone: return startedAsEdit ? { @MainActor in model.switchToEdit() } : nil
        case .edit: return nil
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalPage: some View {
        if model.kind == .edit, let original = model.original {
            connectionSection(original)
        }

        if model.isSentinelDatabase {
            sentinelSections
        } else {
            Section("Database") {
                TextField("Alias", text: $model.name, prompt: Text("Required"))
                    .focused($focus, equals: .alias)
                TextField("Host", text: $model.host, prompt: Text("Hostname, IP address, or connection URL"))
                    .focused($focus, equals: .host)
                    .onChange(of: model.host) { old, new in model.hostChanged(from: old, to: new) }
                TextField("Port", text: $model.port, prompt: Text("Required"))
                    .monospacedDigit()
                    .digitsOnly($model.port)
                ipFamilyPicker($model.connectionFamily)
                TextField("Username", text: $model.username, prompt: Text("Optional"))
                StoredSecretField(title: "Password", secret: $model.password)
                timeoutRow
            }
            Section {
                if model.showsLogicalDatabase {
                    logicalDatabaseRows
                }

                Toggle("Force standalone connection", isOn: $model.forceStandalone)
            } header: {
                Text("Options")
            } footer: {
                SectionFooter(Self.forceStandaloneHelp)
            }
        }

        Section {
            Picker("Environment", selection: $model.environment) {
                Text("Unspecified").tag(DatabaseEnvironment.unspecified)
                Text("Production").tag(DatabaseEnvironment.production)
                Text("Development").tag(DatabaseEnvironment.development)
            }
            .pickerStyle(.menu)
            .focused($focus, equals: .environment)
        } footer: {
            SectionFooter(Self.environmentHelp)
        }
    }

    private var timeoutRow: some View {
        LabeledContent("Timeout") {
            HStack(spacing: 6) {
                TextField("Timeout", text: $model.timeoutSeconds, prompt: Text("30"))
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .digitsOnly($model.timeoutSeconds)
                Text("seconds").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var logicalDatabaseRows: some View {
        Toggle("Select logical database", isOn: $model.selectLogicalDatabase.animation())
        if model.selectLogicalDatabase {
            TextField("Database Index", text: $model.dbIndex, prompt: Text("0"))
                .monospacedDigit()
                .digitsOnly($model.dbIndex)
                .padding(.leading, 20)
        }
    }

    private func connectionSection(_ config: DatabaseConfig) -> some View {
        Section("Connection") {
            LabeledContent("Connection Type", value: DatabaseListLogic.connectionTypeLabel(config.connectionType))
            if let provider = config.nameFromProvider, !provider.isEmpty {
                LabeledContent("Database Name from Provider", value: provider)
            }

            if let provider = DatabaseListLogic.providerLabel(config.provider) {
                LabeledContent("Hosting Provider", value: provider)
            }

            if let nodes = config.nodes, !nodes.isEmpty {
                LabeledContent("Host", value: config.host)
                    .help("Cluster nodes:\n" + nodes.map { "\($0.host):\($0.port)" }.joined(separator: "\n"))
                LabeledContent("Port") { Text(String(config.port)).monospacedDigit() }
            }

            if let db = config.db {
                LabeledContent("Database Index") { Text(String(db)).monospacedDigit() }
            }

            if !config.modules.isEmpty {
                LabeledContent("Modules") {
                    ModuleSummaryText(modules: DatabaseListLogic.orderedModules(config.modules),
                                      flavor: config.providerFlavor)
                }
            }
        }
    }

    @ViewBuilder
    private var sentinelSections: some View {
        Section("Database") {
            TextField("Alias", text: $model.name, prompt: Text("Required"))
                .focused($focus, equals: .alias)
            LabeledContent("Primary Group", value: model.sentinelMasterName)
            if model.kind == .clone {
                logicalDatabaseRows
            } else if let db = model.original?.db {
                LabeledContent("Database Index") { Text(String(db)).monospacedDigit() }
            }

            TextField("Username", text: $model.sentinelMasterUsername, prompt: Text("Optional"))
            StoredSecretField(title: "Password", secret: $model.sentinelMasterPassword)
        }
        Section("Sentinel") {
            if model.kind == .clone {
                TextField("Host", text: $model.host, prompt: Text("Hostname or IP address"))
            } else {
                LabeledContent("Host", value: model.host)
            }

            TextField("Port", text: $model.port, prompt: Text("Required"))
                .monospacedDigit()
                .digitsOnly($model.port)
            TextField("Username", text: $model.username, prompt: Text("Optional"))
            StoredSecretField(title: "Password", secret: $model.password)
        }
    }

    // MARK: - Security

    @ViewBuilder
    private var securityPage: some View {
        TLSSectionView(tls: model.tls, certificates: model.certificates)
        if !model.isSentinelDatabase {
            Section("SSH Tunnel") {
                Toggle("Use SSH tunnel", isOn: $model.useSSH.animation())
                if model.useSSH {
                    TextField("Host", text: $model.sshHost, prompt: Text("Required"))
                    TextField("Port", text: $model.sshPort, prompt: Text("Required"))
                        .monospacedDigit()
                        .digitsOnly($model.sshPort)
                    TextField("Username", text: $model.sshUsername, prompt: Text("Required"))
                    Picker("Authentication", selection: $model.sshAuthMode) {
                        ForEach(SSHAuthMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    if model.sshAuthMode == .password {
                        StoredSecretField(title: "Password", secret: $model.sshPassword)
                    } else {
                        PEMEditor(title: "Private Key", prompt: "-----BEGIN OPENSSH PRIVATE KEY-----",
                                  text: $model.sshPrivateKey.text, isStored: model.sshPrivateKey.isStored,
                                  onReplaceStored: { model.sshPrivateKey.replace() }, masked: true)
                        StoredSecretField(title: "Passphrase", secret: $model.sshPassphrase)
                    }
                }
            }
        }

        scriptSection("Pre-Connection Script", text: $model.preConnectScript,
                      placeholder: "~/scripts/start-vpn.sh staging", help: Self.preConnectHelp)
        scriptSection("Post-Disconnect Script", text: $model.postDisconnectScript,
                      placeholder: "~/scripts/stop-vpn.sh staging", help: Self.postDisconnectHelp)
    }

    private func scriptSection(_ title: String, text: Binding<String>, placeholder: String,
                               help: String) -> some View {
        Section {
            CodeEditorView(text: text, placeholder: placeholder, showsLineNumbers: false, fontSize: 12,
                           autoCloseBrackets: false)
                .frame(height: 60)
                .accessibilityLabel(title)
        } header: {
            Text(title)
        } footer: {
            SectionFooter(help)
        }
    }

    // MARK: - Decompression

    @ViewBuilder
    private var decompressionPage: some View {
        Section("Decompression") {
            Toggle("Enable automatic data decompression", isOn: $model.decompressionEnabled.animation())
            if model.decompressionEnabled {
                Picker("Decompression Format", selection: $model.compressor) {
                    ForEach(Self.compressorOptions, id: \.self) { compressor in
                        Text(compressor.displayName).tag(compressor)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        Section("Formatters") {
            Picker("Key Name Format", selection: $model.keyNameFormat) {
                Text("Unicode").tag(KeyNameFormat.unicode)
                Text("HEX").tag(KeyNameFormat.hex)
            }
            .pickerStyle(.menu)
        }
    }

    static let compressorOptions: [Compressor] = [.gzip, .lz4, .snappy, .zstd, .brotli, .phpGZCompress]

    // MARK: - Submit

    private func submit() {
        guard model.canSubmit, !model.isWorking else { return }
        Task {
            switch await model.submit() {
            case .saved(let config): onSaved(config)
            case .sentinelRequired(let draft): onSentinelRequired(draft)
            case .failed: break
            }
        }
    }
}
