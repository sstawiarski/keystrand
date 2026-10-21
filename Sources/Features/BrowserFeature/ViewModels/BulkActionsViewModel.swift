import Foundation
import Observation
import RedisCore

/// Bulk Actions panel: delete keys by filter and upload a file of commands, both streamed from `KeyOperations`.
@MainActor
@Observable
public final class BulkActionsViewModel {
    public enum Tab: Hashable, Sendable {
        case delete
        case upload
    }

    /// 3,000 MB upload limit.
    public nonisolated static let maxUploadBytes = 3_000 * 1_024 * 1_024

    public let session: DatabaseSession
    public var tab: Tab = .delete
    /// Folder delete: pattern + type chosen from the tree instead of the search bar.
    public var filterOverride: BulkActionFilter?

    public private(set) var deleteOverview: BulkActionOverview?
    public private(set) var deleteFilter: BulkActionFilter?
    public var downloadReport = false
    @ObservationIgnored private var deleteTask: Task<Void, Never>?

    public var fileURL: URL? {
        didSet { if fileURL != oldValue { uploadError = nil } }
    }

    public private(set) var uploadSummary: BulkImportSummary?
    public private(set) var uploadFileName: String?
    public private(set) var uploadError: String?
    public private(set) var isUploading = false
    /// The last upload was stopped by the user before it finished.
    public private(set) var uploadWasStopped = false
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var uploadRunID = 0

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var isDeleting: Bool {
        guard let status = deleteOverview?.status else { return false }
        return !status.isFinished
    }

    public var isRunning: Bool { isDeleting || isUploading }

    public var deleteProgress: Int {
        guard let overview = deleteOverview else { return 0 }
        if overview.status == .completed { return 100 }
        return BrowserFormatting.progress(scanned: overview.scanned, total: overview.total)
    }

    /// Status banner text for the delete tab.
    public var deleteStatusText: String? {
        guard let overview = deleteOverview else { return nil }
        switch overview.status {
        case .completed: return "Completed"
        case .aborted: return "Stopped at \(deleteProgress)%"
        case .failed: return overview.error.map { "Failed: \($0)" } ?? "Failed"
        case .disconnected: return "Connection Lost at \(deleteProgress)%"
        default: return "In Progress: \(deleteProgress)%"
        }
    }

    // MARK: - Delete

    /// Runs the bulk delete; returns when it finishes or is stopped. `onFinished` runs after a completed delete.
    public func startDelete(_ filter: BulkActionFilter, onFinished: (@MainActor (BulkActionOverview) -> Void)? = nil) {
        guard !isRunning else { return }
        deleteFilter = filter
        deleteOverview = BulkActionOverview(status: .initializing, filter: filter)
        let stream = KeyOperations(session: session).bulkDelete(filter)
        deleteTask = Task { [weak self] in
            for await overview in stream {
                guard let self else { return }
                if Task.isCancelled { break }
                self.deleteOverview = overview
            }

            guard let self else { return }
            if Task.isCancelled {
                self.markAborted()
            } else if var final = self.deleteOverview, !final.status.isFinished {
                final.status = .aborted
                self.deleteOverview = final
            }

            if let final = self.deleteOverview, final.status.isFinished {
                onFinished?(final)
            }
        }
    }

    /// Waits for the running delete.
    public func waitForDelete() async {
        await deleteTask?.value
    }

    public func stopDelete() {
        deleteTask?.cancel()
        markAborted()
    }

    private func markAborted() {
        guard var overview = deleteOverview, !overview.status.isFinished else { return }
        overview.status = .aborted
        deleteOverview = overview
    }

    /// "Start New": clears the finished delete.
    public func resetDelete() {
        guard !isDeleting else { return }
        deleteOverview = nil
        deleteFilter = nil
    }

    public func reportText(format: KeyNameFormat) -> String? {
        guard let overview = deleteOverview, overview.status.isFinished else { return nil }
        return BrowserFormatting.bulkDeleteReport(overview, format: format)
    }

    public nonisolated static func reportFileName(date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return "bulk-delete-report-\(stamp).txt"
    }

    // MARK: - Upload

    /// Runs the command file. `onFinished` runs only for an upload that ran to the end, never for a stopped one.
    /// `isUploading` stays true until the task has really ended, so a new upload cannot overlap a stopping one.
    public func startUpload(onFinished: (@MainActor (BulkImportSummary) -> Void)? = nil) {
        guard !isRunning, let url = fileURL else { return }
        uploadRunID += 1
        let runID = uploadRunID
        uploadError = nil
        uploadSummary = nil
        uploadWasStopped = false
        uploadFileName = url.lastPathComponent
        isUploading = true
        let session = self.session
        uploadTask = Task { [weak self] in
            let contents: Data
            do {
                contents = try await Task.detached(priority: .userInitiated) {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > Self.maxUploadBytes { throw KeyOperationError.invalid("File should not exceed 3000 MB") }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
            } catch {
                guard let self, runID == self.uploadRunID else { return }
                if !self.uploadWasStopped { self.uploadError = error.localizedDescription }
                self.isUploading = false
                return
            }

            guard !Task.isCancelled else {
                self?.finishStoppedUpload(runID)
                return
            }
            let stream = KeyOperations(session: session).bulkUpload(contents)
            for await summary in stream {
                guard let self, runID == self.uploadRunID else { return }
                if Task.isCancelled { break }
                self.uploadSummary = summary
            }

            guard let self, runID == self.uploadRunID else { return }
            if Task.isCancelled || self.uploadWasStopped {
                self.finishStoppedUpload(runID)
                return
            }

            self.isUploading = false
            if var summary = self.uploadSummary {
                if !summary.isFinished {
                    summary.isFinished = true
                    self.uploadSummary = summary
                }

                onFinished?(summary)
            }
        }
    }

    private func finishStoppedUpload(_ runID: Int) {
        guard runID == uploadRunID else { return }
        uploadWasStopped = true
        isUploading = false
        if var summary = uploadSummary, !summary.isFinished {
            summary.isFinished = true
            uploadSummary = summary
        }
    }

    public func waitForUpload() async {
        await uploadTask?.value
    }

    public func stopUpload() {
        guard isUploading else { return }
        uploadWasStopped = true
        uploadTask?.cancel()
    }

    /// Status banner text for the upload tab.
    public var uploadStatusText: String? {
        guard let summary = uploadSummary else { return nil }
        if uploadWasStopped && !isUploading { return "Stopped" }
        if isUploading && uploadWasStopped { return "Stopping…" }
        return summary.isFinished ? "Completed" : "In Progress"
    }

    public func resetUpload() {
        guard !isUploading else { return }
        uploadSummary = nil
        uploadFileName = nil
        uploadError = nil
        uploadWasStopped = false
        fileURL = nil
    }

    public func cancelAll() {
        deleteTask?.cancel()
        uploadTask?.cancel()
    }
}
