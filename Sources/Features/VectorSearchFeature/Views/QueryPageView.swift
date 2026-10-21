import RedisUI
import SwiftUI

struct QueryPageView: View {
    let model: VectorSearchViewModel
    @Bindable var page: QueryPageViewModel
    @State private var editorController = CodeEditorController()
    @State private var confirmsClear = false

    var body: some View {
        HSplitView {
            VSplitView {
                editorPane
                    .frame(minHeight: 100, idealHeight: 220, maxHeight: .infinity)
                QueryResultsView(page: page)
                    .frame(minHeight: 140, maxHeight: .infinity)
            }
            .frame(minWidth: 380, maxWidth: .infinity)
            if page.isIndexPanelOpen {
                IndexInfoPane(model: model, indexName: page.indexName)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 440)
            }
        }
        .toolbar { toolbarItems }
        .focusedSceneValue(\.editorRunAction, EditorRunAction(canRun: page.canRun) { runEditor() })
        .sheet(isPresented: $page.isSaveSheetPresented) {
            SaveQuerySheet(page: page).sheetSize(.small).sheetAlerts(page.session)
        }
        .sheet(item: $page.expandedCard) { card in
            ResultExpandSheet(card: card, page: page).sheetSize(.large).sheetAlerts(page.session)
        }
        .destructiveConfirmation(flushTitle, isPresented: flushPresented,
                                 message: page.flushWarning?.message, confirmTitle: "Run") {
            page.resolveFlushWarning(proceed: true)
        }
        .destructiveConfirmation("Clear All Results?", isPresented: $confirmsClear,
                                 message: "Every result of this page will be removed.", confirmTitle: "Clear") {
            Task { await page.clearResults() }
        }
    }

    private func runEditor() {
        Task { await page.runEditor() }
    }

    private var flushTitle: String {
        "Run \(page.flushWarning?.verbs.joined(separator: " and ") ?? "Command")?"
    }

    /// Cancel resolves on the next main-actor turn so the dialog's own "Run" wins when both fire.
    private var flushPresented: Binding<Bool> {
        Binding(get: { page.flushWarning != nil }, set: { isPresented in
            guard !isPresented, let id = page.flushWarning?.id else { return }
            Task { @MainActor in
                if page.flushWarning?.id == id { page.resolveFlushWarning(proceed: false) }
            }
        })
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Index", selection: Binding(get: { page.indexName }, set: { model.openQuery($0) })) {
                    ForEach(model.indexNames, id: \.self) { name in
                        Text(IndexListLogic.displayName(name)).tag(name)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Show All Indexes") { model.setPath([]) }
            } label: {
                Text(TextTruncation.formatLongName(IndexListLogic.displayName(page.indexName), maxLength: 24, tail: 6))
            }
            .help("Switch index or show all indexes")

            Picker("View", selection: $page.tab) {
                Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right").tag(QueryEditorTab.editor)
                Label("Library", systemImage: "books.vertical").tag(QueryEditorTab.library)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show the query editor or the Query Library")

            Toggle(isOn: $page.isIndexPanelOpen) {
                Label("Index Info", systemImage: "list.bullet.rectangle")
            }
            .toggleStyle(.button)
            .help(page.isIndexPanelOpen ? "Hide Index Info" : "Show Index Info")

            moreMenu

            Button(action: runEditor) {
                if page.isRunning {
                    Label { Text("Run") } icon: { ProgressView().controlSize(.small) }
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(!page.canRun)
            .help(page.isRunning ? "Running commands…" : "Run (⌘↩)")
        }
    }

    private var moreMenu: some View {
        let reason = page.explainDisabledReason
        let templates = QueryCommands.templates(indexName: page.indexNameString, info: model.infos[page.indexName],
                                                capabilities: model.session.capabilities)
        return Menu {
            Button("Save Query…") { page.beginSave() }
                .disabled(!page.canSave)
            Menu("Insert Template") {
                ForEach(templates) { template in
                    Button(template.title) { page.apply(template, controller: editorController) }
                        .help(template.detail)
                }
            }
            if page.supportsExplain {
                Divider()
                Button("Explain") { Task { await page.explain() } }
                    .disabled(reason != nil)
                    .help(reason ?? VectorSearchStrings.explainHelp)
                Button("Profile") { Task { await page.profile() } }
                    .disabled(reason != nil)
                    .help(reason ?? VectorSearchStrings.profileHelp)
            }

            Divider()
            Button("Clear Results…") { confirmsClear = true }
                .disabled(page.cards.isEmpty || page.isClearing || page.isRunning)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More")
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorPane: some View {
        switch page.tab {
        case .editor:
            CodeEditorView(text: $page.editorText, language: .redis, completions: completionProvider,
                           onSubmit: runEditor,
                           signatureHint: signatureProvider,
                           placeholder: VectorSearchStrings.editorPlaceholder,
                           wrapsLines: false, controller: editorController)
        case .library:
            QueryLibraryView(page: page)
        }
    }

    // MARK: - Completion

    private var completionProvider: CodeCompletionProvider {
        let context = completionContext
        return { text, cursor in
            CompletionEngine().complete(text: text, cursorOffset: cursor, context: context).items.map { item in
                CodeCompletion(label: item.label, insertText: item.insertText, detail: item.detail,
                               documentation: item.documentation, kind: Self.kind(item.kind))
            }
        }
    }

    private var signatureProvider: CodeSignatureHintProvider {
        { text, cursor in
            CompletionEngine().signature(text: text, cursorOffset: cursor).map {
                CodeSignatureHint(label: $0.label, highlight: $0.highlight, documentation: $0.documentation)
            }
        }
    }

    private var completionContext: CompletionContext {
        let indexes = model.indexNames.map { String(decoding: $0, as: UTF8.self) }
        let fields = (model.infos[page.indexName]?.attributes ?? []).map {
            SearchFieldSuggestion(name: $0.queryName, type: $0.type.uppercased())
        }
        return CompletionContext(indexes: indexes, fields: fields,
                                 availability: model.session.capabilities.commandAvailability)
    }

    private static func kind(_ kind: CompletionItem.Kind) -> CodeCompletion.Kind {
        switch kind {
        case .command, .subcommand: return .command
        case .keyword: return .keyword
        case .index: return .index
        case .field: return .field
        case .function: return .other
        }
    }
}

struct SaveQuerySheet: View {
    @Bindable var page: QueryPageViewModel
    @FocusState private var focused: Bool

    private var isNameEmpty: Bool { page.saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        SheetForm(title: "Save Query", primaryTitle: "Save", isPrimaryDisabled: isNameEmpty, isWorking: page.isSaving,
                  onCancel: { page.isSaveSheetPresented = false },
                  onPrimary: { Task { await page.save() } }) {
            Form {
                Section {
                    TextField("Name", text: $page.saveName)
                        .focused($focused)
                        .onSubmit { if !isNameEmpty { Task { await page.save() } } }
                } footer: {
                    Text("The query is added to the Query Library of this index.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .defaultFocus($focused, true)
        .onAppear { focused = true }
    }
}
