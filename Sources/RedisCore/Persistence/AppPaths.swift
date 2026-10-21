import Foundation

/// On-disk layout under `~/Library/Application Support/Keystrand` (tests pass a temp root).
public struct AppPaths: Hashable, Sendable {
    /// Environment variable whose value, when set, replaces the whole data root (isolated launches and scripts).
    public static let dataDirectoryEnvironmentKey = "KEYSTRAND_DATA_DIR"

    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: AppPaths {
        resolved(environment: ProcessInfo.processInfo.environment)
    }

    /// `KEYSTRAND_DATA_DIR` (tilde-expanded) when it is set and not blank, otherwise Application Support/Keystrand.
    public static func resolved(environment: [String: String]) -> AppPaths {
        if let override = environment[dataDirectoryEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return AppPaths(root: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppPaths(root: base.appendingPathComponent("Keystrand", isDirectory: true))
    }

    /// Fresh unique directory in the temp folder (tests / previews).
    public static func temporary() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystrand-\(UUID().uuidString)", isDirectory: true))
    }

    public var databasesFile: URL { root.appendingPathComponent("databases.json") }
    public var certificatesFile: URL { root.appendingPathComponent("certificates.json") }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var queryLibraryFile: URL { root.appendingPathComponent("QueryLibrary.json") }
    public var databaseSettingsDirectory: URL { root.appendingPathComponent("database-settings", isDirectory: true) }
    public var workbenchDirectory: URL { root.appendingPathComponent("workbench", isDirectory: true) }
    public var analysisRoot: URL { root.appendingPathComponent("Analysis", isDirectory: true) }
    public var profilerLogsDirectory: URL { root.appendingPathComponent("ProfilerLogs", isDirectory: true) }

    public func databaseSettingsFile(for id: DatabaseID) -> URL {
        databaseSettingsDirectory.appendingPathComponent("\(id.rawValue).json")
    }

    public func analysisDirectory(for id: DatabaseID) -> URL {
        analysisRoot.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    public func commandHistoryFile(for id: DatabaseID, type: CommandExecutionType) -> URL {
        let suffix = type == .search ? "-search" : ""
        return workbenchDirectory.appendingPathComponent("\(id.rawValue)\(suffix).json")
    }
}

/// Atomic JSON read/write helpers (ISO-8601 dates, base64 Data).
public enum JSONFile {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Same date and data strategies as `makeEncoder`, without whitespace or key sorting (large files).
    public static func makeCompactEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Returns nil when the file does not exist.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try makeDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeEncoder().encode(value).write(to: url, options: .atomic)
    }

    /// Loads a JSON array, dropping elements that fail to decode. Returns [] if the file is missing.
    /// If the file is unreadable or drops elements, first copies it to `<name>.damaged-<timestamp>.json`
    /// so the next save cannot destroy the original data.
    public static func loadArrayPreservingDamaged<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let elements = try? makeDecoder().decode([Failable<T>].self, from: data) else {
            preserveDamaged(url)
            return []
        }
        let values = elements.compactMap(\.value)
        if values.count != elements.count { preserveDamaged(url) }
        return values
    }

    /// Copies `url` to `<name>.damaged-<timestamp>.<ext>` in the same folder.
    @discardableResult
    static func preserveDamaged(_ url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(name).damaged-\(stamp).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: backup.path) { return backup }
            try FileManager.default.copyItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    private struct Failable<T: Decodable>: Decodable {
        let value: T?

        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    /// Moves a file or folder to the Trash (falls back to removal when the Trash is unavailable).
    public static func discard(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
