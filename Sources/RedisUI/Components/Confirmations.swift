import SwiftUI

enum ConfirmationText {
    static let aclTip = "Tip: Restrict dangerous commands per user with Redis ACLs."
    static let suppressionTitle = "Don't ask again this session"

    static func typeToConfirmMessage(_ message: String?, confirmationText: String) -> String {
        let instruction = "Type “\(confirmationText)” to confirm."
        return [plain(message), instruction, aclTip].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// True only on an exact match; a mismatch resolves the alert as cancel.
    static func matches(_ typed: String, expected: String) -> Bool {
        !expected.isEmpty && typed == expected
    }

    /// Inline Markdown rendered to plain text (alerts show plain text).
    static func plain(_ markdown: String?) -> String? {
        guard let markdown else { return nil }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else { return markdown }
        return String(attributed.characters)
    }
}

private struct DestructiveConfirmationModifier: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let message: String?
    let confirmTitle: String
    let isSuppressed: Binding<Bool>?
    let onConfirm: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.background {
            if let isSuppressed {
                dialog.dialogSuppressionToggle(isSuppressed: isSuppressed)
            } else {
                dialog
            }
        }
    }

    private var dialog: some View {
        Color.clear.confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible) {
            Button(confirmTitle, role: .destructive) { onConfirm() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let message { Text(message) }
        }
    }
}

public extension View {
    /// Confirmation dialog with a visible title, a destructive button and Cancel (Cancel is the default).
    func destructiveConfirmation(_ title: String, isPresented: Binding<Bool>, message: String? = nil,
                                 confirmTitle: String = "Delete", isSuppressed: Binding<Bool>? = nil,
                                 onConfirm: @escaping @MainActor () -> Void) -> some View {
        modifier(DestructiveConfirmationModifier(title: title, isPresented: isPresented, message: message,
                                                 confirmTitle: confirmTitle, isSuppressed: isSuppressed,
                                                 onConfirm: onConfirm))
    }

    /// "Discard Changes?" before leaving an editor with unsaved edits (Esc, another key, another tab or page).
    func discardChangesConfirmation(isPresented: Binding<Bool>,
                                    message: String = "Your changes have not been saved.",
                                    onDiscard: @escaping @MainActor () -> Void) -> some View {
        destructiveConfirmation("Discard Changes?", isPresented: isPresented, message: message,
                                confirmTitle: "Discard", onConfirm: onDiscard)
    }

    /// Item-driven "Discard Changes?": presents while `item` is non-nil and hands it to `onDiscard`.
    func discardChangesConfirmation<Item: Identifiable>(item: Binding<Item?>,
                                                        message: String = "Your changes have not been saved.",
                                                        onDiscard: @escaping @MainActor (Item) -> Void) -> some View {
        destructiveConfirmation(item: item, title: { _ in "Discard Changes?" }, message: { _ in message },
                                confirmTitle: "Discard", onConfirm: onDiscard)
    }

    /// Item-driven variant: presents while `item` is non-nil.
    func destructiveConfirmation<Item: Identifiable>(item: Binding<Item?>, title: @escaping (Item) -> String,
                                                     message: @escaping (Item) -> String? = { _ in nil },
                                                     confirmTitle: String = "Delete",
                                                     onConfirm: @escaping @MainActor (Item) -> Void) -> some View {
        let current = item.wrappedValue
        return confirmationDialog(current.map(title) ?? "", isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }), titleVisibility: .visible, presenting: current) { value in
            Button(confirmTitle, role: .destructive) { onConfirm(value) }
            Button("Cancel", role: .cancel) {}
        } message: { value in
            if let text = message(value) { Text(text) }
        }
    }

    /// Production confirmations of a session: a confirmation dialog for plain requests, and for type-to-confirm
    /// requests an alert with a text field, a critical severity and a destructive button enabled on an exact match.
    /// Apply once at the window root; sheets use `sheetAlerts(_:)`.
    func productionConfirmations(_ center: ConfirmationCenter) -> some View {
        modifier(ProductionConfirmationsModifier(center: center, isSheet: false))
    }

    /// Presents a session's production confirmations and error alerts inside a sheet. While a sheet is up, macOS
    /// does not show the window root's dialogs, so every `.sheet` whose content may call `session.confirm`,
    /// `confirmProduction`, or `session.toasts.error` must apply this to the sheet's root view. The innermost sheet
    /// presents; the window root waits until no sheet presenter is attached.
    func sheetAlerts(_ session: DatabaseSession) -> some View {
        sheetAlerts(confirmations: session.confirmations, errors: session.toasts)
    }

    /// `sheetAlerts(_:)` for code that holds the centers rather than the session.
    func sheetAlerts(confirmations: ConfirmationCenter, errors: ToastCenter) -> some View {
        modifier(ProductionConfirmationsModifier(center: confirmations, isSheet: true))
            .modifier(ErrorAlertsModifier(center: errors, isSheet: true))
    }

    /// "Edit a Non-Unicode Value?" guard.
    func nonUnicodeEditGuard(isPresented: Binding<Bool>, formatName: String, onEditAnyway: @escaping () -> Void,
                             onChangeToUnicode: @escaping () -> Void) -> some View {
        alert("Edit a Non-Unicode Value?", isPresented: isPresented) {
            Button("Change to Unicode") { onChangeToUnicode() }
                .keyboardShortcut(.defaultAction)
            Button("Edit Anyway") { onEditAnyway() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You're viewing this value as \(formatName). Saving re-encodes it, which can change the stored bytes. To edit the exact stored text, switch to Unicode.")
        }
    }
}

/// Attaches dialogs to invisible helper views so new or resolved requests do not change the content's structure.
private struct ProductionConfirmationsModifier: ViewModifier {
    let center: ConfirmationCenter
    let isSheet: Bool
    @State private var sheetLevel: Int?
    @State private var typed = ""
    @State private var skip = false

    func body(content: Content) -> some View {
        content
            .background { dialog(suppressible: false) }
            .background {
                dialog(suppressible: true)
                    .dialogSuppressionToggle(Text(ConfirmationText.suppressionTitle), isSuppressed: $skip)
            }
            .background { typingAlert(suppressible: false) }
            .background {
                typingAlert(suppressible: true)
                    .dialogSuppressionToggle(Text(ConfirmationText.suppressionTitle), isSuppressed: $skip)
            }
            .onChange(of: center.pending?.id) {
                typed = ""
                skip = false
            }
            .onAppear {
                if isSheet, sheetLevel == nil { sheetLevel = center.presenters.push() }
            }
            .onDisappear {
                guard isSheet, sheetLevel != nil else { return }
                sheetLevel = nil
                center.presenters.pop()
            }
    }

    private var isFrontmost: Bool {
        (isSheet ? sheetLevel : 0) == center.presenters.depth
    }

    private func dialog(suppressible: Bool) -> some View {
        let request = center.pending
        return Color.clear
            .confirmationDialog(request?.title ?? "",
                                isPresented: presented(typing: false, suppressible: suppressible),
                                titleVisibility: .visible) {
                Button(request?.confirmButtonTitle ?? "Confirm", role: .destructive) { resolve(true) }
                Button("Cancel", role: .cancel) { resolve(false) }
            } message: {
                if let message = ConfirmationText.plain(request?.message) { Text(message) }
            }
    }

    private func typingAlert(suppressible: Bool) -> some View {
        let request = center.pending
        let expected = center.confirmationText
        return Color.clear
            .alert(request?.title ?? "", isPresented: presented(typing: true, suppressible: suppressible)) {
                TextField(expected, text: $typed)
                Button(request?.confirmButtonTitle ?? "Confirm", role: .destructive) {
                    resolve(ConfirmationText.matches(typed, expected: expected))
                }
                .disabled(!ConfirmationText.matches(typed, expected: expected))
                Button("Cancel", role: .cancel) { resolve(false) }
            } message: {
                Text(ConfirmationText.typeToConfirmMessage(request?.message, confirmationText: expected))
            }
            .dialogSeverity(.critical)
    }

    /// `suppressible` selects requests with (true) or without (false) an action id.
    private func presented(typing: Bool, suppressible: Bool) -> Binding<Bool> {
        Binding(
            get: {
                guard isFrontmost, let request = center.pending else { return false }
                return request.requiresTyping == typing && (request.actionID != nil) == suppressible
            },
            set: { isPresented in
                guard !isPresented, let id = center.pending?.id else { return }
                Task { @MainActor in
                    if center.pending?.id == id { center.resolve(confirmed: false) }
                }
            })
    }

    private func resolve(_ confirmed: Bool) {
        center.resolve(confirmed: confirmed, skipForSession: confirmed && skip)
    }
}
