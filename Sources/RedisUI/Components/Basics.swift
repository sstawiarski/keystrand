import AppKit
import SwiftUI

/// Borderless copy button: `doc.on.doc` turns into a checkmark for one second after copying.
public struct CopyButton: View {
    private let payload: () -> String
    public var help: String
    public var title: String?
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    public init(text: String, help: String = "Copy", title: String? = nil) {
        self.payload = { text }
        self.help = help
        self.title = title
    }

    /// Copies bytes as lossy UTF-8.
    public init(data: Data, help: String = "Copy", title: String? = nil) {
        self.payload = { String(decoding: data, as: UTF8.self) }
        self.help = help
        self.title = title
    }

    /// Copies the result of `text` evaluated at click time (for large or lazily built payloads).
    public init(help: String = "Copy", title: String? = nil, text: @escaping () -> String) {
        self.payload = text
        self.help = help
        self.title = title
    }

    public var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload(), forType: .string)
            copied = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Label(title ?? help, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .labelStyle(CopyLabelStyle(showsTitle: title != nil))
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : help)
        .accessibilityLabel(help)
    }
}

private struct CopyLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            Label(configuration)
        } else {
            configuration.icon
        }
    }
}

/// TTL as short text (`No limit`, `3 h`, or full `3 h 2 min 5 s`). The tooltip shows the full duration and
/// the absolute expiry time computed from `referenceDate`.
public struct TTLText: View {
    public let ttl: Int?
    public var full: Bool
    public var referenceDate: Date

    public init(ttl: Int?, full: Bool = false, referenceDate: Date = .now) {
        self.ttl = ttl
        self.full = full
        self.referenceDate = referenceDate
    }

    public var body: some View {
        Text(Self.text(ttl, full: full))
            .monospacedDigit()
            .help(Self.tooltip(ttl, referenceDate: referenceDate))
    }

    nonisolated public static func text(_ ttl: Int?, full: Bool = false) -> String {
        guard let ttl else { return "" }
        if ttl < 0 { return "No limit" }
        return full ? DurationText.full(seconds: ttl) : DurationText.firstUnit(seconds: ttl)
    }

    /// `3 h 2 min 5 s` + newline + `Expires at 14:02:11, 3 Oct 2026`.
    nonisolated public static func tooltip(_ ttl: Int?, referenceDate: Date = .now) -> String {
        guard let ttl else { return "" }
        guard ttl >= 0 else { return "No limit" }
        let expiry = referenceDate.addingTimeInterval(TimeInterval(ttl))
        return DurationText.full(seconds: ttl) + "\nExpires at " + expiry.formatted(expiryStyle)
    }

    /// `tooltip` led by the exact seconds: `3,725 s, 1 h 2 min 5 s` + newline + `Expires at …`.
    nonisolated public static func secondsTooltip(_ ttl: Int?, referenceDate: Date = .now) -> String {
        guard let ttl, ttl >= 0 else { return tooltip(ttl, referenceDate: referenceDate) }
        return "\(NumberFormatting.grouped(ttl)) s, " + tooltip(ttl, referenceDate: referenceDate)
    }

    nonisolated static let expiryStyle = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits), \(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)",
        locale: Locale(identifier: "en_US_POSIX"), timeZone: .current, calendar: Calendar(identifier: .gregorian))
}

/// Bytes with base-1024 units (`-1` = too large to measure).
public struct ByteCountText: View {
    public let bytes: Int?
    public var decimals: Int

    public init(bytes: Int?, decimals: Int = 0) {
        self.bytes = bytes
        self.decimals = decimals
    }

    public var body: some View {
        if let bytes, bytes >= 0 {
            Text(ByteFormatter.format(Double(bytes), decimals: decimals))
                .monospacedDigit()
                .help("\(bytes.formatted()) B")
        } else if bytes == -1 {
            Text("Too large")
                .foregroundStyle(.secondary)
                .help("MEMORY USAGE was skipped because this key is too big to measure safely.")
        } else {
            Text("")
        }
    }
}

/// Native search field (`NSSearchField`). With `debounce`, `onDebouncedChange` fires once typing pauses (and
/// immediately when cleared). Return calls `onSubmit`. With `onMoveSelection`, ↑ and ↓ are forwarded instead of moving
/// the insertion point, so a list below the field can move its selection while focus stays in the field.
public struct SearchField: View {
    @Binding public var text: String
    public var placeholder: String
    public var onSubmit: () -> Void
    public var debounce: Duration?
    public var onDebouncedChange: ((String) -> Void)?
    public var onMoveSelection: (@MainActor (MoveCommandDirection) -> Void)?
    @State private var lastEmitted: String?

    public init(text: Binding<String>, placeholder: String = "Search", onSubmit: @escaping () -> Void = {},
                debounce: Duration? = nil, onDebouncedChange: ((String) -> Void)? = nil,
                onMoveSelection: (@MainActor (MoveCommandDirection) -> Void)? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.debounce = debounce
        self.onDebouncedChange = onDebouncedChange
        self.onSubmit = onSubmit
        self.onMoveSelection = onMoveSelection
    }

    public var body: some View {
        NativeSearchField(text: $text, placeholder: placeholder, onMoveSelection: onMoveSelection) {
            emit(text)
            onSubmit()
        }
        .frame(minWidth: 80)
        .onAppear { if lastEmitted == nil { lastEmitted = text } }
        .task(id: text) {
            guard onDebouncedChange != nil, text != lastEmitted else { return }
            if !text.isEmpty, let debounce {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }

            emit(text)
        }
    }

    private func emit(_ value: String) {
        guard let onDebouncedChange, value != lastEmitted else { return }
        lastEmitted = value
        onDebouncedChange(value)
    }
}

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMoveSelection: (@MainActor (MoveCommandDirection) -> Void)?
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.performSearch(_:))
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = text
        field.placeholderString = placeholder
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField

        init(parent: NativeSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let onMoveSelection = parent.onMoveSelection else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                onMoveSelection(.up)
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMoveSelection(.down)
                return true
            default:
                return false
            }
        }

        @objc func performSearch(_ sender: NSSearchField) {
            if parent.text != sender.stringValue { parent.text = sender.stringValue }
            let event = NSApp.currentEvent
            if event?.type == .keyDown, event?.keyCode == 36 || event?.keyCode == 76 { parent.onSubmit() }
        }
    }
}

public extension View {
    /// Inset table with alternating rows.
    func dataTableStyle() -> some View {
        tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

/// Monospaced, single-line, truncating table cell text with a full-text tooltip (500 characters at most).
public struct MonospacedCell: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.count > 200 ? String(text.prefix(200)) + "…" : text)
            .font(.body.monospaced())
            .lineLimit(1)
            .truncationMode(.tail)
            .help(TextTruncation.formatLongName(text, maxLength: 500, tail: 50))
    }
}
