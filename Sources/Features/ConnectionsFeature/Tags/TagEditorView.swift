import RedisUI
import SwiftUI

struct TagEditorView: View {
    @State var model: TagEditorModel
    var isProviderManaged = false
    let onSave: @MainActor ([DatabaseTag]) async -> Bool

    static let description = "Label databases with key-value tags to group and filter them."
    static let providerNote = "Tags edited here are saved on this Mac only. Redis Software keeps its own tags."

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @FocusState private var focusedRow: UUID?

    var body: some View {
        SheetForm(title: "Manage Tags for “\(TextTruncation.formatLongName(model.databaseName, maxLength: 40, tail: 10))”",
                  primaryTitle: "Save", isPrimaryDisabled: !model.canSave, isWorking: isSaving,
                  onCancel: { dismiss() }, onPrimary: save) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.description)
                    if isProviderManaged { Text(Self.providerNote) }
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(model.rows) { row in
                        TagRowView(model: model, row: row, focusedRow: $focusedRow)
                    }
                }
                Button("Add Tag", systemImage: "plus.circle") {
                    model.addRow()
                    focusedRow = model.rows.last?.id
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .sheetSize(.small)
        .onAppear { focusedRow = model.rows.first?.id }
    }

    private func save() {
        guard model.canSave, !isSaving else { return }
        isSaving = true
        Task {
            let saved = await onSave(model.resultTags)
            isSaving = false
            if saved { dismiss() }
        }
    }
}

private struct TagRowView: View {
    let model: TagEditorModel
    let row: TagEditorModel.Row
    var focusedRow: FocusState<UUID?>.Binding

    var body: some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Key", text: Binding(get: { row.key }, set: { model.setKey($0, for: row.id) }),
                          prompt: Text("Key"))
                    .labelsHidden()
                    .focused(focusedRow, equals: row.id)
                    .textInputSuggestions {
                        ForEach(model.keySuggestions(for: row), id: \.self) { key in
                            Text(key).textInputCompletion(key)
                        }
                    }
                validation(model.keyError(for: row))
            }
            Text(":").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Value", text: Binding(get: { row.value }, set: { model.setValue($0, for: row.id) }),
                          prompt: Text("Value"))
                    .labelsHidden()
                    .disabled(!model.isValueEnabled(row))
                    .textInputSuggestions {
                        ForEach(model.valueSuggestions(for: row), id: \.self) { value in
                            Text(value).textInputCompletion(value)
                        }
                    }
                validation(model.valueError(for: row))
            }
            Button {
                model.removeRow(row.id)
            } label: {
                Label("Remove Tag", systemImage: "minus.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove Tag")
        }
    }

    @ViewBuilder
    private func validation(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Saves tags for a stored database.
public struct ManageTagsSheet: View {
    public let database: DatabaseConfig
    public let onSaved: @MainActor ([DatabaseTag]) -> Void

    @Environment(AppServices.self) private var services
    @State private var knownTags: [DatabaseTag]?

    public init(database: DatabaseConfig, onSaved: @escaping @MainActor ([DatabaseTag]) -> Void = { _ in }) {
        self.database = database
        self.onSaved = onSaved
    }

    public var body: some View {
        Group {
            if let knownTags {
                TagEditorView(model: TagEditorModel(databaseName: database.name, tags: database.tags,
                                                    knownTags: knownTags),
                              isProviderManaged: database.provider == .redisSoftware) { tags in
                    let saved = await DatabaseListViewModel.saveTags(tags, for: database.id, services: services)
                    if saved { onSaved(tags) }
                    return saved
                }
            } else {
                ProgressView().frame(width: 460, height: 200)
            }
        }
        .task {
            let all = (try? await services.databaseStore.list()) ?? []
            knownTags = DatabaseListLogic.allTags(all)
        }
    }
}
