import RedisUI
import SwiftUI

/// Shows compact overview metrics in the window activity area and drives auto-refresh.
public struct OverviewBarView: View {
    public let session: DatabaseSession
    private let model: OverviewBarViewModel
    @State private var windowVisibility = WindowVisibility()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(session: DatabaseSession) {
        self.session = session
        model = session.scopedObject(OverviewBarViewModel.self) { OverviewBarViewModel(session: session) }
    }

    private var settings: SettingsStore { session.services.settings }

    public var body: some View {
        let parts = OverviewSummary.parts(overview: session.overview, version: model.version,
                                          flavor: session.serverFlavor, dbIndex: session.effectiveDB)
        HStack(spacing: 6) {
            if parts.isEmpty, model.isWaitingForFirstSample {
                ProgressView().controlSize(.small)
                    .help("Loading overview")
            } else {
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(OverviewSummary.variants(parts).enumerated()), id: \.offset) { _, variant in
                        summary(variant)
                    }
                }
            }

            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
                    .accessibilityLabel("Overview refresh failed: \(error)")
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .trackWindowVisibility(windowVisibility)
        .onAppear {
            model.barDidAppear()
            windowVisibility.onBecameVisible = { [model] in Task { await model.windowBecameVisible() } }
        }
        .onDisappear { model.barDidDisappear() }
        .task(id: session.state.isConnected) {
            guard session.state.isConnected, session.overview == nil else { return }
            try? await Task.sleep(for: OverviewBarViewModel.initialRefreshDelay)
            guard !Task.isCancelled, session.overview == nil else { return }
            await model.refresh()
        }
        .task(id: refreshKey) {
            guard OverviewRefreshPreferences.isEnabled(settings), session.state.isConnected else { return }
            let rate = OverviewRefreshPreferences.rate(settings)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(rate))
                if Task.isCancelled { break }
                await model.autoRefresh(isWindowVisible: windowVisibility.isVisible)
            }
        }
        .onChange(of: session.dbGeneration) { _, _ in Task { await model.refresh() } }
        .onChange(of: session.overview) { _, _ in model.noteExternalRefresh() }
        .onChange(of: session.overviewError) { _, _ in model.noteExternalRefresh() }
    }

    private var refreshKey: String {
        "\(OverviewRefreshPreferences.isEnabled(settings))-\(OverviewRefreshPreferences.rate(settings))-\(session.state.isConnected)"
    }

    private func summary(_ parts: [OverviewSummaryPart]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                if index > 0 { Text(OverviewSummary.separator) }
                Text(part.text)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .help(part.help)
            }
        }
        .fixedSize()
        .animation(reduceMotion ? nil : .default, value: parts)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(OverviewSummary.text(parts))
    }
}
