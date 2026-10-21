import AppKit
import RedisUI
import SwiftUI

struct KeyTreeView: View {
    @Bindable var model: BrowserViewModel
    /// Delay selection until the first layout finishes so the outline does not draw it at a stale position.
    @State private var showsSelection = false

    var body: some View {
        if model.treeRoots.isEmpty && model.isBuildingTree {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(selection: Binding(get: { showsSelection ? model.treeSelection : nil },
                                        set: { showsSelection = true; model.selectTreeRow($0) })) {
                    TreeNodeRows(model: model, nodes: model.treeRoots)
                }
                .task(id: model.searchMode) {
                    await restoreScrollPosition(model.treeScrollAnchor(), proxy: proxy, model: model)
                }
                .task {
                    try? await Task.sleep(for: BrowserLayout.treeSelectionSettleDelay)
                    guard !Task.isCancelled else { return }
                    showsSelection = true
                }
                .onDisappear {
                    model.pauseScrollTracking()
                    showsSelection = false
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: KeyTreeNodeID.self) { ids in
                switch ids.first {
                case .leaf(let key): KeyContextMenu(model: model, key: key)
                case .folder(let path): FolderContextMenu(model: model, path: path)
                case nil: EmptyView()
                }
            } primaryAction: { ids in
                switch ids.first {
                case .leaf(let key): if model.canRename(key) { model.openRename(key) }
                case .folder(let path): model.toggleFolder(path)
                case nil: break
                }
            }
            .onKeyPress(.space) { toggleSelectedFolder(nil) }
            .onKeyPress(.rightArrow) { toggleSelectedFolder(true) }
            .onKeyPress(.leftArrow) { toggleSelectedFolder(false) }
            .onDeleteCommand {
                if case .leaf(let key) = model.treeSelection { model.requestDelete(key) }
            }
            .onCopyCommand {
                guard case .leaf(let key) = model.treeSelection else { return [] }
                return [NSItemProvider(object: model.displayName(key) as NSString)]
            }
            .onExitCommand { model.closeDetails() }
        }
    }

    private func toggleSelectedFolder(_ expand: Bool?) -> KeyPress.Result {
        guard case .folder(let path) = model.treeSelection else { return .ignored }
        if let expand {
            model.setFolder(path, expanded: expand)
        } else {
            model.toggleFolder(path)
        }

        return .handled
    }
}

struct TreeNodeRows: View {
    let model: BrowserViewModel
    let nodes: [KeyTreeNode]

    var body: some View {
        ForEach(nodes) { node in
            if let key = node.keyName {
                TreeLeafRow(model: model, key: key, node: node)
                    .tag(KeyTreeNodeID.leaf(key))
                    .id(node.id)
                    .onAppear {
                        model.rowAppeared(key)
                        model.treeRowAppeared(node.id)
                    }
                    .onDisappear {
                        model.rowDisappeared(key)
                        model.treeRowDisappeared(node.id)
                    }
            } else if let path = node.folderPath {
                DisclosureGroup(isExpanded: Binding(get: { model.expandedFolders.contains(path) },
                                                    set: { model.setFolder(path, expanded: $0) })) {
                    TreeNodeRows(model: model, nodes: node.children)
                } label: {
                    TreeFolderLabel(model: model, node: node)
                        .onAppear { model.treeRowAppeared(node.id) }
                        .onDisappear { model.treeRowDisappeared(node.id) }
                }
                .tag(KeyTreeNodeID.folder(path))
                .id(node.id)
            }
        }
    }
}

/// A key row of the tree; only this row reads the key's list metadata.
struct TreeLeafRow: View {
    let model: BrowserViewModel
    let key: Data
    let node: KeyTreeNode

    var body: some View {
        KeyRowView(model: model, item: model.item(for: key) ?? KeyListItem(name: key),
                   name: BrowserFormatting.cellName(node.name.isEmpty ? node.fullName : node.name),
                   fullName: node.fullName)
    }
}

struct TreeFolderLabel: View {
    let model: BrowserViewModel
    let node: KeyTreeNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(node.name.isEmpty ? " " : BrowserFormatting.cellName(node.name))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(BrowserFormatting.percentage(node.percentage))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .badge(node.keyCount)
        .help(BrowserFormatting.folderTooltip(fullName: node.fullName, delimiters: model.treeOptions.delimiters,
                                              keyCount: node.keyCount, percentage: node.percentage))
        .accessibilityElement(children: .combine)
    }
}

struct FolderContextMenu: View {
    let model: BrowserViewModel
    let path: String

    var body: some View {
        let node = model.folderNode(path)
        Button("Expand All") { model.setFolderSubtree(path, expanded: true) }
        Button("Collapse All") { model.setFolderSubtree(path, expanded: false) }
        Button("Copy Pattern") {
            guard let node else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.folderPattern(node), forType: .string)
        }
        Divider()
        Button("Delete Keys in Folder…", role: .destructive) {
            guard let node else { return }
            model.openBulkActions(filter: BulkActionFilter(match: model.folderPattern(node), type: model.typeFilter))
        }
        .disabled(node.map { !model.canDeleteFolder($0) } ?? true)
    }
}
