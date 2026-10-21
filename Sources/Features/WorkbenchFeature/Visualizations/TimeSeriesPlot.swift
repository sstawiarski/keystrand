import Foundation

/// Time series sorted by timestamp once, so zooming, downsampling and hover lookups can binary search.
struct TimeSeriesPlotData: Sendable {
    struct Series: Sendable, Identifiable {
        var key: String
        var timestamps: [Double]
        var values: [Double]
        var id: String { key }
    }

    var series: [Series]
    var minTimestamp: Double?
    var maxTimestamp: Double?

    init(_ input: [TimeSeriesSeries]) {
        var low: Double?
        var high: Double?
        series = input.map { item in
            let sorted = item.points.enumerated().sorted {
                $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset
                    : $0.element.timestamp < $1.element.timestamp
            }.map(\.element)
            if let first = sorted.first?.timestamp { low = min(low ?? first, first) }
            if let last = sorted.last?.timestamp { high = max(high ?? last, last) }
            return Series(key: item.key, timestamps: sorted.map(\.timestamp), values: sorted.map(\.value))
        }
        minTimestamp = low
        maxTimestamp = high
    }

    var isEmpty: Bool { series.allSatisfy(\.timestamps.isEmpty) }
}

struct TimeSeriesSample: Sendable {
    var date: Date
    var value: Double
}

struct TimeSeriesPlottedSeries: Sendable, Identifiable {
    var key: String
    var samples: [TimeSeriesSample]
    var id: String { key }
}

/// Keeps chart mark counts bounded: only the visible range is plotted, downsampled with min/max buckets.
enum TimeSeriesSampler {
    static let markBudget = 6_000
    static let maxPointsPerSeries = 2_000

    static func pointsPerSeries(seriesCount: Int) -> Int {
        max(100, min(maxPointsPerSeries, markBudget / max(seriesCount, 1)))
    }

    /// First index whose timestamp is >= `value` (`timestamps` ascending).
    static func lowerBound(_ timestamps: [Double], _ value: Double) -> Int {
        var low = 0, high = timestamps.count
        while low < high {
            let mid = (low + high) / 2
            if timestamps[mid] < value { low = mid + 1 } else { high = mid }
        }

        return low
    }

    /// Indices with timestamps in `low...high`, plus one neighbour on each side so lines reach the plot edges.
    static func visibleRange(_ timestamps: [Double], low: Double, high: Double) -> Range<Int> {
        guard !timestamps.isEmpty, low <= high else { return 0..<0 }
        let start = max(lowerBound(timestamps, low) - 1, 0)
        let end = min(lowerBound(timestamps, high.nextUp) + 1, timestamps.count)
        return start < end ? start..<end : 0..<0
    }

    /// Indices of `range` to plot: everything when it fits, else the first, last, and the min and max of each bucket.
    static func downsample(values: [Double], range: Range<Int>, maxPoints: Int) -> [Int] {
        guard range.count > maxPoints, maxPoints >= 4 else { return Array(range) }
        let buckets = max((maxPoints - 2) / 2, 1)
        let inner = (range.lowerBound + 1)..<(range.upperBound - 1)
        var out: [Int] = [range.lowerBound]
        out.reserveCapacity(buckets * 2 + 2)
        let size = Double(inner.count) / Double(buckets)
        for bucket in 0..<buckets {
            let start = inner.lowerBound + Int(Double(bucket) * size)
            let end = bucket == buckets - 1 ? inner.upperBound : inner.lowerBound + Int(Double(bucket + 1) * size)
            guard start < end else { continue }
            var minIndex = start, maxIndex = start
            for index in start..<end {
                if values[index] < values[minIndex] { minIndex = index }
                if values[index] > values[maxIndex] { maxIndex = index }
            }

            if minIndex == maxIndex {
                out.append(minIndex)
            } else {
                out.append(min(minIndex, maxIndex))
                out.append(max(minIndex, maxIndex))
            }
        }

        out.append(range.upperBound - 1)
        return out
    }

    /// Index of the sample closest to `target` (`timestamps` ascending).
    static func nearestIndex(_ timestamps: [Double], to target: Double) -> Int? {
        guard !timestamps.isEmpty else { return nil }
        let index = lowerBound(timestamps, target)
        if index == 0 { return 0 }
        if index == timestamps.count { return timestamps.count - 1 }
        return target - timestamps[index - 1] <= timestamps[index] - target ? index - 1 : index
    }

    /// Visible, downsampled samples of every series, timestamps converted to dates.
    static func plot(_ data: TimeSeriesPlotData, low: Double?, high: Double?,
                     isMilliseconds: Bool) -> [TimeSeriesPlottedSeries] {
        let perSeries = pointsPerSeries(seriesCount: data.series.count)
        let divisor = isMilliseconds ? 1000.0 : 1.0
        return data.series.map { item in
            let range = (low != nil || high != nil)
                ? visibleRange(item.timestamps, low: low ?? -.infinity, high: high ?? .infinity)
                : 0..<item.timestamps.count
            let indices = downsample(values: item.values, range: range, maxPoints: perSeries)
            let samples = indices.map {
                TimeSeriesSample(date: Date(timeIntervalSince1970: item.timestamps[$0] / divisor), value: item.values[$0])
            }
            return TimeSeriesPlottedSeries(key: item.key, samples: samples)
        }
    }
}

/// A Y axis drawn in unit space (0...1), used when the chart has both a left and a right axis.
struct TimeSeriesAxisScale: Equatable, Sendable {
    struct Tick: Equatable, Sendable {
        var unit: Double
        var label: String
    }

    /// Bounds in axis space (`log10` of the value for log scales).
    var lower: Double
    var upper: Double
    var isLog: Bool
    var step: Double

    init(values: [Double], isLog: Bool) {
        self.isLog = isLog
        if isLog {
            let logs = values.filter { $0 > 0 && $0.isFinite }.map(log10)
            let low = (logs.min() ?? 0).rounded(.down)
            var high = (logs.max() ?? 1).rounded(.up)
            if high <= low { high = low + 1 }
            lower = low
            upper = high
            step = 1
            return
        }

        let finite = values.filter(\.isFinite).map(Self.clampLinear)
        var low = finite.min() ?? 0
        var high = finite.max() ?? 1
        if low == high {
            let pad = low == 0 ? 1 : abs(low) * 0.1
            low -= pad
            high += pad
        }

        let step = Self.niceStep((high - low) / 4)
        let lower = (low / step).rounded(.down) * step
        let upper = (high / step).rounded(.up) * step
        if lower.isFinite, upper.isFinite, upper > lower {
            self.step = step
            self.lower = lower
            self.upper = upper
        } else {
            self.step = 0.5
            self.lower = -1
            self.upper = 1
        }
    }

    /// Values beyond this magnitude are pinned to it so padding, rounding and spans stay finite.
    static let linearLimit = Double.greatestFiniteMagnitude / 8

    static func clampLinear(_ value: Double) -> Double {
        min(max(value, -linearLimit), linearLimit)
    }

    /// Position of `value` in 0...1, or nil when it cannot be drawn (non-positive on a log scale).
    func unit(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        let transformed: Double
        if isLog {
            guard value > 0 else { return nil }
            transformed = log10(value)
        } else {
            transformed = Self.clampLinear(value)
        }

        let unit = (transformed - lower) / (upper - lower)
        return unit.isFinite ? unit : nil
    }

    var ticks: [Tick] {
        let intervals = ((upper - lower) / step).rounded()
        guard intervals.isFinite, intervals >= 0, intervals < 64 else { return [] }
        let count = Int(intervals) + 1
        return (0..<count).map { index in
            let position = lower + Double(index) * step
            let unit = (position - lower) / (upper - lower)
            return Tick(unit: unit, label: isLog ? Self.logLabel(exponent: Int(position.rounded()))
                        : Self.linearLabel(position, step: step))
        }
    }

    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let exponent = log10(raw).rounded(.down)
        let base = pow(10, exponent)
        let fraction = raw / base
        let nice: Double = fraction < 1.5 ? 1 : fraction < 3 ? 2 : fraction < 7 ? 5 : 10
        return nice * base
    }

    static func linearLabel(_ value: Double, step: Double) -> String {
        let decimals = max(0, min(8, Int((-log10(step) - 1e-9).rounded(.up))))
        let rounded = abs(value) < step / 2 ? 0 : value
        if abs(rounded) >= 1e15 { return String(format: "%g", rounded) }
        return String(format: "%.\(decimals)f", rounded)
    }

    static func logLabel(exponent: Int) -> String {
        if (0...6).contains(exponent) { return String(Int(pow(10, Double(exponent)))) }
        if (-4..<0).contains(exponent) { return String(format: "%.\(-exponent)f", pow(10, Double(exponent))) }
        return "1e\(exponent)"
    }
}
