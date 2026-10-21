import RedisUI
import SwiftUI

struct SentinelFlowView: View {
    @Bindable var model: SentinelFlowModel
    let onBack: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    var body: some View {
        switch model.stage {
        case .form:
            SentinelFormPage(model: model, onBack: onBack, onClose: onClose)
                .sheetSize(.form)
                .frame(minHeight: 600)
        case .discovery:
            SentinelDiscoveryPage(model: model, onClose: onClose)
                .sheetSize(.large)
        case .results:
            SentinelResultsPage(model: model, onClose: onClose)
                .sheetSize(.large)
        }
    }
}

private struct SentinelFormPage: View {
    @Bindable var model: SentinelFlowModel
    let onBack: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    static let intro = "Connect to a Redis Sentinel to list the primary groups it monitors, then pick the ones to add."
    static let learnMoreURL = URL(string: "https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/")

    var body: some View {
        SheetForm(title: "Redis Sentinel", primaryTitle: "Discover", isPrimaryDisabled: !model.missingFields.isEmpty,
                  isWorking: model.isWorking, errorMessage: model.error.map { "\($0.title): \($0.message)" },
                  onCancel: onClose, onPrimary: discover) {
            VStack(spacing: 0) {
                Form {
                    Section {
                        TextField("Host", text: $model.host, prompt: Text("Hostname, IP address, or connection URL"))
                            .onChange(of: model.host) { old, new in model.hostChanged(from: old, to: new) }
                        TextField("Port", text: $model.port, prompt: Text("Required"))
                            .monospacedDigit()
                            .digitsOnly($model.port)
                        ipFamilyPicker($model.connectionFamily)
                        TextField("Username", text: $model.username, prompt: Text("Optional"))
                        SecureField("Password", text: $model.password, prompt: Text("Optional"))
                    } header: {
                        Text("Sentinel")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionFooter(Self.intro)
                            if let url = Self.learnMoreURL {
                                Link("Learn More", destination: url).font(.footnote)
                            }
                        }
                    }
                    TLSSectionView(tls: model.tls, certificates: model.certificates)
                }
                .formStyle(.grouped)
                if let missing = DatabaseFormModel.requiredFieldsMessage(model.missingFields) {
                    SheetNotice(missing)
                }
            }
        } leadingActions: {
            Button("Back", action: onBack)
        }
        .task { await model.certificates.load() }
    }

    private func discover() {
        Task { await model.discover() }
    }
}

private struct SentinelDiscoveryPage: View {
    @Bindable var model: SentinelFlowModel
    let onClose: @MainActor () -> Void

    @State private var isDiscardPresented = false

    static let intro = "Your Redis Sentinel manages these primary groups. Select the ones to add."

    var body: some View {
        SheetForm(title: "Sentinel Primary Groups", primaryTitle: "Add Primary Groups",
                  isPrimaryDisabled: model.addDisabledMessage != nil, isWorking: model.isWorking,
                  errorMessage: model.error.map { "\($0.title): \($0.message)" },
                  onCancel: cancel, onPrimary: { Task { await model.addSelected() } }) {
            VStack(spacing: 0) {
                HStack {
                    Text(Self.intro).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    SearchField(text: $model.searchText, placeholder: "Filter")
                        .frame(width: 200)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                content
                if let message = model.addDisabledMessage, !model.rows.isEmpty {
                    SheetNotice(message)
                }
            }
        } leadingActions: {
            Button("Back") { model.stage = .form }
        }
        .destructiveConfirmation("Discard Discovered Databases?", isPresented: $isDiscardPresented,
                                 message: "Your changes have not been saved.", confirmTitle: "Discard",
                                 onConfirm: onClose)
    }

    @ViewBuilder
    private var content: some View {
        if model.rows.isEmpty {
            ContentUnavailableView("No Primary Groups", systemImage: "shield.lefthalf.filled",
                                   description: Text("This Sentinel isn't monitoring any primary groups."))
        } else if model.filteredRows.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            table
        }
    }

    private func cancel() {
        if model.hasUnsavedChanges { isDiscardPresented = true } else { onClose() }
    }

    private var table: some View {
        Table(model.filteredRows) {
            TableColumn("Add") { row in
                Toggle("Add \(row.master.name)", isOn: rowBinding(row.id, \.isSelected, default: false))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
            .width(32)
            TableColumn("Primary Group") { row in
                Text(row.master.name).lineLimit(1).help(row.master.name)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Alias") { row in
                TextField("Alias", text: rowBinding(row.id, \.alias, default: ""), prompt: Text("Required"))
                    .labelsHidden()
                    .onChange(of: row.alias) { _, value in
                        if value.count > 500, let index = model.binding(for: row.id) {
                            model.rows[index].alias = String(value.prefix(500))
                        }
                    }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Address") { row in
                Text("\(row.master.host):\(row.master.port)").monospacedDigit().lineLimit(1)
            }
            .width(min: 110, ideal: 140)
            TableColumn("Replicas") { row in
                Text(String(row.master.numberOfSlaves)).monospacedDigit()
            }
            .width(60)
            TableColumn("Username") { row in
                TextField("Username", text: rowBinding(row.id, \.username, default: ""), prompt: Text("Optional"))
                    .labelsHidden()
            }
            .width(min: 90, ideal: 110)
            TableColumn("Password") { row in
                SecureField("Password", text: rowBinding(row.id, \.password, default: ""), prompt: Text("Optional"))
                    .labelsHidden()
            }
            .width(min: 90, ideal: 110)
            TableColumn("Database Index") { row in
                TextField("Database Index", text: rowBinding(row.id, \.db, default: ""), prompt: Text("0"))
                    .labelsHidden()
                    .monospacedDigit()
                    .digitsOnly(rowBinding(row.id, \.db, default: ""))
                    .help("The logical database to use in Browser and Workbench.")
            }
            .width(min: 80, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: SentinelFlowModel.Row.ID.self) { ids in
            if let id = ids.first, let row = model.rows.first(where: { $0.id == id }) {
                Button("Copy Address") { Pasteboard.copy("\(row.master.host):\(row.master.port)") }
            }
        }
    }

    private func rowBinding<T>(_ id: String, _ keyPath: WritableKeyPath<SentinelFlowModel.Row, T>,
                               default value: T) -> Binding<T> {
        Binding(
            get: { model.binding(for: id).map { model.rows[$0][keyPath: keyPath] } ?? value },
            set: { newValue in
                if let index = model.binding(for: id) { model.rows[index][keyPath: keyPath] = newValue }
            })
    }
}

private struct SentinelResultsPage: View {
    @Bindable var model: SentinelFlowModel
    let onClose: @MainActor () -> Void

    var body: some View {
        SheetForm(title: "Primary Groups Added", primaryTitle: "Done", cancelTitle: nil, onCancel: onClose, onPrimary: onClose) {
            VStack(alignment: .leading, spacing: 8) {
                InlineMessage(model.summaryText, kind: model.failedCount == 0 ? .info : .warning)
                    .padding(.horizontal, 20)
                if let error = model.error {
                    InlineMessage("\(error.title): \(error.message)", kind: .error)
                        .padding(.horizontal, 20)
                }

                table
            }
        }
    }

    private var table: some View {
        Table(model.resultRows) {
            TableColumn("Result") { row in resultCell(row) }
                .width(min: 110, ideal: 150)
            TableColumn("Primary Group") { row in Text(row.master.name).lineLimit(1) }
            TableColumn("Alias") { row in
                if row.isRetryable {
                    TextField("Alias", text: rowBinding(row.id, \.alias), prompt: Text("Required")).labelsHidden()
                } else {
                    Text(row.alias).lineLimit(1)
                }
            }
            TableColumn("Address") { row in
                Text("\(row.master.host):\(row.master.port)").monospacedDigit().lineLimit(1)
            }
            TableColumn("Replicas") { row in Text(String(row.master.numberOfSlaves)).monospacedDigit() }
                .width(60)
            TableColumn("Username") { row in
                if row.isRetryable {
                    TextField("Username", text: rowBinding(row.id, \.username), prompt: Text("Optional")).labelsHidden()
                } else {
                    Text(row.username.isEmpty ? "Default" : row.username)
                        .foregroundStyle(row.username.isEmpty ? .secondary : .primary)
                }
            }
            TableColumn("Password") { row in
                if row.isRetryable {
                    SecureField("Password", text: rowBinding(row.id, \.password), prompt: Text("Optional"))
                        .labelsHidden()
                } else {
                    Text(row.password.isEmpty ? "None" : "••••••••").foregroundStyle(.secondary)
                }
            }
            TableColumn("Database Index") { row in
                if row.isRetryable {
                    TextField("Database Index", text: rowBinding(row.id, \.db), prompt: Text("0"))
                        .labelsHidden()
                        .monospacedDigit()
                } else {
                    Text(row.db.isEmpty ? "—" : row.db).monospacedDigit()
                        .foregroundStyle(row.db.isEmpty ? .tertiary : .primary)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder
    private func resultCell(_ row: SentinelFlowModel.Row) -> some View {
        if row.isAdding {
            ProgressView().controlSize(.small)
        } else {
            switch row.result {
            case .added:
                Label("Added", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let error):
                HStack(spacing: 6) {
                    Label("Error", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .help(error.message)
                    if row.isRetryable {
                        Button("Retry") { Task { await model.retry(row.id) } }
                            .controlSize(.small)
                            .disabled(model.isWorking || row.alias.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func rowBinding(_ id: String, _ keyPath: WritableKeyPath<SentinelFlowModel.Row, String>) -> Binding<String> {
        Binding(
            get: { model.binding(for: id).map { model.rows[$0][keyPath: keyPath] } ?? "" },
            set: { newValue in
                if let index = model.binding(for: id) { model.rows[index][keyPath: keyPath] = newValue }
            })
    }
}
