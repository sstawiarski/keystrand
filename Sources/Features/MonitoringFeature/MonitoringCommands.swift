import SwiftUI

/// Menu bar action for the open Profiler pane.
public struct ProfilerCommands {
    /// "Start Profiler", "Pause Profiler" or "Resume Profiler".
    public var title: String
    public var isEnabled: Bool
    public var toggle: @MainActor () -> Void

    public init(title: String, isEnabled: Bool, toggle: @escaping @MainActor () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.toggle = toggle
    }
}

public extension FocusedValues {
    @Entry var profilerCommands: ProfilerCommands?
}
