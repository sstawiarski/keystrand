import RedisUI
import SwiftUI

struct SamplePickerSheet: View {
    @Bindable var model: VectorSearchViewModel
    @State private var selection: SampleDatasetID?
    @State private var datasets: [SampleDataset] = []
    @State private var loadError: String?

    private var isLoading: Bool { model.loadingSample != nil }

    var body: some View {
        SheetForm(title: "Choose Sample Data", primaryTitle: "Start Querying",
                  isPrimaryDisabled: selection == nil || model.sampleBlockedReason != nil,
                  isWorking: isLoading, errorMessage: loadError,
                  onCancel: { model.isSamplePickerPresented = false },
                  onPrimary: start) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Keystrand loads the dataset and creates the index needed to search it.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                List(datasets, selection: $selection) { dataset in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dataset.cardTitle).font(.headline)
                            Text(dataset.cardSubtitle).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: dataset.symbolName)
                            .font(.title2)
                    }
                    .padding(.vertical, 6)
                    .tag(dataset.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .contextMenu(forSelectionType: SampleDatasetID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first {
                        selection = id
                        start()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let reason = model.sampleBlockedReason {
                        InlineMessage(reason, kind: .warning)
                    }

                    if let progress = model.sampleProgress, isLoading {
                        Text("Imported \(NumberFormatting.grouped(progress.succeeded)) of \(NumberFormatting.grouped(progress.processed)) commands")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        } leadingActions: {
            Button("See Index Definition") {
                guard let selection else { return }
                model.isSamplePickerPresented = false
                model.openCreateIndex(.sampleData(selection))
            }
            .disabled(selection == nil || isLoading)
        }
        .interactiveDismissDisabled(isLoading)
        .task {
            do {
                datasets = try SampleDatasets.load()
                if selection == nil { selection = datasets.first?.id }
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func start() {
        guard let selection, model.sampleBlockedReason == nil, !isLoading else { return }
        Task { await model.startSample(selection) }
    }
}
