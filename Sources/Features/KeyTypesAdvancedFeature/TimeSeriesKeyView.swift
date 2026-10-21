import Charts
import RedisUI
import SwiftUI

/// Time Series key value view: TS.INFO summary, range query with aggregation, chart, samples table, add / delete.
public struct TimeSeriesKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        TimeSeriesBody(context: context).id(KeyIdentity(context))
    }
}

private struct TimeSeriesBody: View {
    let context: KeyDetailsContext
    @State private var model: TimeSeriesViewModel

    init(context: KeyDetailsContext) {
        self.context = context
        _model = State(initialValue: TimeSeriesViewModel(context: context))
    }

    private var settings: SettingsStore { context.session.services.settings }

    var body: some View {
        VStack(spacing: 0) {
            if let info = model.info {
                TimeSeriesSummaryView(info: info)
                Divider()
            }

            TimeSeriesQueryBar(model: model)
            Divider()
            KeySubheaderBar {
                Toggle(isOn: $model.showsChart) { Label("Chart", systemImage: "chart.xyaxis.line") }
                    .toggleStyle(.button)
                    .help(model.showsChart ? "Hide the chart" : "Show the chart")
                if model.isLoading, model.hasLoaded { ProgressView().controlSize(.small) }
            } trailing: {
                Button { model.beginEditingSettings() } label: { Label("Edit Series…", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.borderless)
                    .disabled(model.info == nil)
                    .help("Edit retention, duplicate policy and labels (TS.ALTER)")
                Button { model.isDeleteRangeOpen = true } label: { Label("Delete Range…", systemImage: "trash") }
                    .buttonStyle(.borderless)
                    .disabled((model.info?.totalSamples ?? 0) == 0)
                    .help("Delete samples between two timestamps (TS.DEL)")
                AddItemsButton("Add Sample", help: "Add a sample (TS.ADD)") { model.openAddPanel() }
            }
            Divider()
            content
        }
        .task { await model.load() }
        .onChange(of: context.state.refreshGeneration) { Task { await model.refresh() } }
        .sheet(isPresented: $model.isEditingSettings) {
            TimeSeriesSettingsSheet(model: model).sheetAlerts(context.session)
        }
        .sheet(isPresented: $model.isAddPanelOpen) { TimeSeriesAddSheet(model: model).sheetAlerts(context.session) }
        .sheet(isPresented: $model.isDeleteRangeOpen) {
            TimeSeriesDeleteRangeSheet(model: model).sheetAlerts(context.session)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage, !model.hasLoaded {
            ErrorStateView(message: error) { Task { await model.load() } }
        } else if !model.hasLoaded {
            LoadingBody()
        } else if model.samples.isEmpty {
            if (model.info?.totalSamples ?? 0) == 0 {
                ContentUnavailableView("No Samples", systemImage: "chart.xyaxis.line",
                                       description: Text("Add a sample to start the series."))
            } else {
                ContentUnavailableView("No Samples in Range", systemImage: "chart.xyaxis.line",
                                       description: Text("Change the time range or the value filter."))
            }
        } else {
            VSplitView {
                if model.showsChart {
                    TimeSeriesChart(model: model)
                        .frame(minHeight: 140, idealHeight: 220)
                }

                VStack(spacing: 0) {
                    TimeSeriesTable(model: model, settings: settings, keyText: context.keyText)
                    Divider()
                    PagedStatusBar(text: model.resultsText, isLoadingMore: model.isLoadingMore,
                                   canLoadMore: model.canLoadMore, onLoadMore: { model.loadMore() })
                }
                .frame(minHeight: 160)
            }
        }
    }
}

// MARK: - Summary

private struct TimeSeriesSummaryView: View {
    let info: TimeSeriesInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            KeyMetadataRow(items: TimeSeriesSummary.items(info))
            if let details = TimeSeriesSummary.detailsText(info) {
                Text(details)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(details)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

enum TimeSeriesSummary {
    static func items(_ info: TimeSeriesInfo) -> [KeyMetadataItem] {
        var items: [KeyMetadataItem] = []
        let hasSamples = info.totalSamples > 0
        items.append(KeyMetadataItem(label: "First", value: hasSamples ? String(info.firstTimestamp) : "—",
                                     help: hasSamples ? TimestampFormatter.format(milliseconds: Double(info.firstTimestamp)) : nil))
        items.append(KeyMetadataItem(label: "Last", value: hasSamples ? String(info.lastTimestamp) : "—",
                                     help: hasSamples ? TimestampFormatter.format(milliseconds: Double(info.lastTimestamp)) : nil))
        items.append(KeyMetadataItem(label: "Retention", value: TimeSeriesCommands.durationText(ms: info.retentionMs)))
        items.append(KeyMetadataItem(label: "Duplicates", value: info.duplicatePolicy?.uppercased() ?? "Default",
                                     help: "Duplicate policy"))
        items.append(KeyMetadataItem(label: "Chunks", value: chunkText(info)))
        if let memory = info.memoryUsage {
            items.append(KeyMetadataItem(label: "Memory", value: ByteFormatter.format(memory, decimals: 1)))
        }

        return items
    }

    static func chunkText(_ info: TimeSeriesInfo) -> String {
        var parts: [String] = []
        if let count = info.chunkCount { parts.append("\(count)") }
        if let size = info.chunkSize { parts.append("× \(ByteFormatter.format(size, decimals: 0))") }
        if let type = info.chunkType { parts.append(type) }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    static func detailsText(_ info: TimeSeriesInfo) -> String? {
        var parts: [String] = []
        if !info.labels.isEmpty {
            parts.append("Labels: " + info.labels.map { "\($0.name)=\($0.value)" }.joined(separator: ", "))
        }

        if let source = info.sourceKey { parts.append("Source: " + Bytes.text(source)) }
        if !info.rules.isEmpty {
            parts.append("Rules: " + info.rules.map { "\(Bytes.text($0.destination)) \($0.aggregation) \($0.bucketMs) ms" }
                .joined(separator: ", "))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Query bar

private struct TimeSeriesQueryBar: View {
    @Bindable var model: TimeSeriesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("From").foregroundStyle(.secondary)
                TextField("From", text: $model.fromText, prompt: Text("-"))
                    .labelsHidden()
                    .monospacedDigit()
                    .frame(width: 130)
                    .help("Start timestamp in milliseconds; empty or - for the earliest sample")
                    .onSubmit { Task { await model.apply() } }
                Text("To").foregroundStyle(.secondary)
                TextField("To", text: $model.toText, prompt: Text("+"))
                    .labelsHidden()
                    .monospacedDigit()
                    .frame(width: 130)
                    .help("End timestamp in milliseconds; empty or + for the latest sample")
                    .onSubmit { Task { await model.apply() } }
                Menu {
                    ForEach(TimeSeriesPreset.allCases) { preset in
                        Button(preset.rawValue) { Task { await model.applyPreset(preset) } }
                    }
                } label: {
                    Label("Range", systemImage: "clock")
                }
                .fixedSize()
                .help("Time range relative to the last sample")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Toggle("Aggregate", isOn: $model.isAggregating)
                    .toggleStyle(.checkbox)
                    .help("Group samples into time buckets (AGGREGATION)")
                Picker("Aggregation", selection: $model.aggregation) {
                    ForEach(TimeSeriesAggregation.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.isAggregating)
                TextField("Bucket", text: $model.bucketText, prompt: Text("60000"))
                    .labelsHidden()
                    .monospacedDigit()
                    .frame(width: 80)
                    .disabled(!model.isAggregating)
                    .help("Bucket duration in milliseconds")
                    .onSubmit { Task { await model.apply() } }
                Text("ms").foregroundStyle(.secondary)
                Toggle("Empty buckets", isOn: $model.emptyBuckets)
                    .toggleStyle(.checkbox)
                    .disabled(!model.isAggregating)
                    .help("Report empty buckets (EMPTY)")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("Values from").foregroundStyle(.secondary)
                TextField("Minimum", text: $model.minValueText, prompt: Text("min"))
                    .labelsHidden()
                    .monospacedDigit()
                    .frame(width: 80)
                    .onSubmit { Task { await model.apply() } }
                Text("to").foregroundStyle(.secondary)
                TextField("Maximum", text: $model.maxValueText, prompt: Text("max"))
                    .labelsHidden()
                    .monospacedDigit()
                    .frame(width: 80)
                    .onSubmit { Task { await model.apply() } }
                if let error = model.queryError {
                    FieldHint(text: error, isError: true).lineLimit(1)
                }

                Spacer(minLength: 0)
                Button("Reset") { Task { await model.resetQuery() } }
                    .help("Reset the query")
                Button("Apply") { Task { await model.apply() } }
                    .disabled(model.queryError != nil || model.isLoading)
                    .help("Run TS.RANGE / TS.REVRANGE")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Chart

private struct TimeSeriesChart: View {
    let model: TimeSeriesViewModel

    var body: some View {
        Chart(model.chartSamples) { sample in
            LineMark(x: .value("Time", date(sample)), y: .value("Value", sample.value))
                .foregroundStyle(.tint)
                .interpolationMethod(.linear)
            if model.chartSamples.count <= 60 {
                PointMark(x: .value("Time", date(sample)), y: .value("Value", sample.value))
                    .foregroundStyle(.tint)
                    .symbolSize(18)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.samples.count > model.chartSamples.count {
                Text("Showing \(model.chartSamples.count) of \(model.samples.count) loaded points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .accessibilityLabel("Time series chart")
    }

    private func date(_ sample: TimeSeriesSample) -> Date {
        Date(timeIntervalSince1970: Double(sample.timestamp) / 1000)
    }
}

// MARK: - Table

private struct TimeSeriesTable: View {
    let model: TimeSeriesViewModel
    let settings: SettingsStore
    let keyText: String
    @State private var selection: Int64?
    @State private var pendingDelete: TimeSeriesSample?

    private var sortOrder: Binding<[KeyPathComparator<TimeSeriesSample>]> {
        Binding(get: { [KeyPathComparator(\TimeSeriesSample.timestamp, order: model.order == .asc ? .forward : .reverse)] },
                set: { order in
                    let ascending = order.first?.order == .forward
                    Task { await model.setOrder(ascending ? .asc : .desc) }
                })
    }

    private var canDelete: Bool { model.appliedQuery.aggregation == nil }

    var body: some View {
        let ids = model.samples.map(\.id)
        Table(model.samples, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Timestamp", value: \.timestamp) { sample in
                VStack(alignment: .leading, spacing: 2) {
                    Text(TimestampFormatter.format(milliseconds: Double(sample.timestamp), pattern: settings.app.dateFormat,
                                                   timeZone: settings.app.timezone.timeZone))
                    Text(String(sample.timestamp)).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .loadsMore(when: KeyDetailsLayout.isNearEnd(sample.id, in: ids)) { model.loadMore() }
            }
            .width(min: 160, ideal: 200, max: 280)
            TableColumn(model.appliedQuery.aggregation.map { "Value (\($0.rawValue.uppercased()))" } ?? "Value") { sample in
                Text(sample.valueText).font(.body.monospaced()).textSelection(.enabled)
            }
            .width(min: 80, ideal: 200)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let sample = sample(ids.first) {
                Button("Copy Timestamp") { Pasteboard.copy(String(sample.timestamp)) }
                Button("Copy Value") { Pasteboard.copy(sample.valueText) }
                Button("Copy as TS.ADD") {
                    Pasteboard.copy("TS.ADD \(VectorSetCommands.quote(keyText)) \(sample.timestamp) \(sample.valueText)")
                }
                Divider()
                Button("Delete Sample…", role: .destructive) { pendingDelete = sample }
                    .disabled(!canDelete)
            }
        }
        .onDeleteCommand { if canDelete, let sample = sample(selection) { pendingDelete = sample } }
        .destructiveConfirmation(item: $pendingDelete, title: { RemovalText.title(String($0.timestamp), verb: "Delete") },
                                 message: { _ in "The sample will be deleted from “\(Bytes.short(keyText))”." }) { sample in
            Task { await model.deleteSamples(from: sample.timestamp, to: sample.timestamp) }
        }
    }

    private func sample(_ id: Int64?) -> TimeSeriesSample? {
        guard let id else { return nil }
        return model.samples.first { $0.id == id }
    }
}

// MARK: - Sheets

private struct TimeSeriesDeleteRangeSheet: View {
    @Bindable var model: TimeSeriesViewModel

    var body: some View {
        SheetForm(title: "Delete Samples", primaryTitle: "Delete", isPrimaryDisabled: model.deleteRange == nil,
                  isDestructive: true,
                  onCancel: { model.isDeleteRangeOpen = false },
                  onPrimary: {
                      guard let range = model.deleteRange else { return }
                      model.isDeleteRangeOpen = false
                      Task { await model.deleteSamples(from: range.from, to: range.to) }
                  }) {
            Form {
                Section {
                    TextField("From", text: $model.deleteFromText, prompt: Text("Milliseconds")).monospacedDigit()
                    TextField("To", text: $model.deleteToText, prompt: Text("Milliseconds")).monospacedDigit()
                } footer: {
                    FieldHint(text: model.deleteRange == nil
                              ? "Enter millisecond timestamps with From before or equal to To."
                              : "Samples between From and To, inclusive, are deleted permanently.",
                              isError: model.deleteRange == nil)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .sheetSize(.small)
    }
}

private struct TimeSeriesAddSheet: View {
    @Bindable var model: TimeSeriesViewModel

    var body: some View {
        SheetForm(title: "Add Sample", primaryTitle: "Add Sample", isPrimaryDisabled: !model.isAddValid,
                  isWorking: model.isSaving,
                  onCancel: { model.isAddPanelOpen = false }, onPrimary: { Task { await model.saveSample() } }) {
            Form {
                Section {
                    TextField("Timestamp", text: $model.draftTimestamp, prompt: Text("* or milliseconds"))
                        .monospacedDigit()
                    TextField("Value", text: $model.draftValue, prompt: Text("Number"))
                        .monospacedDigit()
                    Picker("On duplicate", selection: $model.draftOnDuplicate) {
                        Text("Key Policy").tag(TimeSeriesDuplicatePolicy?.none)
                        ForEach(TimeSeriesDuplicatePolicy.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    .help("ON_DUPLICATE override for this sample")
                } footer: {
                    if !TimeSeriesCommands.isValidTimestamp(model.draftTimestamp) {
                        FieldHint(text: "Timestamp should be * or milliseconds.", isError: true)
                    } else if !model.draftValue.isEmpty, !TimeSeriesCommands.isValidValue(model.draftValue) {
                        FieldHint(text: "Value should be a number.", isError: true)
                    } else {
                        FieldHint(text: "* uses the server's current time.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .sheetSize(.small)
    }
}

private struct TimeSeriesSettingsSheet: View {
    @Bindable var model: TimeSeriesViewModel

    var body: some View {
        SheetForm(title: "Edit Time Series", primaryTitle: "Save", isPrimaryDisabled: !model.isSettingsValid,
                  onCancel: { model.isEditingSettings = false }, onPrimary: { Task { await model.saveSettings() } }) {
            Form {
                Section {
                    LabeledContent("Retention") {
                        HStack(spacing: 4) {
                            TextField("Retention", text: $model.draftRetention, prompt: Text("0 = no limit"))
                                .labelsHidden()
                                .monospacedDigit()
                                .frame(width: 140)
                            Text("ms").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Duplicate policy", selection: $model.draftDuplicatePolicy) {
                        Text("Unchanged").tag(TimeSeriesDuplicatePolicy?.none)
                        ForEach(TimeSeriesDuplicatePolicy.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                } footer: {
                    if !model.isSettingsValid {
                        FieldHint(text: "Retention must be a non-negative number of milliseconds.", isError: true)
                    }
                }
                Section {
                    MultiRowFormList(rows: $model.draftLabels, addTitle: "Add Label",
                                     makeRow: { TimeSeriesLabel(name: "", value: "") }) { $label in
                        TextField("Label", text: $label.name, prompt: Text("Label")).labelsHidden()
                        TextField("Value", text: $label.value, prompt: Text("Value")).labelsHidden()
                    }
                } header: {
                    Text("Labels")
                } footer: {
                    FieldHint(text: "Saving replaces every label of the series.")
                }
            }
            .formStyle(.grouped)
        }
        .sheetSize(.form)
    }
}
