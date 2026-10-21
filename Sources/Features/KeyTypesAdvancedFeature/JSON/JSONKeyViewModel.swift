import Foundation
import Observation
import RedisUI

@MainActor
@Observable
final class JSONKeyViewModel {
    let context: KeyDetailsContext
    let tree: JSONTreeModel
    private var service: JSONKeyService { JSONKeyService(session: context.session, key: context.key) }

    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// True when the whole document is in memory (copy/text mode without fetching).
    private(set) var isFullyLoaded = false
    private(set) var rootType: JSONNodeType?
    private(set) var isDownloading = false
    /// True while a tree editor (scalar, container, add row, text mode) is open; refresh is disabled meanwhile.
    private(set) var isEditing = false

    init(context: KeyDetailsContext) {
        self.context = context
        self.tree = JSONTreeModel(root: .value(.null), expandRoot: true)
    }

    var actions: JSONTreeActions {
        JSONTreeActions(
            loadChildren: { [weak self] path in
                guard let self else { throw CancellationError() }
                return try await self.loadChildren(path)
            },
            fetchValue: { [weak self] path in
                guard let self else { throw CancellationError() }
                return try await self.service.fetchValue(path)
            },
            setValue: { [weak self] path, json in
                guard let self else { throw CancellationError() }
                try await self.setValue(path, json: json)
            },
            addEntry: { [weak self] parent, key, json in
                guard let self else { throw CancellationError() }
                try await self.addEntry(parent: parent, key: key, json: json)
            },
            delete: { [weak self] path in
                guard let self else { throw CancellationError() }
                try await self.delete(path)
            },
            updatesLocally: true,
            onEditingChanged: { [weak self] editing in self?.setEditing(editing) },
            onUnsavedChangesChanged: { [weak self] dirty in self?.context.state.hasUnsavedChanges = dirty },
            loadChildPage: { [weak self] paths in
                guard let self else { throw CancellationError() }
                do {
                    return try await self.service.childNodes(paths)
                } catch {
                    throw JSONCommands.mapError(error)
                }
            })
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let root = try await service.describe(.root) else { throw KeyOperationError.keyNotFound }
            rootType = root.type
            let result = try await service.loadNode(.root, type: root.type, length: root.length,
                                                    fetchCount: tree.visibleChildLimit(at: .root))
            isFullyLoaded = result.isFull
            tree.setRoot(result.node)
            tree.setExpanded(.root, true)
            tree.expanded = tree.expanded.filter { tree.node(at: $0)?.isLoaded ?? false }
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            if !hasLoaded, !KeyOperationError.isKeyNotFound(error) {
                errorMessage = error.localizedDescription
            }

            context.report(error)
        }
    }

    func refresh() async {
        guard !isEditing else { return }
        await load()
    }

    func setEditing(_ editing: Bool) {
        isEditing = editing
        context.state.isRefreshDisabled = editing
    }

    private func loadChildren(_ path: JSONPath) async throws -> JSONTreeNode {
        guard let node = tree.node(at: path), let kind = node.containerKind else {
            return try await .value(service.fetchValue(path))
        }
        let type: JSONNodeType = kind == .object ? .object : .array
        let result = try await service.loadNode(path, type: type, length: node.childCount,
                                                fetchCount: tree.visibleChildLimit(at: path))
        return result.node
    }

    // MARK: Writes

    private func setValue(_ path: JSONPath, json: String) async throws {
        guard await context.confirmWrite(title: "Edit Value in Production?",
                                         message: "The JSON value will be overwritten. This database is marked as production.",
                                         button: "Save", actionID: KeyConfirmations.editJSONValue) else {
            throw KeyValueError.invalid("Edit cancelled.")
        }
        try await service.set(path, json: json)
        await afterWrite(reloadDocument: path.isRoot)
    }

    private func addEntry(parent: JSONPath, key: String?, json: String) async throws {
        guard await context.confirmWrite(title: "Edit Value in Production?",
                                         message: "The JSON value will be overwritten. This database is marked as production.",
                                         button: "Save", actionID: KeyConfirmations.editJSONValue) else {
            throw KeyValueError.invalid("Edit cancelled.")
        }
        if let key {
            try await service.set(parent.appending(key: key), json: json)
        } else {
            try await service.append(parent, json: json)
        }

        await afterWrite(reloadDocument: false)
    }

    private func delete(_ path: JSONPath) async throws {
        _ = try await service.delete(path)
        await afterWrite(reloadDocument: false)
    }

    /// Re-read fully loaded documents in the background after writes to pick up server normalization.
    private func afterWrite(reloadDocument: Bool) async {
        await context.valueChanged()
        if reloadDocument || isFullyLoaded {
            Task { @MainActor [weak self] in await self?.reloadQuietly() }
        }
    }

    private func reloadQuietly() async {
        guard let root = try? await service.describe(.root),
              let result = try? await service.loadNode(.root, type: root.type, length: root.length,
                                                       fetchCount: tree.visibleChildLimit(at: .root)) else { return }
        rootType = root.type
        isFullyLoaded = result.isFull
        tree.setRoot(result.node)
        tree.expanded = tree.expanded.filter { tree.node(at: $0)?.isLoaded ?? false }
    }

    // MARK: Download

    func download() async {
        isDownloading = true
        defer { isDownloading = false }
        do {
            let text = try await service.fetchDocumentText()
            _ = try FileSaver.save(Data(text.utf8), suggestedName: "json_value")
        } catch {
            context.report(error)
        }
    }
}
