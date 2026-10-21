import AppKit
import RedisUI
import SwiftUI

/// Browser section: key list/tree, filters, search, New Key, Bulk Actions, and the key details host.
public struct BrowserView: View {
    public let session: DatabaseSession
    /// Builds the header and type view for the selected key.
    public let keyDetails: @MainActor (KeyDetailsContext) -> AnyView
    /// Extra Add Key form sections for types whose form lives in another feature (Vector Set). nil = not provided.
    public let addKeyForm: @MainActor (KeyType, AddKeyFormContext) -> AnyView?

    public init(session: DatabaseSession, keyDetails: @escaping @MainActor (KeyDetailsContext) -> AnyView,
                addKeyForm: @escaping @MainActor (KeyType, AddKeyFormContext) -> AnyView? = { _, _ in nil }) {
        self.session = session
        self.keyDetails = keyDetails
        self.addKeyForm = addKeyForm
    }

    public var body: some View {
        BrowserContentView(model: session.scopedObject(BrowserViewModel.self) { BrowserViewModel(session: session) },
                           keyDetails: keyDetails, addKeyForm: addKeyForm)
    }
}

enum BrowserLayout {
    /// Below this detail-column width only one pane is shown: the list, or the details with a Back button.
    static let singlePaneWidth: CGFloat = 720
    static let listMinWidth: CGFloat = 300
    static let listIdealWidth: CGFloat = 420
    static let detailsMinWidth: CGFloat = 380
    static let treeSelectionSettleDelay: Duration = .milliseconds(100)

    static func isSinglePane(width: CGFloat) -> Bool {
        width > 0 && width < singlePaneWidth
    }
}

/// `--sheet new-key|bulk-actions` opens its sheet once per launch.
@MainActor
enum BrowserLaunchSheet {
    private static var consumed = false

    static func take() -> String? {
        guard !consumed, let sheet = QALaunchOptions.current.sheet else { return nil }
        guard sheet == "new-key" || sheet == "bulk-actions" else { return nil }
        consumed = true
        return sheet
    }
}

struct BrowserContentView: View {
    @Bindable var model: BrowserViewModel
    let keyDetails: @MainActor (KeyDetailsContext) -> AnyView
    let addKeyForm: @MainActor (KeyType, AddKeyFormContext) -> AnyView?
    @State private var isSinglePane = false
    @State private var unavailableReason: SearchUnavailableReason?
    @FocusState private var isSearchFocused: Bool

    private var session: DatabaseSession { model.session }
    private var showsDetailsAlone: Bool { isSinglePane && model.rightPanel == .details }

    var body: some View {
        GeometryReader { geometry in
            let single = BrowserLayout.isSinglePane(width: geometry.size.width)
            panes(single: single)
                .onChange(of: single, initial: true) { _, value in isSinglePane = value }
        }
        .toolbar { toolbarItems }
        .searchable(text: patternBinding, tokens: tokensBinding, suggestedTokens: .constant(suggestedTokens),
                    placement: .toolbar,
                    prompt: Text(model.searchMode == .pattern ? "Key name or pattern" : "Search values")) { type in
            Label(type.displayName, systemImage: type.symbolName)
        }
        .searchScopes(scopeBinding, activation: .onSearchPresentation) {
            Text("Key Name").tag(SearchMode.pattern)
            Text("Values (Redis Search)").tag(SearchMode.redisearch)
        }
        .searchSuggestions { BrowserSearchSuggestions(model: model) }
        .searchFocused($isSearchFocused)
        .onSubmit(of: .search) { model.applyPattern() }
        .focusedSceneValue(\.browserCommands, commands)
        .sheet(item: sheetBinding) { sheet in sheetContent(sheet).sheetAlerts(session) }
        .destructiveConfirmation(item: pendingDeleteBinding, title: { "Delete “\($0.title)”?" },
                                 message: { _ in "This key will be deleted. You can't undo this action." }) { ref in
            Task { await model.deleteKey(ref.key) }
        }
        .discardChangesConfirmation(item: $model.pendingSelection,
                                    message: "Your changes to the open key have not been saved.") { pending in
            model.discardChanges(pending)
        }
        .alert(unavailableReason?.title ?? "", isPresented: Binding(get: { unavailableReason != nil },
                                                                     set: { if !$0 { unavailableReason = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(unavailableReason?.message ?? "")
        }
        .task {
            await model.start(navigation: takeNavigation())
            switch BrowserLaunchSheet.take() {
            case "new-key": model.openAddKey()
            case "bulk-actions": model.openBulkActions()
            default: break
            }
        }
        .onChange(of: session.navigator.pending?.id) { _, _ in
            if let request = takeNavigation() { model.handleNavigation(request) }
        }
        .onChange(of: session.dbGeneration) { _, _ in model.databaseChanged() }
        .onChange(of: session.navigator.refreshGeneration) { _, _ in
            model.reload()
            model.refreshDetails()
        }
        .onChange(of: model.details?.info) { _, info in
            if let info { model.syncRow(from: info) }
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private func panes(single: Bool) -> some View {
        if single {
            if model.rightPanel == .details {
                detailsPane
            } else {
                KeysPane(model: model)
            }
        } else if model.isListHidden {
            detailsPane
        } else {
            HSplitView {
                KeysPane(model: model)
                    .frame(minWidth: BrowserLayout.listMinWidth, idealWidth: BrowserLayout.listIdealWidth,
                           maxWidth: .infinity, maxHeight: .infinity)
                detailsPane
                    .frame(minWidth: BrowserLayout.detailsMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var detailsPane: some View {
        BrowserDetailsPane(model: model, keyDetails: keyDetails).equatable()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if showsDetailsAlone {
                Button { model.closeDetails() } label: { Label("Back", systemImage: "chevron.left") }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to Keys (⌘[)")
            } else {
                viewPicker
                if model.searchMode == .redisearch {
                    SearchIndexMenu(model: model)
                }

                KeyTypeFilterMenu(model: model)
            }

            Button { model.openAddKey() } label: { Label("New Key…", systemImage: "plus") }
                .help("New Key (⇧⌘N)")
            Button { if let key = model.selectedKey { model.requestDelete(key) } } label: {
                Label("Delete Key…", systemImage: "trash")
            }
            .disabled(model.selectedKey == nil)
            .help("Delete Key")
            AutoRefreshMenu(postfix: "keys", lastRefresh: model.lastRefresh, isLoading: model.isLoading,
                            isDisabled: model.searchMode == .redisearch && model.selectedIndex == nil) {
                model.reload()
                model.refreshDetails()
            }
        }
    }

    private var viewPicker: some View {
        Picker("View", selection: Binding(get: { model.viewType }, set: { model.setViewType($0) })) {
            Label("List", systemImage: "list.bullet").tag(KeyViewType.list)
            Label("Tree", systemImage: "list.bullet.indent").tag(KeyViewType.tree)
        }
        .pickerStyle(.segmented)
        .disabled(!model.isTreeAvailable)
        .help(model.isTreeAvailable ? "View as List or Tree" : "Tree view is unavailable when key names are shown as HEX.")
        .popover(isPresented: $model.isViewOptionsPresented, arrowEdge: .bottom) {
            ViewOptionsPopover(model: model)
        }
    }

    // MARK: - Search

    private var patternBinding: Binding<String> {
        Binding(get: { model.patternText }, set: { model.searchFieldEdited($0) })
    }

    private var tokensBinding: Binding<[KeyType]> {
        Binding(get: { model.searchMode == .pattern ? model.typeFilter.map { [$0] } ?? [] : [] },
                set: { tokens in
                    guard model.searchMode == .pattern else { return }
                    model.setTypeFilter(tokens.last)
                })
    }

    private var suggestedTokens: [KeyType] {
        guard model.searchMode == .pattern, model.isTypeFilterSupported, model.typeFilter == nil else { return [] }
        return KeyTypeFilterMenu.types(capabilities: session.capabilities)
    }

    private var scopeBinding: Binding<SearchMode> {
        Binding(get: { model.searchMode }, set: { mode in
            if mode == .redisearch, let reason = model.searchUnavailableReason {
                unavailableReason = reason
            } else {
                model.setSearchMode(mode)
            }
        })
    }

    // MARK: - Sheets and confirmations

    private var sheetBinding: Binding<BrowserSheet?> {
        Binding(get: { model.sheet }, set: { value in
            if value == nil { model.sheetDismissed() } else { model.sheet = value }
        })
    }

    @ViewBuilder
    private func sheetContent(_ sheet: BrowserSheet) -> some View {
        switch sheet {
        case .newKey:
            if let addKey = model.addKey {
                NewKeySheet(model: addKey, browser: model, addKeyForm: addKeyForm)
            }
        case .bulkActions:
            if let bulk = model.bulkActions {
                BulkActionsSheet(model: bulk, browser: model)
            }
        case .renameKey:
            if let key = model.sheetKey {
                RenameKeySheet(model: model, key: key)
            }
        case .setTTL:
            if let key = model.sheetKey {
                SetTTLSheet(model: model, key: key)
            }
        }
    }

    private var pendingDeleteBinding: Binding<KeyRef?> {
        Binding(get: { model.pendingDeleteKey.map { KeyRef(key: $0, title: BrowserFormatting.shortName(model.displayName($0))) } },
                set: { model.pendingDeleteKey = $0?.key })
    }

    // MARK: - Menu bar

    private var commands: BrowserCommands {
        let model = self.model
        var commands = BrowserCommands(
            hasSelectedKey: model.selectedKey != nil,
            isTreeAvailable: model.isTreeAvailable,
            viewType: model.viewType,
            newKey: { model.openAddKey() },
            copyKeyName: { if let selected = model.selectedKey { copyKeyName(selected) } },
            renameKey: {
                if let selected = model.selectedKey, model.canRename(selected) { model.openRename(selected) }
            },
            setTTL: { if let selected = model.selectedKey { model.openSetTTL(selected) } },
            deleteKey: { if let selected = model.selectedKey { model.requestDelete(selected) } },
            deleteKeysMatchingFilter: { model.openBulkActions(tab: .delete) },
            uploadCommands: { model.openBulkActions(tab: .upload) },
            showViewOptions: { if !showsDetailsAlone { model.isViewOptionsPresented = true } },
            setViewType: { model.setViewType($0) },
            focusSearch: { isSearchFocused = true })
        commands.canHideList = model.rightPanel == .details && !showsDetailsAlone
        commands.isListHidden = model.isListHidden
        commands.toggleListHidden = { model.toggleFullScreen() }
        return commands
    }

    private func copyKeyName(_ key: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.displayName(key), forType: .string)
    }

    private func takeNavigation() -> DatabaseNavigationRequest? {
        session.navigator.consume { request in
            switch request {
            case .browser, .browseIndex: return true
            default: return false
            }
        }
    }
}

/// Equality ignores parent search and list changes; observed model properties still update the details.
private struct BrowserDetailsPane: View, Equatable {
    let model: BrowserViewModel
    let keyDetails: @MainActor (KeyDetailsContext) -> AnyView

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
    }

    var body: some View {
        Group {
            switch model.rightPanel {
            case .none:
                ContentUnavailableView("No Key Selected", systemImage: "key",
                                       description: Text("Select a key to see its details."))
            case .details:
                if let context = model.detailsContext {
                    keyDetails(context)
                        .id(context.key)
                } else if let error = model.detailsError {
                    ErrorStateView(message: error) { model.refreshDetails() }
                } else {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrowserSearchSuggestions: View {
    let model: BrowserViewModel

    var body: some View {
        if model.patternText.isEmpty && !model.historyItems.isEmpty {
            Section("Recent Searches") {
                ForEach(model.historyItems) { item in
                    Button { model.applyHistory(item) } label: {
                        Label {
                            Text(item.match).fontDesign(.monospaced)
                        } icon: {
                            if let type = item.type {
                                KeyTypeIcon(type: type, size: .small)
                            } else {
                                Image(systemName: "clock")
                            }
                        }
                    }
                    .contextMenu {
                        Button("Remove from Recents") { model.removeHistory(item.id) }
                    }
                }
                Button("Clear Recent Searches") { model.clearHistory() }
            }
        }
    }
}

struct KeyRef: Identifiable {
    let key: Data
    let title: String
    var id: Data { key }
}
