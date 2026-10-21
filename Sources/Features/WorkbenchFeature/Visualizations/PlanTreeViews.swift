import RedisUI
import SwiftUI

/// FT.EXPLAIN / FT.EXPLAINCLI execution plan as an outline.
struct ExplainResultView: View {
    let result: ExplainParseResult
    let rawText: String
    let isFullscreen: Bool

    var body: some View {
        switch result {
        case .empty:
            Text(ExplainParser.emptyMessage)
                .foregroundStyle(.secondary)
        case .failure(let message):
            VStack(alignment: .leading, spacing: 8) {
                MessageBlock(text: message, isError: true)
                MessageBlock(text: rawText)
            }
        case .tree(let root):
            PlanOutline(root: root, isFullscreen: isFullscreen)
        }
    }
}

/// FT.PROFILE: timing metrics, then the iterator / result-processor outline.
struct ProfileResultView: View {
    let profile: ProfileModel
    let isFullscreen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !profile.metrics.isEmpty {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(Array(profile.metrics.enumerated()), id: \.offset) { _, metric in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.0).font(.caption).foregroundStyle(.secondary)
                            Text(metric.1)
                                .font(.body.monospaced().weight(.semibold))
                                .monospacedDigit()
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let tree = profile.tree {
                PlanOutline(root: tree, isFullscreen: isFullscreen)
            } else {
                Text("No profile data to display.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A plan tree in a plain list with disclosure groups (expanded by default).
struct PlanOutline: View {
    let root: PlanNode
    let isFullscreen: Bool

    static let rowHeight: CGFloat = 40

    var body: some View {
        List {
            PlanOutlineRow(node: root)
        }
        .listStyle(.plain)
        .frame(height: isFullscreen ? nil : min(VisualizationMetrics.maxHeight,
                                                CGFloat(root.nodeCount) * Self.rowHeight + 16))
        .frame(maxHeight: isFullscreen ? .infinity : nil)
    }
}

struct PlanOutlineRow: View {
    let node: PlanNode
    @State private var isExpanded = true

    var body: some View {
        if node.children.isEmpty {
            PlanNodeLabel(node: node)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    PlanOutlineRow(node: child)
                }
            } label: {
                PlanNodeLabel(node: node)
            }
        }
    }
}

struct PlanNodeLabel: View {
    let node: PlanNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.type).font(.headline)
                if let detail = node.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(detail)
                }
            }
            Spacer(minLength: 8)
            let metrics = node.metricsText
            if !metrics.isEmpty {
                Text(metrics)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

extension PlanNode {
    var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }

    var metricsText: String {
        var parts: [String] = []
        if let time { parts.append("\(time) ms") }
        if let counter { parts.append("Counter: \(counter)") }
        if let size { parts.append("Size: \(size)") }
        return parts.joined(separator: " · ")
    }
}
