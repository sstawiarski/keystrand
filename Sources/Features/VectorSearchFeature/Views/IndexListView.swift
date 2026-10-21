import RedisUI
import SwiftUI

struct IndexListView: View {
    @Bindable var model: VectorSearchViewModel
    @State private var selection = Set<Data>()

    private var selectedName: Data? {
        guard selection.count == 1, let name = selection.first, model.indexNames.contains(name) else { return nil }
        return name
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.showsUpgradeNotice {
                InlineMessage("Upgrade to Redis 7.2 or later to use fast, real-time vector search.", kind: .info)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
            }

            if let error = model.listError {
                ErrorStateView(message: error) { Task { await model.loadIndexes() } }
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $model.filter, placement: .toolbar, prompt: "Search Indexes")
        .toolbar { toolbarItems }
        .sheet(isPresented: Binding(get: { model.infoPanelIndex != nil },
                                    set: { if !$0 { model.infoPanelIndex = nil } })) {
            if let name = model.infoPanelIndex {
                IndexInfoSheet(model: model, indexName: name) { model.infoPanelIndex = nil }
                    .sheetSize(.large)
                    .sheetAlerts(model.session)
            }
        }
        .destructiveConfirmation(item: pendingDelete, title: Self.deleteTitle,
                                 message: { _ in "The index will be removed. Your data is not deleted." },
                                 confirmTitle: "Delete Index") { pending in
            Task { await model.deleteIndex(pending.name) }
        }
    }

    private struct PendingDelete: Identifiable {
        let name: Data
        var id: Data { name }
    }

    private var pendingDelete: Binding<PendingDelete?> {
        Binding(get: { model.pendingDelete.map(PendingDelete.init) },
                set: { model.pendingDelete = $0?.name })
    }

    private nonisolated static func deleteTitle(_ pending: PendingDelete) -> String {
        let name = IndexListLogic.displayName(pending.name)
        return "Delete “\(TextTruncation.formatLongName(name, maxLength: 60, tail: 10))”?"
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Use Sample Data…") { model.isSamplePickerPresented = true }
                Button("Use Existing Data…") {
                    model.openCreateIndex(.existingData(initialKey: nil, keyType: nil, prefix: nil))
                }
            } label: {
                Label("Create Index", systemImage: "plus")
            }
            .help("Create a search index from sample data or your existing keys")

            Button {
                if let name = selectedName { model.infoPanelIndex = name }
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(selectedName == nil)
            .help("Get Info (⌘I)")

            Button {
                Task { await model.loadIndexes() }
            } label: {
                if model.isLoadingList || model.isLoadingInfos || model.isDeleting {
                    Label { Text("Refresh") } icon: { ProgressView().controlSize(.small) }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .help("Refresh (⌘R)")
        }
    }

    private var table: some View {
        Table(model.rows, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn(IndexListColumn.name.title, value: \.sortName) { row in
                Text(row.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.displayName)
            }
            .width(min: IndexListColumn.name.minWidth, ideal: 220)
            TableColumn(IndexListColumn.prefix.title, value: \.prefixText) { row in
                Text(row.prefixText)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .help(row.prefixText.isEmpty ? IndexListColumn.prefix.tooltip
                                                 : "\(row.prefixText)\n\(IndexListColumn.prefix.tooltip)")
            }
            .width(min: IndexListColumn.prefix.minWidth, ideal: 160)
            TableColumn(IndexListColumn.types.title, value: \.typesText) { row in
                Text(row.typesText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.fieldTypes.map { "\($0.label): \(EditableFieldTypes.shortDescription($0))" }
                        .joined(separator: "\n"))
            }
            .width(min: IndexListColumn.types.minWidth, ideal: 160)
            TableColumn(IndexListColumn.docs.title, value: \.numDocs) { row in countCell(row.numDocs, .docs) }
                .width(min: IndexListColumn.docs.minWidth, ideal: 80)
                .alignment(.numeric)
            TableColumn(IndexListColumn.records.title, value: \.numRecords) { row in countCell(row.numRecords, .records) }
                .width(min: IndexListColumn.records.minWidth, ideal: 80)
                .alignment(.numeric)
            TableColumn(IndexListColumn.terms.title, value: \.numTerms) { row in countCell(row.numTerms, .terms) }
                .width(min: IndexListColumn.terms.minWidth, ideal: 80)
                .alignment(.numeric)
            TableColumn(IndexListColumn.fields.title, value: \.numFields) { row in countCell(row.numFields, .fields) }
                .width(min: IndexListColumn.fields.minWidth, ideal: 80)
                .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Data.self) { names in
            if let name = names.first, names.count == 1 {
                Button("Query") { model.openQuery(name) }
                Button("Get Info") { model.infoPanelIndex = name }
                Button("Browse Dataset") { model.browseDataset(name) }
                Divider()
                Button("Delete Index…", role: .destructive) { model.requestDelete(name) }
            }
        } primaryAction: { names in
            if let name = names.first { model.openQuery(name) }
        }
        .onDeleteCommand {
            if let name = selectedName { model.requestDelete(name) }
        }
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.rows.isEmpty {
            if model.isLoadingInfos {
                ProgressView()
            } else if !model.filter.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: model.filter)
            } else {
                ContentUnavailableView("No Indexes", systemImage: "sparkle.magnifyingglass",
                                       description: Text("Create an index to search your data."))
            }
        }
    }

    private func countCell(_ value: Int, _ column: IndexListColumn) -> some View {
        Text(NumberFormatting.grouped(value))
            .monospacedDigit()
            .help("\(column.title): \(column.tooltip)")
    }
}
