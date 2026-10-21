import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Attaches queued error alerts to an invisible helper view so new errors do not change the content's structure.
struct ErrorAlertsModifier: ViewModifier {
    let center: ToastCenter
    let isSheet: Bool
    @State private var sheetLevel: Int?

    func body(content: Content) -> some View {
        content
            .background { alert }
            .onAppear {
                if isSheet, sheetLevel == nil { sheetLevel = center.presenters.push() }
            }
            .onDisappear {
                guard isSheet, sheetLevel != nil else { return }
                sheetLevel = nil
                center.presenters.pop()
            }
    }

    private var alert: some View {
        let current = (isSheet ? sheetLevel : 0) == center.presenters.depth ? center.toasts.first : nil
        let center = center
        return Color.clear
            .alert(current?.title ?? "Error",
                   isPresented: Binding(get: { current != nil }, set: { if !$0 { center.dismissFront(id: current?.id) } }),
                   presenting: current) { toast in
                if toast.hasLongMessage {
                    Button("Save Full Log…") {
                        ErrorAlerts.saveLog(toast.message ?? "", errors: center)
                        center.dismissFront(id: toast.id)
                    }
                }

                Button("OK", role: .cancel) { center.dismissFront(id: toast.id) }
            } message: { toast in
                if let message = ErrorAlerts.alertMessage(toast.message) { Text(message) }
            }
    }
}

public enum ErrorAlerts {
    /// Alert message: the first 400 characters, with an ellipsis when longer.
    public static func alertMessage(_ message: String?) -> String? {
        guard let message, !message.isEmpty else { return nil }
        guard message.count > Toast.longMessageThreshold else { return message }
        return String(message.prefix(Toast.longMessageThreshold)) + "…"
    }

    /// Writes the full message through a save panel; a failed write is queued as a new error.
    @MainActor
    static func saveLog(_ text: String, errors: ToastCenter) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "error-log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url)
        } catch {
            errors.error(error, title: "Couldn’t Save Log")
        }
    }
}

public extension View {
    /// Error alerts of a window: apply once at the window root. Sheets use `sheetAlerts(_:)`.
    func errorAlerts(_ center: ToastCenter) -> some View {
        modifier(ErrorAlertsModifier(center: center, isSheet: false))
    }
}
