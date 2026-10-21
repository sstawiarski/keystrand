import Foundation
import RedisUI

enum QueryCommands {
    struct SearchCommand: Equatable {
        /// `SEARCH` or `AGGREGATE`.
        var verb: String
        /// Text after `FT.SEARCH` / `FT.AGGREGATE`, starting with whitespace.
        var rest: String
    }

    /// Joins continuation lines, strips comments, and expands repeat prefixes.
    /// A large repeat prefix allocates one string per repetition, so bound the command count first.
    static func commands(in text: String) -> [String] {
        (try? WorkbenchScriptParser.parse(text)) ?? []
    }

    /// Number of commands `commands(in:)` returns, computed without expanding repeat prefixes.
    static func expandedCount(in text: String) -> Int {
        var total = 0
        for line in scriptLines(text) {
            let (command, count) = WorkbenchScriptParser.repeatCount(line)
            let repeats = (count ?? 0) >= 1
            guard !removeComments((repeats ? command : line).trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty
            else { continue }
            let (sum, overflow) = total.addingReportingOverflow(repeats ? count ?? 1 : 1)
            total = overflow ? Int.max : sum
        }

        return total
    }

    /// The first command of the script, without its repeat prefix and comments, with no expansion.
    static func firstCommand(in text: String) -> String? {
        for line in scriptLines(text) {
            let (command, count) = WorkbenchScriptParser.repeatCount(line)
            let candidate = (count ?? 0) >= 1 ? command : line
            let cleaned = removeComments(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
            if !cleaned.isEmpty { return cleaned }
        }

        return nil
    }

    /// The first command, when it is `FT.SEARCH` / `FT.AGGREGATE` followed by whitespace and more text.
    static func searchCommand(in text: String) -> SearchCommand? {
        guard let first = firstCommand(in: text) else { return nil }
        return parseSearchCommand(WorkbenchScriptParser.multilineToOneLine(first))
    }

    /// A non-whitespace character starts each logical command line. Removes a leading `[pipeline=...]` block.
    static func scriptLines(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let last = lines.indices.last, line.first.map({ $0.isWhitespace }) ?? true {
                lines[last] += "\n" + line
            } else {
                lines.append(String(line))
            }
        }

        if let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                lines[0] = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        return lines
    }

    /// Drops indented `//` comment lines and strips `//...` outside quotes.
    static func removeComments(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { line in
                guard let first = line.first, first.isWhitespace else { return true }
                return !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            .map(stripLineComment)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLineComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if let q = quote {
                if c == q && previous != "\\" { quote = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            } else if c == "/", previous == "/" {
                return String(line[..<line.index(before: index)])
            }

            previous = c
            index = line.index(after: index)
        }

        return line
    }

    static func parseSearchCommand(_ command: String) -> SearchCommand? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for verb in ["SEARCH", "AGGREGATE"] {
            let head = "FT.\(verb)"
            guard trimmed.count > head.count, trimmed.uppercased().hasPrefix(head) else { continue }
            let rest = String(trimmed.dropFirst(head.count))
            guard let first = rest.first, first.isWhitespace,
                  !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return SearchCommand(verb: verb, rest: rest)
        }

        return nil
    }

    static func explain(_ command: SearchCommand) -> String {
        "FT.EXPLAIN" + command.rest
    }

    static func profile(_ command: SearchCommand) -> String {
        let (token, remainder) = indexToken(command.rest)
        if remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "FT.PROFILE \(token) \(command.verb) QUERY"
        }

        return "FT.PROFILE \(token) \(command.verb) QUERY\(remainder)"
    }

    /// Returns the first token and remaining text, preserving quotes and skipping escapes inside quotes.
    /// An unterminated quote consumes the remaining text.
    static func indexToken(_ rest: String) -> (token: String, remainder: String) {
        let chars = Array(rest.drop { $0.isWhitespace })
        guard let first = chars.first else { return ("", "") }
        var i = 0
        if first == "\"" || first == "'" {
            i = 1
            var closed = false
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == first { closed = true; i += 1; break }
                i += 1
            }

            if !closed { return (String(chars), "") }
        } else {
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
        }

        let end = min(i, chars.count)
        return (String(chars[..<end]), String(chars[end...]))
    }

    // MARK: - Templates

    struct Template: Identifiable, Hashable {
        var id: String { title }
        var title: String
        var detail: String
        /// VS Code style snippet (`${1:placeholder}`).
        var snippet: String
    }

    /// Builds FT.* and vector templates for the index using the server match-all syntax.
    /// Omits FT.EXPLAIN and FT.PROFILE if the server lacks them.
    static func templates(indexName: String?, info: SearchIndexInfo?,
                          capabilities: DatabaseCapabilities = DatabaseCapabilities()) -> [Template] {
        let index = indexName.map(quoteIndex) ?? "${1:index}"
        let n = indexName == nil ? 2 : 1
        let all = SearchIndexService.matchAllQuery(attributes: info?.attributes ?? [], capabilities: capabilities)
            ?? "query"
        var out = [
            Template(title: "FT.SEARCH", detail: "Query documents by text, tags or ranges", snippet: "FT.SEARCH \(index) \"${\(n):\(all)}\""),
            Template(title: "FT.AGGREGATE", detail: "Group, reduce and sort matches", snippet: "FT.AGGREGATE \(index) \"${\(n):\(all)}\""),
            Template(title: "FT.SUGGET", detail: "Complete a prefix from a suggestion dictionary", snippet: "FT.SUGGET ${1:key} ${2:prefix}"),
            Template(title: "FT.SPELLCHECK", detail: "Check query terms for misspellings", snippet: "FT.SPELLCHECK \(index) \"${\(n):query}\""),
        ]
        if capabilities.supportsSearchExplain {
            out += [
                Template(title: "FT.EXPLAIN", detail: "Show the query plan", snippet: "FT.EXPLAIN \(index) \"${\(n):\(all)}\""),
                Template(title: "FT.PROFILE", detail: "Time each stage of a query", snippet: "FT.PROFILE \(index) SEARCH QUERY \"${\(n):\(all)}\""),
            ]
        }

        out.append(Template(title: "FT._LIST", detail: "List every index name", snippet: "FT._LIST"))
        let vector = info?.attributes.first { $0.fieldType == .vector }
        let vectorName = vector?.queryName ?? "embedding"
        let blob = vector.map(sampleBlob) ?? "${\(n + 1):vector_blob}"
        let filterAttribute = info?.attributes.first { $0.fieldType == .tag || $0.fieldType == .numeric }
        let filter: String
        if let filterAttribute {
            let name = filterAttribute.queryName
            filter = filterAttribute.fieldType == .tag ? "@\(name):{${\(n):value}}" : "@\(name):[${\(n):0} +inf]"
        } else {
            filter = "@${\(n):field}:{${\(n + 2):value}}"
        }

        out += [
            Template(title: "KNN vector search", detail: "Nearest neighbors of a query vector",
                     snippet: "FT.SEARCH \(index) \"*=>[KNN ${\(n):10} @\(vectorName) $vec AS score]\" PARAMS 2 vec \"\(blob)\" SORTBY score DIALECT 2"),
            Template(title: "Vector range query", detail: "Documents within a distance radius",
                     snippet: "FT.SEARCH \(index) \"@\(vectorName):[VECTOR_RANGE ${\(n):0.5} $vec]=>{$YIELD_DISTANCE_AS: score}\" PARAMS 2 vec \"\(blob)\" SORTBY score DIALECT 2"),
            Template(title: "Hybrid search", detail: "Filter first, then rank by vector similarity",
                     snippet: "FT.SEARCH \(index) \"(\(filter))=>[KNN 10 @\(vectorName) $vec AS score]\" PARAMS 2 vec \"\(blob)\" SORTBY score DIALECT 2"),
        ]
        return out
    }

    static func quoteIndex(_ name: String) -> String {
        "'" + name.replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// A runnable query vector of the attribute's dimension (all components 1.0), `\xHH` escaped.
    static func sampleBlob(_ attribute: SearchIndexAttribute) -> String {
        let dims = Int(attribute.raw["dim"] ?? attribute.raw["DIM"] ?? "") ?? 4
        let dataType = (attribute.raw["data_type"] ?? attribute.raw["DATA_TYPE"] ?? "FLOAT32").uppercased()
        let one: [UInt8]
        switch dataType {
        case "FLOAT64": one = [0, 0, 0, 0, 0, 0, 0xF0, 0x3F]
        case "FLOAT16": one = [0x00, 0x3C]
        case "BFLOAT16": one = [0x80, 0x3F]
        default: one = [0x00, 0x00, 0x80, 0x3F]
        }

        let element = one.map { String(format: "\\x%02x", $0) }.joined()
        return String(repeating: element, count: max(1, min(dims, 32_768)))
    }
}
