import RedisUI
import SwiftUI

/// Vector Search index list, index creation, and query pages with database navigation support.
public struct VectorSearchView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var body: some View {
        VectorSearchRootView(model: session.scopedObject(VectorSearchViewModel.self) {
            VectorSearchViewModel(session: session)
        })
    }
}

struct VectorSearchRootView: View {
    @Bindable var model: VectorSearchViewModel

    private var navigator: DatabaseNavigator { model.session.navigator }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: model.availability) {
                await model.loadIfNeeded()
                model.consumeNavigation()
                model.consumeLaunchSheet()
            }
            .onAppear { model.consumeNavigation() }
            .onChange(of: navigator.pending?.id) { model.consumeNavigation() }
            .onChange(of: model.session.dbGeneration) { Task { await model.loadIndexes() } }
            .onChange(of: navigator.refreshGeneration) { Task { await model.refresh() } }
            .sheet(isPresented: $model.isSamplePickerPresented) {
                SamplePickerSheet(model: model).sheetSize(.large).sheetAlerts(model.session)
            }
            .discardChangesConfirmation(isPresented: $model.isConfirmingDiscard,
                                        message: "Your changes to the index fields have not been saved.") {
                model.showList()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.availability {
        case .connecting:
            ProgressView()
        case .disconnected:
            ContentUnavailableView {
                Label("Disconnected", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("The database is disconnected.")
            } actions: {
                Button("Connect") { Task { await model.session.connect() } }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Connection Failed", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.session.reconnect() } }
            }
        case .moduleMissing:
            ContentUnavailableView {
                Label("Redis Search Not Available", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Redis Search adds querying, secondary indexes, full-text and vector search.")
            }
        case .versionTooOld:
            ContentUnavailableView {
                Label("Redis Search Version Too Old", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Vector Search uses Redis Search commands introduced in version 2.0. Redis 6 and later include a compatible version.")
            }
        case .available:
            VectorSearchStack(model: model)
        }
    }
}

/// Switches pages in place because NavigationStack hides the window toolbar items.
struct VectorSearchStack: View {
    @Bindable var model: VectorSearchViewModel

    var body: some View {
        switch model.route {
        case .entry:
            entry
        case .query:
            if let page = model.query {
                QueryPageView(model: model, page: page)
            }
        case .createIndex:
            if let page = model.createIndex {
                CreateIndexView(model: model, page: page)
            }
        }
    }

    @ViewBuilder
    private var entry: some View {
        if !model.hasLoadedList || (model.isLoadingList && model.indexNames.isEmpty) {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.indexNames.isEmpty && model.listError == nil {
            WelcomeView(model: model)
        } else {
            IndexListView(model: model)
        }
    }
}

struct BackToIndexesButton: View {
    let model: VectorSearchViewModel

    var body: some View {
        Button { model.setPath([]) } label: {
            Label("Indexes", systemImage: "chevron.left")
        }
        .help("Back to Indexes")
    }
}

/// Shown when the database has no search indexes yet.
struct WelcomeView: View {
    let model: VectorSearchViewModel

    var body: some View {
        ContentUnavailableView {
            Label("Search Your Data", systemImage: "sparkle.magnifyingglass")
        } description: {
            Text("Full-text, vector and hybrid search at in-memory speed.")
        } actions: {
            Button("Try Sample Data…") { model.isSamplePickerPresented = true }
            Button("Create Index…") { model.openCreateIndex(.existingData(initialKey: nil, keyType: nil, prefix: nil)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.loadIndexes() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
            }
        }
    }
}
