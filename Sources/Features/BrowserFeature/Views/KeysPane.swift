import RedisUI
import SwiftUI

struct KeysPane: View {
    @Bindable var model: BrowserViewModel
    @State private var confirmSample = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.keyListWidthChanged($0) }
            Divider()
            statusBar
        }
        .destructiveConfirmation("Load Sample Data?", isPresented: $confirmSample,
                                 message: "This runs the bundled sample commands against this database. Avoid it on production databases.",
                                 confirmTitle: "Load") {
            Task { await model.loadSampleData() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            ErrorStateView(message: error) { model.reload() }
        } else if model.searchMode == .redisearch && model.selectedIndex == nil {
            ContentUnavailableView("Choose an Index", systemImage: "sparkle.magnifyingglass",
                                   description: Text("Pick an index, then type a query to match against key values."))
        } else if model.searchMode == .redisearch && model.searchNeedsQuery {
            ContentUnavailableView("Enter a Query", systemImage: "text.magnifyingglass",
                                   description: Text("Listing every document needs a numeric field in the index, and this one has none. Type a query to match against key values."))
        } else if !model.hasStarted {
            ProgressView()
        } else if model.isDatabaseEmpty {
            ContentUnavailableView {
                Label("No Keys", systemImage: "key")
            } description: {
                Text("This database is empty.")
            } actions: {
                Button("New Key…") { model.openAddKey() }
                Button("Load Sample Data…") { confirmSample = true }
                    .disabled(model.session.isProduction || model.isLoadingSampleData)
                    .help(model.session.isProduction ? "Sample data cannot be loaded into a production database." : "")
            }
        } else if model.keys.isEmpty {
            if model.searchMode == .pattern && !model.isComplete {
                ContentUnavailableView {
                    Label("No Results Yet", systemImage: "magnifyingglass")
                } description: {
                    Text("Scan more keys or search for an exact key name.")
                } actions: {
                    Button("Scan More") { model.scanMore() }
                        .disabled(!model.canScanMore)
                }
            } else {
                ContentUnavailableView.search(text: model.searchMode == .pattern ? model.appliedPattern : model.appliedQuery)
            }
        } else if model.viewType == .tree {
            KeyTreeView(model: model)
        } else {
            KeyListView(model: model)
        }
    }

    private var statusBar: some View {
        StatusBar {
            HStack(spacing: 6) {
                if (model.isLoading || model.isLoadingSampleData) && !model.hasStarted {
                    ProgressView().controlSize(.mini)
                    Text("Scanning…")
                } else {
                    if model.isLoading || model.isScanningMore || model.isBuildingTree {
                        ProgressView().controlSize(.mini)
                    }

                    Text(model.summaryText)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .help(model.summaryText)
                }

                if let notice = model.searchLimitNotice {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(notice)
                        .accessibilityLabel(notice)
                }
            }
        } accessory: {
            if model.showsScanMoreButton {
                Button("Scan More") { model.scanMore() }
                    .buttonStyle(.borderless)
                    .disabled(!model.canScanMore)
                    .help("Each extra scan adds load on the server and keeps more keys in memory.")
            }
        }
    }
}

/// View Options (⌘J): columns, list sort and tree settings. Changes apply when the popover closes; Cancel discards.
struct ViewOptionsPopover: View {
    @Bindable var model: BrowserViewModel
    @State private var draft = ViewOptionsDraft()
    @State private var isCancelled = false
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("TTL", isOn: $draft.showsTTL)
                    Toggle("Size", isOn: $draft.showsSize)
                } header: {
                    Text("Columns")
                } footer: {
                    Text("Turn off Size if large keys make the list slow to load.")
                }
                if model.viewType == .list {
                    Section("Sort By") {
                        Picker("Sort By", selection: $draft.sortField) {
                            Text("None").tag(KeyListSort.Field?.none)
                            Text("Key").tag(KeyListSort.Field?.some(.name))
                            if draft.showsTTL { Text("TTL").tag(KeyListSort.Field?.some(.ttl)) }
                            if draft.showsSize { Text("Size").tag(KeyListSort.Field?.some(.size)) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Picker("Order", selection: $draft.sortOrder) {
                            Text("Ascending").tag(RedisCore.SortOrder.asc)
                            Text("Descending").tag(RedisCore.SortOrder.desc)
                        }
                        .disabled(draft.sortField == nil)
                    }
                } else {
                    Section("Tree") {
                        TextField("Delimiters", text: $draft.delimitersText, prompt: Text(":"))
                            .fontDesign(.monospaced)
                            .help("Separate several delimiters with commas.")
                        Stepper(value: $draft.prefixLength, in: 0...KeyTreeBuilder.maxPrefixLength) {
                            LabeledContent("Ignore separators in first N characters") {
                                Text(draft.prefixLength.formatted()).monospacedDigit()
                            }
                        }
                        Picker("Sort Folders", selection: $draft.treeSort) {
                            Text("A to Z").tag(RedisCore.SortOrder.asc)
                            Text("Z to A").tag(RedisCore.SortOrder.desc)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {
                    isCancelled = true
                    model.isViewOptionsPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Done") { model.isViewOptionsPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 300)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = ViewOptionsDraft(showsTTL: model.showsTTL, showsSize: model.showsSize, sort: model.sort,
                                     tree: model.treeOptions)
        }
        .onDisappear {
            guard !isCancelled else { return }
            apply()
        }
    }

    private func apply() {
        if draft.showsTTL != model.showsTTL { model.setColumn(.ttl, shown: draft.showsTTL) }
        if draft.showsSize != model.showsSize { model.setColumn(.size, shown: draft.showsSize) }
        if model.viewType == .list {
            if model.sort != draft.sort { model.sort = draft.sort }
        } else {
            model.applyTreeSettings(delimiters: draft.delimiters, prefixLength: draft.prefixLength, sort: draft.treeSort)
        }
    }
}

struct ViewOptionsDraft: Equatable {
    var showsTTL = true
    var showsSize = true
    var sortField: KeyListSort.Field?
    var sortOrder: RedisCore.SortOrder = .asc
    var delimitersText = ":"
    var prefixLength = 0
    var treeSort: RedisCore.SortOrder = .asc

    init() {}

    init(showsTTL: Bool, showsSize: Bool, sort: KeyListSort?, tree: KeyTreeOptions) {
        self.showsTTL = showsTTL
        self.showsSize = showsSize
        self.sortField = sort?.field
        self.sortOrder = sort?.order ?? .asc
        self.delimitersText = Self.delimitersText(tree.delimiters)
        self.prefixLength = tree.prefixLength
        self.treeSort = tree.sort
    }

    /// Sort to apply, dropping a sort on a hidden column.
    var sort: KeyListSort? {
        guard let sortField else { return nil }
        if sortField == .ttl && !showsTTL || sortField == .size && !showsSize { return nil }
        return KeyListSort(field: sortField, order: sortOrder)
    }

    var delimiters: [String] { Self.parseDelimiters(delimitersText) }

    /// ": , -" → [":", "-"]; a lone "," stays a delimiter; empty → [":"].
    static func parseDelimiters(_ text: String) -> [String] {
        if text.trimmingCharacters(in: .whitespaces) == "," { return [","] }
        var out: [String] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: true) {
            let value = part.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, !out.contains(value) { out.append(value) }
        }

        return out.isEmpty ? [":"] : out
    }

    static func delimitersText(_ delimiters: [String]) -> String {
        delimiters.joined(separator: ", ")
    }
}
