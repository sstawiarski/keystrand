import RedisUI
import SwiftUI

/// FT.SEARCH / FT.AGGREGATE / FT.PROFILE results table (`Matched`, `Cursor ID`).
struct SearchResultsTableView: View {
    let table: SearchTableModel
    let highlight: Bool
    let isFullscreen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if table.matched != nil || table.cursorID != nil {
                HStack(spacing: 16) {
                    if let matched = table.matched {
                        Text("Matched: \(matched)")
                    }

                    if let cursor = table.cursorID {
                        Text("Cursor ID: \(cursor)").textSelection(.enabled)
                    }
                }
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            DataGridView(columns: table.columns, rows: table.rows,
                         maxHeight: isFullscreen ? nil : VisualizationMetrics.maxHeight, highlight: highlight,
                         sortable: true)
        }
        .frame(maxHeight: isFullscreen ? .infinity : nil, alignment: .top)
    }
}

/// FT.INFO summary: key type and prefixes, options, attribute table with checkmark flags, document counters.
struct IndexInfoView: View {
    let info: IndexInfoModel
    let isFullscreen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(indexingLine)
            Text(info.options.isEmpty ? "No options" : "Options: " + info.options.joined(separator: ", "))
                .font(.callout)
                .foregroundStyle(.secondary)
            DataGridView(columns: info.columns + info.flagColumns, rows: info.attributes,
                         maxHeight: isFullscreen ? nil : VisualizationMetrics.maxHeight,
                         flagColumns: Set(info.flagColumns), emptyText: "No attributes")
            Text("Docs: \(info.numDocs) (max ID \(info.maxDocID)) · Records: \(info.numRecords) · Terms: \(info.numTerms)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var indexingLine: AttributedString {
        var out = AttributedString("Indexing ")
        var type = AttributedString(info.keyType ?? "HASH")
        type.font = .body.weight(.semibold)
        out += type
        let prefixes = info.prefixes.isEmpty ? "\"\"" : info.prefixes.map { "\"\($0)\"" }.joined(separator: ", ")
        out += AttributedString(" documents prefixed by \(prefixes)")
        return out
    }
}

/// JSON.GET / JSON.MGET / GET as a read-only JSON tree.
struct JSONResultView: View {
    let value: JSONValue
    let isFullscreen: Bool

    var body: some View {
        JSONTreeView(value: value, initiallyExpanded: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 60, maxHeight: isFullscreen ? .infinity : VisualizationMetrics.maxHeight)
    }
}

struct ClientListTableView: View {
    let model: ClientListModel
    let isFullscreen: Bool

    var body: some View {
        DataGridView(columns: model.columns, rows: model.rows,
                     maxHeight: isFullscreen ? nil : VisualizationMetrics.maxHeight, sortable: true,
                     emptyText: "No clients")
    }
}
