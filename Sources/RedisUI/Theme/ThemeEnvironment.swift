import AppKit
import SwiftUI

/// Appearance override chosen in Settings (`system` follows macOS).
public typealias ThemeMode = AppTheme

/// Applies the mode to every window, popover, sheet and AppKit view through `NSApp.appearance`.
/// `preferredColorScheme(nil)` does not reliably restore System mode on macOS.
/// The `--appearance` launch flag overrides the saved mode for one run without saving it.
@MainActor
public enum ThemeApplier {
    public static func apply(_ mode: ThemeMode) {
        guard let app = NSApp else { return }
        let target = effectiveMode(saved: mode, launchOverride: QALaunchOptions.current.appearance).appearance
        if app.appearance?.name != target?.name { app.appearance = target }
    }

    nonisolated static func effectiveMode(saved: ThemeMode, launchOverride: ThemeMode?) -> ThemeMode {
        launchOverride ?? saved
    }
}

private struct AppAppearanceModifier: ViewModifier {
    let mode: ThemeMode

    func body(content: Content) -> some View {
        content
            .onAppear { ThemeApplier.apply(mode) }
            .onChange(of: mode) { _, newMode in ThemeApplier.apply(newMode) }
    }
}

public extension View {
    /// Applies the scene's appearance without setting tint or a color palette.
    func appAppearance(_ mode: ThemeMode) -> some View {
        modifier(AppAppearanceModifier(mode: mode))
    }

}
