import Foundation

public enum ResultsMode: String, Codable, Sendable, Hashable, CaseIterable {
    case `default` = "DEFAULT"
    case group = "GROUP_MODE"
    case silent = "SILENT"
}

public enum CommandExecutionType: String, Codable, Sendable, Hashable, CaseIterable {
    case workbench = "WORKBENCH"
    case search = "SEARCH"
}

public enum CommandExecutionStatus: String, Codable, Sendable, Hashable {
    case success
    case fail
}

public struct GroupItemResult: Codable, Hashable, Sendable {
    public var command: String
    public var response: ReplyNode
    public var status: CommandExecutionStatus

    public init(command: String, response: ReplyNode, status: CommandExecutionStatus) {
        self.command = command
        self.response = response
        self.status = status
    }
}

public enum CommandResponse: Codable, Hashable, Sendable {
    case reply(ReplyNode)
    case group([GroupItemResult])
    case message(String)
}

public struct CommandExecutionResult: Codable, Hashable, Sendable {
    public var status: CommandExecutionStatus
    public var response: CommandResponse
    public var sizeLimitExceeded: Bool?

    public init(status: CommandExecutionStatus, response: CommandResponse, sizeLimitExceeded: Bool? = nil) {
        self.status = status
        self.response = response
        self.sizeLimitExceeded = sizeLimitExceeded
    }
}

public struct ResultsSummary: Codable, Hashable, Sendable {
    public var total: Int
    public var success: Int
    public var fail: Int

    public init(total: Int, success: Int, fail: Int) {
        self.total = total
        self.success = success
        self.fail = fail
    }
}

/// One persisted Workbench or Vector Search execution.
public struct CommandExecution: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var databaseId: DatabaseID
    /// Group mode: commands joined with "\r\n".
    public var command: String
    public var mode: RunQueryMode
    public var resultsMode: ResultsMode
    public var type: CommandExecutionType
    public var summary: ResultsSummary?
    /// `nil` in list loads (results load lazily on expand).
    public var result: [CommandExecutionResult]?
    /// Transient; never persisted.
    public var isNotStored: Bool?
    public var createdAt: Date
    /// Microseconds.
    public var executionTime: Int?
    public var db: Int?

    public init(id: UUID = UUID(), databaseId: DatabaseID, command: String, mode: RunQueryMode = .ascii,
                resultsMode: ResultsMode = .default, type: CommandExecutionType = .workbench,
                summary: ResultsSummary? = nil, result: [CommandExecutionResult]? = nil, isNotStored: Bool? = nil,
                createdAt: Date = Date(), executionTime: Int? = nil, db: Int? = nil) {
        self.id = id
        self.databaseId = databaseId
        self.command = command
        self.mode = mode
        self.resultsMode = resultsMode
        self.type = type
        self.summary = summary
        self.result = result
        self.isNotStored = isNotStored
        self.createdAt = createdAt
        self.executionTime = executionTime
        self.db = db
    }
}

public struct ExecuteParams: Hashable, Sendable {
    /// 0/1 = no batching; nil = Settings value.
    public var batchSize: Int?
    public var mode: RunQueryMode?
    public var resultsMode: ResultsMode?
    public var runConfirmation: Bool?
    public var executable: Bool?
    public var clearEditor: Bool

    public init(batchSize: Int? = nil, mode: RunQueryMode? = nil, resultsMode: ResultsMode? = nil,
                runConfirmation: Bool? = nil, executable: Bool? = nil, clearEditor: Bool = true) {
        self.batchSize = batchSize
        self.mode = mode
        self.resultsMode = resultsMode
        self.runConfirmation = runConfirmation
        self.executable = executable
        self.clearEditor = clearEditor
    }
}

public enum QueryLibraryType: String, Codable, Sendable, Hashable {
    case sample = "SAMPLE"
    case saved = "SAVED"
}

public struct QueryLibraryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var databaseId: DatabaseID
    public var indexName: String
    public var type: QueryLibraryType
    public var name: String
    public var description: String?
    public var query: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), databaseId: DatabaseID, indexName: String, type: QueryLibraryType = .saved,
                name: String, description: String? = nil, query: String, createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.databaseId = databaseId
        self.indexName = indexName
        self.type = type
        self.name = name
        self.description = description
        self.query = query
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
