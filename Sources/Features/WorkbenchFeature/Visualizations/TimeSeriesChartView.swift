import Charts
import RedisUI
import SwiftUI

/// TS.RANGE / TS.MRANGE line or point chart: drag to zoom, double-click to reset, hover values, Chart Options popover.
/// Only the visible range is plotted, downsampled off the main actor, so large replies stay responsive.
struct TimeSeriesChartView: View {
    let series: [TimeSeriesSeries]
    let isFullscreen: Bool
    let onConfigChange: (TimeSeriesChartConfig) -> Void

    @State private var config: TimeSeriesChartConfig
    @State private var data: TimeSeriesPlotData?
    @State private var plotted: [TimeSeriesPlottedSeries] = []
    @State private var zoom: ClosedRange<Date>?
    @State private var pointer = ChartPointerState()
    @State private var scales: DualScales?
    @State private var showsOptions = false
    @State private var title = ""
    @State private var xLabel = ""
    @State private var leftAxis = AxisOptions()
    @State private var rightAxis = AxisOptions()
    @State private var usesRightAxis = false
    @State private var rightKeys: Set<String> = []

    struct AxisOptions: Equatable {
        var label = ""
        var isLog = false
    }

    private struct PlotRequest: Equatable {
        var zoom: ClosedRange<Date>?
        var isMilliseconds: Bool
    }

    private struct ScaleRequest: Equatable {
        var rightKeys: Set<String>
        var leftIsLog: Bool
        var rightIsLog: Bool
    }

    private struct DualScales {
        var left: TimeSeriesAxisScale
        var right: TimeSeriesAxisScale
    }

    private let colors: [String: Color]

    fileprivate static let hoverFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(series: [TimeSeriesSeries], config: TimeSeriesChartConfig, isFullscreen: Bool,
         onConfigChange: @escaping (TimeSeriesChartConfig) -> Void) {
        self.series = series
        self.isFullscreen = isFullscreen
        self.onConfigChange = onConfigChange
        self._config = State(initialValue: config)
        self.colors = Self.seriesColors(for: series.map(\.key))
    }

    private var isMilliseconds: Bool {
        switch config.timeUnit {
        case .milliseconds: return true
        case .seconds: return false
        case nil: return TimeSeriesParser.defaultUnitIsMilliseconds(series)
        }
    }

    private func date(_ timestamp: Double) -> Date {
        Date(timeIntervalSince1970: isMilliseconds ? timestamp / 1000 : timestamp)
    }

    private func timestamp(_ date: Date) -> Double {
        date.timeIntervalSince1970 * (isMilliseconds ? 1000 : 1)
    }

    /// Series colors in input order from the system chart palette, so the hover readout matches the chart.
    nonisolated static func seriesColors(for keys: [String]) -> [String: Color] {
        var out: [String: Color] = [:]
        for (index, key) in keys.enumerated() where out[key] == nil {
            out[key] = ChartPalette.color(at: index)
        }

        return out
    }

    private var fullDomain: ClosedRange<Date>? {
        guard let low = data?.minTimestamp, let high = data?.maxTimestamp else { return nil }
        let start = date(low), end = date(high)
        return start == end ? start.addingTimeInterval(-1)...end.addingTimeInterval(1) : start...end
    }

    private var isDualAxis: Bool { usesRightAxis && !rightKeys.isEmpty }

    var body: some View {
        Group {
            if series.allSatisfy({ $0.points.isEmpty }) {
                Text("No data to display").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !title.isEmpty {
                        Text(title).font(.headline).frame(maxWidth: .infinity)
                    }

                    Group {
                        if data == nil {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            chart
                        }
                    }
                    .frame(height: isFullscreen ? nil : 300)
                    .frame(maxHeight: isFullscreen ? .infinity : 300)
                    HStack(alignment: .firstTextBaseline) {
                        ChartHoverReadout(pointer: pointer, data: data, isMilliseconds: isMilliseconds,
                                          colors: colors, isZoomed: zoom != nil)
                        Spacer(minLength: 8)
                        Button {
                            showsOptions.toggle()
                        } label: {
                            Label("Chart Options", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Chart Options")
                        .popover(isPresented: $showsOptions, arrowEdge: .bottom) { options }
                    }
                }
            }
        }
        .task(id: PlotRequest(zoom: zoom, isMilliseconds: isMilliseconds)) { await replot() }
        .onChange(of: ScaleRequest(rightKeys: rightKeys, leftIsLog: leftAxis.isLog, rightIsLog: rightAxis.isLog)) {
            scales = makeScales()
        }
    }

    private func replot() async {
        let input = series
        let prepared: TimeSeriesPlotData
        if let data {
            prepared = data
        } else {
            prepared = await Task.detached(priority: .userInitiated) { TimeSeriesPlotData(input) }.value
            guard !Task.isCancelled else { return }
            data = prepared
        }

        let low = zoom.map { timestamp($0.lowerBound) }
        let high = zoom.map { timestamp($0.upperBound) }
        let isMilliseconds = self.isMilliseconds
        let result = await Task.detached(priority: .userInitiated) {
            TimeSeriesSampler.plot(prepared, low: low, high: high, isMilliseconds: isMilliseconds)
        }.value
        guard !Task.isCancelled else { return }
        plotted = result
        scales = makeScales()
    }

    // MARK: Options

    private var options: some View {
        Form {
            Section {
                Picker("Mode", selection: binding(\.mode)) {
                    Text("Line").tag(TimeSeriesChartConfig.Mode.line)
                    Text("Points").tag(TimeSeriesChartConfig.Mode.points)
                }
                .pickerStyle(.segmented)
                Picker("Time unit", selection: Binding(
                    get: { isMilliseconds ? TimeSeriesChartConfig.TimeUnit.milliseconds : .seconds },
                    set: { value in
                        zoom = nil
                        update { $0.timeUnit = value }
                    })) {
                    Text("Milliseconds").tag(TimeSeriesChartConfig.TimeUnit.milliseconds)
                    Text("Seconds").tag(TimeSeriesChartConfig.TimeUnit.seconds)
                }
                Toggle("Staircase", isOn: binding(\.staircase))
                Toggle("Fill", isOn: binding(\.fill))
            }
            Section("Labels") {
                TextField("Title", text: $title)
                TextField("X axis label", text: $xLabel)
            }
            Section("Y Axes") {
                TextField("Left axis label", text: $leftAxis.label)
                Picker("Left axis scale", selection: $leftAxis.isLog) {
                    Text("Linear").tag(false)
                    Text("Log").tag(true)
                }
                Toggle("Use right Y axis", isOn: $usesRightAxis)
                if usesRightAxis {
                    TextField("Right axis label", text: $rightAxis.label)
                    Picker("Right axis scale", selection: $rightAxis.isLog) {
                        Text("Linear").tag(false)
                        Text("Log").tag(true)
                    }
                    ForEach(series) { item in
                        Picker(item.key, selection: Binding(
                            get: { rightKeys.contains(item.key) },
                            set: { isRight in
                                if isRight { rightKeys.insert(item.key) } else { rightKeys.remove(item.key) }
                            })) {
                            Text("Left").tag(false)
                            Text("Right").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding<T>(_ path: WritableKeyPath<TimeSeriesChartConfig, T>) -> Binding<T> {
        Binding(get: { config[keyPath: path] }, set: { value in update { $0[keyPath: path] = value } })
    }

    private func update(_ change: (inout TimeSeriesChartConfig) -> Void) {
        change(&config)
        onConfigChange(config)
    }

    // MARK: Chart

    private var chart: some View {
        let domain = zoom ?? fullDomain ?? Date()...Date()
        let keys = series.map(\.key)
        let base = Chart {
            if isDualAxis {
                dualAxisMarks
            } else {
                singleAxisMarks
            }
        }
        .chartForegroundStyleScale(domain: keys, range: keys.map { colors[$0] ?? .accentColor })
        .chartXScale(domain: domain)
        .chartXAxisLabel(xLabel)
        .chartLegend(position: .bottom)
        .chartOverlay { proxy in
            ChartPointerOverlay(proxy: proxy, pointer: pointer) { zoom = $0 }
        }
        return Group {
            if isDualAxis, let scales {
                let leftTicks = scales.left.ticks
                let rightTicks = scales.right.ticks
                base
                    .chartYScale(domain: 0...1)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: leftTicks.map(\.unit)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel { Text(value.index < leftTicks.count ? leftTicks[value.index].label : "") }
                        }
                        AxisMarks(position: .trailing, values: rightTicks.map(\.unit)) { value in
                            AxisTick()
                            AxisValueLabel { Text(value.index < rightTicks.count ? rightTicks[value.index].label : "") }
                        }
                    }
                    .chartYAxisLabel(position: .leading) { Text(leftAxis.label) }
                    .chartYAxisLabel(position: .trailing) { Text(rightAxis.label) }
            } else {
                base
                    .chartYScale(type: leftAxis.isLog ? .log : .linear)
                    .chartYAxisLabel(leftAxis.label)
            }
        }
    }

    private var interpolation: InterpolationMethod { config.staircase ? .stepEnd : .linear }

    @ChartContentBuilder
    private var singleAxisMarks: some ChartContent {
        let isLog = leftAxis.isLog
        ForEach(plotted) { item in
            ForEach(Array(item.samples.indices), id: \.self) { index in
                let sample = item.samples[index]
                if !isLog || sample.value > 0 {
                    marks(key: item.key, date: sample.date, y: sample.value, fills: !isLog)
                }
            }
        }
    }

    @ChartContentBuilder
    private var dualAxisMarks: some ChartContent {
        let scales = scales ?? makeScales()
        ForEach(plotted) { item in
            let isRight = rightKeys.contains(item.key)
            let scale = isRight ? scales.right : scales.left
            ForEach(Array(item.samples.indices), id: \.self) { index in
                let sample = item.samples[index]
                if let y = scale.unit(sample.value) {
                    marks(key: item.key, date: sample.date, y: y, fills: !scale.isLog)
                }
            }
        }
    }

    @ChartContentBuilder
    private func marks(key: String, date: Date, y: Double, fills: Bool) -> some ChartContent {
        if config.mode == .line {
            LineMark(x: .value("Time", date), y: .value("Value", y), series: .value("Key", key))
                .foregroundStyle(by: .value("Key", key))
                .interpolationMethod(interpolation)
            if config.fill, fills {
                AreaMark(x: .value("Time", date), y: .value("Value", y), series: .value("Key", key),
                         stacking: .unstacked)
                    .foregroundStyle(by: .value("Key", key))
                    .opacity(0.3)
                    .interpolationMethod(interpolation)
            }
        } else {
            PointMark(x: .value("Time", date), y: .value("Value", y))
                .foregroundStyle(by: .value("Key", key))
                .symbolSize(20)
        }
    }

    private func makeScales() -> DualScales {
        var leftValues: [Double] = []
        var rightValues: [Double] = []
        for item in plotted {
            if rightKeys.contains(item.key) {
                rightValues += item.samples.map(\.value)
            } else {
                leftValues += item.samples.map(\.value)
            }
        }

        return DualScales(left: TimeSeriesAxisScale(values: leftValues, isLog: leftAxis.isLog),
                          right: TimeSeriesAxisScale(values: rightValues, isLog: rightAxis.isLog))
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}

/// Keeps pointer state separate so hovering redraws only the overlay and readout, preserving plotted marks.
@MainActor
@Observable
private final class ChartPointerState {
    var hoverDate: Date?
    var dragStart: CGFloat?
    var dragCurrent: CGFloat?
}

/// Drag to zoom, double-click to reset, and the hover rule line.
private struct ChartPointerOverlay: View {
    let proxy: ChartProxy
    let pointer: ChartPointerState
    let onZoom: (ClosedRange<Date>?) -> Void

    var body: some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if pointer.dragStart == nil { pointer.dragStart = value.startLocation.x }
                                pointer.dragCurrent = value.location.x
                            }
                            .onEnded { value in
                                defer { pointer.dragStart = nil; pointer.dragCurrent = nil }
                                let a = min(value.startLocation.x, value.location.x) - plot.minX
                                let b = max(value.startLocation.x, value.location.x) - plot.minX
                                guard b - a > 4, let start: Date = proxy.value(atX: a),
                                      let end: Date = proxy.value(atX: b), start < end else { return }
                                onZoom(start...end)
                            })
                    .onTapGesture(count: 2) { onZoom(nil) }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            pointer.hoverDate = proxy.value(atX: location.x - plot.minX)
                        case .ended:
                            pointer.hoverDate = nil
                        }
                    }
                if let date = pointer.hoverDate, let x = proxy.position(forX: date) {
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 1, height: plot.height)
                        .offset(x: plot.minX + x, y: plot.minY)
                        .allowsHitTesting(false)
                }

                if let start = pointer.dragStart, let current = pointer.dragCurrent {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: abs(current - start), height: plot.height)
                        .offset(x: min(start, current), y: plot.minY)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Values of every series at the hovered time, or the zoom hint.
private struct ChartHoverReadout: View {
    let pointer: ChartPointerState
    let data: TimeSeriesPlotData?
    let isMilliseconds: Bool
    let colors: [String: Color]
    let isZoomed: Bool

    var body: some View {
        if let hoverDate = pointer.hoverDate {
            HStack(spacing: 12) {
                Text(TimeSeriesChartView.hoverFormatter.string(from: hoverDate))
                ForEach(rows(at: hoverDate), id: \.key) { row in
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(colors[row.key] ?? .accentColor)
                        Text("\(row.key): \(TimeSeriesChartView.number(row.value))")
                    }
                }
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Text(isZoomed ? "Double-click the chart to reset the zoom." : "Drag across the chart to zoom in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func rows(at date: Date) -> [(key: String, value: Double)] {
        let target = date.timeIntervalSince1970 * (isMilliseconds ? 1000 : 1)
        return (data?.series ?? []).compactMap { item in
            guard let index = TimeSeriesSampler.nearestIndex(item.timestamps, to: target) else { return nil }
            return (item.key, item.values[index])
        }
    }
}
