import RedisUI
import SwiftUI

/// Analytics > Slow Log.
public struct SlowLogView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var body: some View {
        SlowLogContent(model: SlowLogViewModel.shared(for: session))
    }
}

struct SlowLogContent: View {
    @Bindable var model: SlowLogViewModel
    @State private var showConfig = false
    @State private var confirmClear = false
    @State private var sortOrder: [KeyPathComparator<SlowLogEntry>] = []
    @State private var selection: Set<SlowLogEntry.ID> = []
    @State private var windowVisibility = WindowVisibility()

    private var rows: [SlowLogEntry] {
        sortOrder.isEmpty ? model.entries : model.entries.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .toolbar { toolbarItems }
        .focusedSceneValue(\.analyticsCommands, AnalyticsCommands(
            clearSlowLog: { requestClear() }, canClearSlowLog: !model.entries.isEmpty))
        .destructiveConfirmation("Clear Slow Log?", isPresented: $confirmClear,
                                 message: "The Slow Log will be cleared for \(model.session.confirmationName). This changes the server state.",
                                 confirmTitle: "Clear") {
            Task { _ = await model.clear() }
        }
        .trackWindowVisibility(windowVisibility)
        .task { await model.load() }
        .onChange(of: model.count) { Task { await model.refresh() } }
        .onChange(of: model.session.navigator.refreshGeneration) { Task { await model.refresh() } }
        .onChange(of: model.session.dbGeneration) { Task { await model.refresh() } }
    }

    private func requestClear() {
        if model.clearNeedsDialog {
            confirmClear = true
        } else {
            Task { _ = await model.clear() }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu(model.count.menuTitle) {
                Picker("Show", selection: $model.count) {
                    ForEach(SlowLogCount.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(model.isLoading)
            .help(model.countHelp)
            Button {
                showConfig = true
            } label: {
                Label("Configure…", systemImage: "gearshape")
            }
            .help("Configure the Slow Log")
            .popover(isPresented: $showConfig, arrowEdge: .bottom) {
                if model.isCluster {
                    ClusterSlowLogConfigInfo { showConfig = false }
                } else {
                    SlowLogConfigPopover(model: model, isPresented: $showConfig)
                }
            }
            Button {
                requestClear()
            } label: {
                Label("Clear Slow Log…", systemImage: "trash")
            }
            .disabled(model.entries.isEmpty)
            .help("Clear Slow Log")
            AutoRefreshMenu(postfix: "slowlog", lastRefresh: model.lastRefresh, isLoading: model.isLoading,
                            persistsEnabledState: false) {
                Task { await model.autoRefresh(isWindowVisible: windowVisibility.isVisible) }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage, model.entries.isEmpty {
            ErrorStateView(message: error) { Task { await model.refresh() } }
        } else if !model.hasLoaded && model.entries.isEmpty {
            ProgressView()
        } else if model.entries.isEmpty {
            ContentUnavailableView {
                Label("No Slow Log Entries", systemImage: "tortoise")
            } description: {
                Text(model.emptyText)
            }
        } else {
            table
        }
    }

    private var table: some View {
        let rows = self.rows
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Timestamp", value: \.time) { entry in
                Text(model.timestampText(entry)).monospacedDigit()
            }
            .width(min: 140, ideal: 170)
            TableColumn(model.durationHeader, value: \.durationUs) { entry in
                Text(model.durationText(entry))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Command", value: \.args) { entry in
                MonospacedCell(entry.args)
            }
            .width(min: 200)
            TableColumn("Client", value: \.clientText) { entry in
                Text(entry.clientText)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(entry.clientText)
            }
            .width(min: 90, ideal: 150)
            if model.isCluster {
                TableColumn("Node", value: \.nodeText) { entry in
                    Text(entry.nodeText).lineLimit(1).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 150)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: SlowLogEntry.ID.self) { ids in
            let selected = rows.filter { ids.contains($0.id) }
            Button("Copy Command") { copy(selected.map(\.args).joined(separator: "\n")) }
                .disabled(selected.isEmpty)
            Button("Open in Workbench") {
                model.session.navigator.navigate(.workbench(script: selected.map(\.args).joined(separator: "\n")))
            }
            .disabled(selected.isEmpty)
        }
        .onCopyCommand {
            let text = rows.filter { selection.contains($0.id) }.map(\.args).joined(separator: "\n")
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
    }

    private var statusBar: some View {
        StatusBar {
            if let error = model.errorMessage, !model.entries.isEmpty {
                Label {
                    Text("Refresh failed")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .help(error)
                Text("·")
            }

            let status = model.statusText
            Text(status)
                .monospacedDigit()
                .help(status)
        }
    }
}

extension SlowLogEntry {
    var nodeText: String { node ?? "-" }
}

struct ClusterSlowLogConfigInfo: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In a cluster, every node keeps its own Slow Log settings.")
            Text("To change them, connect redis-cli to one node and set slowlog-log-slower-than and slowlog-max-len there with CONFIG SET.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("OK", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 380)
    }
}

struct SlowLogConfigPopover: View {
    let model: SlowLogViewModel
    @Binding var isPresented: Bool
    @State private var form = SlowLogConfigForm()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Log commands slower than") {
                        HStack(spacing: 6) {
                            TextField("Log commands slower than", text: Binding(
                                get: { form.slowerThan },
                                set: { form.slowerThan = SlowLogConfigForm.sanitizeSlowerThan($0, unit: form.unit) }),
                                      prompt: Text("10"))
                                .labelsHidden()
                                .monospacedDigit()
                                .frame(width: 90)
                            Picker("Unit", selection: Binding(get: { form.unit }, set: { form.changeUnit(to: $0) })) {
                                ForEach(SlowLogDurationUnit.allCases, id: \.self) { Text($0.shortLabel).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    LabeledContent("Max length") {
                        TextField("Max length", text: Binding(get: { form.maxLen },
                                                              set: { form.maxLen = SlowLogConfigForm.sanitizeMaxLen($0) }),
                                  prompt: Text("128"))
                            .labelsHidden()
                            .monospacedDigit()
                            .frame(width: 90)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if form.isSlowerThanValid {
                            Text("Equals \(form.conversionHint). -1 disables the Slow Log, 0 logs every command.")
                        } else {
                            InlineMessage(form.unit == .milliseconds
                                ? "Enter -1 or greater, with up to 3 decimals and at most 1,000,000,000,000 ms."
                                : "Enter a whole number from -1 to 1,000,000,000,000,000 µs.", kind: .error)
                        }

                        Text("When the Slow Log is full, the oldest entry is removed for each new one. This changes the server configuration.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Defaults") { form.applyDefaults() }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { if await model.saveConfig(form) { isPresented = false } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.isValid || model.isSavingConfig || model.isLoading)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 380)
        .interactiveDismissDisabled()
        .onAppear {
            form = model.config.map { SlowLogConfigForm(config: $0, unit: model.durationUnit) }
                ?? SlowLogConfigForm(slowerThan: "", unit: model.durationUnit, maxLen: "")
        }
    }
}
