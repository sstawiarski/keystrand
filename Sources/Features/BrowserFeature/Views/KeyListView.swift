import AppKit
import RedisUI
import SwiftUI

/// Loads metadata for visible rows and loads more keys near the end.
struct KeyListView: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        let rows = model.displayedKeys
        let tail = Set(rows.suffix(BrowserViewModel.infiniteLoadThreshold).map(\.name))
        ScrollViewReader { proxy in
            List(selection: Binding(get: { model.selectedKey }, set: { model.select($0) })) {
                ForEach(rows) { item in
                    KeyRowView(model: model, item: item, name: BrowserFormatting.cellName(model.displayName(item.name)),
                               fullName: model.displayName(item.name))
                        .tag(item.name)
                        .id(item.name)
                        .onAppear {
                            model.rowAppeared(item.name)
                            if tail.contains(item.name) { model.listEndApproached() }
                        }
                        .onDisappear { model.rowDisappeared(item.name) }
                }
            }
            .task(id: model.searchMode) {
                await restoreScrollPosition(model.listScrollAnchor(), proxy: proxy, model: model)
            }
            .onDisappear { model.pauseScrollTracking() }
        }
        .background(ScrollWheelMonitor { model.listScrolledDown() })
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .keyListCommands(model: model)
    }
}

struct KeyRowView: View {
    let model: BrowserViewModel
    let item: KeyListItem
    let name: String
    let fullName: String

    var body: some View {
        HStack(spacing: 8) {
            KeyTypeSlot(type: item.type)
            Text(name)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(BrowserFormatting.tooltipName(fullName))
            KeyMetadataCells(ttl: item.ttl, size: item.size, isLoaded: item.type != nil,
                             showsTTL: model.showsTTLCell, showsSize: model.showsSizeCell)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Fixed-width slot for the key type tile; empty until the type is known.
struct KeyTypeSlot: View {
    let type: KeyType?

    var body: some View {
        Group {
            if let type {
                KeyTypeIcon(type: type, size: .small)
            } else {
                Color.clear
            }
        }
        .frame(width: 16, height: 16)
    }
}

struct KeyMetadataCells: View {
    let ttl: Int?
    let size: Int?
    let isLoaded: Bool
    let showsTTL: Bool
    let showsSize: Bool

    var body: some View {
        if showsTTL {
            Text(ttl.map(BrowserFormatting.ttlText) ?? "")
                .help(ttl.map(BrowserFormatting.ttlTooltip) ?? "")
                .modifier(MetadataCellStyle())
        }

        if showsSize {
            Text(size != nil || isLoaded ? BrowserFormatting.sizeText(size) : "")
                .help(size.map { $0 > 0 ? "Size: " + BrowserFormatting.sizeText($0, decimals: 3) : "Size" } ?? "")
                .modifier(MetadataCellStyle())
        }
    }
}

private struct MetadataCellStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 70, alignment: .trailing)
    }
}

extension View {
    /// Context menu, keyboard and copy handling shared by the key list and the key tree.
    func keyListCommands(model: BrowserViewModel) -> some View {
        self
            .contextMenu(forSelectionType: Data.self) { keys in
                if let key = keys.first { KeyContextMenu(model: model, key: key) }
            } primaryAction: { keys in
                if let key = keys.first, model.canRename(key) { model.openRename(key) }
            }
            .onDeleteCommand { if let selection = model.selectedKey { model.requestDelete(selection) } }
            .onCopyCommand {
                guard let selection = model.selectedKey else { return [] }
                return [NSItemProvider(object: model.displayName(selection) as NSString)]
            }
            .onExitCommand { model.closeDetails() }
    }
}

struct KeyContextMenu: View {
    let model: BrowserViewModel
    let key: Data

    var body: some View {
        let display = model.displayName(key)
        Button("Copy Key Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(display, forType: .string)
        }
        Button("Rename…") { model.openRename(key) }
            .disabled(!model.canRename(key))
        Button("Set TTL…") { model.openSetTTL(key) }
        Divider()
        Button("Find Keys with This Prefix") {
            if let pattern = BrowserFormatting.prefixPattern(for: display, delimiters: model.treeOptions.delimiters) {
                model.patternText = pattern
                model.applyPattern()
            }
        }
        .disabled(BrowserFormatting.prefixPattern(for: display, delimiters: model.treeOptions.delimiters) == nil
                  || model.searchMode != .pattern || model.keyNameFormat == .hex)
        Divider()
        Button("Delete Key…", role: .destructive) { model.requestDelete(key) }
    }
}

/// Pauses scroll tracking while restoring the remembered row.
@MainActor
func restoreScrollPosition<ID: Hashable>(_ anchor: ID?, proxy: ScrollViewProxy, model: BrowserViewModel) async {
    model.pauseScrollTracking()
    if let anchor {
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }
        proxy.scrollTo(anchor, anchor: .top)
        try? await Task.sleep(for: .milliseconds(150))
    }

    guard !Task.isCancelled else { return }
    model.resumeScrollTracking()
}

/// Reports scroll-wheel movement toward the end of the content.
struct ScrollWheelMonitor: NSViewRepresentable {
    let onScrollDown: @MainActor () -> Void

    func makeNSView(context: Context) -> ScrollWheelMonitorView {
        let view = ScrollWheelMonitorView()
        view.onScrollDown = onScrollDown
        return view
    }

    func updateNSView(_ nsView: ScrollWheelMonitorView, context: Context) {
        nsView.onScrollDown = onScrollDown
    }
}

final class ScrollWheelMonitorView: NSView {
    var onScrollDown: (@MainActor () -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.scrollingDeltaY < 0, let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onScrollDown?()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
