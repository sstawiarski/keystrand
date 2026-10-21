import Foundation
import RedisCore

/// Persists analysis reports as `Analysis/<databaseId>/<reportId>.json`, keeping the newest `maxReports`.
public actor DatabaseAnalysisStore {
    public static let maxReports = 5

    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    private struct Summary: Decodable {
        var id: UUID
        var createdAt: Date
        var db: Int?
    }

    /// History, newest first. Undecodable files are listed by file date so they can be selected and deleted.
    public func list(databaseID: DatabaseID) -> [ShortDatabaseAnalysis] {
        let directory = paths.analysisDirectory(for: databaseID)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let decoder = JSONFile.makeDecoder()
        let items: [ShortDatabaseAnalysis] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            if let data = try? Data(contentsOf: url), let summary = try? decoder.decode(Summary.self, from: data) {
                return ShortDatabaseAnalysis(id: summary.id, createdAt: summary.createdAt, db: summary.db)
            }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ShortDatabaseAnalysis(id: id, createdAt: modified, db: nil)
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    public func get(_ id: UUID, databaseID: DatabaseID) throws -> DatabaseAnalysisReport {
        let url = fileURL(id, databaseID: databaseID)
        let report: DatabaseAnalysisReport?
        do {
            report = try JSONFile.load(DatabaseAnalysisReport.self, from: url)
        } catch {
            throw AnalysisError.undecodable
        }

        guard let report else { throw AnalysisError.notFound }
        return report
    }

    /// Saves the report and discards everything beyond the newest `maxReports`.
    public func save(_ report: DatabaseAnalysisReport) throws {
        try JSONFile.save(report, to: fileURL(report.id, databaseID: report.databaseId))
        for stale in list(databaseID: report.databaseId).dropFirst(Self.maxReports) {
            JSONFile.discard(fileURL(stale.id, databaseID: report.databaseId))
        }
    }

    public func delete(_ id: UUID, databaseID: DatabaseID) {
        JSONFile.discard(fileURL(id, databaseID: databaseID))
    }

    public func deleteAll(databaseID: DatabaseID) {
        JSONFile.discard(paths.analysisDirectory(for: databaseID))
    }

    private func fileURL(_ id: UUID, databaseID: DatabaseID) -> URL {
        paths.analysisDirectory(for: databaseID).appendingPathComponent("\(id.uuidString).json")
    }
}
