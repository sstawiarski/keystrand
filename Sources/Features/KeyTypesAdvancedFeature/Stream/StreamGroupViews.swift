import RedisUI
import SwiftUI

// MARK: - Consumer groups

struct StreamGroupsTable: View {
    @Bindable var model: StreamViewModel
    let keyText: String
    @State private var selection: Data?
    @State private var pendingDelete: ConsumerGroup?

    var body: some View {
        Group {
            if model.groups.isEmpty, !model.isLoading {
                ContentUnavailableView("No Consumer Groups", systemImage: "person.3",
                                       description: Text("Create a group to let several consumers share this stream."))
            } else {
                table
            }
        }
        .destructiveConfirmation(item: $pendingDelete, title: { RemovalText.title($0.displayName, verb: "Delete") },
                                 message: { _ in "This deletes the group and every consumer in it from “\(Bytes.short(keyText))”." }) { group in
            Task { await model.deleteGroup(group) }
        }
    }

    private var table: some View {
        Table(model.sortedGroups, selection: $selection, sortOrder: $model.groupSort) {
            TableColumn("Group", value: \.displayName) { group in
                Text(group.displayName).lineLimit(1).truncationMode(.middle).help(group.displayName)
            }
            .width(min: 100, ideal: 200)
            TableColumn("Consumers", value: \.consumers) { group in
                Text(NumberFormatting.grouped(group.consumers)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            .alignment(.numeric)
            TableColumn("Pending", value: \.pending) { group in
                Text(NumberFormatting.grouped(group.pending)).monospacedDigit()
                    .help(pendingHelp(group))
            }
            .width(min: 60, ideal: 80)
            .alignment(.numeric)
            TableColumn("Last Delivered ID", value: \.lastDeliveredSortKey) { group in
                LastDeliveredCell(model: model, group: group)
            }
            .width(min: 160, ideal: 220)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Data.self) { ids in
            if let group = group(ids.first) {
                Button("View Consumers") { Task { await model.openGroup(group) } }
                Divider()
                Button("Copy Group Name") { Pasteboard.copy(group.displayName) }
                Button("Copy Last Delivered ID") { Pasteboard.copy(group.lastDeliveredId) }
                Button("Set Last Delivered ID…") { model.editingGroupId = group.id }
                Divider()
                Button("Delete Group…", role: .destructive) { pendingDelete = group }
            }
        } primaryAction: { ids in
            if let group = group(ids.first) { Task { await model.openGroup(group) } }
        }
        .onDeleteCommand { if let group = group(selection) { pendingDelete = group } }
    }

    private func group(_ id: Data?) -> ConsumerGroup? {
        guard let id else { return nil }
        return model.groups.first { $0.id == id }
    }

    private func pendingHelp(_ group: ConsumerGroup) -> String {
        guard let range = group.pendingRangeText else { return "\(group.pending) pending messages" }
        return "\(group.pending) pending messages\n\(range)"
    }
}

private struct LastDeliveredCell: View {
    let model: StreamViewModel
    let group: ConsumerGroup
    @State private var draft = ""

    private var isEditing: Binding<Bool> {
        Binding(get: { model.editingGroupId == group.id },
                set: { model.editingGroupId = $0 ? group.id : nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let ms = StreamID.milliseconds(group.lastDeliveredId), group.lastDeliveredId != "0-0" {
                Text(TimestampFormatter.format(milliseconds: ms)).font(.callout).foregroundStyle(.secondary)
            }

            Text(group.lastDeliveredId).font(.body.monospaced())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { isEditing.wrappedValue = true }
        .help("Double-click to set the last delivered ID")
        .popover(isPresented: isEditing, arrowEdge: .bottom) {
            Form {
                Section {
                    GroupIdField(id: $draft)
                        .onSubmit { apply() }
                } header: {
                    Text("Set Last Delivered ID")
                } footer: {
                    let isValid = StreamID.isValidGroupId(draft)
                    FieldHint(text: isValid ? GroupIdField.help : "Enter a valid ID, 0 or $.", isError: !isValid)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { isEditing.wrappedValue = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Set") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.isEmpty || !StreamID.isValidGroupId(draft))
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 340)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { draft = group.lastDeliveredId }
        }
    }

    private func apply() {
        let id = draft
        guard StreamID.isValidGroupId(id) else { return }
        Task { _ = await model.setGroupId(group, id: id) }
    }
}

// MARK: - Consumers

struct StreamConsumersTable: View {
    @Bindable var model: StreamViewModel
    @State private var selection: Data?
    @State private var pendingDelete: StreamConsumer?

    var body: some View {
        Group {
            if model.consumers.isEmpty, !model.isLoading {
                ContentUnavailableView("No Consumers", systemImage: "person.2",
                                       description: Text("Consumers appear after they read from this group."))
            } else {
                table
            }
        }
        .destructiveConfirmation(item: $pendingDelete, title: { RemovalText.title($0.displayName, verb: "Delete") },
                                 message: { _ in
                                     "The consumer will be removed from “\(model.selectedGroup?.displayName ?? "")”. Its pending messages can no longer be claimed."
                                 }) { consumer in
            Task { await model.deleteConsumer(consumer) }
        }
    }

    private var table: some View {
        Table(model.sortedConsumers, selection: $selection, sortOrder: $model.consumerSort) {
            TableColumn("Name", value: \.displayName) { consumer in
                Text(consumer.displayName).lineLimit(1).truncationMode(.middle).help(consumer.displayName)
            }
            .width(min: 140, ideal: 240)
            TableColumn("Pending", value: \.pending) { consumer in
                Text(NumberFormatting.grouped(consumer.pending)).monospacedDigit()
            }
            .width(min: 60, ideal: 90)
            .alignment(.numeric)
            TableColumn("Idle Time (ms)", value: \.idleMs) { consumer in
                Text(StreamDates.idleText(consumer.idleMs)).monospacedDigit()
            }
            .width(min: 100, ideal: 130)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Data.self) { ids in
            if let consumer = consumer(ids.first) {
                Button("View Pending Messages") { Task { await model.openConsumer(consumer) } }
                Button("Copy Consumer Name") { Pasteboard.copy(consumer.displayName) }
                Divider()
                Button("Delete Consumer…", role: .destructive) { pendingDelete = consumer }
            }
        } primaryAction: { ids in
            if let consumer = consumer(ids.first) { Task { await model.openConsumer(consumer) } }
        }
        .onDeleteCommand { if let consumer = consumer(selection) { pendingDelete = consumer } }
    }

    private func consumer(_ id: Data?) -> StreamConsumer? {
        guard let id else { return nil }
        return model.consumers.first { $0.id == id }
    }
}

// MARK: - Pending messages

struct StreamMessagesTable: View {
    let model: StreamViewModel
    @State private var selection: String?
    @State private var pendingAck: PendingEntry?

    private static let pattern = "HH:mm:ss.SSS d MMM yyyy"

    var body: some View {
        Group {
            if model.pending.isEmpty, !model.isLoading {
                ContentUnavailableView("No Pending Messages", systemImage: "tray",
                                       description: Text("This consumer has acknowledged every message it read."))
            } else {
                VStack(spacing: 0) {
                    table
                    Divider()
                    PagedStatusBar(text: "\(NumberFormatting.grouped(model.pending.count))\(model.pendingCanLoadMore ? "+" : "") pending messages",
                                   isLoadingMore: model.isLoadingMorePending, canLoadMore: model.pendingCanLoadMore,
                                   onLoadMore: { model.loadMorePending() })
                }
            }
        }
        .destructiveConfirmation(item: $pendingAck, title: { "Acknowledge “\($0.id)”?" },
                                 message: { _ in "The message will be removed from the pending messages list." },
                                 confirmTitle: "Acknowledge") { entry in
            Task { await model.ack(entry) }
        }
    }

    private var table: some View {
        let ids = model.pending.map(\.id)
        return Table(model.pending, selection: $selection) {
            TableColumn("Entry ID") { entry in
                VStack(alignment: .leading, spacing: 2) {
                    if let ms = StreamID.milliseconds(entry.id) {
                        Text(TimestampFormatter.format(milliseconds: ms, pattern: Self.pattern))
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    Text(entry.id).font(.body.monospaced())
                }
                .onAppear {
                    if KeyDetailsLayout.isNearEnd(entry.id, in: ids), model.pendingCanLoadMore { model.loadMorePending() }
                }
            }
            .width(min: 150, ideal: 200)
            TableColumn("Last Delivered") { entry in
                Text(TimestampFormatter.format(date: Date().addingTimeInterval(-Double(entry.idleMs) / 1000),
                                               pattern: Self.pattern))
                    .monospacedDigit()
                    .help("Idle for \(StreamDates.idleText(entry.idleMs)) ms")
            }
            .width(min: 150, ideal: 190)
            TableColumn("Delivery Count") { entry in
                Text(NumberFormatting.grouped(entry.delivered)).monospacedDigit()
            }
            .width(min: 60, ideal: 100)
            .alignment(.numeric)
            TableColumn("") { entry in
                HStack(spacing: 12) {
                    Button("Acknowledge…") { pendingAck = entry }
                        .help("Acknowledge the message (XACK)")
                    ClaimButton(model: model, entry: entry)
                }
                .buttonStyle(.borderless)
            }
            .width(min: 170, ideal: 180)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let entry = entry(ids.first) {
                Button("Copy Entry ID") { Pasteboard.copy(entry.id) }
                Divider()
                Button("Acknowledge…") { pendingAck = entry }
            }
        }
    }

    private func entry(_ id: String?) -> PendingEntry? {
        guard let id else { return nil }
        return model.pending.first { $0.id == id }
    }
}

private struct ClaimButton: View {
    let model: StreamViewModel
    let entry: PendingEntry
    @State private var isPresented = false

    var body: some View {
        Button("Claim…") { isPresented = true }
            .disabled(model.otherConsumers.isEmpty)
            .help(model.otherConsumers.isEmpty ? "There is no other consumer to claim the message." : "Claim the message for another consumer (XCLAIM)")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ClaimForm(model: model, entry: entry) { isPresented = false }
            }
    }
}

private struct ClaimForm: View {
    let model: StreamViewModel
    let entry: PendingEntry
    let onClose: () -> Void

    @State private var consumer: Data?
    @State private var minIdle = "0"
    @State private var showOptional = false
    @State private var idle = ""
    @State private var timeMode: ClaimTimeMode = .relative
    @State private var retryCount = ""
    @State private var force = false
    @State private var isClaiming = false
    @State private var nothingClaimed = false

    var body: some View {
        Form {
            Section {
                Picker("Consumer", selection: $consumer) {
                    ForEach(model.otherConsumers) { item in
                        Text("\(item.displayName) (\(item.pending) pending)").tag(Optional(item.name))
                    }
                }
                NumberField(title: "Minimum idle time", text: $minIdle, unit: "ms")
            } header: {
                Text("Claim “\(entry.id)”")
            } footer: {
                if nothingClaimed { InlineMessage(StreamViewModel.nothingClaimedMessage) }
            }
            Section {
                DisclosureGroup("Optional Parameters", isExpanded: $showOptional) {
                    Picker("Time", selection: $timeMode) {
                        ForEach(ClaimTimeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: timeMode) { _, mode in
                        idle = mode == .timestamp ? String(Int(Date().timeIntervalSince1970 * 1000)) : ""
                    }
                    NumberField(title: timeMode == .relative ? "Idle time" : "Timestamp", text: $idle, unit: "ms")
                    NumberField(title: "Retry count", text: $retryCount, unit: nil)
                    Toggle("Force claim", isOn: $force)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Claim") { claim() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(consumer == nil || isClaiming)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { consumer = model.otherConsumers.first?.name }
    }

    private func claim() {
        guard let consumer else { return }
        var options = ClaimOptions(consumer: consumer, minIdleMs: Int(minIdle) ?? 0)
        if showOptional {
            if let value = Int(idle) {
                if timeMode == .relative { options.idleMs = value } else { options.timeMs = value }
            }

            options.retryCount = Int(retryCount)
            options.force = force
        }

        isClaiming = true
        nothingClaimed = false
        Task {
            let claimed = await model.claim(entry, options: options)
            isClaiming = false
            if claimed { onClose() } else { nothingClaimed = true }
        }
    }
}

struct AutoClaimForm: View {
    let model: StreamViewModel
    let onClose: () -> Void
    @State private var consumer: Data?
    @State private var minIdle = "0"
    @State private var start = "0-0"
    @State private var count = "100"
    @State private var isClaiming = false
    @State private var nothingClaimed = false
    @State private var batchMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Consumer", selection: $consumer) {
                    ForEach(model.consumers) { item in
                        Text("\(item.displayName) (\(item.pending) pending)").tag(Optional(item.name))
                    }
                }
                NumberField(title: "Minimum idle time", text: $minIdle, unit: "ms")
                LabeledContent("Start ID") {
                    TextField("Start ID", text: $start).labelsHidden().fontDesign(.monospaced)
                }
                NumberField(title: "Count", text: $count, unit: nil)
            } header: {
                Text("Auto Claim")
            } footer: {
                FieldHint(text: "Moves pending messages of the group that are idle for at least the minimum time to the selected consumer.")
                if nothingClaimed { InlineMessage(StreamViewModel.nothingClaimedMessage) }
                if let batchMessage { InlineMessage(batchMessage) }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Claim") {
                    guard let consumer else { return }
                    let minIdle = Int(minIdle) ?? 0
                    let start = StreamID.filterEntryId(start)
                    let count = Int(count) ?? 100
                    isClaiming = true
                    nothingClaimed = false
                    batchMessage = nil
                    Task {
                        let outcome = await model.autoClaim(to: consumer, minIdleMs: minIdle, start: start, count: count)
                        isClaiming = false
                        guard let outcome else { return }
                        if !outcome.isComplete {
                            self.start = outcome.next
                            batchMessage = Self.batchMessage(outcome)
                        } else if outcome.claimedCount > 0 {
                            onClose()
                        } else {
                            nothingClaimed = true
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(consumer == nil || isClaiming)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { consumer = model.selectedConsumer?.name ?? model.consumers.first?.name }
    }

    nonisolated static func batchMessage(_ outcome: StreamViewModel.AutoClaimOutcome) -> String {
        let claimed = outcome.claimedCount == 1
            ? "Claimed 1 message" : "Claimed \(NumberFormatting.grouped(outcome.claimedCount)) messages"
        return "\(claimed). More pending messages remain from Start ID \(outcome.next). Claim again to continue."
    }
}

struct NumberField: View {
    let title: String
    @Binding var text: String
    let unit: String?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, text: $text, prompt: Text("0"))
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .onChange(of: text) { _, new in
                        let digits = new.filter { $0.isASCII && $0.isNumber }
                        if digits != new { text = digits }
                    }
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}
