import RedisUI
import SwiftUI

/// Analytics > Cluster Details (cluster databases only).
public struct ClusterDetailsView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var body: some View {
        if session.isCluster {
            ClusterDetailsContent(model: ClusterDetailsViewModel.shared(for: session))
        } else {
            ContentUnavailableView {
                Label("Not a Cluster", systemImage: "server.rack")
            } description: {
                Text("Cluster details are available only for databases in cluster mode.")
            } actions: {
                Button("Open Database Analysis") { session.navigator.navigate(.analytics(.databaseAnalysis)) }
            }
        }
    }
}

struct ClusterDetailsContent: View {
    let model: ClusterDetailsViewModel
    @State private var sortOrder: [KeyPathComparator<ClusterNodeRow>] = [KeyPathComparator(\.hostSort)]
    @State private var selection: Set<ClusterNodeRow.ID> = []
    @State private var windowVisibility = WindowVisibility()

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    AutoRefreshMenu(postfix: "clusterDetails", lastRefresh: model.lastRefresh, isLoading: model.isLoading,
                                    enabledByDefault: true, isPaused: model.isPollingStopped) {
                        // Ticks are skipped while polling is stopped, so a call then is a manual click.
                        if model.isPollingStopped {
                            Task { await model.refresh(manual: true) }
                        } else {
                            Task { await model.autoRefresh(isWindowVisible: windowVisibility.isVisible) }
                        }
                    }
                }
            }
            .trackWindowVisibility(windowVisibility)
            .task { await model.refresh(manual: model.details == nil) }
            .onChange(of: model.session.navigator.refreshGeneration) { Task { await model.refresh(manual: true) } }
    }

    @ViewBuilder
    private var content: some View {
        if let details = model.details {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = model.errorMessage {
                        HStack {
                            InlineMessage("Cluster details could not be refreshed: \(error)", kind: .warning)
                            Button("Try Again") { Task { await model.refresh(manual: true) } }
                                .controlSize(.small)
                        }
                    }

                    header(details)
                    Divider()
                    if model.primaries.isEmpty {
                        ContentUnavailableView("No Node Details", systemImage: "server.rack",
                                               description: Text("This cluster didn't report any primary nodes."))
                            .frame(height: 220)
                    } else {
                        charts
                        nodesTable
                    }
                }
                .padding(16)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else if let error = model.errorMessage {
            ErrorStateView(message: error) { Task { await model.refresh(manual: true) } }
        } else {
            ProgressView()
        }
    }

    // MARK: Header

    private func header(_ details: ClusterDetails) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                metric("Type", "OSS Cluster")
                metric("Version", details.versionText ?? "-")
                metric("User", AnalyticsFormat.truncated(model.userText, limit: 30), help: model.userText)
                metric("Uptime", AnalyticsFormat.durationFirstUnit(seconds: details.uptimeSec),
                       help: "\(NumberFormatting.grouped(details.uptimeSec)) s (\(AnalyticsFormat.durationFull(seconds: details.uptimeSec)))")
            }
            GridRow {
                metric("State", details.info.state == "ok" ? "OK" : details.info.state.capitalized,
                       tint: details.info.state == "ok" ? nil : .orange, help: "cluster_state")
                metric("Slots Assigned",
                       "\(NumberFormatting.grouped(details.info.slotsAssigned)) of \(NumberFormatting.grouped(ClusterSlot.count))",
                       help: "OK: \(details.info.slotsOk), PFail: \(details.info.slotsPFail), Fail: \(details.info.slotsFail), Unassigned: \(details.info.slotsUnassigned)")
                metric("Known Nodes", "\(details.info.knownNodes)")
                metric("Size", "\(details.info.size)", help: "Number of shards serving at least one slot")
            }
        }
    }

    private func metric(_ label: String, _ value: String, tint: Color? = nil, help: String? = nil) -> some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .lineLimit(1)
        } label: {
            Text(label).foregroundStyle(.secondary)
        }
        .fixedSize()
        .help(help ?? label)
    }

    // MARK: Charts

    private var charts: some View {
        let primaries = model.primaries
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { memoryChart(primaries); keysChart(primaries) }
            VStack(spacing: 24) { memoryChart(primaries); keysChart(primaries) }
        }
        .frame(maxWidth: .infinity)
    }

    private func memoryChart(_ primaries: [ClusterNodeDetails]) -> some View {
        DonutChartView(
            slices: primaries.map { node in
                DonutSlice(id: node.id, label: "\(node.letter): \(node.endpoint)", value: Double(node.metrics.usedMemory),
                           color: ChartPalette.color(at: node.index),
                           valueText: AnalyticsFormat.bytes(Double(node.metrics.usedMemory)))
            },
            centerTitle: "Memory",
            centerValue: AnalyticsFormat.bytes(Double(primaries.reduce(0) { $0 + $1.metrics.usedMemory })))
        .frame(width: 220, height: 220)
    }

    private func keysChart(_ primaries: [ClusterNodeDetails]) -> some View {
        DonutChartView(
            slices: primaries.map { node in
                DonutSlice(id: node.id, label: "\(node.letter): \(node.endpoint)", value: Double(node.metrics.totalKeys),
                           color: ChartPalette.color(at: node.index),
                           valueText: NumberFormatting.grouped(node.metrics.totalKeys))
            },
            centerTitle: "Keys",
            centerValue: NumberFormatting.grouped(primaries.reduce(0) { $0 + $1.metrics.totalKeys }))
        .frame(width: 220, height: 220)
    }

    // MARK: Table

    private var rows: [ClusterNodeRow] {
        let base = model.primaries.map { ClusterNodeRow(node: $0, children: $0.replicas?.map { ClusterNodeRow(node: $0, children: nil) }) }
        return base.sorted(using: sortOrder)
    }

    private var nodesTable: some View {
        let rows = self.rows
        let all = rows + rows.flatMap { $0.children ?? [] }
        let maxOps = model.maxIndex { $0.metrics.opsPerSecond }
        let maxIn = model.maxIndex { $0.metrics.networkInKbps }
        let maxOut = model.maxIndex { $0.metrics.networkOutKbps }
        let maxMem = model.maxIndex { $0.metrics.usedMemory }
        let maxKeys = model.maxIndex { $0.metrics.totalKeys }
        let maxClients = model.maxIndex { $0.metrics.connectedClients }
        return Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(model.primaryNodesHeader, value: \.hostSort) { row in
                HStack(spacing: 6) {
                    if row.node.isPrimary {
                        Circle().fill(ChartPalette.color(at: row.node.index)).frame(width: 8, height: 8)
                        Text(row.node.letter).fontWeight(.semibold)
                    } else {
                        Text("Replica").foregroundStyle(.secondary)
                    }

                    Text(row.node.endpoint).monospacedDigit().lineLimit(1)
                    if row.node.node.health != .online {
                        Text(row.node.node.health.rawValue.capitalized).font(.caption).foregroundStyle(.orange)
                    }
                }
                .help(nodeTooltip(row.node))
            }
            .width(min: 170, ideal: 230)
            TableColumn("Commands/s", value: \.node.metrics.opsPerSecond) { row in
                numberCell(NumberFormatting.grouped(row.node.metrics.opsPerSecond), bold: row.isMax(maxOps))
            }
            .width(min: 70, ideal: 90)
            TableColumn("Network In", value: \.node.metrics.networkInKbps) { row in
                numberCell("\(AnalyticsFormat.decimal(row.node.metrics.networkInKbps, maxDecimals: 2)) kb/s", bold: row.isMax(maxIn))
            }
            .width(min: 80, ideal: 100)
            TableColumn("Network Out", value: \.node.metrics.networkOutKbps) { row in
                numberCell("\(AnalyticsFormat.decimal(row.node.metrics.networkOutKbps, maxDecimals: 2)) kb/s", bold: row.isMax(maxOut))
            }
            .width(min: 80, ideal: 100)
            TableColumn("Memory", value: \.node.metrics.usedMemory) { row in
                numberCell(AnalyticsFormat.bytes(Double(row.node.metrics.usedMemory)), bold: row.isMax(maxMem))
                    .help("\(NumberFormatting.grouped(row.node.metrics.usedMemory)) B")
            }
            .width(min: 80, ideal: 100)
            TableColumn("Keys", value: \.node.metrics.totalKeys) { row in
                numberCell(NumberFormatting.grouped(row.node.metrics.totalKeys), bold: row.isMax(maxKeys))
            }
            .width(min: 60, ideal: 90)
            TableColumn("Clients", value: \.node.metrics.connectedClients) { row in
                numberCell(NumberFormatting.grouped(row.node.metrics.connectedClients), bold: row.isMax(maxClients))
            }
            .width(min: 60, ideal: 70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ClusterNodeRow.ID.self) { ids in
            if let row = all.first(where: { ids.contains($0.id) }) {
                Button("Copy Address") { copy(row.node.endpoint) }
                Button("Copy Node ID") { copy(row.node.node.id) }
            }
        }
        .frame(height: tableHeight(rowCount: all.count, maxRows: 14))
    }

    private func numberCell(_ text: String, bold: Bool) -> some View {
        Text(text)
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func nodeTooltip(_ node: ClusterNodeDetails) -> String {
        var lines = ["\(node.letter.isEmpty ? "" : node.letter + ": ")\(node.endpoint)", "ID: \(node.node.id)",
                     "Role: \(node.isPrimary ? "Primary" : "Replica")", "Health: \(node.node.health.rawValue)"]
        if !node.node.slots.isEmpty { lines.append("Slots: \(node.node.slots.joined(separator: ", "))") }
        lines.append("Uptime: \(AnalyticsFormat.durationFull(seconds: node.metrics.uptimeSec))")
        if let ratio = node.metrics.cacheHitRatio { lines.append("Cache hit ratio: \(AnalyticsFormat.decimal(ratio * 100, maxDecimals: 2))%") }
        lines.append("Commands processed: \(NumberFormatting.grouped(node.metrics.commandsProcessed))")
        lines.append("Connections received: \(NumberFormatting.grouped(node.metrics.connectionsReceived))")
        lines.append("Replication offset: \(NumberFormatting.grouped(node.metrics.replicationOffset))")
        if let lag = node.replicationLag { lines.append("Replication lag: \(NumberFormatting.grouped(lag))") }
        return lines.joined(separator: "\n")
    }
}

struct ClusterNodeRow: Identifiable, Hashable {
    var node: ClusterNodeDetails
    var children: [ClusterNodeRow]?

    var id: String { node.id }
    var hostSort: String { node.isPrimary ? String(format: "%@:%06d", node.host, node.port) : "~\(node.endpoint)" }

    func isMax(_ index: Int?) -> Bool {
        node.isPrimary && index == node.index
    }
}
