import AppKit
import RedisUI
import SwiftUI

/// String key value view.
public struct StringKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        StringKeyContent(context: context).id(KeyViewIdentity(context))
    }
}

struct StringKeyContent: View {
    let context: KeyDetailsContext
    @State private var model: StringKeyViewModel
    @State private var showGuard = false
    @State private var confirmUnicode = false
    @State private var confirmDiscard = false
    @State private var width: CGFloat = 1_000

    init(context: KeyDetailsContext) {
        self.context = context
        self._model = State(initialValue: StringKeyViewModel(context: context))
    }

    private var settings: SettingsStore { context.session.services.settings }
    private var compact: Bool { width < KeyDetailsLayout.narrowWidth }

    var body: some View {
        VStack(spacing: 0) {
            subheader
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isEditing {
                Divider()
                editBar
            } else if model.showsFooter && !model.isFullyLoaded {
                Divider()
                partialBar
            }
        }
        .trackingWidth($width)
        .onAppear { model.reload() }
        .onChange(of: context.state.refreshGeneration) { model.refresh() }
        .onChange(of: settings.browser.valueFormat) { Task { await model.formatChanged() } }
        .onDisappear { model.viewDidDisappear() }
        .nonUnicodeEditGuard(isPresented: $showGuard, formatName: model.selectedFormat.menuLabel,
                             onEditAnyway: { model.beginEdit() },
                             onChangeToUnicode: {
                                 model.pendingEditAfterFormatChange = true
                                 settings.browser.valueFormat = .unicode
                             })
        .destructiveConfirmation(ValueEditRules.savedAsUnicodeTitle, isPresented: $confirmUnicode,
                                 message: ValueEditRules.savedAsUnicodeMessage, confirmTitle: "Save") {
            Task { await model.saveEdit() }
        }
        .discardChangesConfirmation(isPresented: $confirmDiscard) { model.cancelEdit() }
        .onChange(of: model.hasUnsavedEdit, initial: true) { _, dirty in context.state.hasUnsavedChanges = dirty }
    }

    // MARK: - Subheader

    private var subheader: some View {
        KeySubheaderBar {
            EmptyView()
        } trailing: {
            ValueFormatPicker(selection: valueFormatBinding(settings), compact: compact)
                .disabled(!model.isFullyLoaded || model.isEditing)
                .help(model.isFullyLoaded ? "Value format" : "Load the whole value to choose a format")
            subheaderButton("Copy", systemImage: "doc.on.doc", help: model.canCopy ? "Copy Value" : "Load the whole value to copy it") {
                if let text = model.copyText { copyToPasteboard(text) }
            }
            .disabled(!model.canCopy)
            let editBlockReason = model.editBlockReason
            subheaderButton("Edit", systemImage: "pencil", help: editBlockReason ?? "Edit Value", action: requestEdit)
                .disabled(editBlockReason != nil || model.isEditing)
        }
    }

    private func subheaderButton(_ title: String, systemImage: String, help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: systemImage) }
            .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            .buttonStyle(.borderless)
            .help(help)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError {
            ErrorStateView(message: error) { model.reload() }
        } else if model.isEditing {
            CodeEditorView(text: $model.editDraft, language: ValueEditRules.isJSONLike(model.selectedFormat) ? .json : .plain,
                           placeholder: "Enter Value", showsLineNumbers: false, wrapsLines: true,
                           autoCloseBrackets: ValueEditRules.isJSONLike(model.selectedFormat),
                           onEscape: {
                               if model.hasUnsavedEdit { confirmDiscard = true } else { model.cancelEdit() }
                               return true
                           }, autoFocus: true)
        } else if model.isEmpty {
            Text("Empty")
                .italic()
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
        } else if let result = model.result {
            valueView(result)
                .help(result.isValid ? "" : FormatResult.failedTitle(model.displayFormat))
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func valueView(_ result: FormatResult) -> some View {
        switch result.content {
        case .json(let value):
            JSONTreeView(value: value, initiallyExpanded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .markdown(let text):
            ScrollView {
                MarkdownView(markdown: text)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text(let text):
            CodeEditorView(text: .constant(text), language: .plain, isEditable: false, showsLineNumbers: false,
                           wrapsLines: true, autoCloseBrackets: false)
                .contextMenu {
                    if model.canCopy {
                        Button("Copy Value") { if let copy = model.copyText { copyToPasteboard(copy) } }
                    }

                    Button("Edit Value", action: requestEdit).disabled(model.editBlockReason != nil)
                }
        }
    }

    // MARK: - Bottom bars

    private var partialBar: some View {
        StatusBar {
            Text("Showing the first \(NumberFormatting.grouped(StringService.initialLoadBytes)) bytes of \(ByteFormatter.format(Double(model.length), decimals: 1))")
        } accessory: {
            Button("Load All") { model.reloadAll() }
                .buttonStyle(.borderless)
                .disabled(model.isLoading)
            Button("Save to File…") { download() }
                .buttonStyle(.borderless)
                .disabled(model.isDownloading)
            if model.isLoading || model.isDownloading { ProgressView().controlSize(.mini) }
        }
    }

    private var editBar: some View {
        HStack(spacing: 8) {
            Text(model.selectedFormat.menuLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.cancelEdit() }
            Button(action: attemptSave) {
                HStack(spacing: 6) {
                    Text("Save")
                    if model.isSaving { ProgressView().controlSize(.small) }
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.isSaving)
            .help("Save (⌘S)")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func requestEdit() {
        guard model.editBlockReason == nil, !model.isEditing else { return }
        if model.needsNonUnicodeGuard {
            showGuard = true
        } else {
            model.beginEdit()
        }
    }

    private func attemptSave() {
        Task {
            if await model.encodeDraft().isValid {
                await model.saveEdit()
            } else {
                confirmUnicode = true
            }
        }
    }

    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "string_value"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.download(to: url) }
    }
}

/// Type-erased label style so a view can switch between icon-only and title-and-icon.
struct AnyLabelStyle: LabelStyle {
    private let make: @MainActor (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
