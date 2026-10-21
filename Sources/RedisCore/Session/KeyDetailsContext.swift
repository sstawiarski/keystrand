import Foundation
import Observation

/// Mutable state of the open key shared by the Browser host, the header, and the type view.
@MainActor
@Observable
public final class KeyDetailsState {
    public let key: Data
    public var info: KeyInfo?
    /// Disables the header Refresh button (e.g. while an inline editor is open).
    public var isRefreshDisabled = false
    public var isFullScreen = false
    public var isAddPanelOpen = false
    /// An inline editor holds edits that were not saved; the Browser asks before opening another key.
    public var hasUnsavedChanges = false
    /// Incremented by the header Refresh button and auto-refresh; type views reload when it changes.
    public private(set) var refreshGeneration = 0

    public init(key: Data, info: KeyInfo? = nil) {
        self.key = key
        self.info = info
    }

    @ObservationIgnored private var refreshLockOwners: Set<String> = []

    public func requestRefresh() {
        refreshGeneration += 1
    }

    /// Combines the "editing" flags of the header and the type view into `isRefreshDisabled`.
    public func setRefreshLock(owner: String, locked: Bool) {
        if locked { refreshLockOwners.insert(owner) } else { refreshLockOwners.remove(owner) }
        isRefreshDisabled = !refreshLockOwners.isEmpty
    }
}

/// Session, key state and callbacks passed to an injected key-type view.
public struct KeyDetailsContext {
    public let session: DatabaseSession
    public let key: Data
    public let type: KeyType
    public let state: KeyDetailsState
    /// The key was renamed; the Browser updates its list and selection.
    public var onKeyRenamed: @MainActor (_ newName: Data) -> Void
    /// The key no longer exists (deleted, TTL 0, last element removed): close details and remove from list.
    public var onKeyDeleted: @MainActor () -> Void
    /// Value/TTL/size changed: the Browser refreshes the row metadata.
    public var onKeyChanged: @MainActor () -> Void
    public var onClose: @MainActor () -> Void
    public var onToggleFullScreen: @MainActor () -> Void
    /// Re-runs the key info pipeline (header) and updates `state.info`.
    public var refreshKeyInfo: @MainActor () async -> Void

    public init(session: DatabaseSession, key: Data, type: KeyType, state: KeyDetailsState,
                onKeyRenamed: @escaping @MainActor (Data) -> Void = { _ in },
                onKeyDeleted: @escaping @MainActor () -> Void = {},
                onKeyChanged: @escaping @MainActor () -> Void = {},
                onClose: @escaping @MainActor () -> Void = {},
                onToggleFullScreen: @escaping @MainActor () -> Void = {},
                refreshKeyInfo: @escaping @MainActor () async -> Void = {}) {
        self.session = session
        self.key = key
        self.type = type
        self.state = state
        self.onKeyRenamed = onKeyRenamed
        self.onKeyDeleted = onKeyDeleted
        self.onKeyChanged = onKeyChanged
        self.onClose = onClose
        self.onToggleFullScreen = onToggleFullScreen
        self.refreshKeyInfo = refreshKeyInfo
    }

    /// Asks for confirmation on production databases (always true elsewhere). Key edits never require typing the
    /// database name; the sheet only offers Cancel / Confirm and "Don't ask again".
    @MainActor
    public func confirmProduction(_ request: ConfirmationRequest) async -> Bool {
        var request = request
        request.requiresTyping = false
        return await session.confirm(request)
    }
}

public extension KeyDetailsContext {
    /// Key name in the database's key-name format (HEX or Unicode).
    @MainActor
    var keyDisplayName: String { RedisKeyName(key).displayString(format: session.config.keyNameFormat) }

    /// Key name for dialog and alert text (68 characters, the last 15 kept).
    @MainActor
    var keyShortName: String { TextTruncation.formatLongName(keyDisplayName, maxLength: 68, tail: 15) }

    @MainActor
    func confirmWrite(title: String, message: String, button: String, actionID: String?) async -> Bool {
        await confirmProduction(ConfirmationRequest(title: title, message: message, actionID: actionID,
                                                    confirmButtonTitle: button))
    }

    /// Shows an error alert; when the key is gone, also closes the details and removes it from the list.
    @MainActor
    func report(_ error: Error, title: String = "Error") {
        if error is CancellationError { return }
        session.toasts.error(error, title: title)
        if KeyOperationError.isKeyNotFound(error) { onKeyDeleted() }
    }

    /// The last element was removed (Redis deleted the key) or the key expired.
    @MainActor
    func keyWasDeleted() {
        onKeyDeleted()
    }
}

/// Rebuilds a key-type view and its model when the key, details state or logical database changes.
public struct KeyDetailsIdentity: Hashable {
    public let key: Data
    public let state: ObjectIdentifier
    public let dbGeneration: Int

    @MainActor
    public init(_ context: KeyDetailsContext) {
        key = context.key
        state = ObjectIdentifier(context.state)
        dbGeneration = context.session.dbGeneration
    }
}

/// Production confirmations for key writes. Each id is the "Don't ask again this session" scope of one action.
public enum KeyConfirmations {
    public static let editValue = "browser:edit-value"
    public static let addListElements = "browser:add-list-elements"
    public static let addSetMembers = "browser:add-set-members"
    public static let addHashFields = "browser:add-hash-fields"
    public static let renameKey = "browser:rename-key"
    public static let changeTTL = "browser:change-ttl"
    public static let deleteKey = "browser:delete-key"
    public static let removeItems = "browser:remove-items"
    public static let editJSONValue = "browser:edit-json-value"
    public static let addZSetMembers = "browser:add-zset-members"
    public static let addStreamEntry = "browser:add-stream-entry"
    public static let editStreamGroups = "browser:edit-stream-groups"
    public static let claimStreamMessages = "browser:claim-stream-messages"
    public static let editArrayElement = "browser:edit-array-element"
    public static let addArrayElement = "browser:add-array-element"
    public static let addTimeSeriesSample = "browser:add-ts-sample"
    public static let deleteTimeSeriesSamples = "browser:delete-ts-samples"
    public static let editTimeSeries = "browser:edit-ts-settings"
    public static let editVectorAttributes = "browser:edit-vector-attributes"
    public static let addVectorElements = "browser:add-vector-elements"

    public static func rename(_ name: String, to newName: String) -> ConfirmationRequest {
        ConfirmationRequest(title: "Rename Key in Production?",
                            message: "\(name) will be renamed to \(newName). This database is marked as production.",
                            actionID: renameKey, confirmButtonTitle: "Rename", requiresTyping: false)
    }

    /// `seconds < 0` removes the TTL; 0 deletes the key.
    public static func changeTTL(_ name: String, seconds: Int) -> ConfirmationRequest {
        if seconds == 0 { return deleteKey(name) }
        let change = seconds < 0 ? "\(name) will no longer expire." : "The TTL of \(name) will be set to \(seconds) s."
        return ConfirmationRequest(
            title: "Change TTL in Production?",
            message: "\(change) This database is marked as production.",
            actionID: changeTTL, confirmButtonTitle: "Change TTL", requiresTyping: false)
    }

    public static func deleteKey(_ name: String) -> ConfirmationRequest {
        ConfirmationRequest(title: "Delete Key in Production?",
                            message: "\(name) will be deleted. This database is marked as production.",
                            actionID: deleteKey, confirmButtonTitle: "Delete", requiresTyping: false)
    }

    /// Removing items that are not individually confirmed (list pop, field TTL 0).
    public static func removeItems(_ items: String, from name: String) -> ConfirmationRequest {
        ConfirmationRequest(title: "Remove Items in Production?",
                            message: "\(items) will be removed from \(name). This database is marked as production.",
                            actionID: removeItems, confirmButtonTitle: "Remove", requiresTyping: false)
    }
}

/// Footer state an injected Add Key form hands to the host sheet, so the sheet's own "Add Key" button submits it.
public struct AddKeyFormSubmission {
    public var canSubmit: Bool
    public var isSaving: Bool
    public var validationMessage: String?
    public var submit: @MainActor () -> Void

    public init(canSubmit: Bool, isSaving: Bool, validationMessage: String?, submit: @escaping @MainActor () -> Void) {
        self.canSubmit = canSubmit
        self.isSaving = isSaving
        self.validationMessage = validationMessage
        self.submit = submit
    }
}

/// Context for an injected Add Key form section.
public struct AddKeyFormContext {
    public let session: DatabaseSession
    /// Current key name / TTL typed in the Browser's common Add Key fields.
    public var keyName: @MainActor () -> Data
    public var ttl: @MainActor () -> Int?
    public var onKeyAdded: @MainActor (_ name: Data) -> Void
    public var onCancel: @MainActor () -> Void
    /// The form reports its footer state here whenever it changes; the host renders the footer.
    public var publishSubmission: @MainActor (AddKeyFormSubmission) -> Void

    public init(session: DatabaseSession, keyName: @escaping @MainActor () -> Data, ttl: @escaping @MainActor () -> Int?,
                onKeyAdded: @escaping @MainActor (Data) -> Void, onCancel: @escaping @MainActor () -> Void,
                publishSubmission: @escaping @MainActor (AddKeyFormSubmission) -> Void = { _ in }) {
        self.session = session
        self.keyName = keyName
        self.ttl = ttl
        self.onKeyAdded = onKeyAdded
        self.onCancel = onCancel
        self.publishSubmission = publishSubmission
    }
}
