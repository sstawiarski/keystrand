import AppKit
import RedisUI
import SwiftUI

/// Pub/Sub section with subscription state that survives section switches.
public struct PubSubView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var body: some View {
        PubSubContentView(model: Self.model(for: session))
    }

    /// True while the window's Pub/Sub subscription is starting or active (drives the sidebar symbol effect).
    @MainActor
    public static func isSubscribed(session: DatabaseSession) -> Bool {
        model(for: session).status.isActive
    }

    @MainActor
    static func model(for session: DatabaseSession) -> PubSubViewModel {
        session.scopedObject(PubSubViewModel.self) { PubSubViewModel(session: session) }
    }
}

struct PubSubContentView: View {
    @Bindable var model: PubSubViewModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar {
                Text(model.statusText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .help(model.status.isActive ? model.patternsTooltip : model.statusText)
            } accessory: {
                if model.connectionError != nil, model.status == .unsubscribed {
                    Button("Resubscribe") { Task { await model.resubscribe() } }
                        .buttonStyle(.borderless)
                }
            }
            Divider()
            PublishBar(model: model)
        }
        .toolbar { toolbarItems }
    }

    @ViewBuilder
    private var content: some View {
        if model.messages.isEmpty {
            switch model.status {
            case .unsubscribed:
                ContentUnavailableView {
                    Label("Not Subscribed", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text(notSubscribedDescription)
                } actions: {
                    Button("Subscribe") { Task { await model.subscribe() } }
                }
            case .subscribing:
                ProgressView("Subscribing…")
            case .subscribed, .unsubscribing:
                ContentUnavailableView("No Messages Yet", systemImage: "tray",
                                       description: Text("Messages published to matching channels appear here."))
            }
        } else {
            PubSubMessagesTable(model: model)
        }
    }

    private var notSubscribedDescription: String {
        var text = "Subscribe to see messages published to this database. Subscribing on production may reduce performance."
        if model.showsShardedWarning { text += " Messages published with SPUBLISH do not appear here." }
        return text
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            PatternsField(model: model)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.toggleSubscription() }
            } label: {
                Label(model.status.isActive ? "Unsubscribe" : "Subscribe",
                      systemImage: model.status.isActive ? "stop.circle" : "dot.radiowaves.left.and.right")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(model.status.isBusy && model.status != .subscribing)
            .help(model.status.isActive ? "Unsubscribe from all patterns" : "Subscribe to the channels matching the patterns")
            Button {
                model.clearMessages()
            } label: {
                Label("Clear Messages", systemImage: "trash")
            }
            .disabled(!model.canClear)
            .help("Clear Messages")
        }
    }
}

struct PatternsField: View {
    @Bindable var model: PubSubViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Patterns", text: $model.patternInput, prompt: Text(PubSubPatterns.defaultPattern))
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .frame(width: 180)
            .disabled(model.status != .unsubscribed)
            .focused($isFocused)
            .onSubmit { Task { await model.subscribe() } }
            .onChange(of: isFocused) { _, focused in
                if !focused { model.patternFieldDidLoseFocus() }
            }
            .help("Channels or glob-style patterns separated by spaces; * subscribes to all channels")
    }
}

// MARK: - Messages table

struct PubSubMessagesTable: View {
    @Bindable var model: PubSubViewModel
    @State private var selection = Set<PubSubEntry.ID>()

    private var sortOrder: Binding<[KeyPathComparator<PubSubEntry>]> {
        Binding {
            [KeyPathComparator(\PubSubEntry.receivedAt, order: model.sortDescending ? .reverse : .forward)]
        } set: { newValue in
            if let first = newValue.first { model.sortDescending = first.order == .reverse }
        }
    }

    var body: some View {
        let rows = model.rows
        Table(rows, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Time", value: \.receivedAt) { entry in
                Text(model.timestampText(entry))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 170, max: 260)
            TableColumn("Channel") { entry in
                MonospacedCell(entry.channelText)
            }
            .width(min: 80, ideal: 180, max: 320)
            TableColumn("Message") { entry in
                Text(entry.messagePreview)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.messageTooltip)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: PubSubEntry.ID.self) { ids in
            contextMenu(for: ids, rows: rows)
        }
        .onCopyCommand {
            let text = rows.filter { selection.contains($0.id) }.map(\.messageFullText).joined(separator: "\n")
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<PubSubEntry.ID>, rows: [PubSubEntry]) -> some View {
        let selected = rows.filter { ids.contains($0.id) }
        if let first = selected.first {
            Button("Copy Message") { copy(selected.map(\.messageFullText).joined(separator: "\n")) }
            Button("Copy Channel") { copy(selected.map(\.channelFullText).joined(separator: "\n")) }
            if selected.count == 1 {
                Divider()
                Button("Publish to This Channel") { model.usePublishChannel(first) }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Publish

struct PublishBar: View {
    @Bindable var model: PubSubViewModel
    @FocusState private var focusedField: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Field { case channel, message }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Channel", text: $model.channelInput)
                .frame(width: 200)
                .focused($focusedField, equals: .channel)
                .onSubmit(publish)
            TextField("Message", text: $model.messageInput)
                .frame(maxWidth: .infinity)
                .focused($focusedField, equals: .message)
                .onSubmit(publish)
            if let result = model.publishResult {
                Label(result.statusText, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(result.detailText)
                    .transition(.opacity)
            }

            Button(action: publish) {
                Text("Publish")
            }
            .keyboardShortcut(focusedField == nil ? nil : .defaultAction)
            .disabled(model.isPublishing)
            .help("Publish the message to the channel")
        }
        .controlSize(.regular)
        .padding(12)
        .animation(reduceMotion ? nil : .default, value: model.publishResult)
    }

    private func publish() {
        Task { await model.publish() }
    }
}
