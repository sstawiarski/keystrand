import RedisUI
import SwiftUI

/// Array key value view (Redis 8.8+ `array` type): View / Search / Aggregate.
public struct ArrayKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        if context.session.capabilities.supportsArray {
            ArrayBody(context: context).id(KeyIdentity(context))
        } else {
            UnsupportedKeyView(context: context,
                               note: "This server does not provide the array commands (ARGET, ARSET, …). Arrays need Redis 8.8 or later.")
        }
    }
}

private struct ArrayRemoval: Identifiable {
    let indexes: [String]
    var id: String { indexes.joined(separator: ",") }

    var title: String {
        indexes.count == 1 ? "Remove Element “\(indexes[0])”?" : "Remove \(indexes.count) Elements?"
    }
}

private struct ArrayBody: View {
    let context: KeyDetailsContext
    @State private var model: ArrayViewModel
    @State private var width: CGFloat = 1_000
    @State private var isDeleteRangePresented = false

    init(context: KeyDetailsContext) {
        self.context = context
        _model = State(initialValue: ArrayViewModel(context: context))
    }

    private var settings: SettingsStore { context.session.services.settings }
    private var compact: Bool { KeyDetailsLayout.isCompact(width) }

    var body: some View {
        VStack(spacing: 0) {
            KeySubheaderBar {
                Picker("Mode", selection: $model.tab) {
                    ForEach(ArrayTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if model.isViewLoading || model.isSearching || model.isAggregating { ProgressView().controlSize(.small) }
            } trailing: {
                if model.tab != .aggregate {
                    ValueFormatPicker(selection: Binding(get: { settings.browser.valueFormat },
                                                         set: { settings.browser.valueFormat = $0 }),
                                      compact: compact)
                }

                if model.tab == .view {
                    Button { isDeleteRangePresented = true } label: { Label("Delete Range…", systemImage: "trash") }
                        .buttonStyle(.borderless)
                        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                        .disabled(ArrayIndex.parse(model.startText) == nil || ArrayIndex.parse(model.endText) == nil)
                        .help("Delete every element from the start index to the end index (ARDELRANGE)")
                    AddItemsButton("Add Element", help: "Add an element to the array") { model.openAddPanel() }
                }
            }
            Divider()
            Group {
                switch model.tab {
                case .view: ArrayViewTab(model: model)
                case .search: ArraySearchTab(model: model)
                case .aggregate: ArrayAggregateTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .trackingWidth($width)
        .task { await model.load() }
        .onChange(of: context.state.refreshGeneration) { Task { await model.refresh() } }
        .onChange(of: settings.browser.valueFormat) { Task { await model.formatChanged() } }
        .destructiveConfirmation("Delete Elements in Range?", isPresented: $isDeleteRangePresented,
                                 message: "Indexes \(model.startText)–\(model.endText) will be deleted from the array. This can't be undone.") {
            Task { await model.deleteViewRange() }
        }
        .sheet(isPresented: Binding(get: { model.editingIndex != nil }, set: { if !$0 { model.editingIndex = nil } })) {
            ArrayEditValueSheet(model: model).sheetAlerts(context.session)
        }
        .sheet(isPresented: $model.isAddPanelOpen) { ArrayAddSheet(model: model).sheetAlerts(context.session) }
    }
}

private struct ArrayRunRow: View {
    @Binding var showsPreview: Bool
    let preview: String
    let isRunDisabled: Bool
    let resetHelp: String
    let onReset: () -> Void
    let onRun: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            CommandPreviewBar(command: preview, isExpanded: $showsPreview)
                .disabled(preview.isEmpty)
            Spacer()
            Button("Reset", action: onReset).help(resetHelp)
            Button("Run", action: onRun)
                .disabled(isRunDisabled)
                .help("Run the command")
        }
    }
}

private struct IndexRangeRow: View {
    let title: String
    @Binding var start: String
    @Binding var end: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                field("Start index", text: $start)
                Text("to").foregroundStyle(.secondary)
                field("End index", text: $end)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text("0"))
            .labelsHidden()
            .monospacedDigit()
            .frame(width: 150)
            .onChange(of: text.wrappedValue) { _, new in
                let digits = new.filter { $0.isASCII && $0.isNumber }
                if digits != new { text.wrappedValue = digits }
            }
    }
}

// MARK: - View mode

private struct ArrayViewTab: View {
    @Bindable var model: ArrayViewModel
    @State private var pendingRemoval: ArrayRemoval?
    @State private var guardedRow: ArrayRow?
    @State private var preview: ValuePreviewItem?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    IndexRangeRow(title: "Range", start: $model.startText, end: $model.endText)
                        .onSubmit { Task { await model.runView() } }
                    Toggle("Show empty indexes", isOn: $model.showEmpty)
                        .help("On: ARGETRANGE shows gaps as Empty. Off: ARSCAN lists populated indexes only.")
                    ArrayRunRow(showsPreview: $model.showsViewPreview, preview: model.viewPreview,
                                isRunDisabled: model.viewValidationError != nil || model.isViewLoading,
                                resetHelp: "Reset to indexes 0–9",
                                onReset: { Task { await model.resetView() } },
                                onRun: { Task { await model.runView() } })
                } footer: {
                    if let error = model.viewValidationError { FieldHint(text: error, isError: true) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            content
        }
        .destructiveConfirmation(item: $pendingRemoval, title: { $0.title },
                                 message: { _ in "The elements will be permanently removed from the array." },
                                 confirmTitle: "Remove") { removal in
            Task { await model.delete(indexes: removal.indexes) }
        }
        .nonUnicodeEditGuard(isPresented: Binding(get: { guardedRow != nil }, set: { if !$0 { guardedRow = nil } }),
                             formatName: model.formatContext.format.menuLabel,
                             onEditAnyway: { if let row = guardedRow { model.beginEditing(row) } },
                             onChangeToUnicode: {
                                 model.pendingEditAfterFormatChange = guardedRow?.id
                                 model.context.session.services.settings.browser.valueFormat = .unicode
                             })
        .sheet(item: $preview) { ValuePreviewSheet(item: $0).sheetAlerts(model.context.session) }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.viewError {
            ErrorStateView(message: error) { Task { await model.runView() } }
        } else if !model.hasLoadedView {
            LoadingBody()
        } else if model.rows.isEmpty {
            ContentUnavailableView("No Elements in Range", systemImage: "rectangle.split.3x1",
                                   description: Text("Change the range or show empty indexes."))
        } else {
            table
            Divider()
            StatusBar {
                Text(statusText).monospacedDigit()
            }
        }
    }

    private var statusText: String {
        let count = "\(NumberFormatting.grouped(model.rows.count)) indexes"
        return model.selection.isEmpty ? count : "\(count) · \(model.selection.count) selected"
    }

    private var table: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("Index") { row in
                Text(row.element.index).font(.body.monospaced()).help(row.element.index)
            }
            .width(min: 60, ideal: 90, max: 200)
            TableColumn("Value") { row in
                if let formatted = row.formatted {
                    FormattedValueCell(result: formatted, collapsedText: row.collapsed, format: model.formatContext.format,
                                       columnTitle: "Value", isExpanded: model.selection == [row.id])
                } else {
                    Text("Empty").italic().foregroundStyle(.tertiary)
                }
            }
            .width(min: 120, ideal: 360)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            let rows = model.rows.filter { ids.contains($0.id) }
            if rows.count == 1, let row = rows.first {
                Button("Copy Index") { Pasteboard.copy(row.element.index) }
                if let formatted = row.formatted {
                    Button("Copy Value") { Pasteboard.copy(formatted.displayText(expanded: true)) }
                    Button("Show Value") { preview = ValuePreviewItem(result: formatted, format: model.formatContext.format) }
                }

                Button("Edit Value…") { requestEdit(row) }
                    .disabled(model.editReason(row) != nil)
                    .help(model.editReason(row) ?? "")
            }

            let removable = rows.filter { $0.element.value != nil }.map(\.id)
            if !removable.isEmpty {
                Divider()
                Button(removable.count == 1 ? "Remove Element…" : "Remove \(removable.count) Elements…", role: .destructive) {
                    pendingRemoval = ArrayRemoval(indexes: removable)
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let row = model.rows.first(where: { ids.contains($0.id) }), model.editReason(row) == nil {
                requestEdit(row)
            }
        }
        .onDeleteCommand {
            let removable = model.rows.filter { model.selection.contains($0.id) && $0.element.value != nil }.map(\.id)
            if !removable.isEmpty { pendingRemoval = ArrayRemoval(indexes: removable) }
        }
        .onKeyPress(.space) {
            guard model.selection.count == 1, let row = model.rows.first(where: { model.selection.contains($0.id) }),
                  let formatted = row.formatted else { return .ignored }
            preview = ValuePreviewItem(result: formatted, format: model.formatContext.format)
            return .handled
        }
    }

    private func requestEdit(_ row: ArrayRow) {
        if model.needsNonUnicodeGuard { guardedRow = row } else { model.beginEditing(row) }
    }
}

private struct ArrayEditValueSheet: View {
    @Bindable var model: ArrayViewModel

    var body: some View {
        SheetForm(title: "Edit Value at Index \(model.editingIndex ?? "")", primaryTitle: "Save",
                  isWorking: model.isSavingEdit,
                  onCancel: { model.editingIndex = nil }, onPrimary: { Task { await model.saveEdit() } }) {
            CodeEditorView(text: $model.editText, language: .plain, isEditable: !model.isSavingEdit,
                           showsLineNumbers: false)
                .padding(.horizontal, 20)
        }
        .sheetSize(.form)
        .destructiveConfirmation(item: $model.pendingUnicodeSave, title: { _ in "Save as Unicode?" },
                                 message: { _ in "The value is not valid in the selected format." },
                                 confirmTitle: "Save") { _ in
            Task { await model.confirmUnicodeSave() }
        }
    }
}

private struct ArrayAddSheet: View {
    @Bindable var model: ArrayViewModel

    var body: some View {
        SheetForm(title: "Add Element", primaryTitle: "Add Element", isPrimaryDisabled: !model.isAddValid,
                  isWorking: model.isAdding,
                  onCancel: { model.isAddPanelOpen = false }, onPrimary: { Task { await model.saveAdd() } }) {
            Form {
                Section {
                    TextField("Index", text: $model.addIndexText, prompt: Text("Append to the end"))
                        .monospacedDigit()
                    LabeledContent("Value") {
                        TextField("Value", text: $model.addValue, prompt: Text("Value"), axis: .vertical)
                            .labelsHidden()
                            .fontDesign(.monospaced)
                            .lineLimit(1...6)
                    }
                    Toggle("Show the added element", isOn: $model.moveToAdded)
                        .help("After adding, show the range that contains the new element")
                } footer: {
                    if let error = model.addIndexError {
                        FieldHint(text: error, isError: true)
                    } else {
                        FieldHint(text: "Leave the index empty to append. An index sets the value at that position and replaces any value there.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .sheetSize(.small)
    }
}

// MARK: - Search mode

private struct ArraySearchTab: View {
    @Bindable var model: ArrayViewModel
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach($model.predicates) { $predicate in
                        HStack {
                            Picker("Match", selection: $predicate.criteria) {
                                ForEach(ArrayGrepCriteria.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .help("Exact compares whole values, Match finds substrings, Glob uses * ? [ ] and Regex uses regular expressions.")
                            TextField("Pattern", text: $predicate.pattern, prompt: Text("Pattern"))
                                .labelsHidden()
                                .fontDesign(.monospaced)
                                .onSubmit { Task { await model.runSearch() } }
                            Button { model.predicates.removeAll { $0.id == predicate.id } } label: {
                                Label("Remove Condition", systemImage: "minus.circle")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(model.predicates.count < 2)
                            .help("Remove Condition")
                            Button { model.predicates.append(ArrayGrepPredicate()) } label: {
                                Label("Add Condition", systemImage: "plus.circle")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Add Condition")
                        }
                    }
                    if model.predicates.count >= 2 {
                        Picker("Combine conditions", selection: $model.combineWithAnd) {
                            Text("All (AND)").tag(true)
                            Text("Any (OR)").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }

                    DisclosureGroup("Options", isExpanded: $model.showsSearchOptions) {
                        LabeledContent("Range") {
                            HStack(spacing: 6) {
                                TextField("Start", text: $model.searchRangeStart, prompt: Text("-"))
                                    .labelsHidden().monospacedDigit().frame(width: 150)
                                Text("to").foregroundStyle(.secondary)
                                TextField("End", text: $model.searchRangeEnd, prompt: Text("+"))
                                    .labelsHidden().monospacedDigit().frame(width: 150)
                            }
                        }
                        .help("Leave blank to search the whole array")
                        if let error = model.searchRangeError { FieldHint(text: error, isError: true) }
                        Toggle("Ignore case (NOCASE)", isOn: $model.noCase)
                        Toggle("Return values (WITHVALUES)", isOn: $model.withValues)
                        LabeledContent("Limit (LIMIT)") {
                            HStack {
                                Toggle("Limit", isOn: $model.limitEnabled).labelsHidden()
                                TextField("Limit", text: $model.limitText, prompt: Text("10"))
                                    .labelsHidden().monospacedDigit().frame(width: 90)
                                    .disabled(!model.limitEnabled)
                            }
                        }
                        if let error = model.limitError { FieldHint(text: error, isError: true) }
                    }
                    LabeledContent("Context") {
                        HStack {
                            Toggle("Show neighbouring indexes", isOn: $model.contextEnabled).labelsHidden()
                            Stepper("± \(model.contextSize)", value: $model.contextSize, in: 0...50)
                                .monospacedDigit()
                                .disabled(!model.contextEnabled)
                        }
                    }
                    .help("Select a result to show the indexes around it")
                    ArrayRunRow(showsPreview: $model.showsSearchPreview, preview: model.searchPreview,
                                isRunDisabled: model.searchRequest == nil || model.isSearching,
                                resetHelp: "Reset the search", onReset: { model.resetSearch() },
                                onRun: { Task { await model.runSearch() } })
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            results
        }
        .onChange(of: selection) { _, id in
            guard let id, let row = model.searchRows.first(where: { $0.id == id }) else { return }
            Task { await model.toggleContext(for: row) }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let error = model.searchError {
            ErrorStateView(title: "Search Failed", message: error)
        } else if !model.hasSearched {
            ContentUnavailableView("Search the Array", systemImage: "magnifyingglass",
                                   description: Text("Enter a pattern and click Run."))
        } else if model.searchRows.isEmpty {
            ContentUnavailableView("No Matching Elements", systemImage: "magnifyingglass")
        } else {
            Table(model.searchDisplayRows, selection: $selection) {
                TableColumn("Index") { item in
                    Text(item.row.element.index)
                        .font(.body.monospaced())
                        .fontWeight(item.isCenter && item.isContext ? .semibold : .regular)
                        .foregroundStyle(item.isContext && !item.isCenter ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .padding(.leading, item.isContext ? 16 : 0)
                }
                .width(min: 60, ideal: 90, max: 200)
                TableColumn("Value") { item in
                    if let formatted = item.row.formatted {
                        FormattedValueCell(result: formatted, collapsedText: item.row.collapsed, format: model.formatContext.format,
                                           columnTitle: "Value")
                            .foregroundStyle(item.isContext && !item.isCenter ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    } else {
                        Text("Empty").italic().foregroundStyle(.tertiary)
                    }
                }
                .width(min: 120, ideal: 360)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { ids in
                if let item = model.searchDisplayRows.first(where: { ids.contains($0.id) }) {
                    Button("Copy Index") { Pasteboard.copy(item.row.element.index) }
                    if let formatted = item.row.formatted {
                        Button("Copy Value") { Pasteboard.copy(formatted.displayText(expanded: true)) }
                    }
                }
            }
            Divider()
            StatusBar {
                Text("\(NumberFormatting.grouped(model.searchRows.count)) matches").monospacedDigit()
            }
        }
    }
}

// MARK: - Aggregate mode

private struct ArrayAggregateTab: View {
    @Bindable var model: ArrayViewModel

    var body: some View {
        Form {
            Section {
                IndexRangeRow(title: "Range", start: $model.aggStartText, end: $model.aggEndText)
                    .onSubmit { Task { await model.runAggregate() } }
                Picker("Operation", selection: $model.aggOp) {
                    ForEach(ArrayAggregateOp.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.aggOp == .match {
                    TextField("Value", text: $model.aggValue, prompt: Text("Value to count"))
                        .onSubmit { Task { await model.runAggregate() } }
                }

                ArrayRunRow(showsPreview: $model.showsAggregatePreview, preview: model.aggregatePreview,
                            isRunDisabled: model.aggregateValidationError != nil || model.isAggregating,
                            resetHelp: "Reset", onReset: { model.resetAggregate() },
                            onRun: { Task { await model.runAggregate() } })
            } footer: {
                if let error = model.aggregateValidationError {
                    FieldHint(text: error, isError: true)
                } else {
                    FieldHint(text: "SUM, MIN and MAX use numeric values; AND, OR and XOR combine integers bitwise; MATCH counts equal values; USED counts populated indexes.")
                }
            }
            Section("Result") {
                if model.isAggregating {
                    ProgressView().controlSize(.small)
                } else if let error = model.aggError {
                    InlineMessage(error, kind: .error)
                } else if model.hasAggregated {
                    let text = model.aggResultIsNil ? "(nil)" : (model.aggResult ?? "")
                    LabeledContent("Result") {
                        HStack {
                            Text(text).font(.body.monospaced()).textSelection(.enabled)
                            CopyButton(text: text, help: "Copy Result")
                        }
                    }
                } else {
                    Text("Run an operation to see its result.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
