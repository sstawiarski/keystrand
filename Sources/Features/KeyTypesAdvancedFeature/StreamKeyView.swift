import RedisUI
import SwiftUI

/// Stream key value view.
public struct StreamKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        StreamBody(context: context).id(KeyIdentity(context))
    }
}

private struct StreamBody: View {
    let context: KeyDetailsContext
    @State private var model: StreamViewModel
    @State private var width: CGFloat = 1_000
    @State private var isAutoClaimOpen = false

    init(context: KeyDetailsContext) {
        self.context = context
        _model = State(initialValue: StreamViewModel(context: context))
    }

    private var settings: SettingsStore { context.session.services.settings }
    private var compact: Bool { KeyDetailsLayout.isCompact(width) }

    var body: some View {
        VStack(spacing: 0) {
            KeySubheaderBar {
                pathControl
            } trailing: {
                trailingActions
            }
            Divider()
            Group {
                switch model.viewType {
                case .data: StreamEntriesView(model: model, settings: settings, keyText: context.keyText)
                case .groups: StreamGroupsTable(model: model, keyText: context.keyText)
                case .consumers: StreamConsumersTable(model: model)
                case .messages: StreamMessagesTable(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .trackingWidth($width)
        .task { await model.load() }
        .onChange(of: context.state.refreshGeneration) { Task { await model.refresh() } }
        .onChange(of: settings.browser.valueFormat) { Task { await model.formatChanged() } }
        .sheet(isPresented: $model.isAddEntryOpen) {
            StreamAddEntrySheet(model: model, keyName: context.keyText).sheetAlerts(context.session)
        }
        .sheet(isPresented: $model.isAddGroupOpen) { StreamAddGroupSheet(model: model).sheetAlerts(context.session) }
    }

    private var pageBinding: Binding<StreamPage> {
        Binding(get: { StreamPage(model.viewType) }, set: { page in
            Task { if page == .entries { await model.showData() } else { await model.showGroups() } }
        })
    }

    @ViewBuilder
    private var pathControl: some View {
        Picker("View", selection: pageBinding) {
            Text("Entries").tag(StreamPage.entries)
            Text("Consumer Groups").tag(StreamPage.groups)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        if let group = model.selectedGroup, model.viewType == .consumers || model.viewType == .messages {
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            Button(group.displayName) { Task { await model.openGroup(group) } }
                .buttonStyle(.borderless)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .disabled(model.viewType == .consumers)
                .help("Consumers of \(group.displayName)")
            if let consumer = model.selectedConsumer, model.viewType == .messages {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(consumer.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(consumer.displayName)
            }
        }

        if model.isLoading, model.hasLoaded { ProgressView().controlSize(.small) }
    }

    @ViewBuilder
    private var trailingActions: some View {
        switch model.viewType {
        case .data:
            ValueFormatPicker(selection: Binding(get: { settings.browser.valueFormat },
                                                 set: { settings.browser.valueFormat = $0 }),
                              compact: compact)
            AddItemsButton("New Entry", help: "Add an entry to the stream") { model.openAddEntry() }
        case .groups:
            AddItemsButton("New Group", help: "Create a consumer group") { model.openAddGroup() }
        case .consumers:
            EmptyView()
        case .messages:
            Button { isAutoClaimOpen = true } label: { Label("Auto Claim…", systemImage: "arrow.triangle.branch") }
                .buttonStyle(.borderless)
                .disabled(model.consumers.isEmpty)
                .help("Transfer idle pending messages of the group to a consumer (XAUTOCLAIM)")
                .popover(isPresented: $isAutoClaimOpen, arrowEdge: .bottom) {
                    AutoClaimForm(model: model) { isAutoClaimOpen = false }
                }
        }
    }
}

// MARK: - Entries

private struct StreamEntriesView: View {
    let model: StreamViewModel
    let settings: SettingsStore
    let keyText: String
    @State private var selection: String?
    @State private var pendingDelete: StreamEntryRow?

    private var sortOrder: Binding<[KeyPathComparator<StreamEntryRow>]> {
        Binding(get: { [KeyPathComparator(\StreamEntryRow.id, order: model.sortOrder == .asc ? .forward : .reverse)] },
                set: { order in
                    let ascending = order.first?.order == .forward
                    Task { await model.setSort(ascending ? .asc : .desc) }
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.hasLoaded, let bounds = model.bounds, let range = model.range, bounds.lowerBound < bounds.upperBound {
                rangeFilter(bounds: bounds, range: range)
                Divider()
            }

            content
        }
        .destructiveConfirmation(item: $pendingDelete, title: { RemovalText.title($0.id) },
                                 message: { _ in RemovalText.message(keyName: keyText, lastItemWarning: nil) },
                                 confirmTitle: "Remove") { row in
            Task { await model.deleteEntry(row.id) }
        }
    }

    private func rangeFilter(bounds: ClosedRange<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(date(range.lowerBound))
            RangeSliderView(range: Binding(get: { model.range ?? bounds }, set: { model.range = $0 }),
                            bounds: bounds, step: 1)
                .help("Filter entries by timestamp")
            Text(date(range.upperBound))
            if model.isRangeFiltered {
                Button("Reset") { model.resetRange() }
                    .buttonStyle(.borderless)
                    .help("Show the whole stream")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage, !model.hasLoaded {
            ErrorStateView(message: error) { Task { await model.load() } }
        } else if !model.hasLoaded {
            LoadingBody()
        } else if model.rows.isEmpty {
            if model.isStreamEmpty {
                ContentUnavailableView("No Entries", systemImage: "water.waves",
                                       description: Text("Add an entry to start the stream."))
            } else {
                ContentUnavailableView.search
            }
        } else {
            table
            Divider()
            PagedStatusBar(text: statusText, isLoadingMore: model.isLoadingMore, canLoadMore: model.canLoadMore,
                           onLoadMore: { model.loadMore() })
        }
    }

    private var statusText: String {
        let shown = NumberFormatting.grouped(model.rows.count)
        guard let total = model.info?.length else { return "\(shown) entries" }
        return "\(shown) of \(NumberFormatting.grouped(total)) entries\(model.isRangeFiltered ? " · filtered by time" : "")"
    }

    private var table: some View {
        let ids = model.rows.map(\.id)
        return Table(model.rows, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Entry ID", value: \.id) { row in
                VStack(alignment: .leading, spacing: 2) {
                    if let date = row.date {
                        Text(date).font(.callout).foregroundStyle(.secondary)
                    }

                    Text(row.id).font(.body.monospaced())
                }
                .loadsMore(when: KeyDetailsLayout.isNearEnd(row.id, in: ids)) { model.loadMore() }
            }
            .width(min: 150, ideal: 200)
            TableColumnForEach(model.columns, id: \.self) { column in
                TableColumn(columnTitle(column)) { row in
                    if let result = row.values[column] {
                        FormattedValueCell(result: result, collapsedText: row.collapsed[column],
                                           format: model.formatContext.format, columnTitle: "Value",
                                           isExpanded: selection == row.id, truncateLength: StreamEntryRow.collapsedLength)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 80, ideal: 200)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = row(ids.first) {
                Button("Copy Entry ID") { Pasteboard.copy(row.id) }
                Button("Copy Entry as JSON") { Pasteboard.copy(entryJSON(row.entry)) }
                Divider()
                Button("Remove Entry…", role: .destructive) { pendingDelete = row }
            }
        }
        .onDeleteCommand { if let row = row(selection) { pendingDelete = row } }
        .onCopyCommand {
            guard let row = row(selection) else { return [] }
            return [NSItemProvider(object: row.id as NSString)]
        }
    }

    private func row(_ id: String?) -> StreamEntryRow? {
        guard let id else { return nil }
        return model.rows.first { $0.id == id }
    }

    private func columnTitle(_ column: StreamColumn) -> String {
        model.columnTitles[column]?.displayText(expanded: false) ?? Bytes.text(column.name)
    }

    private func date(_ ms: Double) -> String {
        TimestampFormatter.format(milliseconds: ms, pattern: settings.app.dateFormat, timeZone: settings.app.timezone.timeZone)
    }

    private func entryJSON(_ entry: StreamEntry) -> String {
        let members = entry.fields.map { JSONMember(key: Bytes.text($0.name), value: .string(Bytes.text($0.value))) }
        return JSONLiteral.pretty(.object([JSONMember(key: entry.id, value: .object(members))]), indent: 2)
    }
}

// MARK: - Add sheets

private struct StreamAddEntrySheet: View {
    @Bindable var model: StreamViewModel
    let keyName: String
    @FocusState private var idFocused: Bool

    var body: some View {
        SheetForm(title: "Add Entry to “\(Bytes.short(keyName))”", primaryTitle: "Add Entry",
                  isPrimaryDisabled: !model.isDraftValid, isWorking: model.isSaving,
                  onCancel: { model.isAddEntryOpen = false }, onPrimary: { Task { await model.saveEntry() } }) {
            Form {
                Section {
                    LabeledContent("Entry ID") {
                        TextField("Entry ID", text: $model.draftId, prompt: Text("*"))
                            .labelsHidden()
                            .fontDesign(.monospaced)
                            .focused($idFocused)
                    }
                        .onChange(of: model.draftId) { _, new in
                            let clean = StreamID.filterEntryId(new)
                            if clean != new { model.draftId = clean }
                        }
                        .onChange(of: idFocused) { _, focused in
                            if !focused { model.draftId = StreamID.normalizeOnBlur(model.draftId) }
                        }
                } footer: {
                    if !idFocused, let error = model.draftIdError {
                        FieldHint(text: error, isError: true)
                    } else {
                        FieldHint(text: "Timestamp-sequence number greater than the last ID, or * to generate one from the server time.")
                    }
                }
                Section("Fields") {
                    MultiRowFormList(rows: $model.draftFields, addTitle: "Add Field", makeRow: { StreamFieldInput() }) { $row in
                        TextField("Field", text: $row.name, prompt: Text("Field"))
                            .labelsHidden()
                        TextField("Value", text: $row.value, prompt: Text("Value"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(1...4)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheetSize(.form)
    }
}

private struct StreamAddGroupSheet: View {
    @Bindable var model: StreamViewModel

    var body: some View {
        SheetForm(title: "New Consumer Group", primaryTitle: "Create Group",
                  isPrimaryDisabled: model.draftGroupName.isEmpty || model.draftGroupIdError != nil,
                  isWorking: model.isSaving,
                  onCancel: { model.isAddGroupOpen = false }, onPrimary: { Task { await model.saveGroup() } }) {
            Form {
                Section {
                    TextField("Group Name", text: $model.draftGroupName)
                    GroupIdField(id: $model.draftGroupId)
                } footer: {
                    FieldHint(text: model.draftGroupIdError ?? GroupIdField.help, isError: model.draftGroupIdError != nil)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .sheetSize(.small)
    }
}

struct GroupIdField: View {
    @Binding var id: String

    static let help = "Timestamp-sequence number of the last delivered entry, $ for the last entry in the stream, or 0 for the whole stream."

    var body: some View {
        LabeledContent("Last Delivered ID") {
            TextField("Last Delivered ID", text: $id, prompt: Text("$"))
                .labelsHidden()
                .fontDesign(.monospaced)
                .onChange(of: id) { _, new in
                    let clean = StreamID.filterGroupId(new)
                    if clean != new { id = clean }
                }
        }
    }
}
