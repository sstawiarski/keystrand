import Foundation

public struct MarkdownCodeBlock: Hashable, Sendable {
    /// First word of the fence info string (`redis`, `json`, `redis-auto`…), lowercased.
    public var language: String?
    /// Full fence info string, e.g. `redis:[run_confirmation=true] Create index`.
    public var info: String
    public var code: String

    public init(language: String?, info: String, code: String) {
        self.language = language
        self.info = info
        self.code = code
    }
}

public struct MarkdownListItem: Hashable, Sendable {
    public var text: String
    /// Nesting level (0 = top) from leading indentation.
    public var level: Int
    public var ordered: Bool
    public var number: Int?
    /// Task-list state for `- [ ]` / `- [x]`.
    public var checked: Bool?

    public init(text: String, level: Int = 0, ordered: Bool = false, number: Int? = nil, checked: Bool? = nil) {
        self.text = text
        self.level = level
        self.ordered = ordered
        self.number = number
        self.checked = checked
    }
}

public enum MarkdownTableAlignment: Hashable, Sendable {
    case leading, center, trailing
}

public indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case code(MarkdownCodeBlock)
    case quote([MarkdownBlock])
    case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case image(alt: String, source: String)
    case rule
}

/// Small block-level Markdown parser (headings, paragraphs, lists, block quotes, tables, fenced code, images, rules).
/// Inline formatting is left in the text for `AttributedString(markdown:)`.
public enum MarkdownParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return parse(lines: lines[...])
    }

    private static func parse(lines: ArraySlice<String>) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = lines.startIndex

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(joinParagraph(paragraph)))
            paragraph = []
        }

        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if let fence = fenceMarker(line) {
                flushParagraph()
                let info = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.endIndex {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence), candidate.allSatisfy({ $0 == fence.first }) { break }
                    code.append(lines[i])
                    i += 1
                }

                i += 1
                let language = info.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "{" || $0 == "[" }).first
                    .map { String($0).lowercased() }
                blocks.append(.code(MarkdownCodeBlock(language: language, info: info, code: code.joined(separator: "\n"))))
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.dropFirst(heading).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: heading, text: stripClosingHashes(text)))
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.endIndex {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = candidate.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoted.append(String(content))
                    i += 1
                }

                blocks.append(.quote(parse(lines: quoted[...])))
                continue
            }

            if i + 1 < lines.endIndex, trimmed.contains("|"), let alignments = tableSeparator(lines[i + 1]) {
                flushParagraph()
                let headers = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.endIndex {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, candidate.contains("|") else { break }
                    var cells = tableCells(candidate)
                    if cells.count < headers.count { cells += Array(repeating: "", count: headers.count - cells.count) }
                    rows.append(Array(cells.prefix(headers.count)))
                    i += 1
                }

                let padded = alignments + Array(repeating: .leading, count: max(0, headers.count - alignments.count))
                blocks.append(.table(headers: headers, alignments: Array(padded.prefix(headers.count)), rows: rows))
                continue
            }

            if listMarker(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while i < lines.endIndex {
                    let candidate = lines[i]
                    if let marker = listMarker(candidate) {
                        items.append(marker)
                        i += 1
                        continue
                    }

                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if !candidateTrimmed.isEmpty, candidate.hasPrefix("  ") || candidate.hasPrefix("\t"), !items.isEmpty,
                       fenceMarker(candidate) == nil {
                        items[items.count - 1].text += " " + candidateTrimmed
                        i += 1
                        continue
                    }

                    break
                }

                blocks.append(.list(items))
                continue
            }

            if let image = standaloneImage(trimmed) {
                flushParagraph()
                blocks.append(.image(alt: image.alt, source: image.source))
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    private static func joinParagraph(_ lines: [String]) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            let hardBreak = line.hasSuffix("  ") || line.hasSuffix("\\")
            var content = line.trimmingCharacters(in: .whitespaces)
            if content.hasSuffix("\\") { content.removeLast() }
            result += content
            if index < lines.count - 1 { result += hardBreak ? "\n" : " " }
        }

        return result
    }

    static func fenceMarker(_ line: String) -> String? {
        let leading = line.prefix { $0 == " " }.count
        guard leading <= 3 else { return nil }
        let trimmed = line.dropFirst(leading)
        for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) {
            let char = fence.first ?? "`"
            return String(trimmed.prefix { $0 == char })
        }

        return nil
    }

    static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return hashes
    }

    private static func stripClosingHashes(_ text: String) -> String {
        guard text.hasSuffix("#") else { return text }
        let stripped = text.replacingOccurrences(of: "\\s+#+$", with: "", options: .regularExpression)
        return stripped.isEmpty ? text : stripped
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listMarker(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(indent.count)
        var item: MarkdownListItem?
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            item = MarkdownListItem(text: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces), level: width / 2)
        } else {
            let digits = rest.prefix { $0.isNumber }
            let after = rest.dropFirst(digits.count)
            if !digits.isEmpty, digits.count <= 9, let marker = after.first, marker == "." || marker == ")",
               after.dropFirst().first == " " {
                item = MarkdownListItem(text: String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                                        level: width / 2, ordered: true, number: Int(digits))
            }
        }

        guard var result = item else { return nil }
        if result.text.hasPrefix("[ ] ") || result.text == "[ ]" {
            result.checked = false
            result.text = String(result.text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if result.text.lowercased().hasPrefix("[x] ") || result.text.lowercased() == "[x]" {
            result.checked = true
            result.text = String(result.text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        return result
    }

    static func tableSeparator(_ line: String) -> [MarkdownTableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty, cells.allSatisfy({ $0.contains("-") }) else { return nil }
        return cells.map { cell in
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            return .leading
        }
    }

    static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var previous: Character?
        for char in trimmed {
            if char == "|", previous != "\\" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else if char == "|" {
                current.removeLast()
                current.append(char)
            } else {
                current.append(char)
            }

            previous = char
        }

        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func standaloneImage(_ trimmed: String) -> (alt: String, source: String)? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
              let altEnd = trimmed.range(of: "]("), altEnd.lowerBound > trimmed.index(trimmed.startIndex, offsetBy: 1) else {
            return nil
        }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        var source = String(trimmed[altEnd.upperBound..<trimmed.index(before: trimmed.endIndex)])
        if let space = source.firstIndex(of: " ") { source = String(source[..<space]) }
        guard !source.isEmpty, !alt.contains("]") else { return nil }
        return (alt, source)
    }
}
