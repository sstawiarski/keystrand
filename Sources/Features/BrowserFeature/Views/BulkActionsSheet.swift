import AppKit
import RedisUI
import SwiftUI
import UniformTypeIdentifiers

struct BulkActionsSheet: View {
    @Bindable var model: BulkActionsViewModel
    @Bindable var browser: BrowserViewModel
    @State private var confirmDelete = false
    @State private var confirmUpload = false

    private static let shownErrorLimit = 100

    private var filter: BulkActionFilter { model.deleteFilter ?? browser.currentBulkFilter }
    private var hasFilter: Bool { filter.match != "*" || filter.type != nil }

    var body: some View {
        SheetForm(title: "Bulk Actions", primaryTitle: primaryTitle, isPrimaryDisabled: isPrimaryDisabled,
                  isDestructive: model.isRunning || (!isFinished && model.tab == .delete),
                  cancelTitle: isFinished ? nil : (model.isRunning ? "Close" : "Cancel"),
                  onCancel: { browser.closeBulkActions() }, onPrimary: primaryAction) {
            VStack(spacing: 0) {
                Picker("Action", selection: $model.tab) {
                    Text("Delete Keys").tag(BulkActionsViewModel.Tab.delete)
                    Text("Upload Data").tag(BulkActionsViewModel.Tab.upload)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                .disabled(model.isRunning)
                .padding(.bottom, 4)
                Group {
                    switch model.tab {
                    case .delete: deletePage
                    case .upload: uploadPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } leadingActions: {
            if isFinished {
                Button("Start New") {
                    if model.tab == .delete { model.resetDelete() } else { model.resetUpload() }
                }
            }
        }
        .sheetSize(.large)
        .destructiveConfirmation("Delete Matching Keys?", isPresented: $confirmDelete,
                                 message: "All keys matching the type and pattern will be deleted.") {
            startDelete()
        }
        .destructiveConfirmation("Run Commands from “\(model.fileURL?.lastPathComponent ?? "file")”?",
                                 isPresented: $confirmUpload,
                                 message: "Each command in the file will run against this database, in order.",
                                 confirmTitle: "Run") {
            startUpload()
        }
    }

    // MARK: - Delete

    @ViewBuilder
    private var deletePage: some View {
        if !hasFilter && model.deleteOverview == nil {
            ContentUnavailableView("No Filter Set", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Set a pattern or key type in the Browser first."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Section("Filter") {
                    LabeledContent("Key Type") {
                        if let type = filter.type { KeyTypeLabel(type: type) } else { Text("All Types") }
                    }
                    LabeledContent("Pattern") {
                        Text(filter.match)
                            .fontDesign(.monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if let overview = model.deleteOverview {
                    progressSection(overview)
                    errorsSection(overview.errors.prefix(Self.shownErrorLimit).map { "\(browser.displayName($0.key)): \($0.error)" },
                                  total: overview.errors.count)
                } else {
                    Section {
                        if browser.bulkActions?.filterOverride == nil && browser.searchMode == .pattern {
                            let amount = BrowserFormatting.expectedAmount(found: browser.keys.count, total: browser.total,
                                                                          scanned: browser.scanned)
                            LabeledContent("Expected Keys", value: amount.map { "~" + NumberFormatting.grouped($0) } ?? "Unknown")
                                .monospacedDigit()
                                .help("Estimated from the keys scanned so far.")
                            if let total = browser.total, total > 0 {
                                LabeledContent("Scanned") {
                                    Text(BulkText.scanned(scanned: browser.scanned, total: total, found: browser.keys.count))
                                        .monospacedDigit()
                                }
                            }
                        }

                        Toggle("Save report to a file", isOn: $model.downloadReport)
                    } header: {
                        Text("Estimate")
                    } footer: {
                        InlineMessage("Deleting many keys at once can slow the server and spike its memory use. Avoid it on production databases.",
                                      kind: .warning)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func progressSection(_ overview: BulkActionOverview) -> some View {
        Section("Progress") {
            if model.isDeleting {
                ProgressView(value: Double(model.deleteProgress), total: 100)
            } else {
                deleteStatusLabel(overview)
            }

            LabeledContent("Processed", value: NumberFormatting.grouped(overview.processed))
            LabeledContent("Success", value: NumberFormatting.grouped(overview.succeeded))
            LabeledContent("Errors", value: NumberFormatting.grouped(overview.failed))
            LabeledContent("Time", value: BrowserFormatting.bulkDuration(overview.duration))
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private func deleteStatusLabel(_ overview: BulkActionOverview) -> some View {
        let text = model.deleteStatusText ?? ""
        switch overview.status {
        case .completed:
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed, .disconnected:
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        default:
            Label(text, systemImage: "stop.circle")
        }
    }

    @ViewBuilder
    private func errorsSection(_ lines: [String], total: Int) -> some View {
        if total > 0 {
            Section {
                DisclosureGroup("Errors (\(NumberFormatting.grouped(total)))") {
                    ForEach(lines.prefix(Self.shownErrorLimit).indices, id: \.self) { index in
                        let line = lines[index]
                        Text(line)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Upload

    private var uploadPage: some View {
        Form {
            if let summary = model.uploadSummary {
                Section("Result") {
                    if let name = model.uploadFileName {
                        LabeledContent("File", value: BrowserFormatting.shortFileName(name))
                            .help(name)
                    }

                    if model.isUploading {
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else if model.uploadWasStopped {
                        Label(model.uploadStatusText ?? "Stopped", systemImage: "stop.circle")
                    } else {
                        Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }

                    LabeledContent("Processed", value: NumberFormatting.grouped(summary.processed))
                    LabeledContent("Success", value: NumberFormatting.grouped(summary.succeeded))
                    LabeledContent("Errors", value: NumberFormatting.grouped(summary.failed))
                    LabeledContent("Time", value: BrowserFormatting.bulkDuration(summary.duration))
                }
                .monospacedDigit()
                errorsSection(summary.errors, total: summary.errors.count)
            } else {
                Section {
                    FilePickerRow(fileURL: $model.fileURL, allowedTypes: [.plainText, .text],
                                  maxFileSize: BulkActionsViewModel.maxUploadBytes)
                        .disabled(model.isUploading)
                    if let error = model.uploadError {
                        InlineMessage(error, kind: .error)
                    }
                } header: {
                    Text("File")
                } footer: {
                    Text("Upload a text file with one Redis command per line, for example SET key value. Only run files you trust.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Footer

    /// Closing the sheet keeps a running action active; Stop cancels it.
    private var primaryTitle: String {
        if model.isRunning { return "Stop" }
        if isFinished { return "Done" }
        return model.tab == .delete ? "Delete Keys…" : "Upload…"
    }

    private var isPrimaryDisabled: Bool {
        if model.isRunning { return model.uploadWasStopped && model.isUploading }
        if isFinished { return false }
        return model.tab == .delete ? !hasFilter : model.fileURL == nil
    }

    private func primaryAction() {
        if model.isRunning {
            if model.isDeleting { model.stopDelete() } else { model.stopUpload() }
        } else if isFinished {
            browser.closeBulkActions()
        } else if model.tab == .delete {
            confirmDelete = true
        } else {
            confirmUpload = true
        }
    }

    private var isFinished: Bool {
        switch model.tab {
        case .delete: return model.deleteOverview?.status.isFinished ?? false
        case .upload: return model.uploadSummary?.isFinished == true && !model.isUploading
        }
    }

    // MARK: - Actions

    private func startDelete() {
        let filter = self.filter
        let session = browser.session
        let format = browser.keyNameFormat
        let browser = self.browser
        let model = self.model
        Task {
            let request = ConfirmationRequest(title: "Delete Matching Keys in Production?",
                                              message: "Every key matching \(filter.match) will be deleted. This database is marked as production.",
                                              confirmButtonTitle: "Delete")
            guard await session.confirm(request) else { return }
            model.startDelete(filter) { overview in
                if overview.status == .completed { browser.bulkDeleteFinished() }
                if model.downloadReport, let text = model.reportText(format: format) {
                    BulkReportSaver.save(text, suggestedName: BulkActionsViewModel.reportFileName(), session: session)
                }
            }
        }
    }

    private func startUpload() {
        let session = browser.session
        let browser = self.browser
        let model = self.model
        Task {
            let request = ConfirmationRequest(title: "Run Commands in Production?",
                                              message: "Each command in the file will run. This database is marked as production.",
                                              confirmButtonTitle: "Run")
            guard await session.confirm(request) else { return }
            model.startUpload { _ in
                browser.reload()
            }
        }
    }
}

enum BulkText {
    static func scanned(scanned: Int, total: Int, found: Int) -> String {
        "\(BrowserFormatting.progress(scanned: scanned, total: total))% (\(NumberFormatting.grouped(scanned)) of "
            + "\(NumberFormatting.grouped(total)) scanned), found \(NumberFormatting.grouped(found))"
    }
}

@MainActor
enum BulkReportSaver {
    static func save(_ text: String, suggestedName: String, session: DatabaseSession) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            session.toasts.error(error)
        }
    }
}
