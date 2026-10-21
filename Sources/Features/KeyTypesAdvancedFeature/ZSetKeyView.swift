import RedisUI
import SwiftUI

/// Sorted Set key value view.
public struct ZSetKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        ZSetBody(context: context).id(KeyIdentity(context))
    }
}

private struct ZSetBody: View {
    let context: KeyDetailsContext
    @State private var model: ZSetViewModel
    @State private var width: CGFloat = 1_000
    @State private var selection: Data?
    @State private var pendingRemove: ZSetRow?
    @State private var preview: ValuePreviewItem?
    @State private var sortOrder = [KeyPathComparator(\ZSetRow.sortScore, order: .forward)]

    init(context: KeyDetailsContext) {
        self.context = context
        _model = State(initialValue: ZSetViewModel(context: context))
    }

    private var settings: SettingsStore { context.session.services.settings }
    private var compact: Bool { KeyDetailsLayout.isCompact(width) }

    var body: some View {
        VStack(spacing: 0) {
            KeySubheaderBar {
                SearchField(text: $model.searchText, placeholder: "Filter Members",
                            onSubmit: { Task { await model.applySearch() } },
                            debounce: .milliseconds(300),
                            onDebouncedChange: { text in
                                if text.isEmpty { Task { await model.closeSearch() } }
                            })
                    .frame(maxWidth: 240)
                    .help("Press Return to filter. Use * ? [ ] for patterns; other text looks up an exact member.")
                if model.isLoading, model.hasLoaded { ProgressView().controlSize(.small) }
            } trailing: {
                ValueFormatPicker(selection: formatBinding, compact: compact)
                AddItemsButton("Add Members", help: "Add members to the sorted set") { model.openAddPanel() }
            }
            Divider()
            content
        }
        .trackingWidth($width)
        .task { await model.load() }
        .onChange(of: context.state.refreshGeneration) { Task { await model.refresh() } }
        .onChange(of: settings.browser.valueFormat) { Task { await model.formatChanged() } }
        .onChange(of: sortOrder) { _, order in
            let ascending = order.first?.order != .reverse
            Task { await model.setSort(ascending ? .asc : .desc) }
        }
        .destructiveConfirmation(item: $pendingRemove,
                                 title: { RemovalText.title(Bytes.text($0.id)) },
                                 message: { _ in RemovalText.message(keyName: context.keyText,
                                                                     lastItemWarning: model.lastItemWarning()) },
                                 confirmTitle: "Remove") { row in
            Task { await model.remove(row.id) }
        }
        .sheet(item: $preview) { ValuePreviewSheet(item: $0).sheetAlerts(context.session) }
        .sheet(isPresented: $model.isAddPanelOpen) {
            ZSetAddSheet(model: model, keyName: context.keyText).sheetAlerts(context.session)
        }
    }

    private var formatBinding: Binding<ValueFormat> {
        Binding(get: { settings.browser.valueFormat }, set: { settings.browser.valueFormat = $0 })
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage, model.rows.isEmpty {
            ErrorStateView(message: error) { Task { await model.load() } }
        } else if !model.hasLoaded {
            LoadingBody()
        } else if model.rows.isEmpty {
            if model.isSearching {
                ContentUnavailableView.search(text: model.appliedSearch)
            } else {
                ContentUnavailableView("No Members", systemImage: "list.number")
            }
        } else {
            table
            Divider()
            PagedStatusBar(text: statusText, isLoadingMore: model.isLoadingMore, canLoadMore: model.canLoadMore,
                           onLoadMore: { model.loadMore() })
        }
    }

    private var statusText: String {
        if model.isSearching {
            return "Found \(NumberFormatting.grouped(model.rows.count))\(model.canLoadMore ? "+" : "") members"
        }

        return "\(NumberFormatting.grouped(model.rows.count)) of \(NumberFormatting.grouped(model.total)) members"
    }

    private var table: some View {
        let ids = model.rows.map(\.id)
        return Table(model.rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Member") { row in
                FormattedValueCell(result: row.formatted, collapsedText: row.collapsed, format: model.formatContext.format,
                                   columnTitle: "Member",
                                   isExpanded: selection == row.id)
                    .loadsMore(when: KeyDetailsLayout.isNearEnd(row.id, in: ids)) { model.loadMore() }
            }
            .width(min: 120, ideal: 320)
            TableColumn("Score", value: \.sortScore) { row in
                EditableTextCell(value: row.member.score, isEditing: editingBinding(row.id), placeholder: "Score",
                                 isEditable: row.member.isScoreEditable,
                                 disabledReason: "Use CLI or Workbench to edit this score",
                                 validate: { ZSetCommands.scoreError($0) },
                                 onSave: { text in Task { await model.updateScore(member: row.id, score: text) } })
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Data.self) { ids in
            if let row = row(for: ids) {
                Button("Copy Member") { Pasteboard.copy(row.formatted.displayText(expanded: true)) }
                Button("Copy Score") { Pasteboard.copy(row.member.score) }
                Button("Show Value") { showPreview(row) }
                Button("Edit Score") { model.editingMember = row.id }
                    .disabled(!row.member.isScoreEditable)
                Divider()
                Button("Remove Member…", role: .destructive) { pendingRemove = row }
            }
        } primaryAction: { ids in
            if let row = row(for: ids), row.member.isScoreEditable { model.editingMember = row.id }
        }
        .onDeleteCommand { if let row = row(for: selection.map { [$0] } ?? []) { pendingRemove = row } }
        .onKeyPress(.space) {
            guard model.editingMember == nil, let row = row(for: selection.map { [$0] } ?? []) else { return .ignored }
            showPreview(row)
            return .handled
        }
    }

    private func row(for ids: Set<Data>) -> ZSetRow? {
        guard let id = ids.first else { return nil }
        return model.rows.first { $0.id == id }
    }

    private func row(for ids: [Data]) -> ZSetRow? { row(for: Set(ids)) }

    private func showPreview(_ row: ZSetRow) {
        preview = ValuePreviewItem(result: row.formatted, format: model.formatContext.format)
    }

    private func editingBinding(_ id: Data) -> Binding<Bool> {
        Binding(get: { model.editingMember == id },
                set: { model.editingMember = $0 ? id : (model.editingMember == id ? nil : model.editingMember) })
    }
}

private struct ZSetAddSheet: View {
    @Bindable var model: ZSetViewModel
    let keyName: String

    var body: some View {
        SheetForm(title: "Add Members to “\(Bytes.short(keyName))”", primaryTitle: "Add Members",
                  isPrimaryDisabled: !model.isAddValid, isWorking: model.isSaving,
                  onCancel: { model.isAddPanelOpen = false }, onPrimary: { Task { await model.saveDrafts() } }) {
            Form {
                Section {
                    MultiRowFormList(rows: $model.draftRows, addTitle: "Add Member", makeRow: { ZSetDraftRow() }) { $row in
                        TextField("Member", text: $row.member, prompt: Text("Member"))
                            .labelsHidden()
                            .gridColumnAlignment(.leading)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Score", text: $row.score, prompt: Text("Score"))
                                .labelsHidden()
                                .monospacedDigit()
                                .frame(width: 140)
                                .onChange(of: row.score) { _, new in
                                    let clean = ZSetCommands.sanitizeScore(new)
                                    if clean != new { row.score = clean }
                                }
                                .onSubmit { row.score = ZSetCommands.normalizeScore(row.score) }
                            if !row.score.isEmpty, !ZSetCommands.isValidScore(row.score) {
                                FieldHint(text: "Enter a number", isError: true)
                            }
                        }
                    }
                } footer: {
                    Text("Each member needs a numeric score. Existing members get the new score.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .sheetSize(.form)
    }
}
