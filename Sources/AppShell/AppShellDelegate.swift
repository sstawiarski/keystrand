import AppKit
import RedisUI

/// Closes database sessions before quitting to stop MONITOR and Pub/Sub and remove temporary Profiler logs.
@MainActor
public final class AppShellDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    private final class ReplyOnce {
        private var replied = false

        func reply(_ app: NSApplication) {
            guard !replied else { return }
            replied = true
            app.reply(toApplicationShouldTerminate: true)
        }
    }

    public override init() {
        super.init()
    }

    /// Launch flags disable window restoration through the volatile argument domain without changing saved defaults.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        guard LaunchOptions.current.isActive else { return }
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Presents app-wide errors.
    /// An unpaired flag (`--home --window-size 1280x800`) reaches AppKit as a file and suppresses SwiftUI’s launch window.
    /// Opens the intended window if none appears.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppWindowOpener.presentAppErrors(AppServices.shared.toasts)
        guard LaunchOptions.current.isActive else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal }) else { return }
            await AppWindowOpener.openLaunchWindow()
        }
    }

    /// Clicking the Dock icon with no visible windows shows the Redis Databases window.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        AppWindowOpener.showHome()
        return false
    }

    /// Uses the configured behavior after the last window closes.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppServices.shared.settings.app.quitAfterLastWindowClosed
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let holdToQuit = AppServices.shared.settings.app.holdToQuit
        if QuitHoldController.shared.shouldDefer(sender.currentEvent, isEnabled: holdToQuit) { return .terminateCancel }
        guard let registry = AppServices.shared.sessions else { return .terminateNow }
        let sessions = registry.sessionsIncludingClosing
        guard !sessions.isEmpty else { return .terminateNow }
        let scriptTimeout = AppServices.shared.clientFactory.scriptRunner.timeout
        let once = ReplyOnce()
        Task { @MainActor in
            try? await Task.sleep(for: Self.quitWait(sessions.map(\.config), scriptTimeout: scriptTimeout))
            once.reply(sender)
        }
        Task { @MainActor in
            await registry.closeAll()
            once.reply(sender)
        }
        return .terminateLater
    }

    /// Allows 2 s for sockets to close, plus the script timeout if a post-disconnect script runs.
    nonisolated static func quitWait(_ configs: [DatabaseConfig], scriptTimeout: TimeInterval) -> Duration {
        let hasScript = configs.contains { ConnectionScriptRunner.runnable($0.postDisconnectScript) != nil }
        return .seconds(2 + (hasScript ? scriptTimeout : 0))
    }
}
