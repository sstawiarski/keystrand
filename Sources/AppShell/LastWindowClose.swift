import AppKit
import RedisUI

/// Asks before the last window closes if quitting would close a connected database.
/// Forwards other delegate messages to SwiftUI’s window delegate.
@MainActor
final class LastWindowCloseGuard: NSObject, NSWindowDelegate {
    // AppKit sends delegate messages and the forwarding queries that read this only on the main thread.
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    private let services: AppServices
    private var isConfirmed = false

    private init(original: (any NSWindowDelegate)?, services: AppServices) {
        self.original = original
        self.services = services
    }

    /// The window keeps the guard alive, so it needs no other owner.
    static func install(on window: NSWindow, services: AppServices) {
        guard !(window.delegate is LastWindowCloseGuard) else { return }
        let closeGuard = LastWindowCloseGuard(original: window.delegate, services: services)
        window.delegate = closeGuard
        objc_setAssociatedObject(window, Unmanaged.passUnretained(closeGuard).toOpaque(), closeGuard,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isConfirmed {
            isConfirmed = false
        } else if let message = confirmationMessage(closing: sender) {
            confirm(message, closing: sender)
            return false
        }

        return original?.windowShouldClose?(sender) ?? true
    }

    private func confirmationMessage(closing window: NSWindow) -> String? {
        guard services.settings.app.quitAfterLastWindowClosed, Self.isLastWindow(window),
              let registry = services.sessions
        else { return nil }
        return Self.message(connectedDatabases: registry.sessions.values.filter(\.state.isConnected).map(\.config.name))
    }

    private func confirm(_ message: String, closing window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Quit Keystrand?"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        Task {
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            isConfirmed = true
            window.performClose(nil)
        }
    }

    /// Another window keeps the app open if it can become main and is visible or minimized.
    private static func isLastWindow(_ window: NSWindow) -> Bool {
        !NSApp.windows.contains { $0 !== window && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
    }

    nonisolated static func message(connectedDatabases names: [String]) -> String? {
        guard let first = names.first else { return nil }
        let target = names.count == 1 ? "“\(first)”" : "\(NumberFormatting.grouped(names.count)) databases"
        return "Closing the last window disconnects from \(target) and quits Keystrand."
    }
}
