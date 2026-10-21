import Foundation

public struct SearchHistoryItem: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var mode: SearchMode
    public var match: String
    public var type: KeyType?
    public var createdAt: Date

    public init(id: UUID = UUID(), mode: SearchMode, match: String, type: KeyType? = nil, createdAt: Date = Date()) {
        self.id = id
        self.mode = mode
        self.match = match
        self.type = type
        self.createdAt = createdAt
    }
}

public enum BulkActionStatus: String, Codable, Sendable, Hashable {
    case initializing, initialized, preparing, ready, running, completed, failed, aborted, disconnected

    public var isFinished: Bool { [.completed, .failed, .aborted, .disconnected].contains(self) }
}

public struct BulkActionFilter: Hashable, Sendable {
    public var match: String
    public var type: KeyType?
    /// SCAN COUNT per node iteration.
    public var count: Int

    public init(match: String = "*", type: KeyType? = nil, count: Int = 10_000) {
        self.match = match
        self.type = type
        self.count = count
    }
}

public struct BulkActionError: Hashable, Sendable {
    public var key: Data
    public var error: String

    public init(key: Data, error: String) {
        self.key = key
        self.error = error
    }
}

/// Progress snapshot emitted (throttled to 1 s) while a bulk delete runs.
public struct BulkActionOverview: Hashable, Sendable {
    public var status: BulkActionStatus
    public var total: Int
    public var scanned: Int
    public var processed: Int
    public var succeeded: Int
    public var failed: Int
    /// First errors only (bounded).
    public var errors: [BulkActionError]
    /// Seconds.
    public var duration: TimeInterval
    public var filter: BulkActionFilter
    public var error: String?

    public init(status: BulkActionStatus = .initializing, total: Int = 0, scanned: Int = 0, processed: Int = 0,
                succeeded: Int = 0, failed: Int = 0, errors: [BulkActionError] = [], duration: TimeInterval = 0,
                filter: BulkActionFilter = BulkActionFilter(), error: String? = nil) {
        self.status = status
        self.total = total
        self.scanned = scanned
        self.processed = processed
        self.succeeded = succeeded
        self.failed = failed
        self.errors = errors
        self.duration = duration
        self.filter = filter
        self.error = error
    }
}

/// Progress/summary of importing a file of commands (bulk upload, sample data).
public struct BulkImportSummary: Hashable, Sendable {
    public var processed: Int
    public var succeeded: Int
    public var failed: Int
    public var errors: [String]
    public var duration: TimeInterval
    public var isFinished: Bool

    public init(processed: Int = 0, succeeded: Int = 0, failed: Int = 0, errors: [String] = [],
                duration: TimeInterval = 0, isFinished: Bool = false) {
        self.processed = processed
        self.succeeded = succeeded
        self.failed = failed
        self.errors = errors
        self.duration = duration
        self.isFinished = isFinished
    }
}

/// Request from another feature to show something in the Browser.
public struct BrowserNavigationRequest: Hashable, Sendable {
    public var pattern: String
    public var typeFilter: KeyType?
    public var selectedKey: Data?
    public var treeDelimiter: String?
    public var switchToTreeView: Bool

    public init(pattern: String = "*", typeFilter: KeyType? = nil, selectedKey: Data? = nil,
                treeDelimiter: String? = nil, switchToTreeView: Bool = false) {
        self.pattern = pattern
        self.typeFilter = typeFilter
        self.selectedKey = selectedKey
        self.treeDelimiter = treeDelimiter
        self.switchToTreeView = switchToTreeView
    }
}
