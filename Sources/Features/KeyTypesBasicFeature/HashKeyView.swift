import RedisUI
import SwiftUI

/// Hash key value view.
public struct HashKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        HashKeyContent(context: context).id(KeyViewIdentity(context))
    }
}

struct HashKeyContent: View {
    let context: KeyDetailsContext
    @State private var model: HashKeyViewModel
    @State private var width: CGFloat = 1_000
    @State private var selection: Data?
    @State private var pendingDelete: HashFieldRef?
    @State private var guardField: Data?
    private var compact: Bool { width < KeyDetailsLayout.narrowWidth }

    init(context: KeyDetailsContext) {
        self.context = context
        self._model = State(initialValue: HashKeyViewModel(context: context))
    }

    private var settings: SettingsStore { context.session.services.settings }

    var body: some View {
        VStack(spacing: 0) {
            subheader
            Divider()
            table
                .overlay {
                    TableStateView(isLoading: model.isLoading, error: model.loadError, isEmpty: model.rows.isEmpty,
                                   searchText: model.isFiltered ? model.appliedMatch : nil,
                                   emptyTitle: "No Fields", emptySymbol: "number") { model.reload() }
                }
            if !model.rows.isEmpty {
                Divider()
                ItemsStatusBar(loaded: model.rows.count, total: model.isFiltered ? model.rows.count : model.total,
                               noun: model.total == 1 ? "field" : "fields", canLoadMore: model.canLoadMore,
                               isLoading: model.isLoadingMore) {
                    Task { await model.loadMore() }
                }
            }
        }
        .trackingWidth($width)
        .onAppear { model.reload() }
        .onChange(of: context.state.refreshGeneration) { model.refresh() }
        .onChange(of: settings.browser.valueFormat) { Task { await model.formatChanged() } }
        .onDisappear { model.viewDidDisappear() }
        .sheet(isPresented: Binding(get: { model.isAddPanelOpen }, set: { if !$0 { model.closeAddPanel() } })) {
            addSheet.sheetAlerts(context.session)
        }
        .sheet(isPresented: Binding(get: { model.editingField != nil }, set: { if !$0 { model.cancelEdit() } })) {
            EditValueSheet(title: "Edit Value of “\(DisplayName.short(model.editingField ?? Data()))”",
                           text: $model.editDraft, format: model.format, isSaving: model.isSaving,
                           onCancel: { model.cancelEdit() },
                           onSave: { Task { await model.saveEdit() } })
            .sheetAlerts(context.session)
        }
        .sheet(item: Binding(get: { model.preview }, set: { if $0 == nil { model.closePreview() } })) { preview in
            ValuePreviewSheet(preview: preview) { model.closePreview() }
                .sheetAlerts(context.session)
        }
        .destructiveConfirmation(item: $pendingDelete, title: { "Remove “\($0.title)”?" },
                                 message: { KeyTableText.removeMessage(item: $0.title, key: DisplayName.short(model.keyDisplayName),
                                                                       isLast: model.isLastItem) },
                                 confirmTitle: "Remove") { ref in
            Task { await model.deleteField(ref.field) }
        }
        .nonUnicodeEditGuard(isPresented: Binding(get: { guardField != nil }, set: { if !$0 { guardField = nil } }),
                             formatName: model.format.menuLabel,
                             onEditAnyway: { if let field = guardField { model.beginEdit(field) } },
                             onChangeToUnicode: {
                                 model.pendingEditAfterFormatChange = guardField
                                 settings.browser.valueFormat = .unicode
                             })
    }

    // MARK: - Subheader

    private var subheader: some View {
        KeySubheaderBar {
            SearchField(text: $model.searchText, placeholder: "Filter Fields",
                        onSubmit: { model.search() },
                        debounce: nil,
                        onDebouncedChange: { text in if text.isEmpty { model.search() } })
                .frame(minWidth: 120, maxWidth: 240)
                .help("Field name or glob pattern. Press Return to filter.")
        } trailing: {
            ValueFormatPicker(selection: valueFormatBinding(settings), compact: compact)
            if model.supportsFieldTTL {
                Toggle("Show TTL", isOn: $model.showTTL)
                    .toggleStyle(.checkbox)
            }

            AddItemsButton("Add Fields") { model.openAddPanel() }
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(model.rows, selection: $selection) {
            TableColumn("Field") { row in
                ValuePreviewText(preview: row.fieldPreview, isSelected: selection == row.field)
                    .onAppear { loadMoreIfNeeded(row) }
            }
            .width(min: 80, ideal: 180)
            TableColumn("Value") { row in
                ValuePreviewText(preview: row.valuePreview, isSelected: selection == row.field)
            }
            .width(min: 120)
            if model.showsTTLColumn {
                TableColumn("TTL") { row in
                    ttlCell(row)
                }
                .width(min: 60, ideal: 90, max: 160)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Data.self) { fields in
            if let field = fields.first, let row = row(field) { contextMenu(row) }
        } primaryAction: { fields in
            if let field = fields.first { requestEdit(field) }
        }
        .onKeyPress(.space) {
            guard let selection else { return .ignored }
            Task { await model.showPreview(selection) }
            return .handled
        }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            requestEdit(selection)
            return .handled
        }
        .onDeleteCommand { if let selection { pendingDelete = HashFieldRef(field: selection) } }
        .onCopyCommand {
            guard let selection, let row = row(selection) else { return [] }
            return [NSItemProvider(object: model.copyText(value: row.value) as NSString)]
        }
    }

    private func ttlCell(_ row: HashKeyViewModel.Row) -> some View {
        Group {
            if let expire = row.expire, expire >= 0 {
                Text(NumberFormatting.grouped(expire)).help(TTLText.tooltip(expire))
            } else if row.expire == nil {
                Text(" ")
            } else {
                Text("No limit").foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .popover(isPresented: Binding(get: { model.editingTTLField == row.field },
                                      set: { if !$0 && model.editingTTLField == row.field { model.cancelTTLEdit() } }),
                 arrowEdge: .bottom) {
            SetTTLPopover(title: "Set Field TTL", text: $model.ttlDraft,
                           footer: "Leave empty for no limit. 0 removes the field.", isSaving: model.isSaving,
                           onCancel: { model.cancelTTLEdit() },
                           onSet: { Task { await model.saveTTL() } })
        }
    }

    @ViewBuilder
    private func contextMenu(_ row: HashKeyViewModel.Row) -> some View {
        Button("Copy Field") { copyToPasteboard(model.copyText(field: row.field)) }
        Button("Copy Value") { copyToPasteboard(model.copyText(value: row.value)) }
        Divider()
        Button("Show Value") { Task { await model.showPreview(row.field) } }
        Button("Edit Value…") { requestEdit(row.field) }
            .disabled(model.editBlockReason(row) != nil)
        if model.supportsFieldTTL {
            Button("Set Field TTL…") {
                selection = row.field
                model.beginTTLEdit(row.field)
            }
        }

        Divider()
        Button("Remove Field…", role: .destructive) { pendingDelete = HashFieldRef(field: row.field) }
    }

    // MARK: - Add sheet

    private var addSheet: some View {
        SheetForm(title: "Add Fields to “\(DisplayName.short(model.keyDisplayName))”", primaryTitle: "Add",
                  isPrimaryDisabled: !model.canSubmitAdd, isWorking: model.isSaving,
                  onCancel: { model.closeAddPanel() },
                  onPrimary: { Task { await model.submitAdd() } }) {
            Form {
                Section {
                    MultiRowFormList(rows: $model.addRows, addTitle: "Add Field", makeRow: { HashKeyViewModel.AddRow() }) { $row in
                        TextField("Field", text: $row.field, prompt: Text("Field"))
                            .labelsHidden()
                            .fontDesign(.monospaced)
                        TextField("Value", text: $row.value, prompt: Text("Value"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(1...6)
                            .fontDesign(.monospaced)
                        if model.supportsFieldTTL {
                            DigitsField(title: "TTL", prompt: "TTL (s)", text: $row.ttl, width: 80)
                                .labelsHidden()
                        }
                    }
                } footer: {
                    if model.supportsFieldTTL {
                        Text("Field TTL is in seconds. Leave it empty for no limit.")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheetSize(.form)
    }

    // MARK: - Actions

    private func row(_ field: Data) -> HashKeyViewModel.Row? {
        model.rows.first { $0.field == field }
    }

    private func loadMoreIfNeeded(_ row: HashKeyViewModel.Row) {
        let threshold = model.rows.count > 50 ? model.rows[model.rows.count - 50].field : model.rows.last?.field
        if row.field == threshold { Task { await model.loadMore() } }
    }

    private func requestEdit(_ field: Data) {
        guard let row = row(field), model.editBlockReason(row) == nil else { return }
        if model.needsNonUnicodeGuard {
            guardField = field
        } else {
            model.beginEdit(field)
        }
    }
}

struct HashFieldRef: Identifiable {
    let field: Data
    var id: Data { field }
    var title: String { DisplayName.short(field) }
}
