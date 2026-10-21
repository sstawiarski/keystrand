import AppKit
import RedisUI
import SwiftUI
import UniformTypeIdentifiers

struct ExportConnectionsSheet: View {
    let databases: [DatabaseConfig]
    let export: @MainActor (_ includePasswords: Bool) async throws -> Data

    static let maxListed = 10

    @Environment(\.dismiss) private var dismiss
    @State private var includePasswords = true
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        SheetForm(title: title, primaryTitle: "Export…", isPrimaryDisabled: databases.isEmpty, isWorking: isWorking,
                  errorMessage: errorMessage, onCancel: { dismiss() }, onPrimary: save) {
            Form {
                Section("Databases") {
                    ForEach(databases.prefix(Self.maxListed)) { config in
                        Text(DatabaseListLogic.displayName(config, limit: 120))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if databases.count > Self.maxListed {
                        Text("and \(databases.count - Self.maxListed) more").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Include passwords", isOn: $includePasswords)
                } footer: {
                    Text("Passwords, private keys, passphrases and connection scripts are written to the file as plain text. Without them, the file has no secrets and no scripts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheetSize(.small)
    }

    private var title: String {
        if databases.count == 1, let config = databases.first {
            return "Export “\(DatabaseListLogic.confirmationName(config.name))”"
        }

        return "Export \(databases.count) Databases"
    }

    private func save() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let data = try await export(includePasswords)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = DatabaseListLogic.exportFileName()
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
