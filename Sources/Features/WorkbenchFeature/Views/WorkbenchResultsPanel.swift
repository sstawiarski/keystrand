import RedisUI
import SwiftUI

/// Bottom pane: result sections (newest first) with pinned headers, or the loading and empty states.
struct WorkbenchResultsPanel: View {
    let model: WorkbenchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.cards.isEmpty {
                if model.historyLoaded {
                    WorkbenchEmptyState(navigator: model.session.navigator)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                results
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Color.clear.frame(height: 0).id(Self.topID)
                    ForEach(model.cards) { card in
                        ResultSection(model: model, card: card)
                    }
                }
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .onChange(of: model.scrollToTopToken) { _, _ in
                if reduceMotion {
                    proxy.scrollTo(Self.topID, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.topID, anchor: .top) }
                }
            }
        }
    }

    private static let topID = "workbench-top"
}

/// "No Results" with the tutorial shortcuts (they open the Tutorials inspector on that page).
struct WorkbenchEmptyState: View {
    let navigator: DatabaseNavigator

    static let tutorials: [(title: String, id: String)] = [
        ("Data Structures", "ds-strings"),
        ("Search and Query", "sq-intro"),
        ("Vector Search", "vss-intro"),
    ]

    var body: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "text.and.command.macwindow")
        } description: {
            Text("Run commands to see their results here. New to Redis? Try a tutorial.")
        } actions: {
            HStack {
                ForEach(Self.tutorials, id: \.id) { tutorial in
                    Button(tutorial.title) { navigator.navigate(.tutorial(id: tutorial.id)) }
                }
            }
            .fixedSize()
        }
    }
}
