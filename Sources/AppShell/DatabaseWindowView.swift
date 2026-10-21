import AppKit
import AnalyticsFeature
import BrowserFeature
import CLIFeature
import ConnectionsFeature
import MonitoringFeature
import RedisUI
import SettingsFeature
import SwiftUI
import VectorSearchFeature
import WorkbenchFeature

/// Keeps the window’s session alive. A launch window without a value adopts the `--open` or `--open-id` database.
struct DatabaseWindowContainer: View {
    /// A content minimum width pushes the sidebar and inspector out of view, so set the minimum on the NSWindow.
    static let minimumSize = NSSize(width: 900, height: 600)

    @Binding var id: DatabaseID?
    @Environment(AppServices.self) private var services
    @Environment(\.openWindow) private var openWindow
    @State private var session: DatabaseSession?
    @State private var failure: WindowLoadFailure?
    @State private var windowClosed = false

    var body: some View {
        Group {
            if let session {
                DatabaseWindowView(session: session)
            } else if let failure {
                failureView(failure)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onHostingWindow { window in
            window.contentMinSize = DatabaseWindowContainer.minimumSize
            LaunchActions.sizeFirstWindow(window)
        }
        .task(id: id) { await resolve() }
        .onDisappear {
            session?.windowDidDisappear()
        }
        .onWindowClose {
            windowClosed = true
            guard let session else { return }
            Task { await services.sessions.close(session.id) }
        }
    }

    private func resolve() async {
        guard let id else {
            if LaunchOpener.hasPendingTarget, let launched = await LaunchOpener.resolveOnce(services: services) {
                self.id = launched
            } else {
                failure = .noDatabase
            }

            return
        }
        failure = nil
        do {
            let resolved = try await services.sessions.session(for: id)
            if windowClosed {
                await services.sessions.close(resolved.id)
            } else {
                session = resolved
            }
        } catch DatabaseStoreError.notFound {
            failure = .notFound
        } catch {
            let ids = (try? await services.databaseStore.list().map(\.id)) ?? []
            failure = ids.contains(id) ? .error(error.localizedDescription) : .notFound
        }
    }

    @ViewBuilder
    private func failureView(_ failure: WindowLoadFailure) -> some View {
        Group {
            switch failure {
            case .notFound, .noDatabase:
                ContentUnavailableView {
                    Label(failure == .notFound ? "Database Not Found" : "No Database Selected",
                          systemImage: "cylinder.split.1x2")
                } description: {
                    Text(failure == .notFound ? "This database was removed from Keystrand."
                         : "Choose a database in the Redis Databases window.")
                } actions: {
                    Button("Show All Databases") { HomeWindowActivator.show(openWindow) }
                }
            case .error(let message):
                ContentUnavailableView {
                    Label("Unable to Open Database", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Show All Databases") { HomeWindowActivator.show(openWindow) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Database")
    }
}

enum WindowLoadFailure: Equatable {
    case notFound
    case noDatabase
    case error(String)
}

struct EditDatabaseRequest: Identifiable {
    let id = UUID()
    let config: DatabaseConfig
    let focusEnvironment: Bool
}

/// Per-window popover and prompt state, reachable from the menu bar through the focused session.
@MainActor
@Observable
final class DatabaseWindowChrome {
    var isSwitcherPresented = false
    var isOtherDatabasePromptPresented = false
    var tagsSheetDatabase: DatabaseConfig?

    static func shared(for session: DatabaseSession) -> DatabaseWindowChrome {
        session.scopedObject(DatabaseWindowChrome.self) { DatabaseWindowChrome() }
    }
}

struct DatabaseWindowView: View {
    let session: DatabaseSession
    @Environment(AppServices.self) private var services
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var editRequest: EditDatabaseRequest?
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var drawer = DrawerDragState()
    @SceneStorage("sidebar") private var storedSidebar = ""
    @SceneStorage("inspector") private var storedInspector = false
    @SceneStorage("inspectorPane") private var storedInspectorPane = InspectorPane.commandHelper.rawValue
    @SceneStorage("bottomPanel") private var storedBottomPanel = false

    private var connection: WindowConnectionModel { WindowConnectionModel.shared(for: session) }
    private var bottom: BottomPanelModel { BottomPanelModel.shared(for: session) }
    private var inspector: InspectorState { InspectorState.shared(for: session) }
    private var chrome: DatabaseWindowChrome { DatabaseWindowChrome.shared(for: session) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            DatabaseSidebar(session: session)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            detail
                .inspector(isPresented: Binding(get: { inspector.isShown }, set: { inspector.setShown($0) })) {
                    InspectorView(session: session)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
                .toolbar { toolbarContent }
        }
        .navigationTitle(DatabaseWindowTitle.title(session: session))
        .navigationSubtitle(DatabaseWindowTitle.subtitle(session: session))
        .focusedSceneValue(\.databaseSession, session)
        .shellStatusAlerts(session.toasts)
        .productionConfirmations(session.confirmations)
        .productionPrompt(session: session)
        .logicalDatabasePrompt(session: session)
        .sheet(item: $editRequest) { request in
            DatabaseFormView(mode: .edit(request.config), focusEnvironment: request.focusEnvironment,
                             onSaved: { _ in
                                 Task { await connection.databaseWasEdited() }
                             })
                .environment(services)
                .environment(services.settings)
        }
        .sheet(item: Binding(get: { chrome.tagsSheetDatabase }, set: { chrome.tagsSheetDatabase = $0 })) { config in
            ManageTagsSheet(database: config)
                .environment(services)
                .environment(services.settings)
        }
        .onAppear {
            session.windowDidAppear()
            restoreSceneState()
        }
        .onChange(of: session.navigator.openBottomTools) { _, _ in syncBottomTools() }
        .onChange(of: session.navigator.bottomToolRequest?.id) { _, _ in
            guard case .bottomPanel(let tool)? = session.navigator.bottomToolRequest?.request,
                  BottomPanelModel.tools.contains(tool) else { return }
            bottom.open(tool, navigator: session.navigator)
        }
        .onChange(of: session.navigator.isInsightsOpen) { _, _ in inspector.pull(from: session.navigator) }
        .onChange(of: session.navigator.insightsTab) { _, _ in inspector.pull(from: session.navigator) }
        .onChange(of: inspector.isShown) { _, shown in
            inspector.push(to: session.navigator)
            storedInspector = shown
        }
        .onChange(of: inspector.pane) { _, pane in
            inspector.push(to: session.navigator)
            storedInspectorPane = pane.rawValue
        }
        .onChange(of: bottom.isVisible) { _, visible in storedBottomPanel = visible }
        .onChange(of: DatabaseSidebarItem.current(session.navigator)) { _, item in
            storedSidebar = item.rawValue
            normalizeClusterDetails()
        }
        .onChange(of: session.connectionKind) { _, _ in normalizeClusterDetails() }
        .onChange(of: session.config) { _, _ in
            Task { await connection.configDidChange() }
        }
        .onChange(of: session.overviewError) { _, _ in
            Task { await connection.overviewErrorDidChange() }
        }
        .task {
            session.navigator.onOpenHome = { HomeWindowActivator.show(openWindow) }
            session.navigator.onEditDatabase = { focus in
                Task {
                    guard let full = try? await services.databaseStore.get(session.id) else { return }
                    editRequest = EditDatabaseRequest(config: full, focusEnvironment: focus)
                }
            }
            syncBottomTools()
            inspector.pull(from: session.navigator)
            if let redirect = DeepLinkRedirects.consume(session.id) { session.navigator.navigate(redirect) }
            RecentDatabases.shared.reload(services: services)
            await connection.connectOnFirstAppearance()
            if session.state.isConnected { LaunchActions.applyDatabase(session: session) }
            let tips = LiveTipsModel.shared(for: session)
            if session.state.isConnected { await tips.refresh() } else { await tips.load() }
        }
        .onChange(of: session.state.isConnected) { _, connected in
            if connected { LaunchActions.applyDatabase(session: session) }
        }
    }

    // MARK: Detail column

    /// A 1 pt inset keeps AppKit split views from expanding into the sidebar, toolbar and inspector safe areas.
    private var detail: some View {
        splitDetail
            .padding([.top, .horizontal], 1)
    }

    /// A second `VSplitView` pane lays out under the floating sidebar, so use a SwiftUI stack.
    private var splitDetail: some View {
        VStack(spacing: 0) {
            FixedPane { sectionContent }
                .frame(minHeight: DrawerLayout.minMainHeight, maxHeight: .infinity)
            if connection.phase.showsBottomPanel, bottom.isShown(session.navigator) {
                DrawerDivider { [drawer, settings] translation in
                    drawer.drag(translation, storedSizes: settings.ui.bottomPanelSizes)
                } onEnded: { [drawer, settings] in
                    if let sizes = drawer.endDrag(storedSizes: settings.ui.bottomPanelSizes) {
                        settings.ui.bottomPanelSizes = sizes
                    }
                }
                DrawerPane(session: session, drawer: drawer, storedSizes: settings.ui.bottomPanelSizes)
            }

            windowToolbarAnchor
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [drawer] in drawer.totalHeight = $0 }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch connection.phase {
        case .connecting:
            ProgressView("Connecting to \(session.config.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disconnected:
            ContentUnavailableView {
                Label("Disconnected", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("\(session.config.name) is disconnected.")
            } actions: {
                Button("Connect") { Task { await connection.connect() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView {
                Label(TitleCase.make(error.title), systemImage: "bolt.horizontal.circle")
            } description: {
                Text(error.message)
            } actions: {
                Button("Try Again") { Task { await connection.reconnect() } }
                Button("Edit Database…") { session.navigator.navigate(.editDatabase(focusEnvironment: false)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            sectionView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch DatabaseSidebarItem.current(session.navigator) {
        case .browser:
            BrowserView(session: session, keyDetails: KeyDetailsComposer.view(for:),
                        addKeyForm: KeyDetailsComposer.addKeyForm(type:context:))
        case .workbench:
            WorkbenchView(session: session)
        case .vectorSearch:
            VectorSearchView(session: session)
        case .databaseAnalysis:
            DatabaseAnalysisView(session: session)
        case .slowLog:
            SlowLogView(session: session)
        case .clusterDetails:
            ClusterDetailsView(session: session)
        case .pubSub:
            PubSubView(session: session)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DatabaseSwitcherButton(session: session)
        }
        ToolbarItem(placement: .principal) {
            DatabaseActivityView(session: session, isCompact: inspector.isShown)
        }
    }

    /// SwiftUI orders `.primaryAction` items by view-tree order. This anchor follows section content to put window items last.
    private var windowToolbarAnchor: some View {
        Color.clear
            .frame(height: 0)
            .accessibilityHidden(true)
            .toolbar { trailingToolbarContent }
    }

    @ToolbarContentBuilder
    private var trailingToolbarContent: some ToolbarContent {
        ToolbarSpacer(.fixed, placement: .primaryAction)
        if session.databaseCount > 1 {
            ToolbarItem(placement: .primaryAction) {
                LogicalDatabasePicker(session: session)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { bottom.isShown(session.navigator) },
                                 set: { bottom.setVisible($0, navigator: session.navigator) })) {
                Label("Bottom Panel", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .toggleStyle(.button)
            .disabled(!connection.phase.showsBottomPanel)
            .help(bottom.isShown(session.navigator) ? "Hide Bottom Panel (⇧⌘Y)" : "Show Bottom Panel (⇧⌘Y)")
            Toggle(isOn: Binding(get: { inspector.isShown }, set: { inspector.setShown($0) })) {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .toggleStyle(.button)
            .help(inspector.isShown ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        }
    }

    // MARK: State sync

    private func syncBottomTools() {
        let navigator = session.navigator
        if navigator.openBottomTools.contains(.commandHelper) {
            navigator.openBottomTools.remove(.commandHelper)
            inspector.show(.commandHelper)
        }

        bottom.sync(navigator)
    }

    private func restoreSceneState() {
        let chromeState = SceneRestoreMemory.shared(for: session)
        guard !chromeState.didRestore else { return }
        chromeState.didRestore = true
        if let item = DatabaseSidebarItem(rawValue: storedSidebar) {
            item.apply(to: session.navigator)
        }

        if let pane = InspectorPane(rawValue: storedInspectorPane) { inspector.select(pane) }
        if storedInspector { inspector.setShown(true) }
        if storedBottomPanel { bottom.setVisible(true, navigator: session.navigator) }
        inspector.push(to: session.navigator)
    }

    private func normalizeClusterDetails() {
        guard session.state.isConnected else { return }
        let current = DatabaseSidebarItem.current(session.navigator)
        let resolved = current.resolved(isCluster: session.isCluster)
        if resolved != current { resolved.apply(to: session.navigator) }
    }
}

/// Constrains feature content to the split view’s space so its minimum size cannot push the sidebar or inspector out of view.
struct FixedPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            content()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
        }
        .frame(minWidth: 320, maxWidth: .infinity)
    }
}

/// Only the drawer reads drag state, so dragging re-renders its frame without re-rendering the whole window.
@MainActor
@Observable
final class DrawerDragState {
    var totalHeight: CGFloat = 0
    private(set) var dragFraction: Double?
    @ObservationIgnored private var dragStartHeight: CGFloat?

    private var effectiveTotal: CGFloat { totalHeight > 0 ? totalHeight : 700 }

    func bottomHeight(storedSizes: [Double]) -> CGFloat {
        let fraction = dragFraction ?? BottomPanelSplit.bottomFraction(from: storedSizes)
        return DrawerLayout.clampedBottom((effectiveTotal * fraction).rounded(), total: effectiveTotal)
    }

    func drag(_ translation: CGFloat, storedSizes: [Double]) {
        let start = dragStartHeight ?? bottomHeight(storedSizes: storedSizes)
        if dragStartHeight == nil { dragStartHeight = start }
        dragFraction = Double(DrawerLayout.clampedBottom(start - translation, total: effectiveTotal) / effectiveTotal)
    }

    /// Ends the drag; returns the sizes to persist when they changed.
    func endDrag(storedSizes: [Double]) -> [Double]? {
        dragStartHeight = nil
        guard let sizes = BottomPanelSplit.sizes(bottomHeight: bottomHeight(storedSizes: storedSizes),
                                                 totalHeight: effectiveTotal),
              sizes != storedSizes else { return nil }
        return sizes
    }
}

struct DrawerPane: View {
    let session: DatabaseSession
    let drawer: DrawerDragState
    let storedSizes: [Double]

    var body: some View {
        FixedPane { BottomPanelView(session: session) }
            .frame(height: drawer.bottomHeight(storedSizes: storedSizes))
    }
}

enum DrawerLayout {
    static let minMainHeight: CGFloat = 240
    static let minBottomHeight: CGFloat = 140

    /// Keeps both the section content and the drawer at their minimum heights; the section wins when space runs out.
    static func clampedBottom(_ height: CGFloat, total: CGFloat) -> CGFloat {
        let upper = max(total - minMainHeight - DrawerDivider.thickness, minBottomHeight)
        return min(max(height, minBottomHeight), upper)
    }
}

struct DrawerDivider: View {
    nonisolated static let thickness: CGFloat = 1
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    var body: some View {
        Divider()
            .frame(height: Self.thickness)
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { onChanged($0.translation.height) }
                            .onEnded { _ in onEnded() }
                    )
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

final class SceneRestoreMemory {
    var didRestore = false

    @MainActor
    static func shared(for session: DatabaseSession) -> SceneRestoreMemory {
        session.scopedObject(SceneRestoreMemory.self) { SceneRestoreMemory() }
    }
}

struct DatabaseSwitcherButton: View {
    let session: DatabaseSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var chrome = DatabaseWindowChrome.shared(for: session)
        Button {
            chrome.isSwitcherPresented.toggle()
        } label: {
            Label("Switch Database", systemImage: "cylinder.split.1x2")
        }
        .help("Switch Database (⌘O)")
        .popover(isPresented: $chrome.isSwitcherPresented, arrowEdge: .bottom) {
            DatabasePickerPopover(currentDatabaseID: session.id, onSelect: { config in
                chrome.isSwitcherPresented = false
                openWindow(value: config.id)
            }, onOpenHome: {
                chrome.isSwitcherPresented = false
                HomeWindowActivator.show(openWindow)
            })
        }
    }
}

/// Logical database menu with db0…db63 and “Other…” for higher indexes.
struct LogicalDatabasePicker: View {
    let session: DatabaseSession
    nonisolated static let otherTag = -1

    var body: some View {
        let count = session.databaseCount
        Picker("Logical Database", selection: Binding(get: { session.effectiveDB }, set: { select($0) })) {
            ForEach(Self.menuIndexes(count: count, current: session.effectiveDB), id: \.self) { index in
                Text("db\(index)").tag(index)
            }
            if count > 64 {
                Divider()
                Text("Other…").tag(Self.otherTag)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(LogicalDatabaseSwitch.isBlocked(session: session))
        .help("Logical database")
    }

    nonisolated static func menuIndexes(count: Int, current: Int) -> [Int] {
        var indexes = Array(0..<min(max(count, 1), 64))
        if current >= 64 { indexes.append(current) }
        return indexes
    }

    private func select(_ index: Int) {
        if index == Self.otherTag {
            DatabaseWindowChrome.shared(for: session).isOtherDatabasePromptPresented = true
        } else {
            LogicalDatabaseSwitch.select(index, session: session)
        }
    }
}

@MainActor
enum LogicalDatabaseSwitch {
    /// The logical database cannot change while Workbench runs commands.
    static func isBlocked(session: DatabaseSession) -> Bool {
        WorkbenchViewModel.shared(for: session).isRunning
    }

    static func select(_ index: Int, session: DatabaseSession) {
        guard index >= 0, index != session.effectiveDB, !isBlocked(session: session) else { return }
        Task {
            do {
                try await session.select(db: index)
            } catch {
                session.toasts.error(error, title: "Unable to Switch Database")
            }
        }
    }
}

private struct LogicalDatabasePromptModifier: ViewModifier {
    let session: DatabaseSession
    @State private var text = ""

    func body(content: Content) -> some View {
        @Bindable var chrome = DatabaseWindowChrome.shared(for: session)
        content.alert("Choose Logical Database", isPresented: $chrome.isOtherDatabasePromptPresented) {
            TextField("Database Index", text: $text)
            Button("Choose") {
                if let index = Int(text.trimmingCharacters(in: .whitespaces)), (0..<session.databaseCount).contains(index) {
                    LogicalDatabaseSwitch.select(index, session: session)
                } else {
                    NSSound.beep()
                }

                text = ""
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { text = "" }
        } message: {
            Text("Enter a database index from 0 to \(max(session.databaseCount - 1, 0)).")
        }
    }
}

/// “Not Now” dismisses the production database prompt for every database.
private struct ProductionPromptModifier: ViewModifier {
    let session: DatabaseSession

    func body(content: Content) -> some View {
        let model = ProductionPromptModel.shared(for: session)
        content
            .background {
                Color.clear
                    .alert(ProductionPromptModel.title,
                           isPresented: Binding(get: { model.isOpen }, set: { if !$0, model.isOpen { model.close() } })) {
                        Button(ProductionPromptModel.confirmLabel) { model.openDatabaseSettings() }
                            .keyboardShortcut(.defaultAction)
                        Button(ProductionPromptModel.dismissLabel, role: .cancel) { model.notNow() }
                    } message: {
                        Text(ProductionPromptModel.message)
                    }
            }
            .task(id: model.triggerKey) { await model.evaluate() }
    }
}

extension View {
    func productionPrompt(session: DatabaseSession) -> some View {
        modifier(ProductionPromptModifier(session: session))
    }

    func logicalDatabasePrompt(session: DatabaseSession) -> some View {
        modifier(LogicalDatabasePromptModifier(session: session))
    }
}
