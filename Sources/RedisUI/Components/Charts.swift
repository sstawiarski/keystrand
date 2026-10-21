import Charts
import SwiftUI

public struct DonutSlice: Identifiable, Hashable {
    public var id: String
    public var label: String
    public var value: Double
    /// nil takes the slice's `ChartPalette` color by its position in the input.
    public var color: Color?
    /// Text shown after the percentage in the tooltip, e.g. a formatted byte count. Defaults to the raw value.
    public var valueText: String?
    /// Extra tooltip line (e.g. `host:port`).
    public var detail: String?

    public init(id: String? = nil, label: String, value: Double, color: Color? = nil, valueText: String? = nil,
                detail: String? = nil) {
        self.id = id ?? label
        self.label = label
        self.value = value
        self.color = color
        self.valueText = valueText
        self.detail = detail
    }
}

/// Donut chart (Database Analysis / Cluster Details): slices sorted by value, percentage labels on slices ≥ 5 %,
/// center title and value, and the hovered slice's details in the center.
public struct DonutChartView: View {
    public var slices: [DonutSlice]
    public var centerTitle: String
    public var centerValue: String
    public var labelThreshold: Double
    @State private var selectedAngle: Double?

    public init(slices: [DonutSlice], centerTitle: String, centerValue: String, labelThreshold: Double = 0.05) {
        self.slices = slices
        self.centerTitle = centerTitle
        self.centerValue = centerValue
        self.labelThreshold = labelThreshold
    }

    private var colored: [DonutSlice] {
        slices.enumerated().map { index, slice in
            var copy = slice
            if copy.color == nil { copy.color = ChartPalette.color(at: index) }
            return copy
        }
    }

    private var sorted: [DonutSlice] { colored.filter { $0.value > 0 }.sorted { $0.value > $1.value } }
    private var total: Double { sorted.reduce(0) { $0 + $1.value } }

    private var selectedSlice: DonutSlice? {
        guard let selectedAngle else { return nil }
        var cumulative = 0.0
        for slice in sorted {
            cumulative += slice.value
            if selectedAngle <= cumulative { return slice }
        }

        return nil
    }

    public var body: some View {
        let sorted = sorted
        let total = total
        let selected = selectedSlice
        Chart(sorted) { slice in
            SectorMark(angle: .value("Value", slice.value), innerRadius: .ratio(0.62), angularInset: 1)
                .foregroundStyle(slice.color ?? .accentColor)
                .opacity(selected == nil || selected == slice ? 1 : 0.55)
                .annotation(position: .overlay) {
                    if total > 0, slice.value / total >= labelThreshold {
                        Text(Self.percent(slice.value, of: total))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .chartAngleSelection(value: $selectedAngle)
        .chartBackground { _ in
            VStack(spacing: 2) {
                if let slice = selected {
                    Text(slice.label).font(.caption.weight(.semibold)).lineLimit(1)
                    if let detail = slice.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Text("\(Self.percent(slice.value, of: total)) (\(slice.valueText ?? Int(slice.value).formatted()))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text(centerTitle).font(.caption).foregroundStyle(.secondary)
                    Text(centerValue).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: 120)
        }
        .overlay {
            if sorted.isEmpty {
                Circle().stroke(.quaternary, lineWidth: 24).padding(12)
            }
        }
    }

    nonisolated public static func percent(_ value: Double, of total: Double) -> String {
        guard total > 0 else { return "0%" }
        let pct = value / total * 100
        return pct >= 10 || pct == pct.rounded() ? "\(Int(pct.rounded()))%" : String(format: "%.1f%%", pct)
    }
}

public struct BarDatum: Identifiable, Hashable {
    public var id: String { label }
    public var label: String
    public var value: Double
    /// nil uses the accent color.
    public var color: Color?

    public init(label: String, value: Double, color: Color? = nil) {
        self.label = label
        self.value = value
        self.color = color
    }
}

/// Vertical bar chart with categorical x labels (e.g. memory per TTL bucket), system axes and styling.
public struct BarChartView: View {
    public var bars: [BarDatum]
    public var valueFormatter: (Double) -> String
    public var tooltipFormatter: (Double) -> String
    @State private var selectedLabel: String?

    public init(bars: [BarDatum], valueFormatter: @escaping (Double) -> String = { Int($0).formatted() },
                tooltipFormatter: ((Double) -> String)? = nil) {
        self.bars = bars
        self.valueFormatter = valueFormatter
        self.tooltipFormatter = tooltipFormatter ?? valueFormatter
    }

    public var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value("Bucket", bar.label), y: .value("Value", bar.value))
                .foregroundStyle(bar.color ?? .accentColor)
                .opacity(selectedLabel == nil || selectedLabel == bar.label ? 1 : 0.6)
                .annotation(position: .top) {
                    if selectedLabel == bar.label {
                        Text(tooltipFormatter(bar.value))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .chartXSelection(value: $selectedLabel)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(valueFormatter(number)) }
                }
            }
        }
    }
}
