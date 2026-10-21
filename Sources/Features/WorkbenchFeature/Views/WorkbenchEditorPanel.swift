import RedisUI
import SwiftUI

/// Top pane: the Redis editor, edge to edge. Read-only until the command specs are loaded.
struct WorkbenchEditorPanel: View {
    @Bindable var model: WorkbenchViewModel
    @State private var controller = CodeEditorController()

    var body: some View {
        CodeEditorView(
            text: $model.editorText,
            language: .redis,
            isEditable: model.isCommandCatalogLoaded,
            completions: { text, cursor in model.completions(text: text, cursor: cursor) },
            onSubmit: { run() },
            onHistoryUp: { model.historyUp(caretAtStart: controller.selectedRange?.location == 0) },
            signatureHint: { text, cursor in model.signature(text: text, cursor: cursor) },
            placeholder: "Enter Redis commands and press ⌘↩ to run them",
            showsLineNumbers: true,
            showsCommandMarkers: true,
            wrapsLines: true,
            controller: controller)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.editorText) { _, _ in model.editorTextDidChange() }
    }

    private func run() {
        guard !model.isRunning, model.isCommandCatalogLoaded else { return }
        Task { await model.runEditor() }
    }
}
