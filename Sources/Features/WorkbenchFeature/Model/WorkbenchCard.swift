import Foundation
import Observation
import RedisCore

/// UI state of one result card. `execution.id` is the persisted history id once the run finished.
@MainActor
@Observable
public final class WorkbenchCard: Identifiable {
    public let id: UUID
    public var execution: CommandExecution
    public var isOpen: Bool
    /// The command is still executing (placeholder card).
    public var isRunning: Bool
    /// The stored result is being read from history (lazy load on expand).
    public var isLoadingResult = false
    /// Saved in history (deleting it also deletes the history entry).
    public var isPersisted: Bool
    public var selectedView: WorkbenchViewKind
    /// Number of commands in a running group/silent card.
    public var commandCount: Int
    /// Rendered Text view lines (built off the main actor).
    public private(set) var lines: [ResultLine]?
    public var loadError: String?
    /// Only the first render after a live run shows the result-too-large warning.
    public var showsNotStoredWarning = false
    /// Visualization message shown in the header while collapsed (`Matched:42` once the search table rendered).
    public var headerMessage: String?

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var cachedNotice: (command: String, notice: WorkbenchResultFormatter.Notice?)?

    public init(execution: CommandExecution, isOpen: Bool, isRunning: Bool, isPersisted: Bool,
                selectedView: WorkbenchViewKind = .text, commandCount: Int = 1) {
        self.id = UUID()
        self.execution = execution
        self.isOpen = isOpen
        self.isRunning = isRunning
        self.isPersisted = isPersisted
        self.selectedView = selectedView
        self.commandCount = commandCount
    }

    public var isGroup: Bool { execution.resultsMode != .default }

    public var result: CommandExecutionResult? { execution.result?.first }

    /// Silent cards without errors cannot be expanded.
    public var isExpandable: Bool {
        if isRunning { return false }
        if execution.resultsMode == .silent { return (execution.summary?.fail ?? 0) > 0 }
        return true
    }

    public var title: String {
        if isGroup {
            return WorkbenchResultFormatter.summaryText(execution.summary, resultsMode: execution.resultsMode,
                                                        commandCount: commandCount, isRunning: isRunning)
        }

        return WorkbenchResultFormatter.title(command: execution.command, db: execution.db)
    }

    /// Guidance or unsupported message shown instead of the result, parsed once per command.
    var notice: WorkbenchResultFormatter.Notice? {
        if let cachedNotice, cachedNotice.command == execution.command { return cachedNotice.notice }
        let notice = WorkbenchResultFormatter.notice(for: execution.command)
        cachedNotice = (execution.command, notice)
        return notice
    }

    public var viewOptions: [WorkbenchViewKind] {
        guard !isGroup, result?.sizeLimitExceeded != true else { return [.text] }
        return VisualizationRegistry.options(for: execution.command)
    }

    /// Builds Text view lines off the main actor; the returned task completes when they are ready.
    @discardableResult
    public func renderText() -> Task<Void, Never> {
        renderTask?.cancel()
        guard execution.result != nil else {
            lines = nil
            return Task {}
        }
        let execution = self.execution
        let task = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                WorkbenchResultFormatter.lines(for: execution)
            }.value
            guard !Task.isCancelled else { return }
            self?.lines = built
        }
        renderTask = task
        return task
    }

    public func setLines(_ lines: [ResultLine]?) {
        self.lines = lines
    }
}

/// Time series chart options persisted per database (`workbench.tsPreferences`).
public struct TimeSeriesChartConfig: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case line, points }
    public enum TimeUnit: String, Codable, Sendable, CaseIterable { case milliseconds, seconds }

    public var mode: Mode
    /// nil = pick from the data (milliseconds when the first timestamp is beyond 1e10).
    public var timeUnit: TimeUnit?
    public var staircase: Bool
    public var fill: Bool

    public init(mode: Mode = .line, timeUnit: TimeUnit? = nil, staircase: Bool = false, fill: Bool = true) {
        self.mode = mode
        self.timeUnit = timeUnit
        self.staircase = staircase
        self.fill = fill
    }
}

public struct TimeSeriesPreferences: Codable, Hashable, Sendable {
    /// `"text"` or `"chart"`.
    public var selectedView: String
    public var chartConfig: TimeSeriesChartConfig

    public static let featureKey = "workbench.tsPreferences"

    public init(selectedView: String = "chart", chartConfig: TimeSeriesChartConfig = TimeSeriesChartConfig()) {
        self.selectedView = selectedView
        self.chartConfig = chartConfig
    }
}
