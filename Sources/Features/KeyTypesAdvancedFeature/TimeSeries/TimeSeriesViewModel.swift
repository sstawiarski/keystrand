import Foundation
import Observation
import RedisUI

enum TimeSeriesPreset: String, CaseIterable, Identifiable {
    case all = "All Samples"
    case lastHour = "Last Hour"
    case lastDay = "Last 24 Hours"
    case lastWeek = "Last 7 Days"
    case lastMonth = "Last 30 Days"
    var id: String { rawValue }

    var durationMs: Int64? {
        switch self {
        case .all: return nil
        case .lastHour: return 3_600_000
        case .lastDay: return 86_400_000
        case .lastWeek: return 7 * 86_400_000
        case .lastMonth: return 30 * 86_400_000
        }
    }
}

@MainActor
@Observable
final class TimeSeriesViewModel {
    let context: KeyDetailsContext
    private var service: TimeSeriesService { TimeSeriesService(session: context.session, key: context.key) }

    private(set) var info: TimeSeriesInfo?
    private(set) var samples: [TimeSeriesSample] = []
    private(set) var chartSamples: [TimeSeriesSample] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var canLoadMore = false
    private(set) var appliedQuery = TimeSeriesQuery()

    // MARK: Query controls

    var fromText = ""
    var toText = ""
    var order: KeySortOrder = .desc
    var isAggregating = false
    var aggregation: TimeSeriesAggregation = .avg
    var bucketText = "60000"
    var emptyBuckets = false
    var minValueText = ""
    var maxValueText = ""
    var showsChart = true

    // MARK: Add sample

    var isAddPanelOpen = false { didSet { context.state.isAddPanelOpen = isAddPanelOpen } }
    var draftTimestamp = "*"
    var draftValue = ""
    var draftOnDuplicate: TimeSeriesDuplicatePolicy?
    private(set) var isSaving = false

    // MARK: Delete range

    var isDeleteRangeOpen = false
    var deleteFromText = ""
    var deleteToText = ""

    // MARK: Edit settings

    var isEditingSettings = false { didSet { context.state.isRefreshDisabled = isEditingSettings } }
    var draftRetention = ""
    var draftDuplicatePolicy: TimeSeriesDuplicatePolicy?
    var draftLabels: [TimeSeriesLabel] = []

    init(context: KeyDetailsContext) {
        self.context = context
    }

    // MARK: Validation

    var queryError: String? {
        if !TimeSeriesCommands.isValidBound(fromText) || !TimeSeriesCommands.isValidBound(toText) {
            return "Timestamps must be milliseconds, - or +"
        }

        if let from = Int64(fromText), let to = Int64(toText), from > to { return "From must not be after To" }
        if isAggregating, (Int64(bucketText) ?? 0) <= 0 { return "Bucket duration must be a positive number of milliseconds" }
        let hasMin = !minValueText.trimmingCharacters(in: .whitespaces).isEmpty
        let hasMax = !maxValueText.trimmingCharacters(in: .whitespaces).isEmpty
        if hasMin != hasMax { return "Enter both a minimum and a maximum value to filter by value" }
        if hasMin, Double(minValueText.trimmingCharacters(in: .whitespaces)) == nil
            || Double(maxValueText.trimmingCharacters(in: .whitespaces)) == nil {
            return "Value filter must be numeric"
        }

        return nil
    }

    func makeQuery() -> TimeSeriesQuery {
        var query = TimeSeriesQuery()
        let from = fromText.trimmingCharacters(in: .whitespaces)
        let to = toText.trimmingCharacters(in: .whitespaces)
        query.from = from.isEmpty ? "-" : from
        query.to = to.isEmpty ? "+" : to
        query.order = order
        if isAggregating {
            query.aggregation = aggregation
            query.bucketMs = max(Int64(bucketText) ?? 60_000, 1)
            query.emptyBuckets = emptyBuckets
        }

        if let min = Double(minValueText.trimmingCharacters(in: .whitespaces)),
           let max = Double(maxValueText.trimmingCharacters(in: .whitespaces)) {
            query.minValue = min
            query.maxValue = max
        }

        return query
    }

    var isAddValid: Bool {
        TimeSeriesCommands.isValidTimestamp(draftTimestamp) && TimeSeriesCommands.isValidValue(draftValue)
    }

    var deleteRange: (from: Int64, to: Int64)? {
        guard let from = Int64(deleteFromText.trimmingCharacters(in: .whitespaces)),
              let to = Int64(deleteToText.trimmingCharacters(in: .whitespaces)), from >= 0, from <= to else { return nil }
        return (from, to)
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await service.info()
            info = loaded
            if deleteFromText.isEmpty, deleteToText.isEmpty, loaded.totalSamples > 0 {
                deleteFromText = String(loaded.firstTimestamp)
                deleteToText = String(loaded.lastTimestamp)
            }

            guard queryError == nil else { return }
            let query = makeQuery()
            let page = try await service.samples(query)
            appliedQuery = query
            samples = page
            canLoadMore = page.count >= query.count
            rebuildChart()
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            if !hasLoaded, !KeyOperationError.isKeyNotFound(error) { errorMessage = error.localizedDescription }
            context.report(error)
        }
    }

    func refresh() async {
        guard !isEditingSettings else { return }
        await load()
    }

    func apply() async {
        guard queryError == nil else { return }
        await load()
    }

    func loadMore() {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        Task { @MainActor in await loadNextPage() }
    }

    func loadNextPage() async {
        guard canLoadMore, !isLoadingMore, !isLoading, let last = samples.last?.timestamp,
              let next = TimeSeriesCommands.nextPage(after: last, query: appliedQuery) else {
            canLoadMore = false
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.samples(next)
            canLoadMore = page.count >= next.count
            let known = Set(samples.map(\.timestamp))
            samples += page.filter { !known.contains($0.timestamp) }
            rebuildChart()
        } catch {
            canLoadMore = false
            context.report(error)
        }
    }

    func toggleOrder() async {
        await setOrder(order == .desc ? .asc : .desc)
    }

    func setOrder(_ newOrder: KeySortOrder) async {
        guard newOrder != order else { return }
        order = newOrder
        await apply()
    }

    var resultsText: String {
        let suffix = canLoadMore ? "+" : ""
        let noun = appliedQuery.aggregation == nil ? "samples" : "buckets"
        return "\(NumberFormatting.grouped(samples.count))\(suffix) \(noun)"
    }

    func applyPreset(_ preset: TimeSeriesPreset) async {
        if let duration = preset.durationMs, let info, info.totalSamples > 0 {
            fromText = String(max(info.lastTimestamp - duration, 0))
            toText = ""
        } else {
            fromText = ""
            toText = ""
        }

        await apply()
    }

    func resetQuery() async {
        fromText = ""
        toText = ""
        isAggregating = false
        emptyBuckets = false
        minValueText = ""
        maxValueText = ""
        order = .desc
        await apply()
    }

    private func rebuildChart() {
        let ascending = samples.sorted { $0.timestamp < $1.timestamp }
        chartSamples = TimeSeriesCommands.chartPoints(ascending)
    }

    // MARK: Writes

    func openAddPanel() {
        draftTimestamp = "*"
        draftValue = ""
        draftOnDuplicate = nil
        isAddPanelOpen = true
    }

    func saveSample() async {
        guard isAddValid else { return }
        guard await context.confirmWrite(title: "Add Sample in Production?",
                                         message: "A sample will be added to this time series. This database is marked as production.",
                                         button: "Add Sample", actionID: KeyConfirmations.addTimeSeriesSample) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await service.add(timestamp: draftTimestamp.trimmingCharacters(in: .whitespaces),
                                      value: draftValue.trimmingCharacters(in: .whitespaces),
                                      onDuplicate: draftOnDuplicate)
            isAddPanelOpen = false
            await load()
            await context.valueChanged()
        } catch {
            context.report(error)
        }
    }

    func deleteSamples(from: Int64, to: Int64) async {
        guard await context.confirmWrite(title: "Delete Samples in Production?",
                                         message: "Samples will be deleted from this time series. This database is marked as production.",
                                         button: "Delete", actionID: KeyConfirmations.deleteTimeSeriesSamples) else { return }
        do {
            _ = try await service.delete(from: from, to: to)
            await load()
            await context.valueChanged()
        } catch {
            context.report(error)
        }
    }

    func beginEditingSettings() {
        guard let info else { return }
        draftRetention = String(info.retentionMs)
        draftDuplicatePolicy = info.duplicatePolicy.flatMap { TimeSeriesDuplicatePolicy(rawValue: $0.uppercased()) }
        draftLabels = info.labels
        isEditingSettings = true
    }

    var isSettingsValid: Bool {
        let retention = draftRetention.trimmingCharacters(in: .whitespaces)
        return retention.isEmpty || (Int64(retention).map { $0 >= 0 } ?? false)
    }

    func saveSettings() async {
        guard isSettingsValid else { return }
        guard await context.confirmWrite(title: "Edit Time Series in Production?",
                                         message: "The settings of this time series will change. This database is marked as production.",
                                         button: "Save", actionID: KeyConfirmations.editTimeSeries) else { return }
        let retention = Int64(draftRetention.trimmingCharacters(in: .whitespaces))
        do {
            try await service.alter(retentionMs: retention, duplicatePolicy: draftDuplicatePolicy,
                                    labels: draftLabels.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
            isEditingSettings = false
            await load()
            await context.valueChanged()
        } catch {
            context.report(error)
        }
    }
}
