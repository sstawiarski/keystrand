import Foundation
import Observation
import RedisUI

/// Computes result text, tables, and JSON off the main actor when the card first opens.
@Observable
@MainActor
final class ResultCardModel: Identifiable {
    let id = UUID()
    private(set) var execution: CommandExecution
    var isOpen: Bool
    private(set) var isLoading: Bool
    private(set) var content: ResultContent?
    private(set) var isComputing = false
    private(set) var loadError: String?
    var selectedView: ResultViewKind?
    private var contentTask: Task<Void, Never>?

    init(execution: CommandExecution, isOpen: Bool, isLoading: Bool = false) {
        self.execution = execution
        self.isOpen = isOpen
        self.isLoading = isLoading
    }

    var command: String { execution.command }
    var hasResult: Bool { execution.result != nil }
    var isFailed: Bool { execution.result?.first?.status == .fail }
    var isSearchCommand: Bool { QueryCommands.parseSearchCommand(execution.command) != nil }

    var effectiveView: ResultViewKind {
        guard let content else { return .text }
        if let selectedView, content.availableViews.contains(selectedView) { return selectedView }
        return content.defaultView
    }

    func complete(with execution: CommandExecution) {
        self.execution = execution
        isLoading = false
        isOpen = true
        loadError = nil
        content = nil
        computeContent()
    }

    func fail(_ message: String) {
        execution.result = [CommandExecutionResult(status: .fail, response: .reply(.error(message)))]
        isLoading = false
        isOpen = true
        content = nil
        computeContent()
    }

    func setLoadError(_ message: String) {
        loadError = message
    }

    func attachResult(_ full: CommandExecution) {
        execution.result = full.result
        loadError = nil
        computeContent()
    }

    func computeContent() {
        guard content == nil, execution.result != nil, !isComputing else { return }
        isComputing = true
        let execution = self.execution
        contentTask = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                SearchResultParser.content(for: execution)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.content = computed
            self.isComputing = false
        }
    }

    // MARK: - Header text

    var title: String {
        let db = execution.db.map { $0 != 0 ? "[db\($0)] " : "" } ?? ""
        return db + execution.command.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    var executionTimeText: String? {
        guard let micros = execution.executionTime, !isLoading else { return nil }
        return Self.durationText(microseconds: micros)
    }

    var executionTimeTooltip: String? {
        guard let micros = execution.executionTime else { return nil }
        let ms = Double(micros) / 1000
        return "Processing Time: \(Self.groupedMilliseconds(ms)) msec"
    }

    nonisolated static func durationText(microseconds: Int) -> String {
        if microseconds < 1 { return "0.001 msec" }
        let ms = Double(microseconds) / 1000
        if ms < 1000 {
            return ms < 1 ? String(format: "%.3f msec", ms) : "\(Int(ms)) msec"
        }

        return DurationText.firstUnit(seconds: Int(ms / 1000))
    }

    static func groupedMilliseconds(_ ms: Double) -> String {
        let whole = Int(ms)
        let fraction = String(format: "%.3f", ms - Double(whole)).dropFirst(1)
        return NumberFormatting.grouped(whole) + fraction
    }
}
