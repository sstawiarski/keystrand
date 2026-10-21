import RedisUI
import SwiftUI

/// Database > Stop and Clear Results… menu item state, published by the Workbench with `.focusedSceneValue`.
/// Equality covers the menu state only.
public struct WorkbenchCommands: Sendable, Equatable {
    public var hasResults: Bool
    public var canStop: Bool
    public var clearResults: @MainActor () -> Void
    public var stop: @MainActor () -> Void

    public init(hasResults: Bool, canStop: Bool, clearResults: @escaping @MainActor () -> Void,
                stop: @escaping @MainActor () -> Void) {
        self.hasResults = hasResults
        self.canStop = canStop
        self.clearResults = clearResults
        self.stop = stop
    }

    public static func == (lhs: WorkbenchCommands, rhs: WorkbenchCommands) -> Bool {
        lhs.hasResults == rhs.hasResults && lhs.canStop == rhs.canStop
    }
}

public extension FocusedValues {
    @Entry var workbenchCommands: WorkbenchCommands?
}

/// Workbench section: editor over results, toolbar run controls, history. Consumes `.workbench(script:)` requests.
public struct WorkbenchView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    private var model: WorkbenchViewModel { WorkbenchViewModel.shared(for: session) }

    public var body: some View {
        WorkbenchContent(model: model, navigator: session.navigator)
    }
}

enum WorkbenchSheet: String, Identifiable {
    case library
    case saveQuery

    var id: String { rawValue }
}

struct WorkbenchContent: View {
    @Bindable var model: WorkbenchViewModel
    let navigator: DatabaseNavigator
    @State private var confirmsClear = false
    @State private var sheet: WorkbenchSheet?

    var body: some View {
        VSplitView {
            WorkbenchEditorPanel(model: model)
                .frame(minHeight: 80, idealHeight: 160, maxHeight: .infinity)
            WorkbenchResultsPanel(model: model)
                .frame(minHeight: 120, idealHeight: 640, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .toolbar { toolbarItems }
        .focusedSceneValue(\.editorRunAction, EditorRunAction(canRun: canRun) { run() })
        .focusedSceneValue(\.workbenchCommands, WorkbenchCommands(
            hasResults: hasResults, canStop: canStop,
            clearResults: { confirmsClear = true }, stop: { model.stop() }))
        .destructiveConfirmation("Clear Results?", isPresented: $confirmsClear,
                                 message: "All Workbench results of this database will be deleted.",
                                 confirmTitle: "Clear") {
            Task { await model.clearResults() }
        }
        .confirmationDialog(model.flushWarning.map { "Run \($0.verbs.joined(separator: " and "))?" } ?? "",
                            isPresented: flushPresented, titleVisibility: .visible,
                            presenting: model.flushWarning) { _ in
            Button("Run", role: .destructive) { model.resolveFlushWarning(proceed: true) }
            Button("Cancel", role: .cancel) { model.resolveFlushWarning(proceed: false) }
        } message: { warning in
            Text(warning.message)
        }
        .sheet(item: expandedCard) { card in
            ExpandedResultSheet(model: model, card: card).sheetAlerts(model.session)
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .library:
                    QueryLibrarySheet(model: model) { self.sheet = nil }
                case .saveQuery:
                    SaveQuerySheet(model: model) { self.sheet = nil }
                }
            }
            .sheetAlerts(model.session)
        }
        .task { await model.loadCommandCatalog() }
        .task { await model.onAppear() }
        .onAppear(perform: consumeNavigation)
        .onChange(of: navigator.pending?.id) { _, _ in consumeNavigation() }
        .onChange(of: navigator.refreshGeneration) { _, _ in
            Task { await model.refreshIndexes() }
        }
        .onChange(of: model.session.dbGeneration) { _, _ in
            Task { await model.refreshIndexes() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: rawBinding) {
                Label("Raw Mode", systemImage: "text.alignleft")
            }
            .toggleStyle(.button)
            .disabled(model.isRunning)
            .help("Show raw output")
            Toggle(isOn: groupBinding) {
                Label("Group Results", systemImage: "square.stack")
            }
            .toggleStyle(.button)
            .disabled(model.isRunning)
            .help("Group the results of a run into one section; grouped results are shown as text")
            Menu {
                Button("Save Query…") { sheet = .saveQuery }
                    .disabled(model.isEditorEmpty)
                Button("Query Library…") { sheet = .library }
            } label: {
                Label("Query Library", systemImage: "books.vertical")
            }
            .help("Save the editor content or open a saved query")
            Button {
                confirmsClear = true
            } label: {
                Label("Clear Results…", systemImage: "trash")
            }
            .disabled(!hasResults)
            .help("Clear all results of this database")
        }
        if model.isRunning {
            ToolbarItem(placement: .primaryAction) {
                Button(action: model.stop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!canStop)
                .help("Stop (⌘.)")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: run) {
                if model.isRunning || !model.isCommandCatalogLoaded {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(!canRun)
            .help(model.isRunning ? "Running commands…" : "Run (⌘↩)")
        }
    }

    private var hasResults: Bool {
        !model.cards.isEmpty && !model.isRunning && !model.isClearing
    }

    private var canStop: Bool {
        model.isRunning && !model.isStopping
    }

    private var canRun: Bool {
        !model.isRunning && model.isCommandCatalogLoaded && !model.isEditorEmpty
    }

    private var settings: SettingsStore { model.session.services.settings }

    private var rawBinding: Binding<Bool> {
        Binding(get: { settings.app.workbenchRunQueryMode == .raw },
                set: { settings.app.workbenchRunQueryMode = $0 ? .raw : .ascii })
    }

    private var groupBinding: Binding<Bool> {
        Binding(get: { settings.app.workbenchResultsMode == .group },
                set: { settings.app.workbenchResultsMode = $0 ? .group : .default })
    }

    private var flushPresented: Binding<Bool> {
        Binding(get: { model.flushWarning != nil }, set: { presented in
            // Deferred so a button's explicit answer lands before the dismissal fallback.
            guard !presented, let pending = model.flushWarning else { return }
            Task { @MainActor in
                if model.flushWarning?.id == pending.id { model.resolveFlushWarning(proceed: false) }
            }
        })
    }

    private var expandedCard: Binding<WorkbenchCard?> {
        Binding(get: { model.card(id: model.fullscreenCardID) }, set: { model.fullscreenCardID = $0?.id })
    }

    private func run() {
        guard canRun else { return }
        Task { await model.runEditor() }
    }

    private func consumeNavigation() {
        let request = navigator.consume { request in
            if case .workbench = request { return true }
            return false
        }
        if case .workbench(let script)? = request, let script {
            model.enqueueScript(script)
        }
    }
}

/// "Expand…": one result in a large sheet with its view picker, Copy and Done.
struct ExpandedResultSheet: View {
    let model: WorkbenchViewModel
    @Bindable var card: WorkbenchCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetForm(title: card.title, primaryTitle: "Done", cancelTitle: nil, onCancel: { dismiss() },
                  onPrimary: { dismiss() }) {
            VStack(spacing: 0) {
                Divider()
                CardBodyView(model: model, card: card, isFullscreen: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
            }
        } leadingActions: {
            ResultViewPicker(model: model, card: card)
            Button("Copy") { copyResult(card.execution) }
                .disabled(card.execution.result == nil)
        }
        .sheetSize(.large)
    }
}
