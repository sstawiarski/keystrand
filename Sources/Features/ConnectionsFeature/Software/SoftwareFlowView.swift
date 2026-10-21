import RedisUI
import SwiftUI

struct SoftwareFlowView: View {
    @Bindable var model: SoftwareDiscoveryModel
    let onBack: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    @State private var isDiscardPresented = false

    static let intro = "Connect to a Redis Software cluster to list its databases, then pick the ones to add."

    var body: some View {
        switch model.stage {
        case .form: form.sheetSize(.form)
        case .discovery: discovery.sheetSize(.large)
        case .results: results.sheetSize(.large)
        }
    }

    private var form: some View {
        SheetForm(title: "Redis Software", primaryTitle: "Discover", isPrimaryDisabled: !model.missingFields.isEmpty,
                  isWorking: model.isWorking, errorMessage: model.error, onCancel: onClose, onPrimary: discover) {
            VStack(spacing: 0) {
                Form {
                    Section {
                        TextField("Cluster Host", text: $model.host, prompt: Text("Required"))
                            .onChange(of: model.host) { old, new in model.hostChanged(from: old, to: new) }
                        TextField("Cluster Port", text: $model.port, prompt: Text("Required"))
                            .monospacedDigit()
                            .digitsOnly($model.port)
                        TextField("Admin Username", text: $model.username, prompt: Text("Required"))
                        SecureField("Admin Password", text: $model.password, prompt: Text("Required"))
                    } header: {
                        Text("Cluster")
                    } footer: {
                        SectionFooter(Self.intro)
                    }
                }
                .formStyle(.grouped)
                if let missing = DatabaseFormModel.requiredFieldsMessage(model.missingFields) {
                    SheetNotice(missing)
                }
            }
        } leadingActions: {
            Button("Back", action: onBack)
        }
    }

    private func discover() {
        Task { await model.discover() }
    }

    private var discovery: some View {
        SheetForm(title: "Redis Software Databases", primaryTitle: "Add Databases",
                  isPrimaryDisabled: model.selected.isEmpty, isWorking: model.isWorking, errorMessage: model.error,
                  onCancel: cancel, onPrimary: { Task { await model.addSelected() } }) {
            VStack(spacing: 0) {
                HStack {
                    Text("Select the databases to add.").foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    SearchField(text: $model.searchText, placeholder: "Filter")
                        .frame(width: 200)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                discoveryContent
                if model.selected.isEmpty, !model.databases.isEmpty {
                    SheetNotice("Select at least one database.")
                }
            }
        } leadingActions: {
            Button("Back") { model.stage = .form }
        }
        .destructiveConfirmation("Discard Discovered Databases?", isPresented: $isDiscardPresented,
                                 message: "Your changes have not been saved.", confirmTitle: "Discard",
                                 onConfirm: onClose)
    }

    private func cancel() {
        if model.selected.isEmpty { onClose() } else { isDiscardPresented = true }
    }

    @ViewBuilder
    private var discoveryContent: some View {
        if model.databases.isEmpty {
            ContentUnavailableView("No Databases", systemImage: "building.2",
                                   description: Text("Your Redis Software cluster has no databases."))
        } else if model.filtered.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            Table(model.filtered, selection: $model.selected) {
                TableColumn("Database") { db in Text(db.name).lineLimit(1) }
                TableColumn("Status") { db in Text(db.status) }
                    .width(80)
                TableColumn("Endpoint") { db in Text(db.endpoint).monospacedDigit().lineLimit(1).help(db.endpoint) }
                TableColumn("Modules") { db in ModuleSummaryText(modules: DatabaseListLogic.orderedModules(db.modules)) }
                TableColumn("Options") { db in optionSymbols(db) }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func optionSymbols(_ db: SoftwareDatabase) -> some View {
        HStack(spacing: 6) {
            ForEach(db.options, id: \.self) { option in
                Image(systemName: option.systemImage)
                    .foregroundStyle(.secondary)
                    .help(db.tooltip(for: option))
                    .accessibilityLabel(db.tooltip(for: option))
            }
        }
    }

    private var results: some View {
        SheetForm(title: "Databases Added", primaryTitle: "Done", cancelTitle: nil, onCancel: onClose, onPrimary: onClose) {
            VStack(alignment: .leading, spacing: 8) {
                InlineMessage(model.summaryText, kind: model.failedCount == 0 ? .info : .warning)
                    .padding(.horizontal, 20)
                Table(model.results) {
                    TableColumn("Result") { row in
                        if row.added {
                            Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Error", systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                                .help(row.message)
                        }
                    }
                    .width(100)
                    TableColumn("Database") { row in Text(row.database.name).lineLimit(1) }
                    TableColumn("Endpoint") { row in Text(row.database.endpoint).monospacedDigit().lineLimit(1) }
                    TableColumn("Modules") { row in
                        ModuleSummaryText(modules: DatabaseListLogic.orderedModules(row.database.modules))
                    }
                    TableColumn("Options") { row in optionSymbols(row.database) }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}
