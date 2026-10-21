import AppKit
import RedisUI
import SwiftUI

struct AnalysisSection<Controls: View, Content: View>: View {
    let title: String
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(title).font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                controls()
                    .controlSize(.small)
            }
            content()
        }
    }
}

struct ExtrapolateToggle: View {
    var title = "Extrapolate results"
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .help("Extrapolate the sampled results to the whole database")
    }
}

struct RankingPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

enum AnalysisTypes {
    static func keyType(_ raw: String) -> KeyType { KeyType(rawValue: raw) }

    static func typeName(_ raw: String) -> String {
        raw == "N/A" ? "Unknown" : KeyType(rawValue: raw).displayName
    }
}

// MARK: - Summary by data type

struct SummaryPerTypeSection: View {
    @Bindable var model: DatabaseAnalysisViewModel
    let report: DatabaseAnalysisReport

    var body: some View {
        let factor = model.extrapolationFactor
        let on = model.extrapolateSummary
        AnalysisSection(title: "Summary by Data Type") {
            if model.canExtrapolate { ExtrapolateToggle(isOn: $model.extrapolateSummary) }
        } content: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { memoryChart(factor: factor, on: on); keysChart(factor: factor, on: on) }
                VStack(spacing: 24) { memoryChart(factor: factor, on: on); keysChart(factor: factor, on: on) }
            }
            .frame(maxWidth: .infinity)
            TypeLegend(types: report.totalKeys.types.map(\.type))
        }
    }

    private func memoryChart(factor: Double, on: Bool) -> some View {
        DonutChartView(
            slices: report.totalMemory.types.map { type in
                DonutSlice(id: type.type, label: AnalysisTypes.typeName(type.type),
                           value: Extrapolation.value(type.total, factor: factor, enabled: on),
                           color: AnalysisTypes.keyType(type.type).tint,
                           valueText: Extrapolation.bytesText(type.total, factor: factor, enabled: on))
            },
            centerTitle: "Memory",
            centerValue: Extrapolation.bytesText(report.totalMemory.total, factor: factor, enabled: on))
        .frame(width: 220, height: 220)
    }

    private func keysChart(factor: Double, on: Bool) -> some View {
        DonutChartView(
            slices: report.totalKeys.types.map { type in
                DonutSlice(id: type.type, label: AnalysisTypes.typeName(type.type),
                           value: Extrapolation.value(type.total, factor: factor, enabled: on),
                           color: AnalysisTypes.keyType(type.type).tint,
                           valueText: Extrapolation.keysText(type.total, factor: factor, enabled: on))
            },
            centerTitle: "Keys",
            centerValue: Extrapolation.keysText(report.totalKeys.total, factor: factor, enabled: on))
        .frame(width: 220, height: 220)
    }
}

struct TypeLegend: View {
    let types: [String]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(types, id: \.self) { type in
                Label {
                    Text(AnalysisTypes.typeName(type))
                } icon: {
                    KeyTypeIcon(type: AnalysisTypes.keyType(type))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - TTL

struct ExpirationSection: View {
    @Bindable var model: DatabaseAnalysisViewModel

    var body: some View {
        let factor = model.extrapolationFactor
        let on = model.extrapolateTTL
        AnalysisSection(title: "Memory by Time to Expire") {
            if model.canExtrapolate { ExtrapolateToggle(title: "Extrapolate", isOn: $model.extrapolateTTL) }
            Toggle("Show No Expiry", isOn: $model.showNoExpiry)
                .toggleStyle(.switch)
                .help("Include keys without a TTL")
        } content: {
            BarChartView(
                bars: model.expirationBars.map { group in
                    BarDatum(label: group.label,
                             value: Extrapolation.value(Double(group.total), factor: factor, enabled: on),
                             color: group.label == AnalysisAggregator.noExpiryLabel ? .gray : nil)
                },
                valueFormatter: { AnalyticsFormat.bytes($0, decimals: 1) },
                tooltipFormatter: {
                    (Extrapolation.isApplied(factor: factor, enabled: on) ? "~" : "") + AnalyticsFormat.bytes($0, decimals: 3)
                })
            .frame(height: 240)
        }
    }
}

// MARK: - Top namespaces

struct NamespaceRow: Identifiable, Hashable {
    var id: String
    var summary: NspSummary
    var pattern: String
    var type: String?
    var types: [String]
    var memory: Double
    var keys: Double
    var children: [NamespaceRow]?
}

struct TopNamespacesSection: View {
    @Bindable var model: DatabaseAnalysisViewModel
    @State private var sortOrder: [KeyPathComparator<NamespaceRow>] = []
    @State private var selection: Set<NamespaceRow.ID> = []

    private var rows: [NamespaceRow] {
        let factor = model.extrapolationFactor
        let on = model.extrapolateNamespaces
        let base = model.namespaces.map { nsp -> NamespaceRow in
            let pattern = model.namespacePattern(nsp.nsp)
            let children: [NamespaceRow]? = nsp.types.count > 1 ? nsp.types.map { type in
                NamespaceRow(id: "\(pattern)\u{0}\(type.type)", summary: nsp, pattern: pattern, type: type.type, types: [type.type],
                             memory: Extrapolation.value(Double(type.memory), factor: factor, enabled: on),
                             keys: Extrapolation.value(Double(type.keys), factor: factor, enabled: on), children: nil)
            } : nil
            return NamespaceRow(id: pattern, summary: nsp, pattern: pattern, type: nil, types: nsp.types.map(\.type),
                                memory: Extrapolation.value(Double(nsp.memory), factor: factor, enabled: on),
                                keys: Extrapolation.value(Double(nsp.keys), factor: factor, enabled: on), children: children)
        }
        return sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
    }

    var body: some View {
        AnalysisSection(title: "Top Namespaces") {
            RankingPicker(title: "Rank Namespaces", selection: $model.namespaceRanking,
                          options: [(.memory, "By Memory"), (.keys, "By Keys")])
            if model.canExtrapolate { ExtrapolateToggle(title: "Extrapolate", isOn: $model.extrapolateNamespaces) }
        } content: {
            if model.namespaces.isEmpty {
                ContentUnavailableView {
                    Label("No Namespaces", systemImage: "folder")
                } description: {
                    Text("Set the delimiter in the Browser's tree view to customize the namespaces shown here.")
                } actions: {
                    Button("Open Tree View") { model.openTreeView() }
                }
                .frame(height: 220)
            } else {
                table
            }
        }
    }

    private var table: some View {
        let rows = self.rows
        let prefix = Extrapolation.isApplied(factor: model.extrapolationFactor, enabled: model.extrapolateNamespaces) ? "~" : ""
        let all = rows + rows.flatMap { $0.children ?? [] }
        return Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Key Pattern", value: \.pattern) { row in
                Text(AnalyticsFormat.truncated(row.pattern, limit: 200))
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.pattern)
            }
            .width(min: 160, ideal: 380)
            TableColumn("Data Type") { row in
                HStack(spacing: 4) {
                    ForEach(row.types, id: \.self) { KeyTypeIcon(type: AnalysisTypes.keyType($0)) }
                }
                .help(row.types.map(AnalysisTypes.typeName).joined(separator: ", "))
            }
            .width(min: 70, ideal: 120)
            TableColumn("Total Memory", value: \.memory) { row in
                Text(prefix + AnalyticsFormat.bytes(row.memory))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("\(NumberFormatting.grouped(Int(row.memory.rounded()))) B")
            }
            .width(min: 90, ideal: 120)
            TableColumn("Total Keys", value: \.keys) { row in
                Text(prefix + NumberFormatting.grouped(Int(row.keys.rounded())))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: NamespaceRow.ID.self) { ids in
            if let row = all.first(where: { ids.contains($0.id) }) {
                Button("Open in Browser") { model.openNamespace(row.summary, type: row.type) }
                Button("Copy Pattern") { copy(row.pattern) }
            }
        } primaryAction: { ids in
            if let row = all.first(where: { ids.contains($0.id) }) { model.openNamespace(row.summary, type: row.type) }
        }
        .frame(height: tableHeight(rowCount: max(rows.count, 3), maxRows: 15))
        .onChange(of: model.namespaceRanking) { sortOrder = [] }
    }
}

/// Height for a table embedded in a scroll view: header plus up to `maxRows` rows.
func tableHeight(rowCount: Int, rowHeight: CGFloat = 26, maxRows: Int = 32) -> CGFloat {
    CGFloat(min(max(rowCount, 1), maxRows)) * rowHeight + 34
}

@MainActor
func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Top keys

struct TopKeyRow: Identifiable, Hashable {
    var key: AnalyzedKey
    var id: Data { key.name }
    var name: String
    var typeName: String
    var ttlSort: Int
    var memorySort: Int
    var lengthSort: Int
}

struct TopKeysSection: View {
    @Bindable var model: DatabaseAnalysisViewModel
    @State private var sortOrder: [KeyPathComparator<TopKeyRow>] = []
    @State private var selection: Set<TopKeyRow.ID> = []

    static let bigMemory = 5_000_000
    static let bigLength = 5_000
    static let lengthHighlightTypes: Set<String> = ["list", "zset", "set", "hash"]
    static let splitHint = "Large key; splitting it into smaller keys may help"

    private var rows: [TopKeyRow] {
        let base = model.topKeys.map { key in
            TopKeyRow(key: key, name: AnalyticsFormat.keyName(key.name), typeName: key.type,
                      ttlSort: key.ttl < 0 ? Int.max : key.ttl, memorySort: key.memory ?? -1, lengthSort: key.length ?? -1)
        }
        return sortOrder.isEmpty ? base : base.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        AnalysisSection(title: model.topKeysTitle) {
            RankingPicker(title: "Rank Keys", selection: $model.topKeysRanking,
                          options: [(.memory, "By Memory"), (.length, "By Length")])
        } content: {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Type", value: \.typeName) { row in
                    KeyTypeIcon(type: AnalysisTypes.keyType(row.key.type))
                        .help(AnalysisTypes.typeName(row.key.type))
                }
                .width(min: 40, ideal: 50, max: 60)
                TableColumn("Key Name", value: \.name) { row in
                    Text(AnalyticsFormat.truncated(row.name, limit: 200))
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.name)
                }
                .width(min: 160, ideal: 360)
                TableColumn("TTL", value: \.ttlSort) { row in
                    Text(AnalyticsFormat.ttl(row.key.ttl))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(AnalyticsFormat.ttlTooltip(row.key.ttl) ?? "")
                }
                .width(min: 60, ideal: 90)
                TableColumn("Size", value: \.memorySort) { row in
                    let big = (row.key.memory ?? 0) >= Self.bigMemory
                    Text(AnalyticsFormat.bytes(row.key.memory))
                        .monospacedDigit()
                        .fontWeight(big ? .semibold : .regular)
                        .foregroundStyle(big ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(row.key.memory.map { (big ? Self.splitHint + "\n" : "") + "\(NumberFormatting.grouped($0)) B" } ?? "")
                }
                .width(min: 70, ideal: 100)
                TableColumn("Length", value: \.lengthSort) { row in
                    let big = Self.lengthHighlightTypes.contains(row.key.type) && (row.key.length ?? 0) >= Self.bigLength
                    Text(row.key.length.map(NumberFormatting.grouped) ?? "-")
                        .monospacedDigit()
                        .fontWeight(big ? .semibold : .regular)
                        .foregroundStyle(big ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(big ? Self.splitHint : "")
                }
                .width(min: 60, ideal: 90)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: TopKeyRow.ID.self) { ids in
                if let row = rows.first(where: { ids.contains($0.id) }) {
                    Button("Open in Browser") { model.openKey(row.key) }
                    Button("Copy Key Name") { copy(row.name) }
                }
            } primaryAction: { ids in
                if let row = rows.first(where: { ids.contains($0.id) }) { model.openKey(row.key) }
            }
            .frame(height: tableHeight(rowCount: rows.count, maxRows: 15))
            .onChange(of: model.topKeysRanking) { sortOrder = [] }
        }
    }
}
