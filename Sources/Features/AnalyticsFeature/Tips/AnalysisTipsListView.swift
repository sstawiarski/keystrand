import RedisUI
import SwiftUI

struct AnalysisTipsListView: View {
    let model: DatabaseAnalysisViewModel
    let tips: LiveTipsModel
    let catalog: RecommendationCatalog

    var body: some View {
        let recommendations = model.recommendations
        if model.allRecommendations.isEmpty {
            ContentUnavailableView("No Tips", systemImage: "checkmark.seal",
                                   description: Text("Keep up the good work."))
        } else {
            VStack(spacing: 0) {
                if recommendations.isEmpty {
                    ContentUnavailableView {
                        Label("All Tips Hidden", systemImage: "eye.slash")
                    } description: {
                        Text("Show hidden tips to see them again.")
                    } actions: {
                        Button("Show Hidden Tips") { Task { await tips.setShowHidden(true) } }
                    }
                } else {
                    List {
                        ForEach(recommendations) { recommendation in
                            if let content = catalog[recommendation.name] {
                                let hidden = tips.isHidden(recommendation.name)
                                TipRow(title: content.title, content: content, params: recommendation.params,
                                       isHidden: hidden)
                                    .contextMenu {
                                        Button(hidden ? "Show Tip" : "Hide Tip") {
                                            Task { await model.setTipHidden(recommendation, hidden: !hidden) }
                                        }
                                        if let key = recommendation.params?.keys.first {
                                            Divider()
                                            Button("Copy Example Key") { copy(AnalyticsFormat.keyName(key)) }
                                        }
                                    }
                            }
                        }
                    }
                    .listStyle(.inset)
                }

                if model.hasHiddenRecommendations || tips.showHidden {
                    Divider()
                    ShowHiddenTipsBar(tips: tips)
                }
            }
        }
    }
}

struct ShowHiddenTipsBar: View {
    let tips: LiveTipsModel

    var body: some View {
        HStack {
            Toggle("Show hidden tips", isOn: Binding(get: { tips.showHidden },
                                                     set: { value in Task { await tips.setShowHidden(value) } }))
                .toggleStyle(.checkbox)
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct TipRow: View {
    let title: String
    var titleHelp: String?
    let content: RecommendationContent
    var params: RecommendationParams?
    var isHidden = false
    var isUnread = false
    var initiallyExpanded = true
    @State private var isExpanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isExpanded ?? initiallyExpanded }, set: { isExpanded = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                RecommendationContentView(nodes: content.content, params: params)
                if let key = params?.keys.first {
                    RecommendationKeyExample(key: key)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        .accessibilityLabel("Unread")
                }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(isHidden ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(titleHelp ?? title)
                Spacer(minLength: 8)
                RecommendationBadgesView(badges: content.badges)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
