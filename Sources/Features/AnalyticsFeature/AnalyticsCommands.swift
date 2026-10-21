import SwiftUI

/// Menu bar actions for Analytics. Equality covers only menu state; each action requires its flag to be true.
public struct AnalyticsCommands: Equatable {
    public var newReport: @MainActor () -> Void
    public var canCreateReport: Bool
    /// Presents the Clear Slow Log confirmation.
    public var clearSlowLog: @MainActor () -> Void
    public var canClearSlowLog: Bool

    public init(newReport: @escaping @MainActor () -> Void = {}, canCreateReport: Bool = false,
                clearSlowLog: @escaping @MainActor () -> Void = {}, canClearSlowLog: Bool = false) {
        self.newReport = newReport
        self.canCreateReport = canCreateReport
        self.clearSlowLog = clearSlowLog
        self.canClearSlowLog = canClearSlowLog
    }

    public static func == (lhs: AnalyticsCommands, rhs: AnalyticsCommands) -> Bool {
        lhs.canCreateReport == rhs.canCreateReport && lhs.canClearSlowLog == rhs.canClearSlowLog
    }
}

public extension FocusedValues {
    @Entry var analyticsCommands: AnalyticsCommands?
}
