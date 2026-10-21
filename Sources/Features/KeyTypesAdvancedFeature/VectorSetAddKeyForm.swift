import RedisUI
import SwiftUI

/// Adds Vector Set options to the New Key form. The host footer submits the grouped form rows.
public struct VectorSetAddKeyForm: View {
    public let context: AddKeyFormContext
    @State private var model: VectorSetAddKeyModel
    @State private var showsPreview = false

    public init(context: AddKeyFormContext) {
        self.context = context
        _model = State(initialValue: VectorSetAddKeyModel(context: context))
    }

    public var body: some View {
        Group {
            MultiRowFormList(rows: $model.drafts, addTitle: "Add Element", makeRow: { VectorElementInput() }) { $row in
                VectorElementInputRow(row: $row,
                                      expectedDimension: model.expectedDimension(forDraftAt: model.drafts.firstIndex { $0.id == row.id } ?? 0))
            }
            DisclosureGroup("Vector Set Options", isExpanded: $model.showsOptions) {
                Picker("Quantization", selection: $model.quantization) {
                    ForEach(VectorQuantization.allCases) { Text($0.label).tag($0) }
                }
                option("Reduce dimensions", text: $model.reduceText, prompt: "None",
                       help: "Random projection to fewer dimensions (REDUCE)")
                option("Exploration factor (EF)", text: $model.efText, prompt: "200",
                       help: "Build exploration factor (EF)")
                option("Maximum links (M)", text: $model.linksText, prompt: "16",
                       help: "Maximum links per node in the HNSW graph (M)")
                if let error = model.optionsError { FieldHint(text: error, isError: true) }
            }
            let preview = model.previewText
            if !preview.isEmpty {
                CommandPreviewBar(command: preview, isExpanded: $showsPreview)
            }

            if let error = model.errorMessage {
                InlineMessage(error, kind: .error)
            }
        }
        .disabled(model.isSaving)
        .onAppear(perform: publishSubmission)
        .onChange(of: SubmissionState(model)) { _, _ in publishSubmission() }
    }

    private func publishSubmission() {
        let model = self.model
        context.publishSubmission(AddKeyFormSubmission(canSubmit: model.isValid, isSaving: model.isSaving,
                                                       validationMessage: model.validationMessage) {
            Task { await model.submit() }
        })
    }

    private func option(_ title: String, text: Binding<String>, prompt: String, help: String) -> some View {
        TextField(title, text: text, prompt: Text(prompt))
            .monospacedDigit()
            .help(help)
            .onChange(of: text.wrappedValue) { _, new in
                let digits = new.filter { $0.isASCII && $0.isNumber }
                if digits != new { text.wrappedValue = digits }
            }
    }
}

private struct SubmissionState: Equatable {
    let isValid: Bool
    let isSaving: Bool
    let validationMessage: String?

    @MainActor init(_ model: VectorSetAddKeyModel) {
        isValid = model.isValid
        isSaving = model.isSaving
        validationMessage = model.validationMessage
    }
}
