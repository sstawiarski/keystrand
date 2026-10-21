import RedisCore
import SwiftUI

/// Browser menu bar actions. Equality covers only menu state; actions read current state when they run.
public struct BrowserCommands: Equatable {
    public var hasSelectedKey: Bool
    public var isTreeAvailable: Bool
    public var viewType: KeyViewType
    public var newKey: @MainActor () -> Void
    public var copyKeyName: @MainActor () -> Void
    public var renameKey: @MainActor () -> Void
    public var setTTL: @MainActor () -> Void
    public var deleteKey: @MainActor () -> Void
    public var deleteKeysMatchingFilter: @MainActor () -> Void
    public var uploadCommands: @MainActor () -> Void
    public var showViewOptions: @MainActor () -> Void
    public var setViewType: @MainActor (KeyViewType) -> Void
    public var focusSearch: @MainActor () -> Void
    /// A key is open in the details pane, so the key list can be hidden.
    public var canHideList = false
    public var isListHidden = false
    public var toggleListHidden: @MainActor () -> Void = {}

    public init(hasSelectedKey: Bool, isTreeAvailable: Bool, viewType: KeyViewType,
                newKey: @escaping @MainActor () -> Void, copyKeyName: @escaping @MainActor () -> Void,
                renameKey: @escaping @MainActor () -> Void, setTTL: @escaping @MainActor () -> Void,
                deleteKey: @escaping @MainActor () -> Void, deleteKeysMatchingFilter: @escaping @MainActor () -> Void,
                uploadCommands: @escaping @MainActor () -> Void, showViewOptions: @escaping @MainActor () -> Void,
                setViewType: @escaping @MainActor (KeyViewType) -> Void, focusSearch: @escaping @MainActor () -> Void) {
        self.hasSelectedKey = hasSelectedKey
        self.isTreeAvailable = isTreeAvailable
        self.viewType = viewType
        self.newKey = newKey
        self.copyKeyName = copyKeyName
        self.renameKey = renameKey
        self.setTTL = setTTL
        self.deleteKey = deleteKey
        self.deleteKeysMatchingFilter = deleteKeysMatchingFilter
        self.uploadCommands = uploadCommands
        self.showViewOptions = showViewOptions
        self.setViewType = setViewType
        self.focusSearch = focusSearch
    }

    public static func == (lhs: BrowserCommands, rhs: BrowserCommands) -> Bool {
        lhs.hasSelectedKey == rhs.hasSelectedKey && lhs.isTreeAvailable == rhs.isTreeAvailable
            && lhs.viewType == rhs.viewType && lhs.canHideList == rhs.canHideList
            && lhs.isListHidden == rhs.isListHidden
    }
}

public extension FocusedValues {
    @Entry var browserCommands: BrowserCommands?
}
