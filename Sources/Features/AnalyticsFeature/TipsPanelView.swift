import RedisUI
import SwiftUI

/// Inspector > Tips (database recommendations).
public struct TipsPanelView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var body: some View {
        TipsPanelContent(tips: LiveTipsModel.shared(for: session),
                         analysis: DatabaseAnalysisViewModel.shared(for: session))
    }
}

struct TipsPanelContent: View {
    let tips: LiveTipsModel
    let analysis: DatabaseAnalysisViewModel
    @State private var confirmAnalyze = false
    /// Tips unread when the pane opened start expanded.
    @State private var initiallyUnread: Set<String> = []

    static let analyzeMessage = "The analysis samples up to 10,000 keys, breaks down their memory use, and suggests ways to reduce it."

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .confirmationDialog("Run Database Analysis?", isPresented: $confirmAnalyze, titleVisibility: .visible) {
            Button("Analyze") { runAnalysis() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.analyzeMessage)
        }
        .task {
            await tips.refresh(analysisStore: analysis.store)
            initiallyUnread = Set(tips.allTips.filter { !$0.read }.map(\.name))
        }
        .onDisappear { Task { await tips.markAllRead() } }
    }

    @ViewBuilder
    private var content: some View {
        if !tips.hasLoaded {
            ProgressView()
        } else if tips.allTips.isEmpty {
            ContentUnavailableView {
                Label("No Tips Yet", systemImage: "lightbulb")
            } description: {
                Text("Tips show up here as you browse keys and run commands. An analysis can find more.")
            } actions: {
                Button("Analyze Database") { confirmAnalyze = true }
                    .disabled(analysis.isAnalyzing)
            }
        } else if tips.visibleTips.isEmpty {
            ContentUnavailableView {
                Label("All Tips Hidden", systemImage: "eye.slash")
            } description: {
                Text("Show hidden tips to see them again.")
            }
        } else {
            List {
                ForEach(tips.visibleTips) { tip in
                    if let content = tips.catalog[tip.name] {
                        TipRow(title: content.liveTitle ?? content.title, titleHelp: content.title, content: content,
                               params: tip.params, isHidden: tip.hide, isUnread: !tip.read,
                               initiallyExpanded: initiallyUnread.contains(tip.name))
                            .contextMenu {
                                Button(tip.hide ? "Show Tip" : "Hide Tip") { Task { await tips.toggleHidden(tip) } }
                                Button("Snooze") { Task { await tips.snooze(tip) } }
                                if let key = tip.params?.keys.first {
                                    Divider()
                                    Button("Copy Example Key") { copy(AnalyticsFormat.keyName(key)) }
                                }
                            }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if tips.hasHiddenTips || tips.showHidden {
                ShowHiddenTipsBar(tips: tips)
                Divider()
            }

            HStack(spacing: 8) {
                if analysis.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Text("Analyzing Database…").foregroundStyle(.secondary)
                } else {
                    Button("Analyze Database") { confirmAnalyze = true }
                        .help("Run Database Analysis to get more tips")
                }

                Spacer()
                if tips.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .help("Checking the database for tips")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func runAnalysis() {
        analysis.subTab = .tips
        analysis.startAnalysis()
        analysis.session.navigator.navigate(.analytics(.databaseAnalysis))
    }
}
