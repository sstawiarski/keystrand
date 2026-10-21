import AppKit
import SwiftUI

/// Key details subheader row (Xcode jump bar style): leading controls (search, segmented pickers) and trailing
/// actions (`ValueFormatPicker`, `AddItemsButton`). Small controls, no background; callers add a `Divider()` below.
public struct KeySubheaderBar<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .controlSize(.small)
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
    }
}

public extension KeySubheaderBar where Leading == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}

/// "Add Fields…" style button: callers pass the title without an ellipsis. Shows the title when there is room,
/// otherwise only the `plus` symbol with the title as tooltip.
public struct AddItemsButton: View {
    public var title: String
    public var help: String?
    public let action: () -> Void

    public init(_ title: String = "Add", help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.action = action
    }

    nonisolated public static func displayTitle(_ title: String) -> String {
        var base = title.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("...") { base.removeLast(3) }
        if base.hasSuffix("…") { base.removeLast() }
        return base + "…"
    }

    public var body: some View {
        let label = Self.displayTitle(title)
        ViewThatFits(in: .horizontal) {
            Button(action: action) { Label(label, systemImage: "plus") }
                .labelStyle(.titleAndIcon)
            Button(action: action) { Label(label, systemImage: "plus") }
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(help ?? label)
    }
}

/// Table cell showing a formatted value: truncated (200 characters) single line, full-text tooltip (≤ 500
/// characters), "Failed to convert to {format}" tooltip title when invalid, JSON as a tree when expanded.
/// Pass `collapsedText` precomputed with `collapsedText(_:truncateLength:)` off the main actor for large values.
public struct FormattedValueCell: View {
    public nonisolated static let defaultTruncateLength = 200

    public var result: FormatResult
    public var format: ValueFormat?
    public var columnTitle: String?
    public var isExpanded: Bool
    public var truncateLength: Int
    private let precomputedCollapsedText: String?

    public init(result: FormatResult, collapsedText: String? = nil, format: ValueFormat? = nil,
                columnTitle: String? = nil, isExpanded: Bool = false, truncateLength: Int = defaultTruncateLength) {
        self.result = result
        self.precomputedCollapsedText = collapsedText
        self.format = format
        self.columnTitle = columnTitle
        self.isExpanded = isExpanded
        self.truncateLength = truncateLength
    }

    public var body: some View {
        let collapsed = precomputedCollapsedText ?? Self.collapsedText(result, truncateLength: truncateLength)
        Group {
            if isExpanded, case .json(let value) = result.content {
                JSONTreeView(value: value, initiallyExpanded: true)
                    .frame(minHeight: 60, maxHeight: 400)
            } else if isExpanded {
                Text(fullText)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(collapsed)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.body.monospaced())
        .foregroundStyle(result.isValid ? .primary : .secondary)
        .help(tooltip(collapsed))
    }

    private var fullText: String {
        if case .json(let value) = result.content { return JSONLiteral.pretty(value, indent: 2) }
        return result.text
    }

    /// Single-line text of `result`: newlines folded to spaces, cut to `truncateLength` characters plus "…".
    public nonisolated static func collapsedText(_ result: FormatResult,
                                                 truncateLength: Int = defaultTruncateLength) -> String {
        let text: String
        if case .json(let value) = result.content { text = JSONLiteral.format(value) } else { text = result.text }
        var single = ""
        var count = 0
        for character in text {
            if count == truncateLength { return single + "…" }
            single.append(character == "\n" || character == "\r\n" ? " " : character)
            count += 1
        }

        return single
    }

    /// `collapsedText` for many results, off the main actor.
    public nonisolated static func collapsedTexts(_ results: [FormatResult]) async -> [String] {
        await Task.detached(priority: .userInitiated) { results.map { collapsedText($0) } }.value
    }

    private func tooltip(_ collapsed: String) -> String {
        let title = result.isValid ? columnTitle : format.map { "Failed to convert to \($0.menuLabel)" }
        let body = TextTruncation.formatLongName(collapsed, maxLength: 500, tail: 50)
        return [title, body].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Table cell edited in place: double-click starts editing (when editable); Return saves (⌘Return when
/// multiline), Esc cancels. No hover controls.
public struct EditableTextCell: View {
    public let value: String
    public var placeholder: String
    public var isMultiline: Bool
    public var isEditable: Bool
    public var disabledReason: String?
    public var validate: (String) -> String?
    public let onSave: (String) -> Void
    @Binding private var isEditing: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    public init(value: String, isEditing: Binding<Bool>, placeholder: String = "", isMultiline: Bool = false,
                isEditable: Bool = true, disabledReason: String? = nil,
                validate: @escaping (String) -> String? = { _ in nil }, onSave: @escaping (String) -> Void) {
        self.value = value
        self._isEditing = isEditing
        self.placeholder = placeholder
        self.isMultiline = isMultiline
        self.isEditable = isEditable
        self.disabledReason = disabledReason
        self.validate = validate
        self.onSave = onSave
    }

    public var body: some View {
        if isEditing {
            let error = validate(draft)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if isMultiline {
                        TextField(placeholder, text: $draft, axis: .vertical)
                            .lineLimit(3...10)
                            .onKeyPress(.return, phases: .down) { press in
                                guard press.modifiers.contains(.command) else { return .ignored }
                                save()
                                return .handled
                            }
                    } else {
                        TextField(placeholder, text: $draft)
                            .onSubmit { save() }
                    }
                }
                .font(.body.monospaced())
                .focused($focused)
                .onExitCommand { isEditing = false }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .onAppear {
                draft = value
                focused = true
            }
        } else {
            Text(value.isEmpty ? placeholder : value)
                .font(.body.monospaced())
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .lineLimit(isMultiline ? 3 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if isEditable { isEditing = true } }
                .help(isEditable ? "Double-click to edit" : (disabledReason ?? ""))
        }
    }

    private func save() {
        guard validate(draft) == nil else { return }
        isEditing = false
        if draft != value { onSave(draft) }
    }
}

/// Command an add form will run: a "Show command" checkbox and, when on, selectable monospaced text with Copy.
public struct CommandPreviewBar: View {
    public var command: String
    @Binding public var isExpanded: Bool

    public init(command: String, isExpanded: Binding<Bool>) {
        self.command = command
        self._isExpanded = isExpanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Show command", isOn: $isExpanded)
                .toggleStyle(.checkbox)
            if isExpanded {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(command)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(text: command, help: "Copy Command")
                }
            }
        }
    }
}

/// Editable list of form rows in a grid with Mail-rules style `minus.circle` / `plus.circle` buttons. Removing
/// the last row clears it instead.
public struct MultiRowFormList<Row: Identifiable, RowContent: View>: View {
    @Binding public var rows: [Row]
    public var addTitle: String
    public var maxRows: Int?
    private let makeRow: () -> Row
    private let content: (Binding<Row>) -> RowContent

    public init(rows: Binding<[Row]>, addTitle: String = "Add", maxRows: Int? = nil, makeRow: @escaping () -> Row,
                @ViewBuilder content: @escaping (Binding<Row>) -> RowContent) {
        self._rows = rows
        self.addTitle = addTitle
        self.maxRows = maxRows
        self.makeRow = makeRow
        self.content = content
    }

    private var canAdd: Bool { maxRows.map { rows.count < $0 } ?? true }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach($rows) { $row in
                GridRow(alignment: .firstTextBaseline) {
                    content($row)
                    HStack(spacing: 4) {
                        Button {
                            remove(row.id)
                        } label: {
                            Label(rows.count > 1 ? "Remove" : "Clear", systemImage: "minus.circle")
                        }
                        .help(rows.count > 1 ? "Remove" : "Clear")
                        Button {
                            insert(after: row.id)
                        } label: {
                            Label(addTitle, systemImage: "plus.circle")
                        }
                        .disabled(!canAdd)
                        .help(addTitle)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .gridColumnAlignment(.trailing)
                }
            }
        }
    }

    private func remove(_ id: Row.ID) {
        if rows.count > 1 {
            rows.removeAll { $0.id == id }
        } else if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index] = makeRow()
        }
    }

    private func insert(after id: Row.ID) {
        guard canAdd else { return }
        let index = rows.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? rows.count
        rows.insert(makeRow(), at: index)
    }
}

/// Dual-thumb slider over `bounds` (e.g. a stream range filter) with system-colored track and thumbs.
public struct RangeSliderView: View {
    @Binding public var range: ClosedRange<Double>
    public var bounds: ClosedRange<Double>
    public var step: Double?

    public init(range: Binding<ClosedRange<Double>>, bounds: ClosedRange<Double>, step: Double? = nil) {
        self._range = range
        self.bounds = bounds
        self.step = step
    }

    private let thumb: CGFloat = 16

    public var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - thumb, 1)
            let span = max(bounds.upperBound - bounds.lowerBound, .leastNonzeroMagnitude)
            let lowX = CGFloat((range.lowerBound - bounds.lowerBound) / span) * width
            let highX = CGFloat((range.upperBound - bounds.lowerBound) / span) * width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4).padding(.horizontal, thumb / 2)
                Capsule().fill(.tint).frame(width: max(highX - lowX, 0), height: 4).offset(x: lowX + thumb / 2)
                knob.offset(x: lowX).gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let value = Self.value(at: drag.location.x - thumb / 2, width: width, bounds: bounds, step: step)
                    range = min(value, range.upperBound)...range.upperBound
                })
                .accessibilityLabel("Range start")
                knob.offset(x: highX).gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let value = Self.value(at: drag.location.x - thumb / 2, width: width, bounds: bounds, step: step)
                    range = range.lowerBound...max(value, range.lowerBound)
                })
                .accessibilityLabel("Range end")
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: 20)
    }

    private var knob: some View {
        Circle()
            .fill(Color(nsColor: .controlColor))
            .frame(width: thumb, height: thumb)
            .shadow(radius: 1)
    }

    nonisolated static func value(at x: CGFloat, width: CGFloat, bounds: ClosedRange<Double>, step: Double?) -> Double {
        let span = max(bounds.upperBound - bounds.lowerBound, .leastNonzeroMagnitude)
        let fraction = Double(min(max(x / max(width, 1), 0), 1))
        var value = bounds.lowerBound + fraction * span
        if let step, step > 0 { value = (value / step).rounded() * step }
        return min(max(value, bounds.lowerBound), bounds.upperBound)
    }
}

/// Monospaced text lines in a lazy list (large replies, logs). Each line is selectable.
public struct VirtualizedTextLinesView: View {
    public var lines: [String]
    public var lineColor: ((Int, String) -> Color?)?
    public var autoScrollToBottom: Bool

    public init(lines: [String], autoScrollToBottom: Bool = false, lineColor: ((Int, String) -> Color?)? = nil) {
        self.lines = lines
        self.autoScrollToBottom = autoScrollToBottom
        self.lineColor = lineColor
    }

    public init(text: String, autoScrollToBottom: Bool = false) {
        self.init(lines: text.components(separatedBy: "\n"), autoScrollToBottom: autoScrollToBottom)
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(Font(EditorAppearance.font()))
                            .foregroundStyle(lineColor?(index, line) ?? EditorAppearance.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: lines.count) { _, count in
                if autoScrollToBottom, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}
