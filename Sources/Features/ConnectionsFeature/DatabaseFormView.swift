import RedisUI
import SwiftUI

public enum DatabaseFormMode: Hashable, Sendable {
    case add
    case edit(DatabaseConfig)
    case clone(DatabaseConfig)
}

/// Adds, edits, or clones a database and dismisses after saving.
/// Add starts with connection options; edit and clone show the connection settings form.
public struct DatabaseFormView: View {
    public let mode: DatabaseFormMode
    public let focusEnvironment: Bool
    public let onSaved: @MainActor (DatabaseConfig) -> Void

    private let initialScreen: AddDatabaseFlowModel.Screen
    private let importFile: URL?
    private let deepLink: DatabaseDeepLink?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @State private var flow: AddDatabaseFlowModel?
    @State private var form: DatabaseFormModel?

    public init(mode: DatabaseFormMode, focusEnvironment: Bool = false,
                onSaved: @escaping @MainActor (DatabaseConfig) -> Void = { _ in }) {
        self.init(mode: mode, focusEnvironment: focusEnvironment, initialScreen: .start, importFile: nil,
                  onSaved: onSaved)
    }

    /// The Add Database form prefilled from a `keystrand://databases/connect` link that needs credentials or
    /// certificates.
    public init(deepLink: DatabaseDeepLink, onSaved: @escaping @MainActor (DatabaseConfig) -> Void = { _ in }) {
        self.init(mode: .add, initialScreen: .form, deepLink: deepLink, onSaved: onSaved)
    }

    init(mode: DatabaseFormMode, focusEnvironment: Bool = false, initialScreen: AddDatabaseFlowModel.Screen,
         importFile: URL? = nil, deepLink: DatabaseDeepLink? = nil,
         onSaved: @escaping @MainActor (DatabaseConfig) -> Void = { _ in }) {
        self.mode = mode
        self.focusEnvironment = focusEnvironment
        self.initialScreen = initialScreen
        self.importFile = importFile
        self.deepLink = deepLink
        self.onSaved = onSaved
    }

    public var body: some View {
        Group {
            switch mode {
            case .add:
                if let flow {
                    AddDatabaseFlowView(model: flow, onClose: { dismiss() }, onSaved: saved)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).sheetSize(.form)
                }
            case .edit, .clone:
                if let form {
                    ConnectionSettingsView(model: form, focusEnvironment: focusEnvironment,
                                           onCancel: { dismiss() }, onSaved: saved)
                        .sheetSize(.form)
                        .frame(minHeight: ConnectionSettingsView.idealHeight)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).sheetSize(.form)
                }
            }
        }
        .onAppear(perform: makeModels)
    }

    private func makeModels() {
        switch mode {
        case .add:
            if flow == nil {
                flow = AddDatabaseFlowModel(services: services, initialScreen: initialScreen, importFile: importFile,
                                            deepLink: deepLink)
            }
        case .edit, .clone:
            if form == nil { form = DatabaseFormModel(mode: mode, services: services) }
        }
    }

    private func saved(_ config: DatabaseConfig) {
        onSaved(config)
        dismiss()
    }
}
