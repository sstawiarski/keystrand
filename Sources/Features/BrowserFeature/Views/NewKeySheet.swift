import RedisUI
import SwiftUI
import UniformTypeIdentifiers

struct NewKeySheet: View {
    @Bindable var model: AddKeyViewModel
    @Bindable var browser: BrowserViewModel
    let addKeyForm: @MainActor (KeyType, AddKeyFormContext) -> AnyView?
    @State private var showJSONImporter = false
    @State private var injectedSubmission: AddKeyFormSubmission?
    @FocusState private var nameFocused: Bool

    var body: some View {
        SheetForm(title: "New Key", primaryTitle: "Add Key", isPrimaryDisabled: !canSubmit, isWorking: isSaving,
                  errorMessage: model.usesInjectedForm ? nil : model.errorMessage,
                  onCancel: { browser.closeAddKey() }, onPrimary: submit) {
            form
        } leadingActions: {
            if let message = validationMessage, !model.keyName.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .sheetSize(.form)
        .defaultFocus($nameFocused, true)
        .fileImporter(isPresented: $showJSONImporter, allowedContentTypes: [.json, .plainText, .text]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                model.loadJSONFile(url)
                if access { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private var canSubmit: Bool {
        model.usesInjectedForm ? injectedSubmission?.canSubmit == true : model.isValid
    }

    private var isSaving: Bool {
        model.usesInjectedForm ? injectedSubmission?.isSaving == true : model.isSaving
    }

    private var validationMessage: String? {
        model.usesInjectedForm ? injectedSubmission?.validationMessage : model.validationMessage
    }

    private var form: some View {
        Form {
            Section("Key") {
                Picker("Type", selection: $model.type) {
                    ForEach(AddKeyViewModel.offeredTypes) { type in
                        Label(typeTitle(type), systemImage: type.symbolName)
                            .tag(type)
                            .disabled(!model.isAvailable(type))
                    }
                }
                .pickerStyle(.menu)
                TextField("Name", text: $model.keyName, prompt: Text("Required"))
                    .fontDesign(.monospaced)
                    .focused($nameFocused)
                LabeledContent("TTL") {
                    HStack {
                        TextField("TTL", text: $model.ttlText, prompt: Text("No limit"))
                            .labelsHidden()
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(model.isSaving)
            valueSection
                .disabled(model.isSaving)
        }
        .formStyle(.grouped)
    }

    private func typeTitle(_ type: KeyType) -> String {
        guard let reason = model.unavailableReason(type) else { return type.displayName }
        return "\(type.displayName) (\(reason))"
    }

    @ViewBuilder
    private var valueSection: some View {
        switch model.type {
        case .string:
            Section("String Value") {
                CodeEditorView(text: $model.stringValue, showsLineNumbers: false, autoCloseBrackets: false)
                    .frame(minHeight: 140)
                    .accessibilityLabel("String Value")
            }
        case .hash:
            Section {
                MultiRowFormList(rows: $model.hashRows, addTitle: "Add Field", makeRow: { AddKeyPairRow() }) { $row in
                    TextField("Field", text: $row.name, prompt: Text("Field"))
                        .labelsHidden()
                        .fontDesign(.monospaced)
                    TextField("Value", text: $row.value, prompt: Text("Value"))
                        .labelsHidden()
                        .fontDesign(.monospaced)
                    if model.supportsHashFieldTTL {
                        TextField("TTL", text: $row.extra, prompt: Text("TTL (s)"))
                            .labelsHidden()
                            .monospacedDigit()
                            .frame(width: 80)
                            .onChange(of: row.extra) { _, value in
                                let clean = BrowserFormatting.sanitizeTTL(value)
                                if clean != value { row.extra = clean }
                            }
                    }
                }
            } header: {
                Text("Hash Value")
            } footer: {
                if model.supportsHashFieldTTL { Text("Field TTL is in seconds. Leave it empty for no limit.") }
            }
        case .list:
            Section("List Value") {
                Picker("Insert At", selection: $model.listDestination) {
                    Text("Tail").tag(ListDestination.tail)
                    Text("Head").tag(ListDestination.head)
                }
                .pickerStyle(.menu)
                MultiRowFormList(rows: $model.listElements, addTitle: "Add Element", makeRow: { AddKeyTextRow() }) { $row in
                    TextField("Element", text: $row.value, prompt: Text("Element"))
                        .labelsHidden()
                        .fontDesign(.monospaced)
                }
            }
        case .set:
            Section("Set Value") {
                MultiRowFormList(rows: $model.setMembers, addTitle: "Add Member", makeRow: { AddKeyTextRow() }) { $row in
                    TextField("Member", text: $row.value, prompt: Text("Member"))
                        .labelsHidden()
                        .fontDesign(.monospaced)
                }
            }
        case .zset:
            Section("Sorted Set Value") {
                MultiRowFormList(rows: $model.zsetRows, addTitle: "Add Member", makeRow: { AddKeyPairRow() }) { $row in
                    TextField("Member", text: $row.name, prompt: Text("Member"))
                        .labelsHidden()
                        .fontDesign(.monospaced)
                    TextField("Score", text: $row.extra, prompt: Text("Score"))
                        .labelsHidden()
                        .monospacedDigit()
                        .frame(width: 100)
                        .foregroundStyle(row.extra.isEmpty || BrowserFormatting.parseScore(row.extra) != nil
                                         ? Color.primary : Color.red)
                }
            }
        case .json:
            Section {
                CodeEditorView(text: $model.jsonText, language: .json, placeholder: "JSON value", showsLineNumbers: false,
                               wrapsLines: true)
                    .frame(minHeight: 160)
                HStack {
                    if let message = model.jsonValidationMessage {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }

                    Spacer()
                    Button("Choose File…") { showJSONImporter = true }
                }
            } header: {
                Text("JSON Value")
            } footer: {
                if model.jsonModuleMissing {
                    InlineMessage("This database does not support JSON.", kind: .warning)
                }
            }
        case .stream:
            Section("Stream Value") {
                TextField("Entry ID", text: $model.streamID, prompt: Text("*"))
                    .fontDesign(.monospaced)
                    .help("Timestamp-sequence (for example 1700000000000-0) or * to generate one")
                if !BrowserFormatting.isValidStreamID(model.streamID) {
                    Text("Entry ID format is incorrect.").font(.footnote).foregroundStyle(.red)
                }

                MultiRowFormList(rows: $model.streamRows, addTitle: "Add Field", makeRow: { AddKeyPairRow() }) { $row in
                    TextField("Field", text: $row.name, prompt: Text("Field"))
                        .labelsHidden()
                        .fontDesign(.monospaced)
                    TextField("Value", text: $row.value, prompt: Text("Value"))
                        .labelsHidden()
                        .fontDesign(.monospaced)
                }
            }
        case .timeSeries:
            Section("Time Series Options") {
                TextField("Retention (ms)", text: $model.tsRetention, prompt: Text("Server default"))
                    .monospacedDigit()
                    .onChange(of: model.tsRetention) { _, value in
                        let clean = BrowserFormatting.digitsOnly(value)
                        if clean != value { model.tsRetention = clean }
                    }
                Picker("Duplicate Policy", selection: $model.tsDuplicatePolicy) {
                    ForEach(AddKeyViewModel.duplicatePolicies, id: \.self) { policy in
                        Text(policy.isEmpty ? "Default" : policy).tag(policy)
                    }
                }
                Picker("Encoding", selection: $model.tsEncoding) {
                    ForEach(AddKeyViewModel.encodings, id: \.self) { encoding in
                        Text(encoding.isEmpty ? "Default" : encoding).tag(encoding)
                    }
                }
            }
            Section("Labels") {
                MultiRowFormList(rows: $model.tsLabels, addTitle: "Add Label", makeRow: { AddKeyPairRow() }) { $row in
                    TextField("Label", text: $row.name, prompt: Text("Label")).labelsHidden()
                    TextField("Value", text: $row.value, prompt: Text("Value")).labelsHidden()
                }
            }
            Section("Samples") {
                MultiRowFormList(rows: $model.tsSamples, addTitle: "Add Sample", makeRow: { AddKeyPairRow(name: "*") }) { $row in
                    TextField("Timestamp", text: $row.name, prompt: Text("* or milliseconds"))
                        .labelsHidden()
                        .monospacedDigit()
                    TextField("Value", text: $row.value, prompt: Text("Value"))
                        .labelsHidden()
                        .monospacedDigit()
                }
            }
        case .vectorSet:
            Section("Vector Set Value") {
                if let form = addKeyForm(.vectorSet, vectorSetContext) {
                    form
                } else {
                    InlineMessage("The Vector Set form is not available.", kind: .warning)
                }
            }
        default:
            EmptyView()
        }
    }

    private var vectorSetContext: AddKeyFormContext {
        AddKeyFormContext(session: browser.session,
                          keyName: { [model] in model.keyNameData },
                          ttl: { [model] in model.ttl },
                          onKeyAdded: { [browser] name in browser.keyAdded(name, type: .vectorSet) },
                          onCancel: { [browser] in browser.closeAddKey() },
                          publishSubmission: { submission in injectedSubmission = submission })
    }

    private func submit() {
        if model.usesInjectedForm {
            injectedSubmission?.submit()
            return
        }

        Task {
            if let result = await model.submit() {
                browser.keyAdded(result.name, type: result.type)
            }
        }
    }
}
