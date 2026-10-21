import Observation
import RedisUI
import SwiftUI

/// Database switcher list: Home's sort order, search on "name [dbN]".
@MainActor
@Observable
public final class DatabasePickerModel {
    public private(set) var databases: [DatabaseConfig] = []
    public private(set) var isLoading = false
    public var errorMessage: String?
    public var searchText = ""

    @ObservationIgnored private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            databases = try await services.databaseStore.list()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var visibleDatabases: [DatabaseConfig] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? databases : databases.filter {
            DatabaseListLogic.fullDisplayName($0).lowercased().contains(needle)
        }
        return DatabaseListLogic.sort(filtered, by: services.settings.ui.homeSorting)
    }
}

/// Database switcher popover of the database window toolbar: search, list, "Show All Databases".
public struct DatabasePickerPopover: View {
    public let currentDatabaseID: DatabaseID?
    public let onSelect: @MainActor (DatabaseConfig) -> Void
    public let onOpenHome: @MainActor () -> Void

    @Environment(AppServices.self) private var services
    @State private var model: DatabasePickerModel?

    public init(currentDatabaseID: DatabaseID?, onSelect: @escaping @MainActor (DatabaseConfig) -> Void,
                onOpenHome: @escaping @MainActor () -> Void = {}) {
        self.currentDatabaseID = currentDatabaseID
        self.onSelect = onSelect
        self.onOpenHome = onOpenHome
    }

    public var body: some View {
        Group {
            if let model {
                DatabasePickerList(model: model, currentDatabaseID: currentDatabaseID, onSelect: onSelect,
                                   onOpenHome: onOpenHome)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 320, height: 380)
        .task {
            let model = self.model ?? DatabasePickerModel(services: services)
            self.model = model
            await model.load()
        }
    }
}

private struct DatabasePickerList: View {
    @Bindable var model: DatabasePickerModel
    let currentDatabaseID: DatabaseID?
    let onSelect: @MainActor (DatabaseConfig) -> Void
    let onOpenHome: @MainActor () -> Void

    @Environment(AppServices.self) private var services
    @State private var selection: DatabaseID?

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.searchText, placeholder: "Search Databases", onSubmit: openSelection,
                        onMoveSelection: moveSelection)
                .padding(8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Show All Databases") { onOpenHome() }
                    .buttonStyle(.borderless)
                    .help("Show All Databases (⌘0)")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { selection = currentDatabaseID ?? model.visibleDatabases.first?.id }
        .onChange(of: model.searchText) { _, _ in selection = model.visibleDatabases.first?.id }
    }

    @ViewBuilder
    private var content: some View {
        let rows = model.visibleDatabases
        if let error = model.errorMessage, model.databases.isEmpty {
            ErrorStateView(title: "Unable to Load Databases", message: error) { Task { await model.load() } }
        } else if rows.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if model.databases.isEmpty {
                ContentUnavailableView("No Databases", systemImage: "cylinder.split.1x2")
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        } else {
            List(selection: $selection) {
                ForEach(rows) { config in
                    PickerRow(config: config, isCurrent: config.id == currentDatabaseID,
                              isConnecting: services.sessions.existingSession(for: config.id)?.state == .connecting)
                        .tag(config.id)
                }
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: DatabaseID.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                if let id = ids.first, let config = model.databases.first(where: { $0.id == id }) { onSelect(config) }
            }
            .onKeyPress(.return) {
                openSelection()
                return .handled
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = model.visibleDatabases.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selection.flatMap { ids.firstIndex(of: $0) }
        switch direction {
        case .up: selection = ids[max((current ?? 0) - 1, 0)]
        case .down: selection = ids[min((current ?? -1) + 1, ids.count - 1)]
        default: break
        }
    }

    private func openSelection() {
        let rows = model.visibleDatabases
        if let config = rows.first(where: { $0.id == selection }) ?? rows.first { onSelect(config) }
    }
}

private struct PickerRow: View {
    let config: DatabaseConfig
    let isCurrent: Bool
    let isConnecting: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(DatabaseListLogic.displayName(config, limit: 80))
                .lineLimit(1)
                .truncationMode(.middle)
            if config.environment == .production {
                EnvironmentLabel(environment: .production, style: .iconOnly)
            }

            Spacer(minLength: 8)
            if isConnecting {
                ProgressView().controlSize(.small)
            } else if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Current database")
            }
        }
        .help("\(DatabaseListLogic.fullDisplayName(config)) — \(config.hostPort)")
    }
}
