import RedisUI
import SwiftUI

struct RecommendationContentView: View {
    let nodes: [RecommendationNode]
    var params: RecommendationParams?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(Self.blocks(nodes).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case inline([RecommendationNode])
        case paragraph(String)
        case spacer(CGFloat)
        case list([[RecommendationNode]])
        case unknown(String?)
    }

    nonisolated static func blocks(_ nodes: [RecommendationNode]) -> [Block] {
        var out: [Block] = []
        var run: [RecommendationNode] = []

        func flush() {
            if !run.isEmpty { out.append(.inline(run)); run = [] }
        }

        for node in nodes {
            if node.isInline { run.append(node); continue }
            flush()
            switch node {
            case .paragraph(let text): out.append(.paragraph(text))
            case .spacer(let size): out.append(.spacer(spacerHeight(size)))
            case .list(let items): out.append(.list(items))
            case .unknown(let text): out.append(.unknown(text))
            default: break
            }
        }

        flush()
        return out
    }

    nonisolated static func spacerHeight(_ size: String) -> CGFloat {
        switch size {
        case "xs": return 2
        case "s": return 4
        case "m": return 8
        case "l": return 16
        case "xl": return 24
        default: return 8
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .inline(let run):
            Text(Self.attributed(run, params: params))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(RecommendationCatalog.fill(text, params: params))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        case .spacer(let height):
            Color.clear.frame(height: height)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(Self.attributed(item, params: params))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 6)
        case .unknown(let text):
            if let text {
                Text(text)
            } else {
                Text("*Unknown format*").bold()
            }
        }
    }

    static func attributed(_ run: [RecommendationNode], params: RecommendationParams?) -> AttributedString {
        var out = AttributedString()
        for node in run {
            switch node {
            case .span(let text):
                out += AttributedString(RecommendationCatalog.fill(text, params: params))
            case .paragraph(let text):
                out += AttributedString(RecommendationCatalog.fill(text, params: params))
            case .code(let text):
                var piece = AttributedString(RecommendationCatalog.fill(text, params: params))
                piece.font = .body.monospaced()
                out += piece
            case .codeLink(let href, let name):
                var piece = AttributedString(name)
                piece.font = .body.monospaced()
                if let url = URL(string: href) { piece.link = url }
                out += piece
            case .link(let href, let name):
                var piece = AttributedString(name)
                if let url = URL(string: href) { piece.link = url }
                out += piece
            case .unknown(let text):
                out += AttributedString(text ?? "")
            case .spacer, .list:
                break
            }
        }

        return out
    }
}

struct RecommendationBadgesView: View {
    let badges: [RecommendationBadge]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                Image(systemName: badge.systemImage)
                    .foregroundStyle(.secondary)
                    .help(badge.label)
                    .accessibilityLabel(badge.label)
            }
        }
    }
}

struct RecommendationKeyExample: View {
    let key: Data

    var body: some View {
        let name = AnalyticsFormat.keyName(key)
        VStack(alignment: .leading, spacing: 4) {
            Text("One key this tip applies to:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(name)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(name)
                CopyButton(text: name, help: "Copy Key Name")
                Spacer(minLength: 0)
            }
        }
    }
}
