import AppKit
import SwiftUI

/// Tracks the hosting window so auto-refresh ticks can be skipped while it is minimized, hidden or fully occluded.
@MainActor
final class WindowVisibility {
    weak var window: NSWindow?
    /// Called when the window is deminiaturized or its occlusion state changes to visible.
    var onBecameVisible: (@MainActor () -> Void)?

    var isVisible: Bool { Self.isVisible(window) }

    /// No window yet (previews, tests) counts as visible.
    static func isVisible(_ window: NSWindow?) -> Bool {
        guard let window else { return true }
        return isVisible(isOnScreen: window.isVisible, isMiniaturized: window.isMiniaturized,
                         isOccluded: !window.occlusionState.contains(.visible))
    }

    nonisolated static func isVisible(isOnScreen: Bool, isMiniaturized: Bool, isOccluded: Bool) -> Bool {
        isOnScreen && !isMiniaturized && !isOccluded
    }

    func windowStateChanged() {
        if isVisible { onBecameVisible?() }
    }
}

struct WindowVisibilityReader: NSViewRepresentable {
    let visibility: WindowVisibility

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.visibility = visibility
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.visibility = visibility
        visibility.window = view.window
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        view.stopObserving()
    }

    final class ReaderView: NSView {
        weak var visibility: WindowVisibility?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibility?.window = window
            stopObserving()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.visibility?.windowStateChanged() }
                })
            }
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}

extension View {
    func trackWindowVisibility(_ visibility: WindowVisibility) -> some View {
        background(WindowVisibilityReader(visibility: visibility).frame(width: 0, height: 0))
    }
}
