import Foundation

/// Per-database UI settings (deleted with the database).
public struct DatabaseSettings: Codable, Hashable, Sendable {
    public var treeViewDelimiters: [String]
    public var treeViewSort: SortOrder
    /// "Ignore separator in the first N characters" (0...512).
    public var treeViewDelimiterPrefixLength: Int
    public var slowLogDurationUnit: SlowLogDurationUnit
    public var showHiddenRecommendations: Bool
    public var notShowConfirmationRunTutorial: Bool
    public var browserShownColumns: [BrowserColumn]
    /// False until the user changes columns (production databases default to `[.ttl]`).
    public var didUserConfigureColumns: Bool
    /// Newest first, per mode (max 10 each).
    public var searchHistory: [SearchHistoryItem]
    /// Opaque JSON blobs owned by individual features (e.g. "valueDecoderRules", "workbench.tsPreferences").
    public var featureData: [String: Data]

    public init(treeViewDelimiters: [String] = [":"], treeViewSort: SortOrder = .asc,
                treeViewDelimiterPrefixLength: Int = 0, slowLogDurationUnit: SlowLogDurationUnit = .milliseconds,
                showHiddenRecommendations: Bool = false, notShowConfirmationRunTutorial: Bool = false,
                browserShownColumns: [BrowserColumn] = [.size, .ttl], didUserConfigureColumns: Bool = false,
                searchHistory: [SearchHistoryItem] = [], featureData: [String: Data] = [:]) {
        self.treeViewDelimiters = treeViewDelimiters
        self.treeViewSort = treeViewSort
        self.treeViewDelimiterPrefixLength = treeViewDelimiterPrefixLength
        self.slowLogDurationUnit = slowLogDurationUnit
        self.showHiddenRecommendations = showHiddenRecommendations
        self.notShowConfirmationRunTutorial = notShowConfirmationRunTutorial
        self.browserShownColumns = browserShownColumns
        self.didUserConfigureColumns = didUserConfigureColumns
        self.searchHistory = searchHistory
        self.featureData = featureData
    }

    enum CodingKeys: String, CodingKey {
        case treeViewDelimiters, treeViewSort, treeViewDelimiterPrefixLength, slowLogDurationUnit
        case showHiddenRecommendations, notShowConfirmationRunTutorial, browserShownColumns
        case didUserConfigureColumns, searchHistory, featureData
    }

    public init(from decoder: Decoder) throws {
        let d = DatabaseSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        treeViewDelimiters = c.value(.treeViewDelimiters, default: d.treeViewDelimiters)
        treeViewSort = c.value(.treeViewSort, default: d.treeViewSort)
        treeViewDelimiterPrefixLength = c.value(.treeViewDelimiterPrefixLength, default: d.treeViewDelimiterPrefixLength)
        slowLogDurationUnit = c.value(.slowLogDurationUnit, default: d.slowLogDurationUnit)
        showHiddenRecommendations = c.value(.showHiddenRecommendations, default: d.showHiddenRecommendations)
        notShowConfirmationRunTutorial = c.value(.notShowConfirmationRunTutorial, default: d.notShowConfirmationRunTutorial)
        browserShownColumns = c.value(.browserShownColumns, default: d.browserShownColumns)
        didUserConfigureColumns = c.value(.didUserConfigureColumns, default: d.didUserConfigureColumns)
        searchHistory = c.value(.searchHistory, default: d.searchHistory)
        featureData = c.value(.featureData, default: d.featureData)
    }

    /// Decodes a feature blob from `featureData`.
    public func feature<T: Decodable>(_ type: T.Type, key: String) -> T? {
        featureData[key].flatMap { try? JSONFile.makeDecoder().decode(T.self, from: $0) }
    }

    public mutating func setFeature<T: Encodable>(_ value: T?, key: String) {
        featureData[key] = value.flatMap { try? JSONFile.makeEncoder().encode($0) }
    }
}

/// `database-settings/<id>.json`.
public actor DatabaseSettingsStore {
    private let paths: AppPaths
    private var cache: [DatabaseID: DatabaseSettings] = [:]

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func settings(for id: DatabaseID) -> DatabaseSettings {
        if let cached = cache[id] { return cached }
        let value = DatabaseSettingsFile.load(from: paths.databaseSettingsFile(for: id))
        cache[id] = value
        return value
    }

    public func save(_ settings: DatabaseSettings, for id: DatabaseID) throws {
        try JSONFile.save(DatabaseSettingsFile(settings: settings), to: paths.databaseSettingsFile(for: id))
        cache[id] = settings
    }

    @discardableResult
    public func update(_ id: DatabaseID, _ change: @Sendable (inout DatabaseSettings) -> Void) throws -> DatabaseSettings {
        var value = settings(for: id)
        change(&value)
        try save(value, for: id)
        return value
    }

    public func delete(_ id: DatabaseID) {
        cache[id] = nil
        JSONFile.discard(paths.databaseSettingsFile(for: id))
    }
}

/// The settings object with a `schemaVersion` key beside its fields. A file without the key is version 1.
struct DatabaseSettingsFile: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var settings: DatabaseSettings

    init(settings: DatabaseSettings) {
        self.settings = settings
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, default: 1)
        settings = try DatabaseSettings(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try settings.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
    }

    /// Default settings when the file is missing. Backs up the original beside it when the file is unreadable or
    /// comes from a newer version.
    static func load(from url: URL) -> DatabaseSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return DatabaseSettings() }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONFile.makeDecoder().decode(Self.self, from: data) else {
            DataFileBackup.preserve(url, label: "damaged")
            return DatabaseSettings()
        }
        if file.schemaVersion > currentSchemaVersion {
            DataFileBackup.preserve(url, label: "v\(file.schemaVersion)")
        }

        return file.settings
    }
}
