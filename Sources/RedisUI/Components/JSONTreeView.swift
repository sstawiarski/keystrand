import AppKit
import SwiftUI

/// Callbacks that make `JSONTreeView` editable and lazily loaded. Leave a closure nil to hide that capability.
/// JSON text arguments are valid JSON (already checked with the shared parser).
public struct JSONTreeActions: Sendable {
    /// Fetch the children of an unloaded container at a path (lazy loading for big documents).
    public var loadChildren: (@MainActor (JSONPath) async throws -> JSONTreeNode)?
    /// Fetch `.pending` children of a paged container, one summary per child path, when "Show more" reveals them.
    public var loadChildPage: (@MainActor ([JSONPath]) async throws -> [JSONTreeNode])?
    /// Fetch the full value at a path (container edit and text mode when the document is partial).
    public var fetchValue: (@MainActor (JSONPath) async throws -> JSONValue)?
    /// Replace the value at a path (`$` for the whole document) with JSON text.
    public var setValue: (@MainActor (JSONPath, String) async throws -> Void)?
    /// Add under a container: object → `key` set, array → append (`key` nil).
    public var addEntry: (@MainActor (_ parent: JSONPath, _ key: String?, _ json: String) async throws -> Void)?
    /// Remove a non-root node.
    public var delete: (@MainActor (JSONPath) async throws -> Void)?
    /// Selection / path reporting.
    public var onSelect: (@MainActor (JSONPath) -> Void)?
    /// Apply successful edits to the local model immediately (the owner may still reload afterwards).
    public var updatesLocally: Bool
    /// True while a scalar or container editor, an add sheet, or text mode is open; false when it closes.
    public var onEditingChanged: (@MainActor (Bool) -> Void)?
    /// True while text mode holds edits that were not saved; false when they are saved or discarded.
    public var onUnsavedChangesChanged: (@MainActor (Bool) -> Void)?

    public init(loadChildren: (@MainActor (JSONPath) async throws -> JSONTreeNode)? = nil,
                fetchValue: (@MainActor (JSONPath) async throws -> JSONValue)? = nil,
                setValue: (@MainActor (JSONPath, String) async throws -> Void)? = nil,
                addEntry: (@MainActor (_ parent: JSONPath, _ key: String?, _ json: String) async throws -> Void)? = nil,
                delete: (@MainActor (JSONPath) async throws -> Void)? = nil,
                onSelect: (@MainActor (JSONPath) -> Void)? = nil,
                updatesLocally: Bool = true,
                onEditingChanged: (@MainActor (Bool) -> Void)? = nil,
                onUnsavedChangesChanged: (@MainActor (Bool) -> Void)? = nil,
                loadChildPage: (@MainActor ([JSONPath]) async throws -> [JSONTreeNode])? = nil) {
        self.loadChildren = loadChildren
        self.loadChildPage = loadChildPage
        self.fetchValue = fetchValue
        self.setValue = setValue
        self.addEntry = addEntry
        self.delete = delete
        self.onSelect = onSelect
        self.updatesLocally = updatesLocally
        self.onEditingChanged = onEditingChanged
        self.onUnsavedChangesChanged = onUnsavedChangesChanged
    }

    public static let readOnly = JSONTreeActions()
}

enum JSONTreeNavigation {
    static func nodePaths(_ rows: [JSONTreeRow]) -> [JSONPath] {
        JSONTreeNodePaths(rows: rows).paths
    }

    static func move(from current: JSONPath?, offset: Int, in rows: [JSONTreeRow]) -> JSONPath? {
        move(from: current, offset: offset, in: JSONTreeNodePaths(rows: rows))
    }

    /// The node path one step up (`offset` -1) or down (+1) from `current`; the first node when nothing is selected.
    static func move(from current: JSONPath?, offset: Int, in nodes: JSONTreeNodePaths) -> JSONPath? {
        let paths = nodes.paths
        guard !paths.isEmpty else { return nil }
        guard let current, let index = nodes.positions[current] else { return offset < 0 ? paths.last : paths.first }
        return paths[min(max(index + offset, 0), paths.count - 1)]
    }

    enum LeftAction: Equatable {
        case collapse(JSONPath)
        case select(JSONPath)
        case none
    }

    /// ← collapses an expanded container, otherwise moves to the parent.
    static func left(from current: JSONPath, isExpandedContainer: Bool) -> LeftAction {
        if isExpandedContainer { return .collapse(current) }
        if let parent = current.parent { return .select(parent) }
        return .none
    }
}

/// Collapsible JSON outline: system disclosure chevrons, monospaced text in editor colors, system selection,
/// context-menu and keyboard actions (Return edits, ⌫ deletes, ←/→ collapse/expand, ⌘C copies the value), lazy
/// loading of unloaded containers, paging of large containers and a raw-text mode.
public struct JSONTreeView: View {
    @State private var ownedModel: JSONTreeModel
    @State private var edit = JSONTreeEditState()
    @State private var textMode = false
    @State private var isTextDirty = false
    @State private var confirmDiscardText = false
    @FocusState private var treeFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let externalModel: JSONTreeModel?
    private let value: JSONValue?
    private let confirmations: ConfirmationCenter?
    private let errors: ToastCenter?
    public var actions: JSONTreeActions
    public var keyName: String?
    public var showsToolbar: Bool
    public var showsPathBar: Bool
    /// Extra trailing subheader item (for example "Save to File…" for partially loaded documents).
    public var toolbarAccessory: AnyView?

    /// Value-backed tree (formatter output, read-only by default). The root starts expanded when `initiallyExpanded`.
    public init(value: JSONValue, initiallyExpanded: Bool = true, actions: JSONTreeActions = .readOnly,
                keyName: String? = nil, showsToolbar: Bool = false, showsPathBar: Bool = false) {
        self._ownedModel = State(initialValue: JSONTreeModel(value: value, expandRoot: initiallyExpanded))
        self.externalModel = nil
        self.value = value
        self.confirmations = nil
        self.errors = nil
        self.actions = actions
        self.keyName = keyName
        self.showsToolbar = showsToolbar
        self.showsPathBar = showsPathBar
    }

    /// Model-backed tree (JSON keys): keep the model per key so expansion survives reloads. Pass the session's
    /// `confirmations` and `errors` when `actions` may ask for a production confirmation or report an error, so the
    /// edit sheets can present them.
    public init(model: JSONTreeModel, actions: JSONTreeActions = .readOnly, keyName: String? = nil,
                showsToolbar: Bool = true, showsPathBar: Bool = true, toolbarAccessory: AnyView? = nil,
                confirmations: ConfirmationCenter? = nil, errors: ToastCenter? = nil) {
        self._ownedModel = State(initialValue: model)
        self.externalModel = model
        self.value = nil
        self.confirmations = confirmations
        self.errors = errors
        self.actions = actions
        self.keyName = keyName
        self.showsToolbar = showsToolbar
        self.showsPathBar = showsPathBar
        self.toolbarAccessory = toolbarAccessory
    }

    private var model: JSONTreeModel { externalModel ?? ownedModel }
    private var operations: JSONTreeOperations { JSONTreeOperations(model: model, actions: actions, edit: edit) }

    public var body: some View {
        VStack(spacing: 0) {
            if showsToolbar {
                JSONTreeToolbar(model: model, textMode: Binding(get: { textMode }, set: { tree in
                    if !tree, textMode, isTextDirty { confirmDiscardText = true } else { textMode = tree }
                }), accessory: toolbarAccessory)
                Divider()
            }

            if textMode {
                JSONRawTextView(model: model, actions: actions, textMode: $textMode, isDirty: $isTextDirty)
            } else {
                tree
            }

            if showsPathBar, !textMode {
                JSONTreePathBar(model: model)
            }
        }
        .onChange(of: value) { _, newValue in
            if let newValue, externalModel == nil { ownedModel.setValue(newValue) }
        }
        .onChange(of: isEditing) { _, editing in actions.onEditingChanged?(editing) }
        .onDisappear { if isEditing { actions.onEditingChanged?(false) } }
        .sheet(item: Binding(get: { edit.containerSheet }, set: { if $0 == nil { edit.cancel() } })) { request in
            JSONContainerEditSheet(operations: operations, path: request.path)
                .modifier(OptionalSheetAlerts(confirmations: confirmations, errors: errors))
        }
        .sheet(item: Binding(get: { edit.addSheet }, set: { if $0 == nil { edit.cancel() } })) { request in
            JSONAddEntrySheet(operations: operations, request: request)
                .modifier(OptionalSheetAlerts(confirmations: confirmations, errors: errors))
        }
        .duplicateKeysAlert(edit.containerSheet == nil ? edit.duplicateKeys : nil) {
            operations.resolveDuplicateKeys($0, overwrite: $1)
        }
        .destructiveConfirmation(item: Binding(get: { edit.pendingDelete }, set: { edit.pendingDelete = $0 }),
                                 title: { "Delete “\(TextTruncation.formatLongName($0.label, maxLength: 60, tail: 10))”?" },
                                 message: { _ in
                                     keyName.map { "It will be removed from “\(TextTruncation.formatLongName($0, maxLength: 60, tail: 10))”." }
                                 },
                                 confirmTitle: "Delete") { request in
            operations.delete(request.path)
        }
        .discardChangesConfirmation(isPresented: $confirmDiscardText) { textMode = false }
        .onChange(of: isTextDirty) { _, dirty in actions.onUnsavedChangesChanged?(dirty) }
    }

    private var isEditing: Bool {
        textMode || edit.editingPath != nil || edit.containerSheet != nil || edit.addSheet != nil
    }

    private var tree: some View {
        let rows = model.rows(includeAddRows: false)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        JSONTreeRowView(row: row, operations: operations, isEmphasized: treeFocused,
                                        reduceMotion: reduceMotion) {
                            treeFocused = true
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body.monospaced())
            .focusable()
            .focusEffectDisabled()
            .focused($treeFocused)
            .onKeyPress(.upArrow) { moveSelection(-1, proxy: proxy) }
            .onKeyPress(.downArrow) { moveSelection(1, proxy: proxy) }
            .onKeyPress(.leftArrow) { handleLeft(proxy: proxy) }
            .onKeyPress(.rightArrow) { handleRight() }
            .onKeyPress(.return) { handleReturn() }
            .onDeleteCommand { requestDeleteOfSelection() }
            .onCopyCommand {
                guard let path = model.selectedPath, let text = operations.copyText(at: path) else { return [] }
                return [NSItemProvider(object: text as NSString)]
            }
        }
    }

    private func moveSelection(_ offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard edit.editingPath == nil,
              let path = JSONTreeNavigation.move(from: model.selectedPath, offset: offset, in: model.nodePaths()) else {
            return .ignored
        }
        select(path, revealingWith: proxy)
        return .handled
    }

    private func select(_ path: JSONPath, revealingWith proxy: ScrollViewProxy) {
        operations.select(path)
        proxy.scrollTo(JSONTreeRow.ID.node(path))
    }

    private func handleLeft(proxy: ScrollViewProxy) -> KeyPress.Result {
        guard edit.editingPath == nil, let path = model.selectedPath else { return .ignored }
        let isExpandedContainer = (model.node(at: path)?.isContainer ?? false) && model.isExpanded(path)
        switch JSONTreeNavigation.left(from: path, isExpandedContainer: isExpandedContainer) {
        case .collapse(let target): model.setExpanded(target, false)
        case .select(let target): select(target, revealingWith: proxy)
        case .none: return .ignored
        }

        return .handled
    }

    private func handleRight() -> KeyPress.Result {
        guard edit.editingPath == nil, let path = model.selectedPath, model.node(at: path)?.isContainer == true,
              !model.isExpanded(path) else { return .ignored }
        operations.toggle(path)
        return .handled
    }

    private func handleReturn() -> KeyPress.Result {
        guard edit.editingPath == nil, let path = model.selectedPath, actions.setValue != nil else { return .ignored }
        operations.beginEdit(path)
        return .handled
    }

    private func requestDeleteOfSelection() {
        guard let path = model.selectedPath, !path.isRoot, actions.delete != nil else { return }
        edit.pendingDelete = JSONTreeDeleteRequest(path: path)
    }
}

struct JSONTreePathRequest: Identifiable {
    let path: JSONPath
    var id: String { path.bracketed }
}

struct JSONTreeAddRequest: Identifiable {
    let parent: JSONPath
    let kind: JSONContainerKind
    var id: String { parent.bracketed }
}

struct JSONTreeDeleteRequest: Identifiable {
    let path: JSONPath
    var id: String { path.bracketed }
    var label: String { path.last?.label ?? "$" }
}

@MainActor @Observable
final class JSONTreeEditState {
    var editingPath: JSONPath?
    var editText = ""
    var editValidity = JSONTextValidity(text: "", isValid: false)
    var containerSheet: JSONTreePathRequest?
    var addSheet: JSONTreeAddRequest?
    var pendingDelete: JSONTreeDeleteRequest?
    var duplicateKeys: JSONDuplicateKeysPrompt?
    var addKey = ""
    var addValue = ""
    var confirmOverwrite = false
    var error: String?
    var busy = false
    /// Changes when a save starts or the editor closes, so a save whose parse finishes late can tell it is stale.
    @ObservationIgnored private(set) var saveGeneration = 0

    /// Puts JSON printed from a value in the editor; it is known to be valid.
    func load(_ text: String) {
        editText = text
        editValidity = JSONTextValidity(text: text, isValid: true)
    }

    func beginSave() -> Int {
        saveGeneration += 1
        busy = true
        error = nil
        return saveGeneration
    }

    func cancel() {
        editingPath = nil
        containerSheet = nil
        addSheet = nil
        duplicateKeys = nil
        error = nil
        confirmOverwrite = false
        busy = false
        saveGeneration += 1
    }
}

/// Caches JSON validity with the exact text checked.
struct JSONTextValidity: Equatable {
    var text: String
    var isValid: Bool

    func accepts(_ current: String) -> Bool {
        isValid && text == current
    }

    /// Parses `text` off the main actor after `delay` (a pause in typing); nil when the calling task is cancelled.
    static func check(_ text: String, after delay: Duration = .milliseconds(250)) async -> JSONTextValidity? {
        do {
            try await Task.sleep(for: delay)
        } catch {
            return nil
        }

        let isValid = await Task.detached(priority: .userInitiated) { JSONLiteral.parse(text) != nil }.value
        return Task.isCancelled ? nil : JSONTextValidity(text: text, isValid: isValid)
    }
}

/// Edited JSON text parsed off the main actor, with the object keys it repeats.
struct JSONEditCheck: Sendable {
    let value: JSONValue
    let duplicateKeys: [String]

    static func parse(_ text: String) async -> JSONEditCheck? {
        await Task.detached(priority: .userInitiated) { () -> JSONEditCheck? in
            guard let value = JSONLiteral.parse(text) else { return nil }
            return JSONEditCheck(value: value, duplicateKeys: JSONParser.duplicateKeys(in: value))
        }.value
    }
}

/// A parsed edit whose JSON repeats object keys, waiting on "Overwrite Duplicate Keys?".
struct JSONDuplicateKeysPrompt: Identifiable {
    let id = UUID()
    let keys: [String]
    let path: JSONPath
    let text: String
    let value: JSONValue
}

private struct DuplicateKeysAlert: ViewModifier {
    let prompt: JSONDuplicateKeysPrompt?
    let onResolve: @MainActor (JSONDuplicateKeysPrompt, _ overwrite: Bool) -> Void

    func body(content: Content) -> some View {
        content.background {
            Color.clear.alert("Overwrite Duplicate Keys?", isPresented: isPresented, presenting: prompt) { prompt in
                Button("Overwrite", role: .destructive) { onResolve(prompt, true) }
                Button("Cancel", role: .cancel) { onResolve(prompt, false) }
            } message: { prompt in
                Text("The edited value repeats a key, so the last value wins: \(prompt.keys.prefix(5).joined(separator: ", ")).")
            }
        }
    }

    /// Any other dismissal resolves as Cancel on the next turn; the owner ignores a prompt it already resolved.
    private var isPresented: Binding<Bool> {
        let prompt = prompt
        let onResolve = onResolve
        return Binding(get: { prompt != nil }, set: { presented in
            guard !presented, let prompt else { return }
            Task { @MainActor in onResolve(prompt, false) }
        })
    }
}

private struct OptionalSheetAlerts: ViewModifier {
    let confirmations: ConfirmationCenter?
    let errors: ToastCenter?

    func body(content: Content) -> some View {
        if let confirmations, let errors {
            content.sheetAlerts(confirmations: confirmations, errors: errors)
        } else {
            content
        }
    }
}

extension View {
    /// "Overwrite Duplicate Keys?" while `prompt` is set; `onResolve` receives the user's choice.
    func duplicateKeysAlert(_ prompt: JSONDuplicateKeysPrompt?,
                            onResolve: @escaping @MainActor (JSONDuplicateKeysPrompt, _ overwrite: Bool) -> Void) -> some View {
        modifier(DuplicateKeysAlert(prompt: prompt, onResolve: onResolve))
    }
}

@MainActor
struct JSONTreeOperations {
    let model: JSONTreeModel
    let actions: JSONTreeActions
    let edit: JSONTreeEditState

    func select(_ path: JSONPath) {
        model.selectedPath = path
        actions.onSelect?(path)
    }

    func canCopy(at path: JSONPath) -> Bool {
        model.node(at: path)?.isFullyLoaded ?? false
    }

    func copyText(at path: JSONPath) -> String? {
        guard let node = model.node(at: path) else { return nil }
        if let scalar = node.scalar { return JSONLiteral.format(scalar) }
        return node.fullValue.map { JSONLiteral.pretty($0, indent: 2) }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func toggle(_ path: JSONPath) {
        guard let node = model.node(at: path), node.isContainer else { return }
        let isExpanded = model.isExpanded(path)
        model.setExpanded(path, !isExpanded)
        guard !isExpanded, !node.isLoaded, let loader = actions.loadChildren, !model.loading.contains(path) else { return }
        model.loading.insert(path)
        model.errors[path] = nil
        Task { @MainActor in
            defer { model.loading.remove(path) }
            do {
                let loaded = try await loader(path)
                model.replaceNode(at: path, with: loaded)
            } catch {
                model.errors[path] = error.localizedDescription
                model.setExpanded(path, false)
            }
        }
    }

    /// Reveals the next page of children, fetching any that are still `.pending` first.
    func showMore(_ path: JSONPath) {
        guard !model.loading.contains(path), let node = model.node(at: path) else { return }
        let fetched = node.fetchedChildCount
        let target = min(model.visibleChildLimit(at: path) + model.pageSize, node.childCount)
        guard fetched < target, let loader = actions.loadChildPage else {
            model.showMore(at: path)
            return
        }
        let paths = node.children(in: fetched..<target).map { path.appending($0.0) }
        model.loading.insert(path)
        model.errors[path] = nil
        Task { @MainActor in
            defer { model.loading.remove(path) }
            do {
                let nodes = try await loader(paths)
                guard nodes.count == paths.count, model.node(at: path)?.fetchedChildCount == fetched else { return }
                model.replaceChildren(at: path, from: fetched, with: nodes)
                model.showMore(at: path)
            } catch {
                model.errors[path] = error.localizedDescription
            }
        }
    }

    /// Return / "Edit Value…": scalars edit in place, containers in a sheet.
    func beginEdit(_ path: JSONPath) {
        guard actions.setValue != nil, let node = model.node(at: path) else { return }
        edit.cancel()
        if let scalar = node.scalar {
            edit.editingPath = path
            edit.load(JSONLiteral.format(scalar))
            return
        }

        if let full = node.fullValue {
            edit.load(JSONLiteral.pretty(full, indent: 4))
            edit.containerSheet = JSONTreePathRequest(path: path)
            return
        }

        guard let fetch = actions.fetchValue else {
            model.errors[path] = "The value is not fully loaded."
            return
        }
        edit.editText = ""
        edit.busy = true
        edit.containerSheet = JSONTreePathRequest(path: path)
        Task { @MainActor in
            do {
                let value = try await fetch(path)
                if edit.containerSheet?.path == path { edit.load(JSONLiteral.pretty(value, indent: 4)) }
            } catch {
                edit.error = error.localizedDescription
            }

            edit.busy = false
        }
    }

    func beginAdd(_ path: JSONPath) {
        guard actions.addEntry != nil, let kind = model.node(at: path)?.containerKind else { return }
        edit.cancel()
        edit.addKey = ""
        edit.addValue = ""
        edit.addSheet = JSONTreeAddRequest(parent: path, kind: kind)
    }

    /// Saves the open scalar editor or container sheet. JSON that repeats an object key waits on
    /// "Overwrite Duplicate Keys?" (`edit.duplicateKeys`) before it is written.
    @discardableResult
    func saveEdit(at path: JSONPath) -> Task<Void, Never>? {
        guard actions.setValue != nil else { return nil }
        let text = edit.editText
        let generation = edit.beginSave()
        return Task { @MainActor in
            let checked = await JSONEditCheck.parse(text)
            guard edit.saveGeneration == generation else { return }
            guard let checked else {
                edit.error = "Enter valid JSON."
                edit.busy = false
                return
            }
            if checked.duplicateKeys.isEmpty {
                await commitEdit(path: path, text: text, value: checked.value)
            } else {
                edit.duplicateKeys = JSONDuplicateKeysPrompt(keys: checked.duplicateKeys, path: path, text: text,
                                                             value: checked.value)
            }
        }
    }

    @discardableResult
    func resolveDuplicateKeys(_ prompt: JSONDuplicateKeysPrompt, overwrite: Bool) -> Task<Void, Never>? {
        guard edit.duplicateKeys?.id == prompt.id else { return nil }
        edit.duplicateKeys = nil
        guard overwrite else {
            edit.busy = false
            return nil
        }
        return Task { @MainActor in await commitEdit(path: prompt.path, text: prompt.text, value: prompt.value) }
    }

    private func commitEdit(path: JSONPath, text: String, value: JSONValue) async {
        guard let setValue = actions.setValue else { return }
        do {
            try await setValue(path, text)
            if actions.updatesLocally { model.replaceNode(at: path, with: .value(value)) }
            edit.cancel()
        } catch {
            edit.error = error.localizedDescription
            edit.busy = false
        }
    }

    func saveAdd(_ request: JSONTreeAddRequest, overwrite: Bool = false) {
        guard let addEntry = actions.addEntry else { return }
        var key: String?
        if request.kind == .object {
            guard let parsedKey = JSONLiteral.parseQuotedKey(edit.addKey) else {
                edit.error = "Enter the key as a quoted JSON string."
                return
            }
            key = parsedKey
        }

        guard let parsed = JSONLiteral.parse(edit.addValue) else {
            edit.error = "Enter valid JSON."
            return
        }
        if let key, !overwrite, model.node(at: request.parent)?.child(.key(key)) != nil {
            edit.confirmOverwrite = true
            edit.error = nil
            return
        }

        let text = edit.addValue
        edit.busy = true
        edit.error = nil
        Task { @MainActor in
            do {
                try await addEntry(request.parent, key, text)
                if actions.updatesLocally { model.addNode(.value(parsed), key: key, under: request.parent) }
                edit.cancel()
            } catch {
                edit.error = error.localizedDescription
                edit.busy = false
            }
        }
    }

    func delete(_ path: JSONPath) {
        guard let deleteAction = actions.delete else { return }
        Task { @MainActor in
            do {
                try await deleteAction(path)
                if actions.updatesLocally { model.removeNode(at: path) }
            } catch {
                model.errors[path] = error.localizedDescription
            }
        }
    }
}

struct JSONTreeToolbar: View {
    let model: JSONTreeModel
    @Binding var textMode: Bool
    var accessory: AnyView?

    var body: some View {
        KeySubheaderBar {
            Picker("View", selection: $textMode) {
                Text("Tree").tag(false)
                Text("Text").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } trailing: {
            if !textMode {
                Button { model.collapseAll() } label: { Label("Collapse All", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .labelStyle(.iconOnly)
                    .help("Collapse All")
                Button { model.expandAll() } label: { Label("Expand All", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .labelStyle(.iconOnly)
                    .help("Expand All")
            }

            if model.root.isFullyLoaded {
                CopyButton(help: "Copy", title: "Copy") { model.root.fullValue.map { JSONLiteral.pretty($0, indent: 2) } ?? "" }
            }

            if let accessory { accessory }
        }
        .buttonStyle(.borderless)
    }
}

struct JSONRawTextView: View {
    let model: JSONTreeModel
    let actions: JSONTreeActions
    @Binding var textMode: Bool
    @Binding var isDirty: Bool
    @State private var original = ""
    @State private var text = ""
    @State private var validity = JSONTextValidity(text: "", isValid: false)
    @State private var duplicateKeys: JSONDuplicateKeysPrompt?
    @State private var error: String?
    @State private var isLoading = false
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeEditorView(text: $text, language: .json, isEditable: actions.setValue != nil && !isSaving)
            }

            if let error {
                Divider()
                InlineMessage(error, kind: .error)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            if actions.setValue != nil {
                Divider()
                HStack(spacing: 8) {
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                    Button("Revert") {
                        show(original)
                        error = nil
                    }
                    .disabled(text == original || isSaving)
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(text == original || !validity.accepts(text) || isSaving)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .task { await load() }
        .onChange(of: text != original, initial: true) { _, dirty in isDirty = dirty }
        .onDisappear { isDirty = false }
        .task(id: text) {
            guard validity.text != text, let checked = await JSONTextValidity.check(text), checked.text == text else {
                return
            }
            validity = checked
        }
        .duplicateKeysAlert(duplicateKeys) { resolveDuplicateKeys($0, overwrite: $1) }
    }

    private func load() async {
        if let full = model.root.fullValue {
            show(await Self.pretty(full))
            return
        }

        guard let fetch = actions.fetchValue else {
            error = "The document is not fully loaded."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await fetch(.root)
            show(await Self.pretty(value))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private nonisolated static func pretty(_ value: JSONValue) async -> String {
        await Task.detached(priority: .userInitiated) { JSONLiteral.pretty(value, indent: 2) }.value
    }

    /// Shows the document as printed from its value, which is valid JSON.
    private func show(_ document: String) {
        original = document
        text = document
        validity = JSONTextValidity(text: document, isValid: true)
    }

    private func save() {
        guard actions.setValue != nil else { return }
        let text = text
        isSaving = true
        Task {
            guard let checked = await JSONEditCheck.parse(text) else {
                error = "Enter valid JSON."
                isSaving = false
                return
            }
            if checked.duplicateKeys.isEmpty {
                await commit(text, value: checked.value)
            } else {
                duplicateKeys = JSONDuplicateKeysPrompt(keys: checked.duplicateKeys, path: .root, text: text,
                                                        value: checked.value)
            }
        }
    }

    private func resolveDuplicateKeys(_ prompt: JSONDuplicateKeysPrompt, overwrite: Bool) {
        guard duplicateKeys?.id == prompt.id else { return }
        duplicateKeys = nil
        guard overwrite else {
            isSaving = false
            return
        }
        Task { await commit(prompt.text, value: prompt.value) }
    }

    private func commit(_ text: String, value: JSONValue) async {
        defer { isSaving = false }
        guard let setValue = actions.setValue else { return }
        do {
            try await setValue(.root, text)
            if actions.updatesLocally { model.setValue(value) }
            original = text
            error = nil
            textMode = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct JSONTreeRowView: View {
    let row: JSONTreeRow
    let operations: JSONTreeOperations
    let isEmphasized: Bool
    let reduceMotion: Bool
    let onFocus: () -> Void

    private nonisolated static let indentWidth: CGFloat = 12
    private nonisolated static let maxIndentLevels = 8
    private nonisolated static let disclosureWidth: CGFloat = 16
    private nonisolated static let horizontalPadding: CGFloat = 8
    private static let maxDisplayLength = 5_000

    nonisolated static func indent(depth: Int) -> CGFloat {
        CGFloat(min(depth, maxIndentLevels)) * indentWidth
    }

    /// Whether `x`, in row coordinates, falls on the disclosure chevron of a container row at `depth`.
    nonisolated static func isOnDisclosure(x: CGFloat, depth: Int) -> Bool {
        let start = horizontalPadding + indent(depth: depth)
        return x >= start && x < start + disclosureWidth
    }

    private var model: JSONTreeModel { operations.model }
    private var edit: JSONTreeEditState { operations.edit }
    private var actions: JSONTreeActions { operations.actions }
    private var indent: CGFloat { Self.indent(depth: row.depth) }

    private var isNodeRow: Bool {
        switch row.kind {
        case .container, .scalar: return true
        default: return false
        }
    }

    private var isSelected: Bool { isNodeRow && model.selectedPath == row.path }
    private var whiteText: Bool { isSelected && isEmphasized }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Color.clear.frame(width: indent, height: 1)
                content
                Spacer(minLength: 8)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, Self.horizontalPadding)
            .background {
                if isSelected {
                    Color(nsColor: isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
                }
            }
            .contentShape(Rectangle())
            // Simultaneous, so buttons in the row do not wait out the double-click interval.
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                switch row.kind {
                case .container:
                    // The chevron button already toggles on each click.
                    guard !Self.isOnDisclosure(x: tap.location.x, depth: row.depth) else { return }
                    operations.toggle(row.path)
                case .scalar:
                    operations.beginEdit(row.path)
                default:
                    break
                }
            })
            .simultaneousGesture(TapGesture().onEnded {
                guard isNodeRow else { return }
                operations.select(row.path)
                onFocus()
            })
            .contextMenu { if isNodeRow { contextMenu } }
            .modifier(JSONTreeNodeAccessibility(row: row, isSelected: isSelected,
                                                isEditing: edit.editingPath == row.path, operations: operations))
            if let error = model.errors[row.path], isNodeRow {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, indent + Self.disclosureWidth + Self.horizontalPadding)
            }
        }
    }

    private func color(_ base: Color) -> Color { whiteText ? .white : base }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .container(let kind, let count, let isExpanded, _):
            disclosure(isExpanded: isExpanded)
            label
            if isExpanded {
                Text(kind.open).foregroundStyle(color(EditorAppearance.JSON.punctuation))
            } else {
                Text(JSONLiteral.collapsedPreview(kind, count: count)).foregroundStyle(color(EditorAppearance.JSON.punctuation))
                if count > 0 {
                    Text("  \(count) \(count == 1 ? "item" : "items")")
                        .font(.caption)
                        .foregroundStyle(whiteText ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }

            if model.loading.contains(row.path) {
                ProgressView().controlSize(.mini).padding(.leading, 4)
            }
        case .scalar(let value):
            Color.clear.frame(width: Self.disclosureWidth, height: 1)
            label
            if edit.editingPath == row.path {
                scalarEditor
            } else {
                scalarText(value)
            }
        case .closing(let kind):
            Color.clear.frame(width: Self.disclosureWidth, height: 1)
            Text(kind.close).foregroundStyle(EditorAppearance.JSON.punctuation)
        case .more(let shown, let remaining):
            Color.clear.frame(width: Self.disclosureWidth, height: 1)
            Button("Show \(min(model.pageSize, remaining)) More (\(remaining) of \(shown + remaining) Hidden)") {
                operations.showMore(row.path)
            }
            .buttonStyle(.link)
            .font(.callout)
        case .add:
            EmptyView()
        }
    }

    private func disclosure(isExpanded: Bool) -> some View {
        Button { operations.toggle(row.path) } label: {
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .fontWeight(.semibold)
                .foregroundStyle(whiteText ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isExpanded)
                .frame(width: Self.disclosureWidth, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var label: some View {
        switch row.label {
        case .key(let key)?:
            Text(JSONLiteral.quote(key)).foregroundStyle(color(EditorAppearance.JSON.key))
            Text(": ").foregroundStyle(color(EditorAppearance.JSON.punctuation))
        case .index(let index)?:
            Text(String(index)).foregroundStyle(color(EditorAppearance.JSON.arrayKey))
            Text(": ").foregroundStyle(color(EditorAppearance.JSON.punctuation))
        case nil:
            EmptyView()
        }
    }

    private func scalarText(_ value: JSONValue) -> some View {
        var literal = JSONLiteral.format(value)
        if literal.count > Self.maxDisplayLength { literal = String(literal.prefix(Self.maxDisplayLength)) + "…" }
        let base: Color
        switch value {
        case .string: base = EditorAppearance.JSON.string
        case .number: base = EditorAppearance.JSON.number
        case .bool: base = EditorAppearance.JSON.boolean
        default: base = EditorAppearance.JSON.null
        }

        return Text(literal)
            .foregroundStyle(color(base))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if actions.setValue != nil {
            Button("Edit Value…") { operations.beginEdit(row.path) }
        }

        if case .container = row.kind, actions.addEntry != nil {
            Button("Add Entry…") { operations.beginAdd(row.path) }
        }

        Button("Copy Path") { operations.copy(row.path.dotted) }
        if operations.canCopy(at: row.path) {
            Button("Copy Value") { if let text = operations.copyText(at: row.path) { operations.copy(text) } }
        }

        if !row.path.isRoot, actions.delete != nil {
            Divider()
            Button("Delete…", role: .destructive) { edit.pendingDelete = JSONTreeDeleteRequest(path: row.path) }
        }
    }

    private var scalarEditor: some View {
        @Bindable var edit = edit
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TextField("JSON value", text: $edit.editText, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(1...8)
                    .frame(minWidth: 160, maxWidth: 520)
                    .onSubmit { operations.saveEdit(at: row.path) }
                    .onExitCommand { edit.cancel() }
                    .disabled(edit.busy)
                if edit.busy { ProgressView().controlSize(.small) }
            }
            if let error = edit.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// VoiceOver for a node row: one element with selected trait, expansion state, and Expand/Collapse actions.
private struct JSONTreeNodeAccessibility: ViewModifier {
    let row: JSONTreeRow
    let isSelected: Bool
    let isEditing: Bool
    let operations: JSONTreeOperations

    func body(content: Content) -> some View {
        switch row.kind {
        case .container(_, _, let isExpanded, _):
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityAction { operations.select(row.path) }
                .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") { operations.toggle(row.path) }
        case .scalar where !isEditing:
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction { operations.select(row.path) }
        default:
            content
        }
    }
}

/// The selected node's path below the tree, observed apart from the rows so selection changes stay local.
struct JSONTreePathBar: View {
    let model: JSONTreeModel

    var body: some View {
        if let path = model.selectedPath {
            let dotted = path.dotted
            Divider()
            HStack(spacing: 4) {
                Text(dotted)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                CopyButton(text: dotted, help: "Copy Path")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 22)
        }
    }
}

struct JSONContainerEditSheet: View {
    let operations: JSONTreeOperations
    let path: JSONPath

    var body: some View {
        @Bindable var edit = operations.edit
        SheetForm(title: "Edit Value", primaryTitle: "Save",
                  isPrimaryDisabled: !edit.editValidity.accepts(edit.editText), isWorking: edit.busy,
                  errorMessage: edit.error, onCancel: { edit.cancel() },
                  onPrimary: { operations.saveEdit(at: path) }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(path.dotted).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                CodeEditorView(text: $edit.editText, language: .json, isEditable: !edit.busy, showsLineNumbers: true)
                    .frame(minHeight: 260)
            }
            .padding(.horizontal, 20)
        }
        .sheetSize(.form)
        .task(id: edit.editText) {
            guard edit.editValidity.text != edit.editText, let checked = await JSONTextValidity.check(edit.editText),
                  checked.text == edit.editText else { return }
            edit.editValidity = checked
        }
        .duplicateKeysAlert(edit.duplicateKeys) { operations.resolveDuplicateKeys($0, overwrite: $1) }
    }
}

struct JSONAddEntrySheet: View {
    let operations: JSONTreeOperations
    let request: JSONTreeAddRequest

    var body: some View {
        @Bindable var edit = operations.edit
        SheetForm(title: request.kind == .object ? "Add Field" : "Add Element", primaryTitle: "Add",
                  isPrimaryDisabled: edit.addValue.isEmpty || (request.kind == .object && edit.addKey.isEmpty),
                  isWorking: edit.busy, errorMessage: edit.error, onCancel: { edit.cancel() },
                  onPrimary: { operations.saveAdd(request) }) {
            Form {
                if request.kind == .object {
                    TextField("Key", text: $edit.addKey, prompt: Text(verbatim: "\"key\""))
                        .font(.body.monospaced())
                        .onChange(of: edit.addKey) { edit.confirmOverwrite = false }
                }

                TextField("Value", text: $edit.addValue, prompt: Text("JSON value"), axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(1...6)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .sheetSize(.small)
        .destructiveConfirmation("Replace “\(edit.addKey)”?", isPresented: $edit.confirmOverwrite,
                                 message: "This key already exists. Its value will be overwritten.",
                                 confirmTitle: "Replace") {
            operations.saveAdd(request, overwrite: true)
        }
    }
}
