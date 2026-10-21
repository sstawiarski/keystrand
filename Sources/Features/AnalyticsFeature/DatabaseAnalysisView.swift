import RedisUI
import SwiftUI

/// Analytics > Database Analysis (reports, summary, tips).
public struct DatabaseAnalysisView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var body: some View {
        DatabaseAnalysisContent(model: DatabaseAnalysisViewModel.shared(for: session),
                                tips: LiveTipsModel.shared(for: session))
    }
}

struct DatabaseAnalysisContent: View {
    @Bindable var model: DatabaseAnalysisViewModel
    let tips: LiveTipsModel
    @State private var confirmDelete = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { toolbarItems }
            .focusedSceneValue(\.analyticsCommands, AnalyticsCommands(
                newReport: { model.startAnalysis() }, canCreateReport: canCreateReport))
            .destructiveConfirmation("Delete Report?", isPresented: $confirmDelete,
                                     message: "The selected report will be removed from the history.") {
                if let id = model.selectedReportID { Task { await model.deleteReport(id) } }
            }
            .task { await model.loadIfNeeded() }
    }

    private var canCreateReport: Bool { !model.isAnalyzing && !model.isLoadingReport }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.report != nil {
                Picker("View", selection: $model.subTab) {
                    Text("Summary").tag(AnalysisSubTab.summary)
                    Text(model.tipsTitle).tag(AnalysisSubTab.tips)
                }
                .pickerStyle(.segmented)
                .help("Show the summary or the tips of the selected report")
            }

            if !model.reports.isEmpty {
                Menu {
                    Picker("Report", selection: Binding(
                        get: { model.selectedReportID },
                        set: { id in if let id { Task { await model.select(id) } } })) {
                        ForEach(model.reports) { item in
                            Text(model.historyLabel(item)).tag(Optional(item.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button("Delete Report…") { confirmDelete = true }
                        .disabled(model.selectedReportID == nil)
                } label: {
                    Text(selectedReportTitle)
                }
                .disabled(model.isAnalyzing)
                .help("Previously generated reports")
            }

            Button {
                model.startAnalysis()
            } label: {
                Label("New Report", systemImage: "play.fill")
            }
            .disabled(!canCreateReport)
            .help(model.session.isCluster
                ? "Samples up to 10,000 keys on each shard, breaks down their memory use, and suggests ways to reduce it."
                : "Samples up to 10,000 keys, breaks down their memory use, and suggests ways to reduce it.")
        }
    }

    private var selectedReportTitle: String {
        guard let id = model.selectedReportID, let item = model.reports.first(where: { $0.id == id }) else { return "Reports" }
        return AnalyticsFormat.date(item.createdAt, settings: model.session.services.settings)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView()
        } else if model.reports.isEmpty {
            if model.isAnalyzing {
                AnalysisRunningView(progress: model.liveProgress) { model.cancelAnalysis() }
            } else {
                ContentUnavailableView {
                    Label("No Reports", systemImage: "chart.pie")
                } description: {
                    Text("Sample up to 10,000 keys for a memory breakdown and tips on saving space.")
                } actions: {
                    Button("New Report") { model.startAnalysis() }
                }
            }
        } else if let error = model.reportError {
            ContentUnavailableView {
                Label("Report Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error == .undecodable ? "Re-run the analysis to create a new report." : error.localizedDescription)
            } actions: {
                Button("New Report") { model.startAnalysis() }.disabled(!canCreateReport)
            }
        } else if let report = model.report {
            switch model.subTab {
            case .summary: summary(report)
            case .tips: AnalysisTipsListView(model: model, tips: tips, catalog: model.catalog)
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func summary(_ report: DatabaseAnalysisReport) -> some View {
        if report.totalKeys.total == 0 && !model.isAnalyzing {
            ContentUnavailableView {
                Label("No Keys to Analyze", systemImage: "key")
            } description: {
                Text("Use the Workbench tutorials to load sample data.")
            } actions: {
                Button("Open Workbench") { model.openWorkbench() }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    AnalysisProgressLine(progress: model.displayedProgress, isAnalyzing: model.isAnalyzing,
                                         onCancel: { model.cancelAnalysis() })
                    if model.showsSummarySection {
                        Divider()
                        SummaryPerTypeSection(model: model, report: report)
                    }

                    if model.showsTTLSection {
                        Divider()
                        ExpirationSection(model: model)
                    }

                    if model.showsNamespacesSection {
                        Divider()
                        TopNamespacesSection(model: model)
                    }

                    if model.showsTopKeysSection {
                        Divider()
                        TopKeysSection(model: model)
                    }
                }
                .padding(20)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct AnalysisProgressLine: View {
    let progress: AnalysisProgress?
    let isAnalyzing: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(text)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(isPartial ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .contentTransition(.numericText())
                    .help("Keys analyzed of the keys in the database")
                Spacer()
                if isAnalyzing {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Stop the running analysis")
                }
            }
            if isAnalyzing {
                ProgressView(value: AnalyticsFormat.progressFraction(progress))
            }
        }
    }

    private var isPartial: Bool {
        guard !isAnalyzing, let progress else { return false }
        return progress.processed != progress.total
    }

    private var text: String {
        guard let progress else { return "Scanning keys…" }
        if isAnalyzing { return AnalyticsFormat.liveProgressText(progress) }
        return AnalyticsFormat.progressLine(progress)
    }
}

struct AnalysisRunningView: View {
    let progress: AnalysisProgress?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: AnalyticsFormat.progressFraction(progress))
                .frame(width: 240)
            Text(progress.map(AnalyticsFormat.liveProgressText) ?? "Scanning keys…")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Cancel", action: onCancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
