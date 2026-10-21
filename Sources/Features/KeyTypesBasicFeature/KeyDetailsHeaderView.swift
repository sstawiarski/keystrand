import RedisUI
import SwiftUI

/// Key details header for every type: type tile, key name, actions menu and the metadata row.
public struct KeyDetailsHeaderView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        KeyHeaderContent(context: context).id(KeyViewIdentity(context))
    }
}

struct KeyHeaderContent: View {
    let context: KeyDetailsContext
    @State private var model: KeyHeaderViewModel
    @State private var isRenaming = false
    @State private var isEditingTTL = false
    @State private var ttlDraft = ""
    @State private var confirmDeleteByTTL = false
    @State private var confirmDelete = false
    @Environment(SettingsStore.self) private var settings

    init(context: KeyDetailsContext) {
        self.context = context
        self._model = State(initialValue: KeyHeaderViewModel(context: context))
    }

    private var postfix: String { KeyHeaderLabels.refreshPostfix(for: context.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            metadataRow
                .popover(isPresented: $isEditingTTL, arrowEdge: .bottom) {
                    SetTTLPopover(title: "Set TTL", text: $ttlDraft, footer: "Leave empty for no limit.",
                                   isSaving: model.isWorking,
                                   onCancel: { isEditingTTL = false },
                                   onSet: commitTTL)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .task(id: context.key) {
            if context.state.info?.name != context.key {
                await model.loadInfo()
            }

            await model.loadCoveringIndexes()
        }
        .task(id: autoRefreshID) { await runAutoRefresh() }
        .onChange(of: isRenaming) { updateRefreshDisabled() }
        .onChange(of: isEditingTTL) { updateRefreshDisabled() }
        .onDisappear { RefreshLock.set(context.state, owner: "header", locked: false) }
        .sheet(isPresented: $isRenaming) { renameSheet.sheetAlerts(context.session) }
        .destructiveConfirmation("Delete “\(DisplayName.short(model.displayName))”?", isPresented: $confirmDeleteByTTL,
                                 message: "A TTL of 0 deletes the key.") {
            isEditingTTL = false
            Task { await model.setTTL(0) }
        }
        .destructiveConfirmation("Delete “\(DisplayName.short(model.displayName))”?", isPresented: $confirmDelete,
                                 message: "This key will be deleted. You can't undo this action.") {
            Task { await model.deleteKey() }
        }
    }

    // MARK: - Rows

    private var titleRow: some View {
        HStack(spacing: 10) {
            KeyTypeIcon(type: model.type, size: .large)
            Text(TextTruncation.formatLongName(model.displayName, maxLength: 500, tail: 50))
                .font(.title3)
                .fontDesign(.monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(TextTruncation.formatLongName(model.displayName, maxLength: 500, tail: 50))
                .onTapGesture(count: 2) { beginRename() }
            Spacer(minLength: 8)
            if model.isLoading || model.isWorking {
                ProgressView().controlSize(.small)
            }

            actionsMenu
        }
    }

    @ViewBuilder
    private var metadataRow: some View {
        if let info = context.state.info {
            KeyMetadataRow(items: KeyHeaderLabels.metadataItems(for: info).map {
                KeyMetadataItem(label: $0.label, value: $0.value, help: $0.help)
            })
            .font(.callout)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button("Copy Key Name") { copyToPasteboard(model.displayName) }
            Button("Rename…", action: beginRename)
                .disabled(!model.canRename)
                .help(model.renameDisabledReason ?? "")
            Button("Set TTL…", action: beginTTLEdit)
            if model.supportsIndexActions {
                Divider()
                indexActions
            }

            Divider()
            Button("Refresh Key") { Task { await model.refresh() } }
                .disabled(context.state.isRefreshDisabled)
            Menu("Auto Refresh") {
                Toggle("Auto Refresh", isOn: autoRefreshBinding)
                Picker("Every", selection: rateBinding) {
                    ForEach(AutoRefreshMenu.presetRates, id: \.self) { rate in
                        Text(AutoRefreshMenu.rateTitle(rate)).tag(rate)
                    }
                    if !AutoRefreshMenu.presetRates.contains(currentRate) {
                        Text(AutoRefreshMenu.rateTitle(currentRate)).tag(currentRate)
                    }
                }
            }
            .disabled(context.state.isRefreshDisabled)
            Divider()
            Button(context.state.isFullScreen ? "Show Key List" : "Hide Key List") { model.toggleFullScreen() }
            Divider()
            Button("Delete Key…", role: .destructive, action: requestDelete)
        } label: {
            Label("Key Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .help("Key Actions")
    }

    @ViewBuilder
    private var indexActions: some View {
        if model.coveringIndexes.count > 1 {
            Menu("View Index") {
                ForEach(model.coveringIndexes, id: \.name) { index in
                    Button(String(decoding: index.name, as: UTF8.self)) { model.viewIndex(index) }
                }
            }
        } else if let index = model.coveringIndexes.first {
            Button("View Index") { model.viewIndex(index) }
        } else {
            Button("Make Searchable…") { model.makeSearchable() }
        }
    }

    // MARK: - Rename

    private var renameSheet: some View {
        RenameKeyForm(initialName: model.renameDraft(), isWorking: model.isWorking, confirmReplace: overwriteBinding,
                      validate: { model.renameValidation($0) }, onCancel: { isRenaming = false }) { name, overwrite in
            Task { if await model.rename(to: name, overwrite: overwrite) { isRenaming = false } }
        }
    }

    private var overwriteBinding: Binding<Bool> {
        Binding(get: { model.pendingOverwriteName != nil }, set: { if !$0 { model.pendingOverwriteName = nil } })
    }

    private func beginRename() {
        guard model.canRename else { return }
        isRenaming = true
    }

    // MARK: - TTL and delete

    private func beginTTLEdit() {
        ttlDraft = model.ttlDraft()
        isEditingTTL = true
    }

    private func commitTTL() {
        guard let seconds = TTLInput.parse(ttlDraft) else { return }
        if seconds == 0, !model.skipsDeleteConfirmation {
            confirmDeleteByTTL = true
            return
        }

        isEditingTTL = false
        if seconds == (context.state.info?.ttl ?? -1) { return }
        Task { await model.setTTL(seconds) }
    }

    private func requestDelete() {
        if model.skipsDeleteConfirmation {
            Task { await model.deleteKey() }
        } else {
            confirmDelete = true
        }
    }

    // MARK: - Auto refresh

    private var isAutoRefreshOn: Bool { settings.ui.autoRefreshEnabled[postfix] ?? false }
    private var currentRate: Double { max(settings.ui.autoRefreshRate(postfix), 1) }

    private var autoRefreshBinding: Binding<Bool> {
        Binding(get: { isAutoRefreshOn }, set: { settings.ui.autoRefreshEnabled[postfix] = $0 })
    }

    private var rateBinding: Binding<Double> {
        Binding(get: { currentRate }, set: { settings.ui.autoRefreshRates[postfix] = $0 })
    }

    private var autoRefreshID: String {
        "\(isAutoRefreshOn)-\(currentRate)-\(context.state.isRefreshDisabled)"
    }

    private func runAutoRefresh() async {
        guard isAutoRefreshOn, !context.state.isRefreshDisabled else { return }
        let rate = currentRate
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(rate))
            if Task.isCancelled { break }
            await model.refresh()
        }
    }

    private func updateRefreshDisabled() {
        RefreshLock.set(context.state, owner: "header", locked: isRenaming || isEditingTTL)
    }
}
