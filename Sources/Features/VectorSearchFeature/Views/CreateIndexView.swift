import RedisUI
import SwiftUI

struct CreateIndexView: View {
    let model: VectorSearchViewModel
    @Bindable var page: CreateIndexViewModel

    var body: some View {
        HSplitView {
            if page.mode == .browse {
                KeysPickerView(picker: page.keys, selectedKey: page.selectedKey) { key in
                    Task { await page.selectKey(key, type: page.keys.keyType) }
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
            }

            SchemaPane(page: page)
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .toolbar { toolbarItems }
        .sheet(item: $page.fieldEditor) { draft in
            FieldEditorSheet(page: page, initial: draft).sheetSize(.small).sheetAlerts(page.session)
        }
        .confirmationDialog("Discard Field Changes?",
                            isPresented: Binding(get: { page.pendingKey != nil },
                                                 set: { if !$0 { page.cancelPendingKey() } }),
                            titleVisibility: .visible, presenting: page.pendingKey) { pending in
            Button("Discard and Load", role: .destructive) { Task { await page.confirmPendingKey(pending) } }
            Button("Keep Editing", role: .cancel) { page.cancelPendingKey() }
        } message: { _ in
            Text("You changed the index fields. Loading another key replaces them with the fields of that key.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            BackToIndexesButton(model: model)
            Picker("View", selection: $page.viewMode) {
                ForEach(CreateIndexViewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(page.mode == .probing)
            .help("Show the schema as a table or as the FT.CREATE command")

            Button { page.beginAddField() } label: {
                Label("Add Field…", systemImage: "plus")
            }
            .disabled(!page.mode.isEditable)
            .help(page.mode.isEditable ? "Add a field to the index schema" : "Sample indexes cannot be edited")

            let reason = page.createDisabledReason
            let isBusy = page.isCreating || model.loadingSample != nil
            Button {
                Task { await model.createIndexFromPage() }
            } label: {
                if isBusy {
                    Label { Text("Create Index") } icon: { ProgressView().controlSize(.small) }
                } else {
                    Label("Create Index", systemImage: "checkmark")
                }
            }
            .labelStyle(.titleOnly)
            .buttonStyle(.glassProminent)
            .disabled(reason != nil || isBusy || page.mode == .probing)
            .help(reason ?? "Run the FT.CREATE command")
        }
    }
}

struct SchemaPane: View {
    @Bindable var page: CreateIndexViewModel

    var body: some View {
        VStack(spacing: 0) {
            if page.showsNameEditor || page.isSampleMode {
                header
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = page.skippedNotice {
                Divider()
                StatusBar { Text(notice).help(notice) }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if page.isSampleMode {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title).font(.title3.weight(.semibold))
                LabeledContent("Prefix") {
                    Text(page.prefix).font(.body.monospaced()).textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                IndexNameField(page: page)
                HStack(spacing: 8) {
                    Text("Prefix").foregroundStyle(.secondary)
                    TextField("Prefix", text: $page.prefix, prompt: Text("Key prefix, for example bike:"))
                        .fontDesign(.monospaced)
                        .help("Keys starting with this prefix are indexed.")
                    if page.mode == .manual {
                        Picker("Key Type", selection: $page.keyType) {
                            Text("Hash").tag(SearchIndexKeyType.hash)
                            Text("JSON").tag(SearchIndexKeyType.json)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if page.mode == .probing || (page.isLoadingFields && page.fields.isEmpty) {
            ProgressView()
        } else if let error = page.fieldsError {
            ErrorStateView(message: error)
        } else if page.viewMode == .command && (!page.fields.isEmpty || page.mode == .manual) {
            CommandPreview(command: page.command)
        } else if page.fields.isEmpty {
            if page.mode == .manual {
                ContentUnavailableView {
                    Label("No Fields", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(page.emptySchemaText)
                } actions: {
                    Button("Add Field…") { page.beginAddField() }
                }
            } else {
                ContentUnavailableView {
                    Label("Select a Key", systemImage: "key")
                } description: {
                    Text(page.emptySchemaText)
                    if let probeError = page.probeError { Text(probeError) }
                }
            }
        } else {
            SchemaTable(page: page)
        }
    }
}

/// Index name in the title row: plain `.title3` field; Return or leaving the field applies it, a duplicate name
/// is refused.
struct IndexNameField: View {
    @Bindable var page: CreateIndexViewModel
    @FocusState private var isFocused: Bool

    private var text: Binding<String> {
        Binding(get: { page.isEditingName ? page.nameDraft : page.indexName }, set: { value in
            if !page.isEditingName { page.beginEditingName() }
            page.nameDraft = value
            page.validateNameDraft()
        })
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Index Name", text: text, prompt: Text("Index name"))
                .textFieldStyle(.plain)
                .font(.title3.monospaced())
                .focused($isFocused)
                .onSubmit { page.commitName() }
                .onExitCommand { page.cancelEditingName() }
                .onChange(of: isFocused) { _, focused in
                    if !focused, page.isEditingName, !page.commitName() { page.cancelEditingName() }
                }
            if let error = page.nameError ?? (page.isDuplicateName ? VectorSearchStrings.duplicateIndexName : nil) {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .help(error)
            }
        }
    }
}

struct SchemaTable: View {
    @Bindable var page: CreateIndexViewModel
    @State private var selection = Set<String>()

    var body: some View {
        Table(page.fields, selection: $selection) {
            TableColumn("") { field in
                Toggle("Include \(field.name)", isOn: Binding(get: { page.isSampleMode || page.isChecked(field) },
                                                             set: { page.setChecked(field, $0) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!page.mode.isEditable)
            }
            .width(24)
            TableColumn("Field") { field in
                MonospacedCell(field.name)
            }
            .width(min: 100, ideal: 200)
            TableColumn("Sample Value") { field in
                Text(field.sampleValue)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(TextTruncation.formatLongName(field.sampleValue))
            }
            .width(min: 120, ideal: 280)
            TableColumn("Type") { field in
                Text(page.isSampleMode ? field.type.label : Self.typeText(field))
                    .lineLimit(1)
                    .help(EditableFieldTypes.shortDescription(field.type))
            }
            .width(min: 100, ideal: 220)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, ids.count == 1, let field = page.fields.first(where: { $0.id == id }),
               page.mode.isEditable {
                Button("Edit Field…") { page.beginEdit(field) }
                Button(page.isChecked(field) ? "Exclude from Index" : "Include in Index") {
                    page.setChecked(field, !page.isChecked(field))
                }
                Divider()
                Button("Remove Field", role: .destructive) { page.removeField(field) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let field = page.fields.first(where: { $0.id == id }) { page.beginEdit(field) }
        }
        .onDeleteCommand {
            for field in page.fields where selection.contains(field.id) { page.removeField(field) }
        }
    }

    static func typeText(_ field: IndexFieldDraft) -> String {
        guard field.type == .vector else { return field.type.label }
        let dims = field.vector.dimensions.map(String.init) ?? "?"
        return "VECTOR (\(field.vector.algorithm.rawValue), \(field.vector.dataType.rawValue), \(dims))"
    }
}

struct CommandPreview: View {
    let command: String

    var body: some View {
        if command.isEmpty {
            ContentUnavailableView("No Command", systemImage: "chevron.left.forwardslash.chevron.right",
                                   description: Text("Add at least one field to generate the FT.CREATE command."))
        } else {
            CodeEditorView(text: .constant(command), language: .redis, isEditable: false)
                .overlay(alignment: .topTrailing) {
                    CopyButton(text: command, help: "Copy Command", title: "Copy")
                        .padding(8)
                }
        }
    }
}

struct KeysPickerView: View {
    let picker: KeysPickerViewModel
    let selectedKey: Data?
    let onSelect: (Data) -> Void
    @State private var filterText = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Picker("Key Type", selection: Binding(get: { picker.keyType },
                                                          set: { type in Task { await picker.setKeyType(type) } })) {
                        Text("Hash").tag(SearchIndexKeyType.hash)
                        Text("JSON").tag(SearchIndexKeyType.json)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Only Hash and JSON keys can be indexed.")
                    Button {
                        Task { await picker.refresh() }
                    } label: {
                        Label("Refresh Keys", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(picker.isScanning)
                    .help("Refresh Keys")
                }
                SearchField(text: $filterText, placeholder: "Filter Keys", debounce: .milliseconds(200),
                            onDebouncedChange: { picker.filter = $0 })
            }
            .padding(12)
            Divider()
            if let error = picker.error {
                ErrorStateView(message: error) { Task { await picker.refresh() } }
            } else {
                List(selection: Binding(get: { selectedKey }, set: { key in if let key { onSelect(key) } })) {
                    ForEach(picker.tree) { node in
                        PickerNodeRow(node: node, picker: picker)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if picker.tree.isEmpty {
                        if picker.isScanning {
                            ProgressView()
                        } else if picker.items.isEmpty {
                            ContentUnavailableView("No Keys", systemImage: "key",
                                                   description: Text("This database has no keys of this type."))
                        } else {
                            ContentUnavailableView.search(text: picker.filter)
                        }
                    }
                }
            }

            Divider()
            StatusBar {
                Text(picker.footerText).monospacedDigit()
            } accessory: {
                Button("Scan More") { Task { await picker.scanMore() } }
                    .buttonStyle(.borderless)
                    .disabled(!picker.canScanMore)
                    .help("Each extra scan adds load on the server and keeps more keys in memory.")
            }
        }
    }
}

struct PickerNodeRow: View {
    let node: PickerTreeNode
    let picker: KeysPickerViewModel

    var body: some View {
        if let key = node.keyName {
            HStack(spacing: 6) {
                KeyTypeIcon(type: picker.keyType.keyType)
                Text(node.name)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(RedisKeyName(key).displayString())
            .tag(key)
        } else if let path = node.folderPath {
            DisclosureGroup(isExpanded: Binding(get: { picker.expandedFolders.contains(path) },
                                                set: { if $0 != picker.expandedFolders.contains(path) {
                                                    picker.toggleFolder(path)
                                                } })) {
                ForEach(node.children) { child in
                    PickerNodeRow(node: child, picker: picker)
                }
            } label: {
                Label(node.name.isEmpty ? " " : node.name, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .badge(node.keyCount)
            }
        }
    }
}

struct FieldEditorSheet: View {
    let page: CreateIndexViewModel
    @State private var draft: FieldEditorDraft
    @FocusState private var nameFocused: Bool

    init(page: CreateIndexViewModel, initial: FieldEditorDraft) {
        self.page = page
        _draft = State(initialValue: initial)
    }

    private var errors: [FieldEditorDraft.Input: String] { page.fieldErrors(draft) }

    var body: some View {
        SheetForm(title: draft.isNew ? "Add Field" : "Edit Field", primaryTitle: draft.isNew ? "Add" : "Save",
                  isPrimaryDisabled: !errors.isEmpty,
                  onCancel: { page.fieldEditor = nil },
                  onPrimary: { page.commitFieldEditor(draft) }) {
            Form {
                Section {
                    if draft.isNew {
                        TextField("Name", text: $draft.name, prompt: Text("Field name"))
                            .fontDesign(.monospaced)
                            .focused($nameFocused)
                        errorText(.name)
                    } else {
                        LabeledContent("Name") {
                            Text(draft.name).font(.body.monospaced()).textSelection(.enabled)
                        }
                        if !draft.sampleValue.isEmpty {
                            LabeledContent("Sample Value") {
                                Text(draft.displaySample)
                                    .font(.body.monospaced())
                                    .lineLimit(3)
                                    .truncationMode(.tail)
                                    .textSelection(.enabled)
                            }
                            .help(TextTruncation.formatLongName(draft.sampleValue))
                        }
                    }

                    Picker("Type", selection: $draft.type) {
                        ForEach(EditableFieldTypes.all, id: \.self) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text(EditableFieldTypes.description(draft.type))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if draft.type == .vector { vectorOptions }
                if draft.type == .text { textOptions }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .defaultFocus($nameFocused, true)
    }

    @ViewBuilder
    private var vectorOptions: some View {
        Section("Vector Options") {
            Picker("Algorithm", selection: $draft.algorithm) {
                ForEach(VectorAlgorithm.allCases) { Text($0.rawValue).tag($0) }
            }
            .help("FLAT compares against every vector and returns exact results. HNSW walks a graph for faster, approximate results on large sets.")
            Picker("Vector type", selection: $draft.dataType) {
                ForEach(VectorDataType.available(supportsFloat16: page.supportsFloat16)) { Text($0.rawValue).tag($0) }
            }
            .help("TYPE: numeric type of each vector component.")
            errorText(.dataType)
            numberField("Dimensions", text: $draft.dimensions, prompt: "384", input: .dimensions,
                        help: "DIM: vector length. Stored vectors and query vectors must all have it.")
            Picker("Distance metric", selection: $draft.distanceMetric) {
                ForEach(VectorDistanceMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .help("DISTANCE_METRIC: how closeness is measured (Euclidean, inner product or cosine).")
            numberField("Initial capacity", text: $draft.initialCap, prompt: "Optional", input: .initialCap,
                        help: "INITIAL_CAP: number of vectors to pre-allocate memory for.")
            if draft.algorithm == .flat {
                numberField("Block size", text: $draft.blockSize, prompt: "Optional", input: .blockSize,
                            help: "BLOCK_SIZE: vectors stored per memory block.")
            } else {
                numberField("Max edges", text: $draft.maxEdges, prompt: "16", input: .maxEdges,
                            help: "M: links each graph node keeps. Raising it improves recall and costs memory.")
                numberField("Max neighbors", text: $draft.maxNeighbors, prompt: "200", input: .maxNeighbors,
                            help: "EF_CONSTRUCTION: candidates checked when a vector joins the graph. Raising it improves recall and slows indexing.")
                numberField("Candidate limit", text: $draft.candidateLimit, prompt: "10", input: .candidateLimit,
                            help: "EF_RUNTIME: candidates kept while a KNN query walks the graph. Raising it improves recall and adds latency.")
                numberField("Epsilon", text: $draft.epsilon, prompt: "0.01", input: .epsilon,
                            help: "EPSILON: margin added to a range query's radius while walking the graph. Larger values find more candidates.")
            }
        }
    }

    @ViewBuilder
    private var textOptions: some View {
        Section("Text Options") {
            numberField("Weight", text: $draft.weight, prompt: "1", input: .weight,
                        help: "WEIGHT: multiplier for matches in this field when ranking results.")
            Picker("Phonetic matcher", selection: $draft.phonetic) {
                ForEach(PhoneticMatcher.allCases) { Text($0.title).tag($0) }
            }
            .help("PHONETIC: also match words that sound alike in the chosen language.")
        }
    }

    @ViewBuilder
    private func numberField(_ title: String, text: Binding<String>, prompt: String, input: FieldEditorDraft.Input,
                             help: String) -> some View {
        TextField(title, text: text, prompt: Text(prompt))
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .help(help)
        errorText(input)
    }

    @ViewBuilder
    private func errorText(_ input: FieldEditorDraft.Input) -> some View {
        if let message = errors[input], input != .name || !draft.name.isEmpty {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
