import AppKit
import Foundation
import RedisUI
import SwiftUI

/// Maps native table sort descriptors to Home fields.
struct HomeComparator: SortComparator, Hashable {
    var field: HomeSortField
    var order: Foundation.SortOrder = .forward

    func compare(_ lhs: DatabaseConfig, _ rhs: DatabaseConfig) -> ComparisonResult {
        let ascending = order == .forward
        if DatabaseListLogic.areInIncreasingOrder(lhs, rhs, field: field, ascending: ascending) { return .orderedAscending }
        if DatabaseListLogic.areInIncreasingOrder(rhs, lhs, field: field, ascending: ascending) { return .orderedDescending }
        return .orderedSame
    }
}

@MainActor
struct DatabaseRowActions {
    var open: ([DatabaseConfig]) -> Void
    var edit: (DatabaseConfig) -> Void
    var clone: (DatabaseConfig) -> Void
    var manageTags: (DatabaseConfig) -> Void
    var export: ([DatabaseConfig]) -> Void
    /// Asks for confirmation, then removes.
    var requestRemove: ([DatabaseConfig]) -> Void
    var importFile: (URL) -> Void
}

struct DatabaseTableView: View {
    @Bindable var model: DatabaseListViewModel
    @Binding var columns: TableColumnCustomization<DatabaseConfig>
    let actions: DatabaseRowActions

    var body: some View {
        Table(of: DatabaseConfig.self, selection: $model.selection, sortOrder: sortOrder,
              columnCustomization: $columns) {
            TableColumn(HomeColumn.name.title, sortUsing: HomeComparator(field: .name)) { config in
                NameCell(config: config, isConnecting: model.connecting.contains(config.id))
            }
            .width(min: 140, ideal: 200)
            .customizationID(HomeColumn.name.id)
            .disabledCustomizationBehavior(.visibility)
            TableColumn(HomeColumn.host.title, sortUsing: HomeComparator(field: .host)) { config in
                Text(config.hostPort)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(config.hostPort)
            }
            .width(min: 110, ideal: 150)
            .customizationID(HomeColumn.host.id)
            TableColumn(HomeColumn.connectionType.title, sortUsing: HomeComparator(field: .connectionType)) { config in
                Text(DatabaseListLogic.connectionTypeLabel(config.connectionType))
                    .help(DatabaseListLogic.providerLabel(config.provider).map { "Hosting provider: \($0)" } ?? "")
            }
            .width(min: 80, ideal: 100)
            .customizationID(HomeColumn.connectionType.id)
            TableColumn(HomeColumn.environment.title, sortUsing: HomeComparator(field: .environment)) { config in
                if let label = DatabaseListLogic.environmentLabel(config.environment) {
                    Text(label)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 80, ideal: 100)
            .customizationID(HomeColumn.environment.id)
            TableColumn(HomeColumn.modules.title) { config in
                ModuleSummaryText(modules: DatabaseListLogic.orderedModules(config.modules), flavor: config.providerFlavor)
            }
            .width(min: 90, ideal: 150)
            .customizationID(HomeColumn.modules.id)
            TableColumn(HomeColumn.lastConnection.title, sortUsing: HomeComparator(field: .lastConnection)) { config in
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(DatabaseListLogic.lastConnectionText(config.lastConnection, now: context.date))
                        .foregroundStyle(config.lastConnection == nil ? .secondary : .primary)
                        .help(config.lastConnection.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "Never")
                }
            }
            .width(min: 100, ideal: 140)
            .customizationID(HomeColumn.lastConnection.id)
            TableColumn(HomeColumn.tags.title, sortUsing: HomeComparator(field: .tags)) { config in
                TagText(tags: config.tags)
            }
            .width(min: 80, ideal: 140)
            .customizationID(HomeColumn.tags.id)
        } rows: {
            ForEach(model.visibleDatabases) { config in
                TableRow(config)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand { actions.requestRemove(model.actionTargets) }
        .contextMenu(forSelectionType: DatabaseID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            actions.open(model.databases(ids))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            actions.importFile(url)
            return true
        }
    }

    private var sortOrder: Binding<[HomeComparator]> {
        Binding(
            get: { [HomeComparator(field: model.sortField, order: model.sortAscending ? .forward : .reverse)] },
            set: { comparators in
                guard let first = comparators.first else { return }
                model.setSort(first.field, ascending: first.order == .forward)
            })
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<DatabaseID>) -> some View {
        let configs = model.visibleDatabases.filter { ids.contains($0.id) }
        if configs.count == 1, let config = configs.first {
            Button("Open") { actions.open([config]) }
            Divider()
            Button("Edit Database…") { actions.edit(config) }
            Button("Manage Tags…") { actions.manageTags(config) }
            Button("Clone Database…") { actions.clone(config) }
            Divider()
            Button("Copy Host and Port") { Pasteboard.copy(config.hostPort) }
            Divider()
            Button("Export…") { actions.export([config]) }
            Button("Remove…") { actions.requestRemove([config]) }
        } else if configs.count > 1 {
            Button("Open \(configs.count) Databases") { actions.open(configs) }
            Divider()
            Button("Export \(configs.count) Databases…") { actions.export(configs) }
            Button("Remove \(configs.count) Databases…") { actions.requestRemove(configs) }
        }
    }
}

enum Pasteboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct NameCell: View {
    let config: DatabaseConfig
    let isConnecting: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isConnecting {
                ProgressView().controlSize(.small)
            } else if config.isNew {
                Circle().fill(.blue).frame(width: 6, height: 6).help("New")
            }

            Text(String(config.name.prefix(200)))
                .lineLimit(1)
                .truncationMode(.tail)
            if config.dbIndex > 0 {
                Text("[db\(config.dbIndex)]").foregroundStyle(.secondary)
            }

            if config.environment == .production {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                    .help("Production")
                    .accessibilityLabel("Production")
            }
        }
        .help(DatabaseListLogic.fullDisplayName(config))
    }
}
