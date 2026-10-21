import RedisUI
import SwiftUI

/// One row of a result table; `values` is keyed by column title.
struct GridRow: Identifiable, Hashable {
    let id: Int
    let values: [String: String]
}

/// Orders grid rows by one column: numbers numerically, everything else with Finder-style string comparison.
struct GridRowComparator: SortComparator, Hashable {
    var column: String
    var order: Foundation.SortOrder = .forward

    func compare(_ lhs: GridRow, _ rhs: GridRow) -> ComparisonResult {
        let result = DataGridView.compare(lhs.values[column] ?? "", rhs.values[column] ?? "")
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// A result table with one column per title: monospaced cells, optional sorting by column header,
/// checkmark columns for flags, and a context menu to copy values or show JSON documents.
struct DataGridView: View {
    let columns: [String]
    let rows: [[String: String]]
    var maxHeight: CGFloat? = VisualizationMetrics.maxHeight
    var highlight = false
    var flagColumns: Set<String> = []
    var sortable = false
    var emptyText = "No Results"

    @State private var sortOrder: [GridRowComparator] = []
    @State private var gridRows: [GridRow] = []
    @State private var selection: GridRow.ID?
    @State private var shownJSON: JSONCellItem?

    static let rowHeight: CGFloat = 24
    /// Above this many rows sorting runs off the main actor.
    static let backgroundSortThreshold = 2_000
    static let headerHeight: CGFloat = 28
    static let previewLength = 200

    var body: some View {
        if rows.isEmpty {
            Text(emptyText)
                .foregroundStyle(.secondary)
        } else {
            table
                .frame(height: maxHeight.map { min($0, Self.fittingHeight(rowCount: rows.count)) })
                .sheet(item: $shownJSON) { item in
                    JSONValueSheet(item: item)
                }
                .task(id: GridRowsInput(rows: rows, sortOrder: sortOrder)) {
                    let rows = self.rows
                    let sortOrder = self.sortOrder
                    if rows.count > Self.backgroundSortThreshold {
                        let sorted = await Task.detached(priority: .userInitiated) {
                            Self.makeRows(rows, sortOrder: sortOrder)
                        }.value
                        if !Task.isCancelled { gridRows = sorted }
                    } else {
                        gridRows = Self.makeRows(rows, sortOrder: sortOrder)
                    }
                }
        }
    }

    private struct GridRowsInput: Equatable {
        let rows: [[String: String]]
        let sortOrder: [GridRowComparator]
    }

    nonisolated static func makeRows(_ rows: [[String: String]], sortOrder: [GridRowComparator]) -> [GridRow] {
        let all = rows.enumerated().map { GridRow(id: $0.offset, values: $0.element) }
        return sortOrder.isEmpty ? all : all.sorted(using: sortOrder)
    }

    @ViewBuilder
    private var table: some View {
        if sortable {
            Table(gridRows, selection: $selection, sortOrder: $sortOrder) {
                TableColumnForEach(columns, id: \.self) { column in
                    TableColumn(column, sortUsing: GridRowComparator(column: column)) { row in
                        cell(column, row: row)
                    }
                    .width(min: 60, ideal: idealWidth(column))
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        } else {
            Table(gridRows, selection: $selection) {
                TableColumnForEach(columns, id: \.self) { column in
                    TableColumn(column) { row in
                        cell(column, row: row)
                    }
                    .width(min: 60, ideal: idealWidth(column))
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func idealWidth(_ column: String) -> CGFloat {
        flagColumns.contains(column) ? 70 : 160
    }

    @ViewBuilder
    private func cell(_ column: String, row: GridRow) -> some View {
        let value = row.values[column]
        Group {
            if flagColumns.contains(column) {
                let on = value == "true"
                Image(systemName: on ? "checkmark" : "xmark")
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityLabel(on ? "Yes" : "No")
            } else if let value {
                let preview = value.count > Self.previewLength
                    ? String(value.prefix(Self.previewLength)) + "…" : value
                Group {
                    if highlight, preview.contains("<b>") {
                        Text(Self.highlighted(preview))
                    } else {
                        Text(preview)
                    }
                }
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .help("\(column)\n\(Self.longName(value))")
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            if let value {
                Button("Copy Value") { copyToPasteboard(value) }
                if Self.looksLikeJSON(value) {
                    Button("Show JSON…") {
                        shownJSON = Self.parseJSON(value).map { JSONCellItem(column: column, value: $0) }
                    }
                }
            }

            Button("Copy Row") {
                copyToPasteboard(columns.map { "\($0)=\(row.values[$0] ?? "")" }.joined(separator: " "))
            }
        }
    }

    /// Height that shows every row (plus the header and the inset style's margins), before the max-height cap.
    static func fittingHeight(rowCount: Int) -> CGFloat {
        headerHeight + CGFloat(rowCount) * rowHeight + 20
    }

    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        if let x = Double(a), let y = Double(b) {
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }

        return a.localizedStandardCompare(b)
    }

    static func sort(_ rows: [[String: String]], by column: String, ascending: Bool) -> [[String: String]] {
        rows.sorted { lhs, rhs in
            let result = compare(lhs[column] ?? "", rhs[column] ?? "")
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    /// First 500 characters + `...` + last 50 for long values.
    static func longName(_ text: String) -> String {
        guard text.count > 550 else { return text }
        return String(text.prefix(500)) + "…" + String(text.suffix(50))
    }

    /// Cheap pre-check for JSON documents (FT.SEARCH on JSON indexes returns `$` as a JSON string).
    nonisolated static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        guard first == "{" || first == "[" else { return false }
        let last = text.last(where: { !$0.isWhitespace })
        return (first == "{" && last == "}") || (first == "[" && last == "]")
    }

    nonisolated static func parseJSON(_ text: String) -> JSONValue? {
        guard looksLikeJSON(text) else { return nil }
        if let value = try? JSONParser.parse(text) { return value }
        guard let data = try? ASCIISafeEscaping.unescape(text) else { return nil }
        return try? JSONParser.parse(data)
    }

    /// `<b>term</b>` (FT.SEARCH HIGHLIGHT) rendered bold.
    static func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        while let open = rest.range(of: "<b>") {
            out += AttributedString(String(rest[..<open.lowerBound]))
            rest = rest[open.upperBound...]
            if let close = rest.range(of: "</b>") {
                var bold = AttributedString(String(rest[..<close.lowerBound]))
                bold.font = .body.monospaced().bold()
                out += bold
                rest = rest[close.upperBound...]
            }
        }

        out += AttributedString(String(rest))
        return out
    }
}

struct JSONCellItem: Identifiable {
    let id = UUID()
    let column: String
    let value: JSONValue
}

struct JSONValueSheet: View {
    let item: JSONCellItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetForm(title: item.column, primaryTitle: "Done", cancelTitle: nil, onCancel: { dismiss() },
                  onPrimary: { dismiss() }) {
            JSONTreeView(value: item.value, initiallyExpanded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } leadingActions: {
            Button("Copy") { copyToPasteboard(JSONPrinter.print(item.value, indent: 2)) }
        }
        .sheetSize(.large)
    }
}
