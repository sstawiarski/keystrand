import AppKit
import SwiftUI

/// Renders Markdown blocks natively. Code blocks can be replaced (e.g. tutorial "Run" blocks) with `codeBlock`.
/// Relative image paths resolve against `baseURL`. `onOpenLink` may intercept links (return true when handled).
public struct MarkdownView: View {
    public var blocks: [MarkdownBlock]
    public var baseURL: URL?
    public var codeBlock: ((MarkdownCodeBlock) -> AnyView)?
    public var onOpenLink: ((URL) -> Bool)?

    public init(markdown: String, baseURL: URL? = nil, codeBlock: ((MarkdownCodeBlock) -> AnyView)? = nil,
                onOpenLink: ((URL) -> Bool)? = nil) {
        self.init(blocks: MarkdownParser.parse(markdown), baseURL: baseURL, codeBlock: codeBlock, onOpenLink: onOpenLink)
    }

    public init(blocks: [MarkdownBlock], baseURL: URL? = nil, codeBlock: ((MarkdownCodeBlock) -> AnyView)? = nil,
                onOpenLink: ((URL) -> Bool)? = nil) {
        self.blocks = blocks
        self.baseURL = baseURL
        self.codeBlock = codeBlock
        self.onOpenLink = onOpenLink
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, baseURL: baseURL, codeBlock: codeBlock)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if onOpenLink?(url) == true { return .handled }
            return .systemAction
        })
    }

    /// Inline Markdown (bold, italic, code, links) as an attributed string; falls back to plain text.
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var attributed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = Font.callout.monospaced()
                attributed[run.range].backgroundColor = Color(nsColor: .quaternarySystemFill)
            }

            if run.link != nil {
                attributed[run.range].foregroundColor = Color(nsColor: .linkColor)
            }
        }

        return attributed
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let baseURL: URL?
    let codeBlock: ((MarkdownCodeBlock) -> AnyView)?

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownView.inline(text))
                .font(headingFont(level))
                .foregroundStyle(.primary)
                .padding(.top, level <= 2 ? 4 : 0)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(MarkdownView.inline(text))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        bullet(item)
                        Text(MarkdownView.inline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }
        case .code(let code):
            if let codeBlock {
                codeBlock(code)
            } else {
                MarkdownCodeView(code: code)
            }
        case .quote(let blocks):
            HStack(spacing: 8) {
                Rectangle().fill(.quaternary).frame(width: 3)
                MarkdownView(blocks: blocks, baseURL: baseURL, codeBlock: codeBlock)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let headers, let alignments, let rows):
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows)
        case .image(let alt, let source):
            MarkdownImageView(alt: alt, source: source, baseURL: baseURL)
        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func bullet(_ item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
        } else if item.ordered {
            Text("\(item.number ?? 1).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text(item.level == 0 ? "•" : "◦").foregroundStyle(.secondary)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}

/// Highlighted, monospaced fenced code with an optional language label, Copy and a quaternary fill.
public struct MarkdownCodeView: View {
    public var code: MarkdownCodeBlock

    public init(code: MarkdownCodeBlock) {
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let language = code.language, !language.isEmpty {
                    Text(language).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }

                Spacer()
                CopyButton(text: code.code, help: "Copy Code", title: "Copy")
                    .controlSize(.small)
            }
            ScrollView(.horizontal) {
                Text(highlighted)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary, in: .rect(cornerRadius: 6))
        }
    }

    private var highlighted: AttributedString {
        let language: CodeLanguage
        switch code.language {
        case let value? where value.hasPrefix("redis"): language = .redis
        case "json"?: language = .json
        default: language = .plain
        }

        return SyntaxAttributedString.make(code.code, language: language)
    }
}

/// Highlights read-only snippets with syntax token colors.
public enum SyntaxAttributedString {
    public static func make(_ text: String, language: CodeLanguage, keywords: Set<String>? = nil) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = Color(nsColor: EditorAppearance.Syntax.text)
        guard language != .plain else { return result }
        let ns = text as NSString
        for token in RedisSyntaxHighlighter.tokenize(text, language: language, keywords: keywords) {
            guard NSMaxRange(token.range) <= ns.length, let range = Range(token.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = color(token.kind)
        }

        return result
    }

    static func color(_ kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .key: return EditorAppearance.JSON.key
        case .boolean: return EditorAppearance.JSON.boolean
        case .null: return EditorAppearance.JSON.null
        case .punctuation: return EditorAppearance.JSON.punctuation
        default: return Color(nsColor: EditorAppearance.Syntax.color(for: kind))
        }
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        cell(header, column: index).font(.callout.weight(.semibold))
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                            cell(value, column: index).font(.callout)
                        }
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(.separator))
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: alignment = .leading
        case .center: alignment = .center
        case .trailing: alignment = .trailing
        }

        return Text(MarkdownView.inline(text))
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: alignment)
            .overlay(Rectangle().stroke(.separator, lineWidth: 0.5))
    }
}

struct MarkdownImageView: View {
    let alt: String
    let source: String
    let baseURL: URL?

    var body: some View {
        if let url = resolvedURL, url.isFileURL {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: min(image.size.width, 640))
            } else {
                placeholder
            }
        } else if let url = resolvedURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().frame(maxWidth: 640)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Label(alt.isEmpty ? source : alt, systemImage: "photo").font(.caption).foregroundStyle(.tertiary)
    }

    private var resolvedURL: URL? {
        if let url = URL(string: source), url.scheme != nil { return url }
        guard let baseURL else { return nil }
        return URL(string: source, relativeTo: baseURL)?.absoluteURL
            ?? baseURL.appendingPathComponent(source)
    }
}
