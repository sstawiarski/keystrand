import RedisUI
import SwiftUI

/// Set key value view.
public struct SetKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        SetKeyContent(context: context).id(KeyViewIdentity(context))
    }
}

struct SetKeyContent: View {
    let context: KeyDetailsContext
    @State private var model: SetKeyViewModel
    @State private var width: CGFloat = 1_000
    @State private var selection: Data?
    @State private var pendingDelete: HashFieldRef?
    private var compact: Bool { width < KeyDetailsLayout.narrowWidth }

    init(context: KeyDetailsContext) {
        self.context = context
        self._model = State(initialValue: SetKeyViewModel(context: context))
    }

    private var settings: SettingsStore { context.session.services.settings }

    var body: some View {
        VStack(spacing: 0) {
            KeySubheaderBar {
                SearchField(text: $model.searchText, placeholder: "Filter Members",
                            onSubmit: { model.search() },
                            onDebouncedChange: { text in if text.isEmpty { model.search() } })
                    .frame(minWidth: 120, maxWidth: 240)
                    .help("Member name or glob pattern. Press Return to filter.")
            } trailing: {
                ValueFormatPicker(selection: valueFormatBinding(settings), compact: compact)
                AddItemsButton("Add Members") { model.openAddPanel() }
            }
            Divider()
            table
                .overlay {
                    TableStateView(isLoading: model.isLoading, error: model.loadError, isEmpty: model.rows.isEmpty,
                                   searchText: model.isFiltered ? model.appliedMatch : nil,
                                   emptyTitle: "No Members", emptySymbol: "circle.grid.2x2") { model.reload() }
                }
            if !model.rows.isEmpty {
                Divider()
                ItemsStatusBar(loaded: model.rows.count, total: model.isFiltered ? model.rows.count : model.total,
                               noun: model.total == 1 ? "member" : "members", canLoadMore: model.canLoadMore,
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
        .sheet(item: Binding(get: { model.preview }, set: { if $0 == nil { model.closePreview() } })) { preview in
            ValuePreviewSheet(preview: preview) { model.closePreview() }
                .sheetAlerts(context.session)
        }
        .destructiveConfirmation(item: $pendingDelete, title: { "Remove “\($0.title)”?" },
                                 message: { KeyTableText.removeMessage(item: $0.title, key: DisplayName.short(model.keyDisplayName),
                                                                       isLast: model.isLastItem) },
                                 confirmTitle: "Remove") { ref in
            Task { await model.removeMember(ref.field) }
        }
    }

    private var table: some View {
        Table(model.rows, selection: $selection) {
            TableColumn("Member") { row in
                ValuePreviewText(preview: row.preview, isSelected: selection == row.member)
                    .onAppear { loadMoreIfNeeded(row) }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Data.self) { members in
            if let member = members.first {
                Button("Copy Member") { copyToPasteboard(model.copyText(member)) }
                Button("Show Value") { Task { await model.showPreview(member) } }
                Divider()
                Button("Remove Member…", role: .destructive) { pendingDelete = HashFieldRef(field: member) }
            }
        } primaryAction: { members in
            if let member = members.first { Task { await model.showPreview(member) } }
        }
        .onKeyPress(.space) {
            guard let selection else { return .ignored }
            Task { await model.showPreview(selection) }
            return .handled
        }
        .onDeleteCommand { if let selection { pendingDelete = HashFieldRef(field: selection) } }
        .onCopyCommand {
            guard let selection else { return [] }
            return [NSItemProvider(object: model.copyText(selection) as NSString)]
        }
    }

    private var addSheet: some View {
        SheetForm(title: "Add Members to “\(DisplayName.short(model.keyDisplayName))”", primaryTitle: "Add",
                  isPrimaryDisabled: !model.canSubmitAdd, isWorking: model.isSaving,
                  onCancel: { model.closeAddPanel() },
                  onPrimary: { Task { await model.submitAdd() } }) {
            Form {
                Section("Members") {
                    MultiRowFormList(rows: $model.addRows, addTitle: "Add Member", makeRow: { SetKeyViewModel.AddRow() }) { $row in
                        TextField("Member", text: $row.member, prompt: Text("Member"), axis: .vertical)
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

    private func loadMoreIfNeeded(_ row: SetKeyViewModel.Row) {
        let threshold = model.rows.count > 50 ? model.rows[model.rows.count - 50].member : model.rows.last?.member
        if row.member == threshold { Task { await model.loadMore() } }
    }
}
