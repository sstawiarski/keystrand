import AppKit
import RedisUI
import SwiftUI
import UniformTypeIdentifiers

/// Secure field for a secret that may already be stored: a stored value shows an empty field with the prompt
/// "Saved"; typing replaces it, and typing then clearing removes it. Untouched secrets are never re-sent.
struct StoredSecretField: View {
    let title: String
    var prompt = "Optional"
    @Binding var secret: SecretInput

    var body: some View {
        SecureField(title, text: text, prompt: Text(secret.isStored ? "Saved" : prompt))
            .help(secret.isStored ? "A value is saved. Type to replace it." : "")
    }

    private var text: Binding<String> {
        Binding(get: { secret.isStored ? "" : secret.text },
                set: { secret = Self.updated(secret, typed: $0) })
    }

    nonisolated static func updated(_ secret: SecretInput, typed: String) -> SecretInput {
        var result = secret
        if result.isStored && typed.isEmpty { return result }
        result.text = typed
        return result
    }
}

/// Multi-line PEM input with "Choose File…"; a stored key shows "Saved" until replaced, a masked key shows bullets.
struct PEMEditor: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var isStored = false
    var onReplaceStored: (() -> Void)?
    var masked = false
    var maxLength = 50_000

    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Choose File…", action: chooseFile)
            }
            if isStored {
                HStack {
                    Text("Saved").foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace") { onReplaceStored?() }
                }
            } else if masked && !text.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(repeating: "•", count: min(text.count, 120)))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Clear") { text = "" }
                }
            } else {
                CodeEditorView(text: $text, placeholder: prompt, showsLineNumbers: false, fontSize: 12,
                               autoCloseBrackets: false)
                    .frame(height: 84)
                    .accessibilityLabel(title)
                    .onChange(of: text) { _, value in
                        if value.count > maxLength { text = String(value.prefix(maxLength)) }
                    }
            }

            if let importError {
                Text(importError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            if isStored { onReplaceStored?() }
            text = String(contents.prefix(maxLength))
            importError = nil
        } catch {
            importError = "Unable to read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

struct SectionFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SheetNotice<Accessory: View>: View {
    let text: String
    var kind: InlineMessage.Kind = .warning
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack {
            InlineMessage(text, kind: kind)
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

extension SheetNotice where Accessory == EmptyView {
    init(_ text: String, kind: InlineMessage.Kind = .warning) {
        self.init(text: text, kind: kind, accessory: { EmptyView() })
    }
}

struct WorkingLabel: View {
    let title: String
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if isWorking { ProgressView().controlSize(.small) }
        }
    }
}

@MainActor
func ipFamilyPicker(_ selection: Binding<ConnectionFamily>) -> some View {
    Picker("IP Protocol", selection: selection) {
        Text("Automatic (IPv4 and IPv6)").tag(ConnectionFamily.auto)
        Text("IPv4").tag(ConnectionFamily.ipv4)
        Text("IPv6").tag(ConnectionFamily.ipv6)
    }
    .pickerStyle(.menu)
    .help("Automatic uses IPv4 and IPv6. IPv4 or IPv6 forces that address family when the host name resolves to both.")
}

extension View {
    func digitsOnly(_ text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { _, value in
            let filtered = value.filter(\.isNumber)
            if filtered != value { text.wrappedValue = filtered }
        }
    }
}
