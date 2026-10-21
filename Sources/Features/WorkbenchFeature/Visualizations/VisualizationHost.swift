import RedisUI
import SwiftUI

/// Renders the selected visualization of a successful card; falls back to the Text view when the reply does not fit.
struct VisualizationHost: View {
    let model: WorkbenchViewModel
    let card: WorkbenchCard
    let node: ReplyNode
    let isFullscreen: Bool

    var body: some View {
        let command = card.execution.command
        let fallback = ResultTextView(card: card, isFullscreen: isFullscreen)
        switch card.selectedView {
        case .text:
            fallback
        case .searchTable:
            AsyncParsedView(key: card.execution.id, parse: { SearchResultParser.parse(node, command: command) },
                            fallback: { fallback }) { table in
                SearchResultsTableView(table: table, highlight: command.uppercased().contains("HIGHLIGHT"),
                                       isFullscreen: isFullscreen)
                    .onAppear { card.headerMessage = table.matched.map(WorkbenchResultFormatter.headerMessage(matched:)) }
            }
        case .indexInfo:
            AsyncParsedView(key: card.execution.id, parse: { IndexInfoParser.parse(node) },
                            fallback: { fallback }) { info in
                IndexInfoView(info: info, isFullscreen: isFullscreen)
            }
        case .json:
            let mode = card.execution.mode
            AsyncParsedView(key: card.execution.id, parse: { JSONResultParser.parse(node, command: command, mode: mode) },
                            fallback: { fallback }) { value in
                JSONResultView(value: value, isFullscreen: isFullscreen)
            }
        case .clientList:
            AsyncParsedView(key: card.execution.id, parse: { node.scalarText.map(ClientListParser.parse) },
                            fallback: { fallback }) { clients in
                ClientListTableView(model: clients, isFullscreen: isFullscreen)
            }
        case .timeSeries:
            AsyncParsedView(key: card.execution.id, parse: { TimeSeriesParser.parse(node, command: command) },
                            fallback: { MessageBlock(text: ReplyTextFormatter.text(node, command: command), isError: true) }) { series in
                TimeSeriesChartView(series: series, config: model.timeSeriesPreferences.chartConfig,
                                    isFullscreen: isFullscreen) { model.updateChartConfig($0) }
            }
        case .explain:
            AsyncParsedView(key: card.execution.id, parse: { ExplainParser.parse(node) },
                            fallback: { fallback }) { result in
                ExplainResultView(result: result, rawText: ExplainParser.text(of: node) ?? "", isFullscreen: isFullscreen)
            }
        case .profile:
            AsyncParsedView(key: card.execution.id, parse: { ProfileParser.parse(node) },
                            fallback: {
                                VStack(alignment: .leading) {
                                    MessageBlock(text: ExplainParser.failureMessage, isError: true)
                                    fallback
                                }
                            }) { profile in
                ProfileResultView(profile: profile, isFullscreen: isFullscreen)
            }
        case .geoMap, .geoHeatmap, .geoTable:
            let style: GeoResultView.Style = card.selectedView == .geoMap ? .map
                : card.selectedView == .geoHeatmap ? .heatmap : .details
            AsyncParsedView(key: card.execution.id, parse: { GeoParser.parse(node, command: command) },
                            fallback: { fallback }) { geo in
                GeoResultView(geo: geo, style: style, isFullscreen: isFullscreen)
            }
        }
    }
}

/// Parses a reply on a background task, then shows `content` (or `fallback` when parsing returns nil).
struct AsyncParsedView<Model: Sendable, Content: View, Fallback: View>: View {
    let key: UUID
    let parse: @Sendable () -> Model?
    @ViewBuilder let fallback: () -> Fallback
    @ViewBuilder let content: (Model) -> Content

    @State private var state: ParseState = .loading

    enum ParseState {
        case loading
        case parsed(Model)
        case failed
    }

    init(key: UUID, parse: @escaping @Sendable () -> Model?, @ViewBuilder fallback: @escaping () -> Fallback,
         @ViewBuilder content: @escaping (Model) -> Content) {
        self.key = key
        self.parse = parse
        self.fallback = fallback
        self.content = content
    }

    var body: some View {
        Group {
            switch state {
            case .loading: ProgressView().controlSize(.small)
            case .parsed(let model): content(model)
            case .failed: fallback()
            }
        }
        .task(id: key) {
            let parse = self.parse
            let parsed = await Task.detached(priority: .userInitiated) { parse() }.value
            state = parsed.map { .parsed($0) } ?? .failed
        }
    }
}

/// Maximum visualization height inside a card when it is not fullscreen.
enum VisualizationMetrics {
    static let maxHeight: CGFloat = 380
}
