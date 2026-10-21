import Foundation
import SwiftUI
import Observation

/// Menu requests for Home. The first Home window to observe a pending request consumes it.
@MainActor
@Observable
public final class HomeCommandCenter {
    public enum Request: Equatable, Sendable {
        case addDatabase
        case importConnections
        /// A `keystrand://databases/connect?…` deep link: confirm, then connect; or prefill the Add Database form.
        case openURL(URL)
    }

    /// True for URLs the Home window handles through `.openURL`.
    public static func canHandle(_ url: URL) -> Bool {
        DatabaseDeepLink.parse(url) != nil
    }

    public struct Pending: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let request: Request
    }

    public static let shared = HomeCommandCenter()

    public private(set) var pending: Pending?

    public init() {}

    public func send(_ request: Request) {
        pending = Pending(id: UUID(), request: request)
    }

    public func consume() -> Request? {
        defer { pending = nil }
        return pending?.request
    }
}

/// Home window actions for the menu bar.
public struct HomeCommands {
    /// Number of selected databases in the Home table.
    public var selectionCount: Int
    /// Opens the Export Connections sheet for the selection (File > Export Connections…, ⇧⌘E).
    public var exportSelection: @MainActor () -> Void
    /// Opens Edit Database for the single selected database (Database > Edit Database…, ⌥⌘E).
    public var editSelection: @MainActor () -> Void
    /// Reloads the database list (View > Refresh, ⌘R).
    public var reload: @MainActor () -> Void
    /// Focuses the toolbar search field (Edit > Find > Find…, ⌘F).
    public var focusSearch: @MainActor () -> Void

    public var canExport: Bool { selectionCount > 0 }
    public var canEdit: Bool { selectionCount == 1 }

    public init(selectionCount: Int, exportSelection: @escaping @MainActor () -> Void,
                editSelection: @escaping @MainActor () -> Void, reload: @escaping @MainActor () -> Void,
                focusSearch: @escaping @MainActor () -> Void) {
        self.selectionCount = selectionCount
        self.exportSelection = exportSelection
        self.editSelection = editSelection
        self.reload = reload
        self.focusSearch = focusSearch
    }
}

public extension FocusedValues {
    @Entry var homeCommands: HomeCommands?
}
