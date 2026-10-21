import Foundation
import RedisUI

/// Tabular form of an FT.SEARCH / FT.AGGREGATE / FT.PROFILE reply.
struct SearchResultTable: Hashable, Sendable {
    var matched: String?
    var cursorID: String?
    var columns: [String]
    var rows: [[String: String]]
    var highlights: Bool
}

/// Precomputes result text, tables, and JSON off the main actor once per result.
struct ResultContent: Sendable {
    var lines: [String]
    var isError: Bool
    var table: SearchResultTable?
    var info: SearchIndexInfo?
    var json: JSONValue?
    var copyText: String

    var availableViews: [ResultViewKind] {
        var views: [ResultViewKind] = []
        if table != nil || info != nil { views.append(.table) }
        views.append(.text)
        if json != nil { views.append(.json) }
        return views
    }

    var defaultView: ResultViewKind { availableViews.first ?? .text }

    static let empty = ResultContent(lines: [], isError: false, table: nil, info: nil, json: nil, copyText: "")
}

enum SearchResultParser {
    static let cellPreviewLength = 200

    // MARK: - Command inspection

    static func tokens(_ command: String) -> [String] {
        (try? CommandLineSplitter.splitStrings(WorkbenchScriptParser.multilineToOneLine(command)))
            ?? command.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func verb(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).first.map { $0.uppercased() } ?? ""
    }

    // MARK: - Content

    static func content(for execution: CommandExecution) -> ResultContent {
        guard let result = execution.result?.first else { return .empty }
        switch result.response {
        case .message(let message):
            return ResultContent(lines: message.components(separatedBy: "\n"), isError: result.status == .fail,
                                 table: nil, info: nil, json: nil, copyText: message)
        case .group(let items):
            var lines: [String] = []
            for item in items {
                lines.append("> \(item.command)")
                lines += ReplyTextFormatter.text(item.response, command: item.command).components(separatedBy: "\n")
                lines.append("")
            }

            let text = lines.joined(separator: "\n")
            return ResultContent(lines: lines, isError: false, table: nil, info: nil, json: nil, copyText: text)
        case .reply(let node):
            if case .error(let message) = node {
                return ResultContent(lines: message.components(separatedBy: "\n"), isError: true,
                                     table: nil, info: nil, json: nil, copyText: message)
            }

            let text = ReplyTextFormatter.text(node, command: execution.command)
            let table = self.table(from: node, command: execution.command)
            var info: SearchIndexInfo?
            if verb(execution.command) == "FT.INFO" {
                let name = tokens(execution.command).dropFirst().first ?? ""
                info = SearchIndexService.parseInfo(respValue(node), name: Data(name.utf8))
            }

            let json = table.map(tableJSON) ?? jsonValue(node)
            return ResultContent(lines: text.components(separatedBy: "\n"), isError: result.status == .fail,
                                 table: table, info: info, json: json, copyText: text)
        }
    }

    // MARK: - Tables

    static func table(from node: ReplyNode, command: String) -> SearchResultTable? {
        let words = tokens(command)
        guard let head = words.first?.uppercased() else { return nil }
        let upper = words.map { $0.uppercased() }
        let highlights = upper.contains("HIGHLIGHT")
        switch head {
        case "FT.SEARCH":
            return searchTable(node, upperTokens: upper, highlights: highlights)
        case "FT.AGGREGATE":
            return aggregateTable(node, highlights: highlights)
        case "FT.PROFILE":
            guard upper.count > 2, case .array(let parts) = node, let results = parts.first else { return nil }
            return upper[2] == "AGGREGATE"
                ? aggregateTable(results, highlights: highlights)
                : searchTable(results, upperTokens: upper, highlights: highlights)
        default:
            return nil
        }
    }

    static func searchTable(_ node: ReplyNode, upperTokens upper: [String], highlights: Bool) -> SearchResultTable? {
        guard case .array(let items) = node, let first = items.first else { return nil }
        let matched = scalarText(first)
        var noContent = upper.contains("NOCONTENT")
        if let r = upper.firstIndex(of: "RETURN"), r + 1 < upper.count, upper[r + 1] == "0" { noContent = true }
        let withScores = upper.contains("WITHSCORES")
        let withPayloads = upper.contains("WITHPAYLOADS")
        let withSortKeys = upper.contains("WITHSORTKEYS")
        var chunk = noContent ? 1 : 2
        if withScores { chunk += 1 }
        if withPayloads { chunk += 1 }
        if withSortKeys { chunk += 1 }

        var columns = ["Doc"]
        var seen: Set<String> = ["Doc"]

        func addColumn(_ name: String) {
            if seen.insert(name).inserted { columns.append(name) }
        }

        var rows: [[String: String]] = []
        var index = 1
        while index < items.count {
            let end = min(index + chunk, items.count)
            let values = Array(items[(index + 1)..<max(index + 1, end)])
            var row: [String: String] = ["Doc": scalarText(items[index])]
            var cursor = 0
            if withScores, cursor < values.count { row["Score"] = scalarText(values[cursor]); addColumn("Score"); cursor += 1 }
            if withPayloads, cursor < values.count { row["Payloads"] = scalarText(values[cursor]); addColumn("Payloads"); cursor += 1 }
            if withSortKeys, cursor < values.count { row["Sortkey"] = scalarText(values[cursor]); addColumn("Sortkey"); cursor += 1 }
            if !noContent, cursor < values.count, case .array(let pairs) = values[cursor] {
                for (key, value) in pairList(pairs) {
                    row[key] = value
                    addColumn(key)
                }
            }

            rows.append(row)
            index += chunk
        }

        return SearchResultTable(matched: matched, cursorID: nil, columns: columns, rows: rows, highlights: highlights)
    }

    static func aggregateTable(_ node: ReplyNode, highlights: Bool) -> SearchResultTable? {
        guard case .array(var items) = node, !items.isEmpty else { return nil }
        var cursorID: String?
        if items.count == 2, case .array(let inner) = items[0], case .integer(let cursor) = items[1] {
            items = inner
            cursorID = cursor
        }

        guard let first = items.first else { return nil }
        var columns: [String] = []
        var seen = Set<String>()
        var rows: [[String: String]] = []
        for item in items.dropFirst() {
            var row: [String: String] = [:]
            if case .array(let pairs) = item, pairs.count > 1 {
                for (key, value) in pairList(pairs) {
                    row[key] = value
                    if seen.insert(key).inserted { columns.append(key) }
                }
            }

            rows.append(row)
        }

        return SearchResultTable(matched: scalarText(first), cursorID: cursorID, columns: columns, rows: rows,
                                 highlights: highlights)
    }

    static func pairList(_ items: [ReplyNode]) -> [(String, String)] {
        stride(from: 0, to: items.count - 1, by: 2).map { (displayValue(scalarText(items[$0])), scalarText(items[$0 + 1])) }
    }

    static func scalarText(_ node: ReplyNode) -> String {
        switch node {
        case .null: return ""
        case .integer(let n): return n
        case .string(let s): return displayValue(s)
        case .error(let e): return e
        case .array: return ReplyTextFormatter.text(node, command: "")
        }
    }

    /// ASCII-mode strings are `\xHH` escaped; show them as UTF-8 when they decode to printable text.
    static func displayValue(_ escaped: String) -> String {
        guard escaped.contains("\\") else { return escaped }
        guard let data = try? ASCIISafeEscaping.unescape(escaped),
              let text = String(data: data, encoding: .utf8) else { return escaped }
        let printable = text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" || scalar == "\r"
        }
        return printable ? text : escaped
    }

    static func cellPreview(_ value: String) -> String {
        value.count > cellPreviewLength ? String(value.prefix(cellPreviewLength)) + "…" : value
    }

    /// Splits `<b>…</b>` highlight markup into (text, bold) runs.
    static func highlightRuns(_ text: String) -> [(String, Bool)] {
        var runs: [(String, Bool)] = []
        var rest = Substring(text)
        var bold = false
        while !rest.isEmpty {
            let tag = bold ? "</b>" : "<b>"
            if let range = rest.range(of: tag) {
                if range.lowerBound > rest.startIndex { runs.append((String(rest[..<range.lowerBound]), bold)) }
                rest = rest[range.upperBound...]
                bold.toggle()
            } else {
                runs.append((String(rest), bold))
                break
            }
        }

        return runs
    }

    // MARK: - JSON

    static func tableJSON(_ table: SearchResultTable) -> JSONValue {
        var members: [JSONMember] = []
        if let matched = table.matched { members.append(JSONMember(key: "matched", value: numberOrString(matched))) }
        if let cursor = table.cursorID { members.append(JSONMember(key: "cursor", value: .number(cursor))) }
        let rows: [JSONValue] = table.rows.map { row in
            .object(table.columns.compactMap { column in
                row[column].map { JSONMember(key: column, value: embedded($0)) }
            })
        }
        members.append(JSONMember(key: "results", value: .array(rows)))
        return .object(members)
    }

    static func jsonValue(_ node: ReplyNode) -> JSONValue {
        switch node {
        case .null: return .null
        case .integer(let n): return .number(n)
        case .string(let s): return embedded(displayValue(s))
        case .error(let e): return .string(e)
        case .array(let items): return .array(items.map(jsonValue))
        }
    }

    /// Strings holding a JSON object/array (JSON documents, `$` fields) are embedded as JSON.
    static func embedded(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, first == "{" || first == "[", let parsed = try? JSONParser.parse(trimmed) {
            return parsed
        }

        return .string(text)
    }

    static func numberOrString(_ text: String) -> JSONValue {
        Int64(text) != nil ? .number(text) : .string(text)
    }

    /// ReplyNode back to a RESP2 value (for re-parsing FT.INFO replies).
    static func respValue(_ node: ReplyNode) -> RESPValue {
        switch node {
        case .null: return .bulkString(nil)
        case .integer(let n): return Int64(n).map(RESPValue.integer) ?? .bulk(n)
        case .string(let s): return .bulk(displayValue(s))
        case .error(let e): return .error(RESPError(e))
        case .array(let items): return .array(items.map(respValue))
        }
    }
}
