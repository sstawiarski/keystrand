import AppKit
import Observation
import RedisUI
import SwiftUI

/// Calls `onClose` when the hosting NSWindow closes. Minimize, tab merge and hide do not close it.
struct WindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onClose = onClose
    }

    static func dismantleNSView(_ nsView: ObservingView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class ObservingView: NSView {
        var onClose: (@MainActor () -> Void)?
        private weak var observedWindow: NSWindow?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== observedWindow else { return }
            stopObserving()
            observedWindow = window
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onClose?()
                    self?.stopObserving()
                }
            }
        }

        func stopObserving() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            observedWindow = nil
        }
    }
}

extension View {
    func onWindowClose(_ action: @escaping @MainActor () -> Void) -> some View {
        background(WindowCloseObserver(onClose: action).frame(width: 0, height: 0))
    }
}

/// Brings an existing Home window forward instead of opening another one.
@MainActor
enum HomeWindowActivator {
    static func show(_ openWindow: OpenWindowAction) {
        let existing = NSApp.windows.first { window in
            (window.identifier?.rawValue.hasPrefix(AppWindowID.home) ?? false) && (window.isVisible || window.isMiniaturized)
        }
        guard let existing else {
            openWindow(id: AppWindowID.home)
            return
        }
        if existing.isMiniaturized { existing.deminiaturize(nil) }
        existing.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Calls `action` once with the hosting NSWindow when the view is placed in one.
struct WindowAccessor: NSViewRepresentable {
    let action: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        var action: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let action else { return }
            self.action = nil
            Task { @MainActor in action(window) }
        }
    }
}

extension View {
    func onHostingWindow(_ action: @escaping @MainActor (NSWindow) -> Void) -> some View {
        background(WindowAccessor(action: action).frame(width: 0, height: 0))
    }
}

/// The most recent `openWindow` action, so the app delegate can show Home when the Dock icon is clicked.
@MainActor
enum AppWindowOpener {
    static var openWindow: OpenWindowAction?

    /// The menu commands are built at launch, before any window, so they provide the first `openWindow` action.
    static func remember(_ action: OpenWindowAction) {
        if openWindow == nil { openWindow = action }
    }

    static func showHome() {
        guard let openWindow else { return }
        HomeWindowActivator.show(openWindow)
    }

    /// Brings Home forward to present app-wide errors, even after the last database window closes.
    static func presentAppErrors(_ toasts: ToastCenter) {
        withObservationTracking {
            _ = toasts.toasts.map(\.id)
        } onChange: {
            Task { @MainActor in
                if !toasts.toasts.isEmpty { showHome() }
                presentAppErrors(toasts)
            }
        }
    }

    /// Opens the `--open` database or Home.
    static func openLaunchWindow() async {
        guard let openWindow else { return }
        if LaunchOptions.current.suppressesHome {
            if let id = await LaunchOpener.resolveOnce(services: AppServices.shared) { openWindow(value: id) }
        } else {
            openWindow(id: AppWindowID.home)
        }
    }
}

/// The 10 most recently connected databases for File > Open Recent.
@MainActor
@Observable
final class RecentDatabases {
    static let shared = RecentDatabases()
    static let limit = 10
    static let clearedDefaultsKey = "recentDatabases.clearedAt"

    private(set) var items: [DatabaseConfig] = []
    @ObservationIgnored private var defaults: UserDefaults = .standard

    static func recent(_ configs: [DatabaseConfig], clearedAt: Date?) -> [DatabaseConfig] {
        configs
            .filter { config in
                guard let last = config.lastConnection else { return false }
                return clearedAt.map { last > $0 } ?? true
            }
            .sorted { ($0.lastConnection ?? .distantPast) > ($1.lastConnection ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func reload(services: AppServices) {
        Task {
            let configs = (try? await services.databaseStore.list()) ?? []
            let cleared = defaults.object(forKey: Self.clearedDefaultsKey) as? Date
            items = Self.recent(configs, clearedAt: cleared)
        }
    }

    func clear() {
        defaults.set(Date(), forKey: Self.clearedDefaultsKey)
        items = []
    }

    static func title(_ config: DatabaseConfig) -> String {
        DatabaseWindowTitle.title(name: config.name, dbIndex: config.db ?? 0)
    }
}
