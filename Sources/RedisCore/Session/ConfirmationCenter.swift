import Foundation
import Observation

/// A destructive action that needs confirmation on production databases.
public struct ConfirmationRequest: Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var message: String?
    /// Scope of the "Don't ask again this session" checkbox; nil hides the checkbox.
    public var actionID: String?
    public var confirmButtonTitle: String
    /// If true, requires typing the database name; otherwise shows a plain Cancel / Confirm sheet.
    public var requiresTyping: Bool

    public init(id: UUID = UUID(), title: String = "Confirm action", message: String? = nil, actionID: String? = nil,
                confirmButtonTitle: String = "Confirm", requiresTyping: Bool = true) {
        self.id = id
        self.title = title
        self.message = message
        self.actionID = actionID
        self.confirmButtonTitle = confirmButtonTitle
        self.requiresTyping = requiresTyping
    }
}

/// Production-environment confirmations for one database session. AppShell presents `pending` with RedisUI's
/// `.productionConfirmations` (dialog or type-to-confirm alert) and sheets with `.sheetAlerts`; both call `resolve`.
@MainActor
@Observable
public final class ConfirmationCenter {
    public private(set) var pending: ConfirmationRequest?
    /// Text the user must type (database name, or host:port).
    public private(set) var confirmationText: String = ""
    public private(set) var skippedActionIDs: Set<String> = []
    public var isProduction: Bool = false
    /// Sheet-level presenters attached to this center; only the innermost one presents.
    public let presenters = PresenterDepth()

    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    public init() {}

    /// Returns true immediately when not production or the action was skipped for this session;
    /// otherwise waits for the user's answer.
    public func confirm(_ request: ConfirmationRequest, typing text: String) async -> Bool {
        guard isProduction else { return true }
        if let actionID = request.actionID, skippedActionIDs.contains(actionID) { return true }
        continuation?.resume(returning: false)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.confirmationText = text
            self.pending = request
        }
    }

    public func resolve(confirmed: Bool, skipForSession: Bool = false) {
        if confirmed, skipForSession, let actionID = pending?.actionID { skippedActionIDs.insert(actionID) }
        pending = nil
        continuation?.resume(returning: confirmed)
        continuation = nil
    }

    /// Called when the logical database or the database changes.
    public func resetSkips() {
        skippedActionIDs.removeAll()
    }
}
