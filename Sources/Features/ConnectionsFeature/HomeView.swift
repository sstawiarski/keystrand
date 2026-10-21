import RedisUI
import SwiftUI

/// Home library window with database filters, actions, and tags.
public struct HomeView: View {
    public let onOpenDatabase: @MainActor (DatabaseConfig) -> Void
    public let onDatabasesDeleted: @MainActor ([DatabaseID]) -> Void
    public let onDeepLinkCancelled: @MainActor (DatabaseDeepLink) -> Void
    private let autoDiscovery: LocalAutoDiscovery?

    @Environment(AppServices.self) private var services
    @State private var model: DatabaseListViewModel?

    /// - Parameters:
    ///   - onOpenDatabase: called after the user opens a database (AppShell opens its window).
    ///   - onDatabasesDeleted: called after databases were deleted (AppShell closes their windows).
    ///   - onDeepLinkCancelled: called when the user declines to connect a deep link.
    ///   - autoDiscovery: first-run discovery of local Redis servers; `nil` disables it.
    public init(onOpenDatabase: @escaping @MainActor (DatabaseConfig) -> Void,
                onDatabasesDeleted: @escaping @MainActor ([DatabaseID]) -> Void = { _ in },
                onDeepLinkCancelled: @escaping @MainActor (DatabaseDeepLink) -> Void = { _ in },
                autoDiscovery: LocalAutoDiscovery? = LocalAutoDiscovery.appDefault) {
        self.onOpenDatabase = onOpenDatabase
        self.onDatabasesDeleted = onDatabasesDeleted
        self.onDeepLinkCancelled = onDeepLinkCancelled
        self.autoDiscovery = autoDiscovery
    }

    public var body: some View {
        Group {
            if let model {
                HomeContentView(model: model, onOpenDatabase: onOpenDatabase, onDatabasesDeleted: onDatabasesDeleted,
                                onDeepLinkCancelled: onDeepLinkCancelled)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Redis Databases")
        .onAppear {
            if model == nil { model = DatabaseListViewModel(services: services, autoDiscovery: autoDiscovery) }
        }
    }
}

enum HomeSheet: Identifiable {
    case add
    case sentinel
    case software
    case importFile(URL?)
    case edit(DatabaseConfig)
    case clone(DatabaseConfig)
    case tags(DatabaseConfig)
    case export([DatabaseConfig])
    case deepLink(DatabaseDeepLink)

    var id: String {
        switch self {
        case .add: return "add"
        case .sentinel: return "sentinel"
        case .software: return "software"
        case .importFile: return "import"
        case .edit(let config): return "edit-\(config.id.rawValue)"
        case .clone(let config): return "clone-\(config.id.rawValue)"
        case .tags(let config): return "tags-\(config.id.rawValue)"
        case .export(let configs): return "export-" + configs.map(\.id.rawValue).joined(separator: ",")
        case .deepLink: return "deep-link"
        }
    }
}

/// `--sheet edit-database|tags` with `--home`: opens that sheet on the first row once per launch.
@MainActor
enum HomeLaunchSheet {
    private static var didApply = false

    static func take(options: QALaunchOptions = .current) -> String? {
        guard !didApply, options.home, let sheet = options.sheet, ["edit-database", "tags"].contains(sheet) else {
            return nil
        }
        didApply = true
        return sheet
    }
}

struct HomeContentView: View {
    @Bindable var model: DatabaseListViewModel
    let onOpenDatabase: @MainActor (DatabaseConfig) -> Void
    let onDatabasesDeleted: @MainActor ([DatabaseID]) -> Void
    let onDeepLinkCancelled: @MainActor (DatabaseDeepLink) -> Void

    @State private var sheet: HomeSheet?
    @State private var linkConfirmation: DeepLinkConfirmation?
    @State private var pendingRemoval: [DatabaseConfig] = []
    @State private var isRemovalPresented = false
    @State private var columns = TableColumnCustomization<DatabaseConfig>()
    @State private var didRestoreColumns = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            HomeSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Redis Databases")
        .navigationSubtitle(model.subtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .toolbar { toolbar }
        .sheet(item: $sheet) { sheet in sheetContent(sheet) }
        .destructiveConfirmation(DatabaseListLogic.removalTitle(names: pendingRemoval.map(\.name)),
                                 isPresented: $isRemovalPresented,
                                 message: DatabaseListLogic.removalMessage(names: pendingRemoval.map(\.name)),
                                 confirmTitle: "Remove") {
            let ids = pendingRemoval.map(\.id)
            pendingRemoval = []
            remove(ids)
        }
        .confirmationDialog(linkConfirmation?.title ?? "", isPresented: isLinkConfirmationPresented,
                            titleVisibility: .visible, presenting: linkConfirmation) { confirmation in
            Button("Connect") {
                Task { await model.connect(confirmation, onOpen: onOpenDatabase) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { onDeepLinkCancelled(confirmation.link) }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .focusedSceneValue(\.homeCommands, commands)
        .task {
            restoreColumns()
            await model.start()
            applyLaunchSheet()
        }
        .onChange(of: columns) { _, _ in persistColumns() }
        .onAppear { handleHomeCommand() }
        .onChange(of: HomeCommandCenter.shared.pending?.id) { _, _ in handleHomeCommand() }
        .onDisappear { model.stop() }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let error = model.loadError, model.databases.isEmpty {
            ErrorStateView(title: "Unable to Load Databases", message: error) {
                Task { await model.reload() }
            }
        } else if model.showsEmptyState {
            ContentUnavailableView {
                Label("No Databases", systemImage: "cylinder.split.1x2")
            } description: {
                Text("Add a Redis database with a connection URL, discover Sentinel primary groups, or import connections from a file.")
            } actions: {
                Button("Add Database…") { sheet = .add }
            }
        } else {
            DatabaseTableView(model: model, columns: $columns, actions: rowActions)
                .overlay { tableOverlay }
        }
    }

    @ViewBuilder
    private var tableOverlay: some View {
        if model.visibleDatabases.isEmpty {
            if model.isAutoDiscovering {
                ProgressView("Looking for Local Databases…")
            } else if !model.hasLoaded || (model.isLoading && model.databases.isEmpty) {
                ProgressView()
            } else if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                ContentUnavailableView("No Matching Databases", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Add Database…") { sheet = .add }
                Button("Discover Sentinel Databases…") { sheet = .sentinel }
                Button("Discover Redis Software Databases…") { sheet = .software }
                Divider()
                Button("Import Connections…") { sheet = .importFile(nil) }
            } label: {
                Label("Add Database", systemImage: "plus")
            } primaryAction: {
                sheet = .add
            }
            .help("Add Database (⌘N)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                exportSelection()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .help("Export Connections (⇧⌘E)")
            .disabled(model.selection.isEmpty)
            Button {
                requestRemove(model.actionTargets)
            } label: {
                Label("Remove…", systemImage: "trash")
            }
            .help("Remove Databases (⌫)")
            .disabled(model.selection.isEmpty)
        }
    }

    // MARK: - Commands

    private var commands: HomeCommands {
        HomeCommands(selectionCount: model.selection.count,
                     exportSelection: { exportSelection() },
                     editSelection: { editSelection() },
                     reload: { Task { await model.reload() } },
                     focusSearch: { isSearchFocused = true })
    }

    private var rowActions: DatabaseRowActions {
        DatabaseRowActions(
            open: { configs in open(configs) },
            edit: { config in sheet = .edit(config) },
            clone: { config in sheet = .clone(config) },
            manageTags: { config in sheet = .tags(config) },
            export: { configs in sheet = .export(configs) },
            requestRemove: { configs in requestRemove(configs) },
            importFile: { url in sheet = .importFile(url) })
    }

    private func exportSelection() {
        let targets = model.actionTargets
        guard !targets.isEmpty else { return }
        sheet = .export(targets)
    }

    private func editSelection() {
        let targets = model.actionTargets
        guard targets.count == 1, let config = targets.first else { return }
        sheet = .edit(config)
    }

    private func open(_ configs: [DatabaseConfig]) {
        for config in configs {
            Task { await model.open(config.id, onOpen: onOpenDatabase) }
        }
    }

    private func requestRemove(_ configs: [DatabaseConfig]) {
        guard !configs.isEmpty else { return }
        pendingRemoval = configs
        isRemovalPresented = true
    }

    private func remove(_ ids: [DatabaseID]) {
        Task {
            if await model.delete(ids) { onDatabasesDeleted(ids) }
        }
    }

    // MARK: - Columns

    private func restoreColumns() {
        guard !didRestoreColumns else { return }
        didRestoreColumns = true
        let shown = model.shownColumns
        for column in HomeColumn.allCases where !shown.contains(column) {
            columns[visibility: column.id] = .hidden
        }
    }

    private func persistColumns() {
        guard didRestoreColumns else { return }
        model.shownColumns = Set(HomeColumn.allCases.filter { columns[visibility: $0.id] != .hidden })
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: HomeSheet) -> some View {
        switch sheet {
        case .add:
            DatabaseFormView(mode: .add, onSaved: selectSaved)
        case .sentinel:
            DatabaseFormView(mode: .add, initialScreen: .sentinel)
        case .software:
            DatabaseFormView(mode: .add, initialScreen: .software)
        case .importFile(let url):
            DatabaseFormView(mode: .add, initialScreen: .importFile, importFile: url)
        case .deepLink(let link):
            DatabaseFormView(deepLink: link, onSaved: selectSaved)
        case .edit(let config):
            DatabaseFormView(mode: .edit(config))
        case .clone(let config):
            DatabaseFormView(mode: .clone(config), onSaved: selectSaved)
        case .tags(let config):
            TagEditorView(model: TagEditorModel(databaseName: config.name, tags: config.tags, knownTags: model.allTags),
                          isProviderManaged: config.provider == .redisSoftware) { tags in
                await model.saveTags(tags, for: config.id)
            }
        case .export(let configs):
            ExportConnectionsSheet(databases: configs) { includePasswords in
                try await model.exportData(configs.map(\.id), includePasswords: includePasswords)
            }
        }
    }

    private var isLinkConfirmationPresented: Binding<Bool> {
        Binding(get: { linkConfirmation != nil }, set: { if !$0 { linkConfirmation = nil } })
    }

    private func selectSaved(_ config: DatabaseConfig) {
        model.selection = [config.id]
    }

    private func applyLaunchSheet() {
        guard let first = model.visibleDatabases.first, let launchSheet = HomeLaunchSheet.take() else { return }
        model.selection = [first.id]
        sheet = launchSheet == "tags" ? .tags(first) : .edit(first)
    }

    private func handleHomeCommand() {
        switch HomeCommandCenter.shared.consume() {
        case .addDatabase: sheet = .add
        case .importConnections: sheet = .importFile(nil)
        case .openURL(let url): handleDeepLink(url)
        case nil: break
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let link = DatabaseDeepLink.parse(url) else {
            model.services.toasts.error("The link is not a supported Keystrand database link.", title: "Unsupported Link")
            return
        }
        if link.canAutoConnect {
            sheet = nil
            Task { linkConfirmation = await model.confirmation(for: link) }
        } else {
            sheet = .deepLink(link)
        }
    }
}

private struct HomeSidebar: View {
    @Bindable var model: DatabaseListViewModel

    var body: some View {
        List(selection: $model.filters) {
            Section("Library") {
                row(.all)
                row(.recents)
            }
            if model.hasProduction || model.hasDevelopment {
                Section("Environments") {
                    if model.hasProduction { row(.production) }
                    if model.hasDevelopment { row(.development) }
                }
            }

            let tags = model.allTags
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.self) { tag in row(.tag(tag)) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ filter: HomeFilter) -> some View {
        Label(filter.title, systemImage: filter.systemImage)
            .lineLimit(1)
            .truncationMode(.middle)
            .badge(model.count(for: filter))
            .tag(filter)
    }
}
