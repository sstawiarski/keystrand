import Foundation
import Observation
import RedisCore

/// Import file normalization (plain JSON array or base64-encoded JSON array).
public enum ImportPayload {
    public static let maxBytes = DatabaseStore.maxImportBytes
    public static let tooLargeMessage = "File should not exceed 10 MB."

    /// Decodes base64 content when the file is not JSON but its base64 decoding is.
    public static func normalize(_ data: Data) -> Data {
        if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil { return data }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]),
              (try? JSONSerialization.jsonObject(with: decoded, options: [.fragmentsAllowed])) != nil else { return data }
        return decoded
    }
}

/// "Import from file" screen state.
@MainActor
@Observable
public final class ImportModel {
    public enum State: Equatable {
        case form
        case loading
        case failed(String)
        case results(DatabaseImportResult)
    }

    public var state: State = .form

    public var fileURL: URL? {
        didSet { validateFile() }
    }

    public private(set) var fileError: String?

    @ObservationIgnored private let services: AppServices

    public init(services: AppServices, fileURL: URL? = nil) {
        self.services = services
        self.fileURL = fileURL
        validateFile()
    }

    public var canSubmit: Bool { fileURL != nil && fileError == nil && state == .form }

    private func validateFile() {
        guard let fileURL else {
            fileError = nil
            return
        }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        fileError = size > ImportPayload.maxBytes ? ImportPayload.tooLargeMessage : nil
    }

    public func submit() async {
        guard let fileURL, canSubmit else { return }
        state = .loading
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                ImportPayload.normalize(try Data(contentsOf: fileURL))
            }.value
            let result = try await services.databaseStore.importDatabases(from: data,
                                                                          filename: fileURL.lastPathComponent)
            state = .results(result)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Imports raw data.
    public func submit(data: Data, filename: String) async {
        state = .loading
        do {
            let normalized = ImportPayload.normalize(data)
            state = .results(try await services.databaseStore.importDatabases(from: normalized, filename: filename))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func retry() {
        state = .form
        keptScripts = []
        scriptError = nil
    }

    // MARK: - Script review

    /// Result indexes whose imported scripts the user chose to keep.
    public private(set) var keptScripts: Set<Int> = []
    public private(set) var scriptError: String?

    /// Imported items that carried scripts (which were not saved).
    public var itemsWithScripts: [DatabaseImportResult.Item] {
        guard case .results(let result) = state else { return [] }
        return result.items.filter { $0.strippedScripts != nil && $0.databaseID != nil }
    }

    /// Saves or removes the reviewed scripts of one imported database.
    public func setKeepScripts(_ keep: Bool, for item: DatabaseImportResult.Item) async {
        guard let id = item.databaseID, let scripts = item.strippedScripts else { return }
        do {
            try await services.databaseStore.restoreScripts(keep ? scripts : nil, for: id)
            scriptError = nil
            if keep { keptScripts.insert(item.index) } else { keptScripts.remove(item.index) }
        } catch {
            scriptError = error.localizedDescription
        }
    }
}
