import AppKit
import RedisUI
import SwiftUI

/// Invalid text in the selected format requires confirmation before saving as Unicode.
struct EditValueSheet: View {
    let title: String
    @Binding var text: String
    let format: ValueFormat
    let isSaving: Bool
    let onCancel: @MainActor () -> Void
    let onSave: @MainActor () -> Void
    @State private var confirmUnicode = false

    var body: some View {
        SheetForm(title: title, primaryTitle: "Save", isWorking: isSaving, onCancel: onCancel, onPrimary: attemptSave) {
            CodeEditorView(text: $text, language: ValueEditRules.isJSONLike(format) ? .json : .plain,
                           placeholder: "Enter Value", showsLineNumbers: false, wrapsLines: true,
                           autoCloseBrackets: ValueEditRules.isJSONLike(format), autoFocus: true)
                .frame(minHeight: 240)
                .padding(.horizontal, 20)
        } leadingActions: {
            Text(format.menuLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Value format")
        }
        .sheetSize(.form)
        .destructiveConfirmation(ValueEditRules.savedAsUnicodeTitle, isPresented: $confirmUnicode,
                                 message: ValueEditRules.savedAsUnicodeMessage, confirmTitle: "Save") {
            onSave()
        }
    }

    private func attemptSave() {
        if ValueEditRules.encode(text, format: format).isValid {
            onSave()
        } else {
            confirmUnicode = true
        }
    }
}

/// What the Value Preview sheet shows, captured when it opens so a reload of the key does not clear it.
public struct ValuePreviewState: Identifiable {
    public let id = UUID()
    public let title: String
    public var result: FormatResult?
    public let copyText: String?
}

struct ValuePreviewSheet: View {
    let preview: ValuePreviewState
    let onDone: @MainActor () -> Void

    var body: some View {
        SheetForm(title: preview.title, primaryTitle: "Done", cancelTitle: nil, onCancel: onDone, onPrimary: onDone) {
            ExpandedValueView(result: preview.result, fillsSpace: true)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } leadingActions: {
            if let copyText = preview.copyText {
                Button("Copy") { copyToPasteboard(copyText) }
            }
        }
        .onExitCommand { onDone() }
        .sheetSize(.large)
    }
}

/// One-line formatted value in a table cell; the selected row shows up to eight lines.
struct ValuePreviewText: View {
    let preview: ValuePreview?
    var isSelected = false

    var body: some View {
        if let preview {
            Text(preview.text.isEmpty ? " " : preview.text)
                .font(.body.monospaced())
                .foregroundStyle(preview.isValid ? .primary : .secondary)
                .lineLimit(isSelected ? 8 : 1)
                .truncationMode(.tail)
                .help(preview.tooltip)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(" ").font(.body.monospaced())
        }
    }
}

struct ExpandedValueView: View {
    let result: FormatResult?
    var fillsSpace = false

    var body: some View {
        if let result {
            switch result.content {
            case .json(let value):
                JSONTreeView(value: value, initiallyExpanded: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .markdown(let text):
                ScrollView {
                    MarkdownView(markdown: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .text(let text):
                CodeEditorView(text: .constant(text), language: .plain, isEditable: false, showsLineNumbers: false,
                               wrapsLines: true, autoCloseBrackets: false)
                    .frame(minHeight: fillsSpace ? 300 : 120)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ItemsStatusBar: View {
    let loaded: Int
    let total: Int
    let noun: String
    let canLoadMore: Bool
    let isLoading: Bool
    let onLoadMore: @MainActor () -> Void

    var body: some View {
        StatusBar {
            Text(KeyTableText.countSummary(loaded: loaded, total: total, noun: noun))
                .monospacedDigit()
        } accessory: {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if canLoadMore {
                Button("Load More") { onLoadMore() }
                    .buttonStyle(.borderless)
            }
        }
    }
}

enum KeyTableText {
    static func countSummary(loaded: Int, total: Int, noun: String) -> String {
        let loadedText = NumberFormatting.grouped(loaded)
        if total <= loaded { return "\(loadedText) \(noun)" }
        return "\(loadedText) of \(NumberFormatting.grouped(total)) \(noun)"
    }

    static func removeMessage(item: String, key: String, isLast: Bool) -> String {
        let base = "“\(item)” will be removed from “\(key)”."
        return isLast ? base + " Removing the last item deletes the key." : base
    }
}

struct TableStateView: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    var searchText: String?
    var emptyTitle = "No Fields"
    var emptySymbol = "number"
    let onRetry: @MainActor () -> Void

    var body: some View {
        if let error {
            ErrorStateView(message: error, retry: onRetry)
        } else if isEmpty && isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEmpty, let searchText, !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
        }
    }
}

struct DigitsField: View {
    let title: String
    var prompt: String?
    @Binding var text: String
    var width: CGFloat?

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .monospacedDigit()
            .frame(width: width)
            .onChange(of: text) { _, value in
                let clean = TTLInput.sanitize(value)
                if clean != value { text = clean }
            }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

@MainActor
func valueFormatBinding(_ settings: SettingsStore) -> Binding<ValueFormat> {
    Binding(get: { settings.browser.valueFormat }, set: { settings.browser.valueFormat = $0 })
}

enum KeyDetailsLayout {
    /// Collapses subheader controls to icons below this width.
    static let narrowWidth: CGFloat = 560
}

extension View {
    func trackingWidth(_ width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.wrappedValue = $0 }
    }
}
