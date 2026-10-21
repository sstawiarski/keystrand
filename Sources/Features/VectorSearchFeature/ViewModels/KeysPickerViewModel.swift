import Foundation
import Observation
import RedisUI

/// Scans HASH and JSON keys with client-side filtering and the database tree delimiters.
@Observable
@MainActor
final class KeysPickerViewModel {
    struct Item: Identifiable, Hashable {
        var id: Data { name }
        var name: Data
        var display: String
        var lowercased: String
    }

    static let scanCount = 10_000

    let session: DatabaseSession
    private(set) var keyType: SearchIndexKeyType = .hash
    private(set) var items: [Item] = []
    private(set) var state: KeyScanState?
    private(set) var isScanning = false
    private(set) var error: String?

    var filter = "" {
        didSet {
            guard filter != oldValue else { return }
            if !isFiltered { expandedFolders = [] }
            Task { await rebuildTree() }
        }
    }

    private(set) var treeOptions = PickerTreeOptions()
    private(set) var tree: [PickerTreeNode] = []
    private(set) var rows: [PickerTreeRow] = []
    private(set) var expandedFolders: Set<String> = []
    private var generation = 0
    private var treeGeneration = 0
    private var didLoadTreeSettings = false

    init(session: DatabaseSession) {
        self.session = session
    }

    var visibleItems: [Item] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { $0.lowercased.contains(needle) }
    }

    private var isFiltered: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }

    var canScanMore: Bool { !isScanning && state.map { !$0.isComplete } ?? false }

    var footerText: String {
        if isScanning { return "Scanning…" }
        guard let state else { return "" }
        let count = items.count == 1 ? "1 key" : "\(NumberFormatting.grouped(items.count)) keys"
        if state.isComplete { return count }
        let total = state.total.map(NumberFormatting.grouped) ?? "?"
        return "\(count) · scanned ~\(NumberFormatting.grouped(state.scanned)) of \(total)"
    }

    func setKeyType(_ type: SearchIndexKeyType) async {
        guard type != keyType else { return }
        keyType = type
        await refresh()
    }

    func refresh() async {
        generation += 1
        items = []
        state = nil
        await loadTreeSettingsIfNeeded()
        await rebuildTree()
        await scan(continuing: nil)
    }

    func scanMore() async {
        guard canScanMore else { return }
        await scan(continuing: state)
    }

    private func scan(continuing previous: KeyScanState?) async {
        let token = generation
        isScanning = true
        error = nil
        defer { if token == generation { isScanning = false } }
        let request = ScanRequest(match: "*", type: keyType == .hash ? .hash : .json, count: Self.scanCount)
        do {
            let next = try await KeyScanner(session: session).scan(request, continuing: previous)
            guard token == generation else { return }
            let known = Set(items.map(\.name))
            let added = next.keys.map(\.name).filter { !known.contains($0) }
            let newItems = await Task.detached(priority: .userInitiated) {
                added.map { name -> Item in
                    let display = RedisKeyName(name).displayString()
                    return Item(name: name, display: display, lowercased: display.lowercased())
                }
            }.value
            guard token == generation else { return }
            items += newItems
            state = next
            await rebuildTree()
        } catch {
            guard token == generation else { return }
            self.error = error.localizedDescription
        }
    }

    // MARK: - Tree

    func loadTreeSettingsIfNeeded() async {
        guard !didLoadTreeSettings else { return }
        didLoadTreeSettings = true
        treeOptions = PickerTreeOptions(await session.services.databaseSettingsStore.settings(for: session.id))
    }

    /// Applies and persists tree settings (shared with the Browser's tree view of this database).
    func applyTreeSettings(_ options: PickerTreeOptions) async {
        guard options != treeOptions else { return }
        treeOptions = options
        expandedFolders = []
        do {
            try await session.services.databaseSettingsStore.update(session.id) {
                $0.treeViewDelimiters = options.delimiters
                $0.treeViewDelimiterPrefixLength = options.prefixLength
                $0.treeViewSort = options.sort
            }
        } catch {
            session.toasts.error(error)
        }

        await rebuildTree()
    }

    func rebuildTree() async {
        treeGeneration += 1
        let token = treeGeneration
        let keys = visibleItems.map { (name: $0.name, display: $0.display) }
        let options = treeOptions
        let built = await Task.detached(priority: .userInitiated) {
            PickerKeyTree.build(keys, options: options)
        }.value
        guard token == treeGeneration else { return }
        tree = built
        if isFiltered { expandedFolders = Self.folderPaths(built) }
        updateRows()
    }

    func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) { expandedFolders.remove(path) } else { expandedFolders.insert(path) }
        updateRows()
    }

    private func updateRows() {
        rows = PickerKeyTree.flatten(tree, expanded: expandedFolders)
    }

    private static func folderPaths(_ nodes: [PickerTreeNode]) -> Set<String> {
        var out = Set<String>()
        var stack = nodes
        while let node = stack.popLast() {
            guard let path = node.folderPath else { continue }
            out.insert(path)
            stack += node.children
        }

        return out
    }
}
