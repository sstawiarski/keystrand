import RedisUI
import SwiftUI

/// redis-cli style text of a result: lazy monospaced lines, errors in red, group echoes bold.
struct ResultTextView: View {
    let card: WorkbenchCard
    let isFullscreen: Bool

    static let collapsedMaxHeight: CGFloat = 210
    static let estimatedCharactersPerRow = 120

    var body: some View {
        Group {
            if let lines = card.lines {
                content(lines)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .task { if card.execution.result != nil { await card.renderText().value } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func content(_ lines: [ResultLine]) -> some View {
        if isFullscreen {
            ScrollView { linesStack(lines) }
        } else if Self.estimatedRows(lines) <= 11 {
            linesStack(lines)
        } else {
            ScrollView { linesStack(lines) }
                .frame(height: Self.collapsedMaxHeight)
        }
    }

    private func linesStack(_ lines: [ResultLine]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                ResultLineView(line: lines[index])
            }
        }
    }

    /// Rows after wrapping, approximated from the character count.
    static func estimatedRows(_ lines: [ResultLine]) -> Int {
        var rows = 0
        for line in lines {
            rows += max(1, (line.text.count + estimatedCharactersPerRow - 1) / estimatedCharactersPerRow)
            if rows > 11 { return rows }
        }

        return rows
    }
}

struct ResultLineView: View {
    let line: ResultLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.body.monospaced())
            .bold(line.style == .command)
            .foregroundStyle(color)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var color: Color {
        switch line.style {
        case .normal: return EditorAppearance.text
        case .error: return EditorAppearance.error
        case .command: return .primary
        case .notice: return .secondary
        }
    }
}
