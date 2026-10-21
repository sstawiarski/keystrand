import RedisUI
import SwiftUI

/// Vector Set key value view.
public struct VectorSetKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        VectorSetBody(context: context).id(KeyIdentity(context))
    }
}

private struct VectorSetBody: View {
    let context: KeyDetailsContext
    @State private var model: VectorSetViewModel
    @State private var width: CGFloat = 1_000
    @State private var pendingRemove: VectorRemoval?

    init(context: KeyDetailsContext) {
        self.context = context
        _model = State(initialValue: VectorSetViewModel(context: context))
    }

    private var settings: SettingsStore { context.session.services.settings }
    private var compact: Bool { KeyDetailsLayout.isCompact(width) }

    var body: some View {
        VStack(spacing: 0) {
            SimilaritySearchForm(model: model)
            Divider()
            KeySubheaderBar {
                Text(model.results == nil ? "Elements" : "Similar Elements").font(.headline)
                if model.isLoading || model.isSearching, model.hasLoaded { ProgressView().controlSize(.small) }
            } trailing: {
                ValueFormatPicker(selection: Binding(get: { settings.browser.valueFormat },
                                                     set: { settings.browser.valueFormat = $0 }),
                                  compact: compact)
                if model.results != nil {
                    Button { model.clearResults() } label: { Label("Show All Elements", systemImage: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                        .help("Clear the results and show every element")
                } else {
                    AddItemsButton("Add Elements", help: "Add elements to the vector set") { model.openAddPanel() }
                }
            }
            Divider()
            Group {
                if model.results != nil {
                    SimilarityResultsTable(model: model, onRemove: { pendingRemove = VectorRemoval(name: $0) })
                } else {
                    VectorElementTable(model: model, onRemove: { pendingRemove = VectorRemoval(name: $0) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .trackingWidth($width)
        .task { await model.load() }
        .onChange(of: context.state.refreshGeneration) { Task { await model.refresh() } }
        .onChange(of: settings.browser.valueFormat) { Task { await model.formatChanged() } }
        .destructiveConfirmation(item: $pendingRemove, title: { RemovalText.title(Bytes.text($0.name)) },
                                 message: { _ in RemovalText.message(keyName: context.keyText,
                                                                     lastItemWarning: model.lastItemWarning()) },
                                 confirmTitle: "Remove") { removal in
            Task { await model.remove(removal.name) }
        }
        .sheet(isPresented: Binding(get: { model.details != nil }, set: { if !$0 { model.details = nil } })) {
            VectorElementDetailsSheet(model: model).sheetAlerts(context.session)
        }
        .sheet(isPresented: $model.isAddPanelOpen) {
            VectorAddElementsSheet(model: model, keyName: context.keyText).sheetAlerts(context.session)
        }
    }
}

private struct VectorRemoval: Identifiable {
    let name: Data
    var id: Data { name }
}

// MARK: - Search form

private struct SimilaritySearchForm: View {
    @Bindable var model: VectorSetViewModel
    @State private var showsFilterHelp = false
    @State private var showsCommand = false
    @State private var filterSelection: TextSelection?

    var body: some View {
        Form {
            Section("Find Similar") {
                Picker("Search by", selection: $model.mode) {
                    Text("Vector").tag(SimilarityMode.vector)
                    Text("Element").tag(SimilarityMode.element)
                }
                .pickerStyle(.segmented)
                LabeledContent(model.mode == .vector ? "Vector" : "Element") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Query", text: $model.queryText,
                                  prompt: Text(model.mode == .vector ? "0.12, 0.5, 0.33 or a FP32 blob" : "Element name"))
                            .labelsHidden()
                            .fontDesign(.monospaced)
                            .onSubmit { Task { await model.search() } }
                        if let error = model.queryError { FieldHint(text: error, isError: true) }
                    }
                }
                Stepper("Results: \(model.resultCount)", value: $model.resultCount,
                        in: 1...VectorSetCommands.maxSimilarityCount)
                    .monospacedDigit()
                filterRow
                DisclosureGroup("Search Options", isExpanded: $model.showsAdvanced) {
                    TextField("Exploration factor (EF)", text: $model.efText, prompt: Text("Default"))
                        .help("Higher values are more accurate and slower")
                    TextField("Maximum distance (EPSILON)", text: $model.epsilonText, prompt: Text("0.2"))
                        .help("Only return elements within this distance (0–1)")
                }
                HStack(alignment: .firstTextBaseline) {
                    CommandPreviewBar(command: commandText, isExpanded: $showsCommand)
                        .disabled(model.request == nil)
                    Spacer()
                    Button("Reset") { model.resetForm() }
                        .help("Reset the search form")
                    Button("Find Similar") { Task { await model.search() } }
                        .disabled(model.request == nil || model.isSearching)
                        .help(model.request == nil ? "Enter a vector or an element to search" : "Run VSIM")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var commandText: String {
        if model.isBuildingPreview || model.debouncedPreview == nil { return "Building command…" }
        return model.debouncedPreview ?? ""
    }

    private var filterRow: some View {
        LabeledContent("Filter") {
            HStack {
                filterField
                Button { showsFilterHelp = true } label: { Label("Filter Syntax", systemImage: "questionmark.circle") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Filter Syntax")
                    .popover(isPresented: $showsFilterHelp, arrowEdge: .bottom) { FilterHelp() }
            }
        }
    }

    private var filterField: some View {
        TextField("Filter", text: $model.filter, selection: $filterSelection,
                  prompt: Text(".stock < 10 and .brand == \"acme\""))
            .labelsHidden()
            .fontDesign(.monospaced)
            .onChange(of: filterSelection) { _, selection in model.filterCaret = caretOffset(selection) }
            .textInputSuggestions {
                ForEach(model.filterCompletions, id: \.suggestion) { completion in
                    Text("." + completion.suggestion)
                        .textInputCompletion(completion.text)
                }
            }
            .onSubmit { Task { await model.search() } }
    }

    private func caretOffset(_ selection: TextSelection?) -> Int? {
        guard let selection, case .selection(let range) = selection.indices else { return nil }
        let text = model.filter
        guard range.upperBound <= text.endIndex else { return nil }
        return range.upperBound.utf16Offset(in: text)
    }
}

private struct FilterHelp: View {
    var body: some View {
        Form {
            Section {
                Text("Filters are expressions evaluated against each element's JSON attributes.")
                    .foregroundStyle(.secondary)
            }
            Section("Operators") {
                LabeledContent("Attribute") { Text(".stock").font(.body.monospaced()) }
                LabeledContent("Comparison") { Text("== != < <= > >=").font(.body.monospaced()) }
                LabeledContent("Logic") { Text("and or not").font(.body.monospaced()) }
                LabeledContent("Membership") { Text("in [ … ]").font(.body.monospaced()) }
                LabeledContent("String") { Text("\"…\"").font(.body.monospaced()) }
            }
            Section("Examples") {
                ForEach([".stock < 10", ".brand == \"acme\"", ".score >= 0.8 and .lang == \"en\"",
                         ".label in [\"draft\", \"final\"]"], id: \.self) { example in
                    Text(example).font(.body.monospaced()).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Element list

private struct VectorElementTable: View {
    let model: VectorSetViewModel
    let onRemove: (Data) -> Void
    @State private var selection: Data?

    var body: some View {
        if let error = model.errorMessage, model.rows.isEmpty {
            ErrorStateView(message: error) { Task { await model.load() } }
        } else if !model.hasLoaded {
            LoadingBody()
        } else if model.rows.isEmpty {
            ContentUnavailableView("No Elements", systemImage: "move.3d")
        } else {
            VStack(spacing: 0) {
                table
                Divider()
                PagedStatusBar(text: model.listStatusText, isLoadingMore: model.isLoadingMore,
                               canLoadMore: model.canLoadMore, onLoadMore: { model.loadMore() })
            }
        }
    }

    private var table: some View {
        let ids = model.rows.map(\.id)
        return Table(model.rows, selection: $selection) {
            TableColumn("Element") { row in
                FormattedValueCell(result: row.formatted, collapsedText: row.collapsed, format: model.formatContext.format,
                                   columnTitle: "Element")
                    .loadsMore(when: KeyDetailsLayout.isNearEnd(row.id, in: ids)) { model.loadMore() }
            }
            .width(min: 100, ideal: 160)
            TableColumn("Attributes") { row in
                Text(row.attributes ?? "")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.attributes ?? "No attributes")
            }
            .width(min: 80, ideal: 180)
            TableColumn("") { row in
                VectorRowActions(model: model, name: row.name)
            }
            .width(56)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Data.self) { ids in
            if let name = ids.first { VectorRowMenu(model: model, name: name, onRemove: onRemove) }
        } primaryAction: { ids in
            if let name = ids.first { Task { await model.openDetails(name) } }
        }
        .onDeleteCommand { if let selection { onRemove(selection) } }
    }
}

private struct VectorRowActions: View {
    let model: VectorSetViewModel
    let name: Data

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await model.openDetails(name) } } label: {
                Label("Show Details", systemImage: "doc.text.magnifyingglass")
            }
            .help("Show Details")
            Button { model.findSimilar(to: name) } label: {
                Label("Find Similar Elements", systemImage: "sparkle.magnifyingglass")
            }
            .help("Find Similar Elements")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

private struct VectorRowMenu: View {
    let model: VectorSetViewModel
    let name: Data
    let onRemove: (Data) -> Void

    var body: some View {
        Button("Show Details") { Task { await model.openDetails(name) } }
        Button("Find Similar Elements") { model.findSimilar(to: name) }
        Button("Copy Element Name") { Pasteboard.copy(Bytes.text(name)) }
        Divider()
        Button("Remove Element…", role: .destructive) { onRemove(name) }
    }
}

// MARK: - Results

private struct SimilarityResultsTable: View {
    @Bindable var model: VectorSetViewModel
    let onRemove: (Data) -> Void
    @State private var selection: Data?
    @State private var sortOrder = [KeyPathComparator(\SimilarityMatch.sortScore, order: .reverse)]
    @State private var columns = TableColumnCustomization<SimilarityMatch>()

    var body: some View {
        let results = model.sortedResults
        if results.isEmpty {
            ContentUnavailableView("No Similar Elements", systemImage: "sparkle.magnifyingglass",
                                   description: Text("No element matches the query and filter."))
        } else {
            VStack(spacing: 0) {
                table
                Divider()
                StatusBar {
                    Text("\(results.count) results").monospacedDigit()
                }
            }
            .onChange(of: sortOrder) { _, order in applySort(order) }
        }
    }

    private var table: some View {
        Table(model.sortedResults, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Rank", value: \.rank) { match in
                Text("#\(match.rank)").monospacedDigit()
            }
            .width(min: 44, ideal: 56)
            .customizationID("rank")
            TableColumn("Element", value: \.nameText) { match in
                let name = model.resultRows[match.name]
                FormattedValueCell(result: name?.result ?? .text(match.nameText), collapsedText: name?.collapsed,
                                   format: model.formatContext.format, columnTitle: "Element")
            }
            .width(min: 120, ideal: 240)
            .customizationID("element")
            .disabledCustomizationBehavior(.visibility)
            TableColumnForEach(model.knownAttributeKeys, id: \.self) { key in
                TableColumn(key) { match in
                    if let value = model.resultAttributes[match.name]?[key] {
                        Text(value).lineLimit(1).help(value)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 60, ideal: 120)
                .customizationID("attr:" + key)
                .defaultVisibility(.hidden)
            }
            TableColumn("Similarity", value: \.sortScore) { match in
                Text(VectorSetCommands.similarityText(match.score))
                    .monospacedDigit()
                    .foregroundStyle(match.score >= VectorSetCommands.highSimilarity ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
            }
            .width(min: 80, ideal: 100)
            .alignment(.numeric)
            .customizationID("similarity")
            TableColumn("") { match in
                VectorRowActions(model: model, name: match.name)
            }
            .width(min: 56, ideal: 56)
            .customizationID("actions")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Data.self) { ids in
            if let name = ids.first { VectorRowMenu(model: model, name: name, onRemove: onRemove) }
        } primaryAction: { ids in
            if let name = ids.first { Task { await model.openDetails(name) } }
        }
        .onDeleteCommand { if let selection { onRemove(selection) } }
    }

    private func applySort(_ order: [KeyPathComparator<SimilarityMatch>]) {
        guard let first = order.first else { return }
        let ascending = first.order == .forward
        let field: SimilaritySortField
        switch first.keyPath {
        case \SimilarityMatch.rank: field = .rank
        case \SimilarityMatch.nameText: field = .element
        default: field = .similarity
        }

        model.setResultSort(field, ascending: ascending)
    }
}

// MARK: - Element details

private struct VectorElementDetailsSheet: View {
    @Bindable var model: VectorSetViewModel

    private var details: ElementDetailsState? { model.details }
    private var isDirty: Bool { details?.isEditingAttributes == true }

    var body: some View {
        SheetForm(title: "Element “\(Bytes.short(details.map { Bytes.text($0.name) } ?? ""))”",
                  primaryTitle: "Save Attributes",
                  isPrimaryDisabled: !isDirty,
                  isWorking: details?.isSaving == true,
                  cancelTitle: isDirty ? "Cancel" : "Done",
                  onCancel: { model.details = nil },
                  onPrimary: { Task { await model.saveAttributes() } }) {
            if let details {
                if details.isLoading {
                    LoadingBody()
                } else if let error = details.error {
                    ErrorStateView(message: error)
                } else {
                    form(details)
                }
            }
        }
        .sheetSize(.large)
    }

    private func form(_ details: ElementDetailsState) -> some View {
        Form {
            Section {
                CodeEditorView(text: .constant(details.vectorText), language: .plain, isEditable: false,
                               showsLineNumbers: false, wrapsLines: true)
                    .frame(height: 120)
                HStack {
                    Spacer()
                    if details.isTruncated {
                        Button("Save to File…") { download() }
                    } else {
                        CopyButton(text: details.vectorText, help: "Copy Vector", title: "Copy")
                    }
                }
            } header: {
                Text("Vector")
            } footer: {
                FieldHint(text: "\(details.vectorValues.count) dimensions. The embedding used for similarity search and ranking.")
            }
            Section {
                CodeEditorView(text: Binding(get: { model.details?.draftAttributes ?? "" },
                                             set: { model.updateDraftAttributes($0) }),
                               language: .json, isEditable: !details.isSaving, placeholder: "No attributes",
                               showsLineNumbers: false)
                    .frame(height: 200)
                if isDirty {
                    HStack {
                        Spacer()
                        Button("Revert") { model.revertDraftAttributes() }
                    }
                }
            } header: {
                Text("Attributes")
            } footer: {
                if let warning = model.draftAttributesWarning {
                    InlineMessage(warning, kind: .warning)
                } else {
                    FieldHint(text: "JSON metadata used by filter expressions and hybrid queries.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func download() {
        guard let details = model.details else { return }
        do {
            _ = try FileSaver.save(Data(model.vectorDownloadText().utf8), suggestedName: Bytes.text(details.name) + "_vector.txt")
        } catch {
            model.context.report(error)
        }
    }
}

// MARK: - Add elements

private struct VectorAddElementsSheet: View {
    @Bindable var model: VectorSetViewModel
    let keyName: String

    var body: some View {
        SheetForm(title: "Add Elements to “\(Bytes.short(keyName))”", primaryTitle: "Add Elements",
                  isPrimaryDisabled: !model.isAddValid, isWorking: model.isSaving,
                  onCancel: { model.isAddPanelOpen = false }, onPrimary: { Task { await model.saveDrafts() } }) {
            Form {
                Section {
                    MultiRowFormList(rows: $model.drafts, addTitle: "Add Element", makeRow: { VectorElementInput() }) { $row in
                        VectorElementInputRow(row: $row,
                                              expectedDimension: model.expectedDimension(forDraftAt: model.drafts.firstIndex { $0.id == row.id } ?? 0))
                    }
                } footer: {
                    if let dimension = model.info.inputDimension {
                        FieldHint(text: "Vectors need \(dimension) values.")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheetSize(.form)
    }
}

struct VectorElementInputRow: View {
    @Binding var row: VectorElementInput
    let expectedDimension: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $row.name, prompt: Text("Element name"))
                .labelsHidden()
                .help("Unique identifier for this vector")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Vector", text: $row.vector,
                          prompt: Text(expectedDimension.map { "Vector (\($0) values)" } ?? "Vector, e.g. 0.12, 0.5, 0.33"),
                          axis: .vertical)
                    .labelsHidden()
                    .fontDesign(.monospaced)
                    .lineLimit(1...4)
                let help = VectorParser.help(row.vector, expectedDimension: expectedDimension)
                FieldHint(text: help.text, isError: help.isError)
            }
            DisclosureGroup("Attributes (Optional)", isExpanded: $row.showsAttributes) {
                CodeEditorView(text: $row.attributes, language: .json, placeholder: "{\"price\": 10}",
                               showsLineNumbers: false, minHeight: 100, maxHeight: 100)
                    .frame(height: 100)
                if !row.attributes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !JSONParser.isValid(row.attributes) {
                    FieldHint(text: "Non-JSON attributes can't be used in filter expressions.", isError: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
