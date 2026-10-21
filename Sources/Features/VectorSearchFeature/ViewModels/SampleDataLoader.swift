import Foundation
import RedisUI

enum SampleDataError: Error, LocalizedError, Equatable {
    case importFailed(String)
    case wrongDatabase

    var errorDescription: String? {
        switch self {
        case .importFailed(let message): return message
        case .wrongDatabase: return VectorSearchStrings.wrongDatabaseReason
        }
    }
}

/// Imports the bundled command file, creates its fixed index, and seeds sample queries in the Query Library.
@MainActor
struct SampleDataLoader {
    enum Outcome: Equatable {
        case created(BulkImportSummary)
        case alreadyExists
        /// The production confirmation was declined; nothing was written.
        case cancelled
    }

    let session: DatabaseSession

    func indexExists(_ name: String) async throws -> Bool {
        try await SearchIndexService(session: session).listIndexes().contains(Data(name.utf8))
    }

    func load(_ dataset: SampleDataset,
              onProgress: @escaping @MainActor (BulkImportSummary) -> Void = { _ in }) async throws -> Outcome {
        if try await indexExists(dataset.indexName) {
            try await seedQueries(dataset)
            return .alreadyExists
        }
        if QuerySafety.indexCreationBlockedReason(session) != nil { throw SampleDataError.wrongDatabase }

        guard await session.confirm(Self.confirmation(dataset, databaseName: session.confirmationName)) else {
            return .cancelled
        }
        let data = try await Task.detached(priority: .userInitiated) {
            try SampleDatasets.commandData(for: dataset)
        }.value
        var summary = BulkImportSummary()
        for await progress in CommandFileImporter(session: session).run(data) {
            summary = progress
            onProgress(progress)
        }

        if summary.processed > 0, summary.succeeded == 0 {
            throw SampleDataError.importFailed(summary.errors.first ?? "The sample data could not be imported.")
        }

        let args = try CommandLineSplitter.split(WorkbenchScriptParser.multilineToOneLine(dataset.createCommand))
        _ = try await session.execute(args)
        SearchIndexService(session: session).invalidateSummaries()
        try await seedQueries(dataset)
        return .created(summary)
    }

    static func confirmation(_ dataset: SampleDataset, databaseName: String) -> ConfirmationRequest {
        ConfirmationRequest(
            title: "Load sample data",
            message: "Load the \(dataset.displayName) sample data into \(databaseName)? This writes keys under the "
                + "\"\(dataset.indexPrefix)\" prefix, overwrites existing keys with the same names, and creates the index "
                + "\(dataset.indexName).",
            actionID: "vs-load-sample", confirmButtonTitle: "Load sample data")
    }

    func seedQueries(_ dataset: SampleDataset) async throws {
        try await session.services.queryLibraryStore.seed(SampleDatasets.libraryItems(for: dataset, databaseID: session.id))
    }
}
