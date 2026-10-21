import RedisUI
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Bindable var model: ImportModel
    let onBack: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    static let fileFooter = "Use a JSON file exported from Keystrand or RedisInsight. Use files only from trusted sources."

    var body: some View {
        switch model.state {
        case .form, .loading:
            form.sheetSize(.form)
        case .failed(let message):
            SheetForm(title: "Import Connections", primaryTitle: "Done", cancelTitle: nil, onCancel: onClose, onPrimary: onClose) {
                ContentUnavailableView {
                    Label("Import Failed", systemImage: "xmark.octagon")
                } description: {
                    Text(message).textSelection(.enabled)
                }
            } leadingActions: {
                Button("Try Again") { model.retry() }
            }
            .sheetSize(.form)
        case .results(let result):
            SheetForm(title: "Import Results", primaryTitle: "Done", cancelTitle: nil, onCancel: onClose, onPrimary: onClose) {
                ImportResultsList(result: result, model: model)
            }
            .sheetSize(.large)
        }
    }

    private var form: some View {
        SheetForm(title: "Import Connections", primaryTitle: "Import", isPrimaryDisabled: !model.canSubmit,
                  isWorking: model.state == .loading, onCancel: onClose,
                  onPrimary: { Task { await model.submit() } }) {
            if model.state == .loading {
                ProgressView("Importing…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        FilePickerRow(fileURL: $model.fileURL, allowedTypes: [.json, .plainText, .data],
                                      maxFileSize: ImportPayload.maxBytes)
                    } header: {
                        Text("File")
                    } footer: {
                        if let fileError = model.fileError {
                            InlineMessage(fileError, kind: .error)
                        } else {
                            SectionFooter(Self.fileFooter)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } leadingActions: {
            Button("Back", action: onBack)
                .disabled(model.state == .loading)
        }
    }
}

/// Imported, partially imported and failed connections, one section each.
private struct ImportResultsList: View {
    let result: DatabaseImportResult
    let model: ImportModel

    static let scriptsFooter = "Scripts run in your login shell when the database connects or disconnects. The file's scripts were not saved. Keep them only if you trust the file and have read them."

    var body: some View {
        List {
            scriptsSection
            section("Imported", items: result.success)
            section("Partially Imported", items: result.partial)
            section("Failed", items: result.fail)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder
    private var scriptsSection: some View {
        let items = model.itemsWithScripts
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.index) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Keep Scripts for \(ImportResultText.label(item))", isOn: Binding(
                            get: { model.keptScripts.contains(item.index) },
                            set: { keep in Task { await model.setKeepScripts(keep, for: item) } }))
                        if let pre = item.strippedScripts?.preConnect {
                            ImportScriptText(title: "Pre-connect script", script: pre)
                        }

                        if let post = item.strippedScripts?.postDisconnect {
                            ImportScriptText(title: "Post-disconnect script", script: post)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Connection Scripts (\(items.count))")
            } footer: {
                if let error = model.scriptError {
                    InlineMessage(error, kind: .error)
                } else {
                    SectionFooter(Self.scriptsFooter)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [DatabaseImportResult.Item]) -> some View {
        if !items.isEmpty {
            Section("\(title) (\(items.count))") {
                ForEach(items, id: \.index) { item in
                    LabeledContent(ImportResultText.label(item)) {
                        Text(ImportResultText.result(item))
                            .foregroundStyle(item.status == .fail ? .red : .secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// One imported script, shown verbatim for review.
private struct ImportScriptText: View {
    let title: String
    let script: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(script)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum ImportResultText {
    /// "#3 host:port" (address parts that are missing are left out).
    static func label(_ item: DatabaseImportResult.Item) -> String {
        let address: String
        switch (item.host, item.port) {
        case let (host?, port?): address = "\(host):\(port)"
        case let (host?, nil): address = host
        case let (nil, port?): address = ":\(port)"
        default: address = ""
        }

        return address.isEmpty ? "#\(item.index)" : "#\(item.index) \(address)"
    }

    static func result(_ item: DatabaseImportResult.Item) -> String {
        item.errors.isEmpty ? "Imported" : item.errors.joined(separator: "\n")
    }
}
