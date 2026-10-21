import RedisUI
import SwiftUI

struct RenameKeySheet: View {
    let model: BrowserViewModel
    let key: Data
    @State private var isWorking = false
    @State private var confirmReplace = false

    var body: some View {
        RenameKeyForm(initialName: model.renameDraft(key), isWorking: isWorking, confirmReplace: $confirmReplace,
                      validate: { model.parseKeyName($0) == nil ? "Enter the key name as hexadecimal bytes." : nil },
                      onCancel: { model.sheetDismissed() }) { name, overwrite in
            rename(name, overwrite: overwrite)
        }
    }

    private func rename(_ name: String, overwrite: Bool) {
        guard let newName = model.parseKeyName(name), !isWorking else { return }
        guard newName != key else {
            model.sheetDismissed()
            return
        }
        isWorking = true
        Task {
            let outcome = await model.renameKey(key, to: newName, overwrite: overwrite)
            isWorking = false
            switch outcome {
            case .renamed: model.sheetDismissed()
            case .nameInUse: confirmReplace = true
            case .cancelled, .failed: break
            }
        }
    }
}

struct SetTTLSheet: View {
    let model: BrowserViewModel
    let key: Data
    @State private var text = ""
    @State private var isWorking = false
    @State private var confirmDelete = false

    private var seconds: Int? { TTLInput.parse(text) }

    var body: some View {
        SheetForm(title: "Set TTL for “\(BrowserFormatting.shortName(model.displayName(key)))”", primaryTitle: "Set",
                  isPrimaryDisabled: seconds == nil, isWorking: isWorking,
                  onCancel: { model.sheetDismissed() }, onPrimary: apply) {
            Form {
                Section {
                    LabeledContent("TTL") {
                        TTLField(text: $text, onSubmit: apply)
                    }
                } footer: {
                    Text("Leave empty for no limit. A TTL of 0 deletes the key.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheetSize(.small)
        .onAppear { text = model.ttlDraft(key) }
        .destructiveConfirmation("Delete “\(BrowserFormatting.shortName(model.displayName(key)))”?",
                                 isPresented: $confirmDelete, message: "A TTL of 0 deletes the key.") {
            run(0)
        }
    }

    private func apply() {
        guard let seconds, !isWorking else { return }
        if seconds == 0, model.deleteRequiresConfirmation {
            confirmDelete = true
        } else {
            run(seconds)
        }
    }

    private func run(_ seconds: Int) {
        isWorking = true
        Task {
            let ok = await model.setTTL(key, seconds: seconds)
            isWorking = false
            if ok { model.sheetDismissed() }
        }
    }
}
