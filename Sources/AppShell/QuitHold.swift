import AppKit
import RedisUI
import SwiftUI

enum QuitShortcut {
    /// Matches ⌘Q with or without ⇧ or ⌥.
    static func matches(modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        modifiers.contains(.command) && characters?.lowercased() == "q"
    }
}

/// A short ⌘Q press shows a reminder; holding for `holdDuration` quits.
/// Quit requests from the menu, Dock or Apple Events (logout, `osascript`) bypass the hold.
@MainActor
final class QuitHoldController {
    static let shared = QuitHoldController()

    static let holdDuration: Duration = .seconds(1)
    static let reminderDuration: Duration = .seconds(1.5)

    private enum Phase {
        case idle, holding, quitting
    }

    private var phase = Phase.idle
    private var keyCode: UInt16?
    private var monitor: Any?
    private var holdTask: Task<Void, Never>?
    private let hud = QuitHUD()

    /// Returns true if `applicationShouldTerminate` must cancel the request. Calls `terminate` again after the hold completes.
    func shouldDefer(_ event: NSEvent?, isEnabled: Bool) -> Bool {
        switch phase {
        case .quitting:
            return false
        case .holding:
            return true
        case .idle:
            guard isEnabled, NSAppleEventManager.shared().currentAppleEvent == nil,
                  let event, event.type == .keyDown, !event.isARepeat,
                  QuitShortcut.matches(modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers)
            else { return false }
            begin(keyCode: event.keyCode)
            return true
        }
    }

    private func begin(keyCode: UInt16) {
        phase = .holding
        self.keyCode = keyCode
        hud.show()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let swallow = MainActor.assumeIsolated { QuitHoldController.shared.handle(event) }
            return swallow ? nil : event
        }
        holdTask = Task {
            try? await Task.sleep(for: Self.holdDuration)
            guard !Task.isCancelled else { return }
            holdElapsed()
        }
    }

    /// Swallows the key's auto-repeat so it cannot reach the Quit menu item again.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            return event.keyCode == keyCode
        case .keyUp where event.keyCode == keyCode && phase == .holding:
            release()
        case .flagsChanged where !event.modifierFlags.contains(.command) && phase == .holding:
            release()
        default:
            break
        }

        return false
    }

    private func release() {
        phase = .idle
        keyCode = nil
        holdTask?.cancel()
        holdTask = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hud.hide(after: Self.reminderDuration)
    }

    private func holdElapsed() {
        guard phase == .holding else { return }
        guard NSEvent.modifierFlags.contains(.command) else { return release() }
        phase = .quitting
        keyCode = nil
        holdTask = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hud.hide(after: .zero)
        // `.terminateLater` spins a nested run loop that cannot drain the main queue while a main-actor job runs.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}

@MainActor
private final class QuitHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show() {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let area = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: QuitHUDView())
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

private struct QuitHUDView: View {
    var body: some View {
        Text("Hold ⌘Q to Quit")
            .font(.title2.weight(.semibold))
            .fixedSize()
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .glassEffect(.regular, in: .capsule)
            .padding(24)
    }
}
