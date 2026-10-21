import SwiftUI

/// "Rename Key" sheet (Small) shared by the key list and the key details header: a prefilled, focused "Name" field
/// and the `Replace “<name>”?` confirmation when the new name is taken.
public struct RenameKeyForm: View {
    let initialName: String
    let isWorking: Bool
    let validate: (String) -> String?
    let onCancel: @MainActor () -> Void
    let onRename: @MainActor (_ name: String, _ overwrite: Bool) -> Void
    @Binding var confirmReplace: Bool
    @State private var name: String
    @FocusState private var focused: Bool

    /// `validate` returns nil for a usable name, else the inline error. `confirmReplace` is set by the caller when
    /// the name is in use; confirming calls `onRename` again with `overwrite == true`.
    public init(initialName: String, isWorking: Bool, confirmReplace: Binding<Bool>,
                validate: @escaping (String) -> String?, onCancel: @escaping @MainActor () -> Void,
                onRename: @escaping @MainActor (_ name: String, _ overwrite: Bool) -> Void) {
        self.initialName = initialName
        self.isWorking = isWorking
        self._confirmReplace = confirmReplace
        self.validate = validate
        self.onCancel = onCancel
        self.onRename = onRename
        self._name = State(initialValue: initialName)
    }

    private var error: String? { name.isEmpty ? nil : validate(name) }

    public var body: some View {
        SheetForm(title: "Rename Key", primaryTitle: "Rename",
                  isPrimaryDisabled: name.isEmpty || error != nil || name == initialName, isWorking: isWorking,
                  errorMessage: error, onCancel: onCancel, onPrimary: { submit(overwrite: false) }) {
            Form {
                TextField("Name", text: $name)
                    .fontDesign(.monospaced)
                    .focused($focused)
                    .onSubmit { submit(overwrite: false) }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheetSize(.small)
        .onAppear { focused = true }
        .destructiveConfirmation("Replace “\(TextTruncation.formatLongName(name, maxLength: 68, tail: 15))”?",
                                 isPresented: $confirmReplace,
                                 message: "A key with this name already exists. Renaming replaces it.",
                                 confirmTitle: "Replace") {
            submit(overwrite: true)
        }
    }

    private func submit(overwrite: Bool) {
        guard !isWorking, !name.isEmpty, validate(name) == nil else { return }
        if name == initialName {
            onCancel()
            return
        }

        onRename(name, overwrite)
    }
}

/// TTL text field with a trailing "seconds" unit: digits only, clamped to the Redis maximum, empty = no limit.
public struct TTLField: View {
    @Binding var text: String
    var onSubmit: @MainActor () -> Void
    @FocusState private var focused: Bool

    public init(text: Binding<String>, onSubmit: @escaping @MainActor () -> Void) {
        self._text = text
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack {
            TextField("TTL", text: $text, prompt: Text("No limit"))
                .labelsHidden()
                .monospacedDigit()
                .focused($focused)
                .onSubmit { onSubmit() }
                .onChange(of: text) { _, value in
                    let clean = TTLInput.sanitize(value)
                    if clean != value { text = clean }
                }
            Text("seconds").foregroundStyle(.secondary)
        }
        .onAppear { focused = true }
    }
}

/// Set TTL / Set Field TTL editor shown in a popover: `TTLField`, an optional footer, Cancel and Set.
public struct SetTTLPopover: View {
    let title: String
    @Binding var text: String
    var footer: String?
    let isSaving: Bool
    let onCancel: @MainActor () -> Void
    let onSet: @MainActor () -> Void

    public init(title: String, text: Binding<String>, footer: String? = nil, isSaving: Bool,
                onCancel: @escaping @MainActor () -> Void, onSet: @escaping @MainActor () -> Void) {
        self.title = title
        self._text = text
        self.footer = footer
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSet = onSet
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TTLField(text: $text, onSubmit: onSet)
                .frame(width: 200, alignment: .leading)
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button { onSet() } label: {
                    HStack(spacing: 6) {
                        Text("Set")
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || TTLInput.parse(text) == nil)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
