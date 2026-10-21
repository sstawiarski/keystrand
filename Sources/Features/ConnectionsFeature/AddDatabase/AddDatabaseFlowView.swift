import RedisUI
import SwiftUI

struct AddDatabaseFlowView: View {
    @Bindable var model: AddDatabaseFlowModel
    let onClose: @MainActor () -> Void
    let onSaved: @MainActor (DatabaseConfig) -> Void

    var body: some View {
        switch model.screen {
        case .start:
            AddDatabaseStartPage(model: model, onClose: onClose, onSaved: onSaved)
                .sheetSize(.form)
        case .form:
            ConnectionSettingsView(
                model: model.form, onBack: { model.backToStart() }, onCancel: onClose,
                onSaved: onSaved,
                onSentinelRequired: { draft in
                    Task { await model.switchToSentinelDiscovery(draft: draft, tls: model.form.tls) }
                })
            .sheetSize(.form)
            .frame(minHeight: ConnectionSettingsView.idealHeight)
        case .sentinel:
            if let sentinel = model.sentinel {
                SentinelFlowView(model: sentinel, onBack: { model.backToStart() }, onClose: onClose)
            }
        case .importFile:
            if let importModel = model.importModel {
                ImportView(model: importModel, onBack: { model.backToStart() }, onClose: onClose)
            }
        case .software:
            if let software = model.software {
                SoftwareFlowView(model: software, onBack: { model.backToStart() }, onClose: onClose)
            }
        }
    }
}

private struct AddDatabaseStartPage: View {
    @Bindable var model: AddDatabaseFlowModel
    let onClose: @MainActor () -> Void
    let onSaved: @MainActor (DatabaseConfig) -> Void

    @FocusState private var isURLFocused: Bool

    static let formatsFooter = "Supported formats: redis://[user[:password]@]host:port, rediss://…, host:port"

    var body: some View {
        SheetForm(title: "Add Database", primaryTitle: "Add Database",
                  isPrimaryDisabled: model.urlDisabledReason != nil || model.isTesting, isWorking: model.isAdding,
                  errorMessage: model.error.map { "\($0.title): \($0.message)" },
                  successMessage: model.testSucceeded ? AddDatabaseFlowModel.testSucceededMessage : nil,
                  onCancel: onClose, onPrimary: add) {
            Form {
                Section {
                    TextField("Connection URL", text: $model.urlText, prompt: Text(AddDatabaseFlowModel.defaultURL),
                              axis: .vertical)
                        .lineLimit(2...4)
                        .fontDesign(.monospaced)
                        .labelsHidden()
                        .focused($isURLFocused)
                        .onChange(of: model.urlText) { _, _ in model.testSucceeded = false }
                } header: {
                    Text("Connection URL")
                } footer: {
                    if model.settingsDisabledReason != nil {
                        InlineMessage(ConnectionURLParser.unsupportedMessage, kind: .error)
                    } else {
                        SectionFooter(Self.formatsFooter)
                    }
                }
                Section("Other Ways to Add") {
                    optionRow("Redis Sentinel", systemImage: "shield.lefthalf.filled") { model.openSentinel() }
                    optionRow("Redis Software", systemImage: "building.2") { model.openSoftware() }
                    optionRow("Import from File", systemImage: "doc") { model.openImport() }
                }
            }
            .formStyle(.grouped)
        } leadingActions: {
            Button {
                Task { await model.testURL() }
            } label: {
                WorkingLabel(title: "Test Connection", isWorking: model.isTesting)
            }
            .disabled(model.urlDisabledReason != nil || model.isTesting || model.isAdding)
            .help(model.urlDisabledReason ?? "Test the connection without saving it")
        } trailingActions: {
            Button("Connection Settings…") { model.openConnectionSettings() }
                .disabled(model.settingsDisabledReason != nil || model.isAdding)
                .help(model.settingsDisabledReason ?? "Open the connection settings prefilled from the URL")
        }
        .onAppear { isURLFocused = true }
    }

    private func optionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabeledContent {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            } label: {
                Label(title, systemImage: systemImage)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add() {
        guard model.urlDisabledReason == nil else { return }
        Task {
            if let config = await model.addFromURL() { onSaved(config) }
        }
    }
}
