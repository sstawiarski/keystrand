import RedisUI
import SwiftUI

/// List key value view.
public struct ListKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        ListKeyContent(context: context).id(KeyViewIdentity(context))
    }
}

struct ListKeyContent: View {
    let context: KeyDetailsContext
    @State private var model: ListKeyViewModel
    @State private var width: CGFloat = 1_000
    @State private var selection: Int?
    @State private var confirmRemove = false
    @State private var guardIndex: Int?
    private var compact: Bool { width < KeyDetailsLayout.narrowWidth }

    init(context: KeyDetailsContext) {
        self.context = context
        self._model = State(initialValue: ListKeyViewModel(context: context))
    }

    private var settings: SettingsStore { context.session.services.settings }

    var body: some View {
        VStack(spacing: 0) {
            subheader
            Divider()
            table
                .overlay {
                    TableStateView(isLoading: model.isLoading, error: model.loadError, isEmpty: model.rows.isEmpty,
                                   emptyTitle: model.searchError == nil ? "No Elements" : "No Element at This Index",
                                   emptySymbol: "list.bullet") { model.reload() }
                }
            if !model.rows.isEmpty && model.searchedIndex == nil {
                Divider()
                ItemsStatusBar(loaded: model.rows.count, total: model.total,
                               noun: model.total == 1 ? "element" : "elements", canLoadMore: model.canLoadMore,
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
        .sheet(isPresented: panelBinding(.add)) { addSheet.sheetAlerts(context.session) }
        .sheet(isPresented: panelBinding(.remove)) { removeSheet.sheetAlerts(context.session) }
        .sheet(isPresented: Binding(get: { model.editingIndex != nil }, set: { if !$0 { model.cancelEdit() } })) {
            EditValueSheet(title: "Edit Element \(model.editingIndex ?? 0)", text: $model.editDraft,
                           format: model.format, isSaving: model.isSaving,
                           onCancel: { model.cancelEdit() },
                           onSave: { Task { await model.saveEdit() } })
            .sheetAlerts(context.session)
        }
        .sheet(item: Binding(get: { model.preview }, set: { if $0 == nil { model.closePreview() } })) { preview in
            ValuePreviewSheet(preview: preview) { model.closePreview() }
                .sheetAlerts(context.session)
        }
        .nonUnicodeEditGuard(isPresented: Binding(get: { guardIndex != nil }, set: { if !$0 { guardIndex = nil } }),
                             formatName: model.format.menuLabel,
                             onEditAnyway: { if let index = guardIndex { model.beginEdit(index) } },
                             onChangeToUnicode: {
                                 model.pendingEditAfterFormatChange = guardIndex
                                 settings.browser.valueFormat = .unicode
                             })
    }

    private func panelBinding(_ panel: ListKeyViewModel.Panel) -> Binding<Bool> {
        Binding(get: { model.panel == panel }, set: { if !$0 && model.panel == panel { model.closePanel() } })
    }

    private var subheader: some View {
        KeySubheaderBar {
            SearchField(text: $model.searchText, placeholder: "Go to Index",
                        onSubmit: { model.search() },
                        onDebouncedChange: { text in if text.isEmpty { model.search() } })
                .frame(minWidth: 100, maxWidth: 180)
                .onChange(of: model.searchText) { _, value in
                    let clean = ListKeyViewModel.sanitizeIndex(value)
                    if clean != value { model.searchText = clean }
                }
                .help("Enter an element index and press Return.")
        } trailing: {
            ValueFormatPicker(selection: valueFormatBinding(settings), compact: compact)
            AddItemsButton("Add Elements") { model.openPanel(.add) }
            ViewThatFits(in: .horizontal) {
                Button("Remove Elements…", systemImage: "minus") { model.openPanel(.remove) }
                    .labelStyle(.titleAndIcon)
                Button("Remove Elements…", systemImage: "minus") { model.openPanel(.remove) }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Remove Elements…")
        }
    }

    private var table: some View {
        Table(model.rows, selection: $selection) {
            TableColumn("Index") { row in
                Text(String(row.index))
                    .font(.body.monospaced())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .onAppear { loadMoreIfNeeded(row) }
            }
            .width(80)
            TableColumn("Element") { row in
                ValuePreviewText(preview: row.preview, isSelected: selection == row.index)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Int.self) { indexes in
            if let index = indexes.first, let row = model.rows.first(where: { $0.index == index }) {
                Button("Copy Element") { copyToPasteboard(model.copyText(row.value)) }
                Button("Copy Index") { copyToPasteboard(String(row.index)) }
                Divider()
                Button("Show Value") { Task { await model.showPreview(index) } }
                Button("Edit Value…") { requestEdit(index) }
                    .disabled(model.editBlockReason(row) != nil)
            }
        } primaryAction: { indexes in
            if let index = indexes.first { requestEdit(index) }
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
        .onCopyCommand {
            guard let selection, let row = model.rows.first(where: { $0.index == selection }) else { return [] }
            return [NSItemProvider(object: model.copyText(row.value) as NSString)]
        }
    }

    // MARK: - Sheets

    private var addSheet: some View {
        SheetForm(title: "Add Elements to “\(DisplayName.short(model.keyDisplayName))”", primaryTitle: "Add",
                  isPrimaryDisabled: !model.canSubmitAdd, isWorking: model.isSaving,
                  onCancel: { model.closePanel() },
                  onPrimary: { Task { await model.submitAdd() } }) {
            Form {
                Section {
                    Picker("Insert At", selection: $model.addDestination) {
                        Text("Tail").tag(ListDestination.tail)
                        Text("Head").tag(ListDestination.head)
                    }
                    .pickerStyle(.menu)
                }
                Section("Elements") {
                    MultiRowFormList(rows: $model.addRows, addTitle: "Add Element",
                                     makeRow: { ListKeyViewModel.AddRow() }) { $row in
                        TextField("Element", text: $row.element, prompt: Text("Element"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(1...6)
                            .fontDesign(.monospaced)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheetSize(.form)
    }

    private var removeSheet: some View {
        SheetForm(title: "Remove Elements", primaryTitle: "Remove…", isPrimaryDisabled: model.removeCount == nil,
                  isWorking: model.isSaving,
                  onCancel: { model.closePanel() },
                  onPrimary: {
                      if model.skipsRemoveConfirmation {
                          Task { await model.submitRemove() }
                      } else {
                          confirmRemove = true
                      }
                  }) {
            Form {
                Section {
                    Picker("Remove From", selection: $model.removeDestination) {
                        Text("Tail").tag(ListDestination.tail)
                        Text("Head").tag(ListDestination.head)
                    }
                    .pickerStyle(.menu)
                    DigitsField(title: "Count", prompt: "1", text: $model.removeCountText)
                        .disabled(!model.supportsPopCount)
                } footer: {
                    if !model.supportsPopCount {
                        Text("Removing several elements at once requires Redis 6.2 or later.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheetSize(.small)
        .destructiveConfirmation("Remove Elements?", isPresented: $confirmRemove,
                                 message: model.removeConfirmationMessage, confirmTitle: "Remove") {
            Task { await model.submitRemove() }
        }
    }

    // MARK: - Actions

    private func loadMoreIfNeeded(_ row: ListKeyViewModel.Row) {
        let threshold = model.rows.count > 50 ? model.rows[model.rows.count - 50].index : model.rows.last?.index
        if row.index == threshold { Task { await model.loadMore() } }
    }

    private func requestEdit(_ index: Int) {
        guard let row = model.rows.first(where: { $0.index == index }), model.editBlockReason(row) == nil else { return }
        if model.needsNonUnicodeGuard {
            guardIndex = index
        } else {
            model.beginEdit(index)
        }
    }
}
