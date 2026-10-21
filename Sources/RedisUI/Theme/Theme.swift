import AppKit
import SwiftUI

public extension NSAppearance {
    /// Used by AppKit-backed views that must pick between appearance-specific drawing; colors stay system colors.
    var isDarkMode: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

public extension AppTheme {
    /// `nil` = follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// AppKit appearance to force, or nil to follow the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}
