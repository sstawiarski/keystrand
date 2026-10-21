import AppKit
import SwiftUI

/// Tracks the hosting window so auto-refresh ticks can be skipped while it is minimized, hidden or fully occluded.
@MainActor
final class WindowVisibility {
    weak var window: NSWindow?

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
}

/// Zero-size background view that hands its window to a `WindowVisibility`.
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

    final class ReaderView: NSView {
        weak var visibility: WindowVisibility?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibility?.window = window
        }
    }
}

extension View {
    func trackWindowVisibility(_ visibility: WindowVisibility) -> some View {
        background(WindowVisibilityReader(visibility: visibility).frame(width: 0, height: 0))
    }
}
