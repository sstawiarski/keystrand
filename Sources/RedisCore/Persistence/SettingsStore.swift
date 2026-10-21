import Foundation
import Observation

public enum AppTheme: String, Codable, Sendable, Hashable, CaseIterable {
    case system
    case dark
    case light

    public var displayName: String {
        switch self {
        case .system: return "Match System"
        case .dark: return "Dark Theme"
        case .light: return "Light Theme"
        }
    }
}

public enum AppTimeZone: String, Codable, Sendable, Hashable, CaseIterable {
    case local
    case utc = "UTC"

    public var timeZone: TimeZone {
        self == .utc ? TimeZone(identifier: "UTC") ?? .current : .current
    }
}

/// Settings window values and Workbench preferences.
public struct AppSettings: Codable, Hashable, Sendable {
    public static let defaultDateFormat = "HH:mm:ss d MMM yyyy"
    public static let presetDateFormats = [defaultDateFormat, "yyyy-MM-dd HH:mm:ss.sss", "dd-MMM-yyyy HH:mm:ss.SSS", "dd.MM.yyyy HH:mm:ss"]
    public static let defaultScanThreshold = 10_000
    public static let minimumScanThreshold = 500

    public var theme: AppTheme
    /// date-fns style pattern (≤ 50 chars).
    public var dateFormat: String
    public var timezone: AppTimeZone
    /// "Keys to Scan in List view"; values below 500 are raised to 500.
    public var scanThreshold: Int
    /// Workbench "Commands in pipeline" (0/1 = no batching).
    public var workbenchBatchSize: Int
    /// Workbench "Clear the Editor after running commands".
    public var workbenchCleanup: Bool
    public var workbenchResultsMode: ResultsMode
    public var workbenchRunQueryMode: RunQueryMode
    /// ⌘Q quits only while held; a short press shows a reminder.
    public var holdToQuit: Bool
    /// Closing the last window quits the app instead of leaving it running without windows.
    public var quitAfterLastWindowClosed: Bool

    public init(theme: AppTheme = .system, dateFormat: String = AppSettings.defaultDateFormat,
                timezone: AppTimeZone = .local, scanThreshold: Int = AppSettings.defaultScanThreshold,
                workbenchBatchSize: Int = 5, workbenchCleanup: Bool = true,
                workbenchResultsMode: ResultsMode = .default, workbenchRunQueryMode: RunQueryMode = .ascii,
                holdToQuit: Bool = true, quitAfterLastWindowClosed: Bool = true) {
        self.theme = theme
        self.dateFormat = dateFormat
        self.timezone = timezone
        self.scanThreshold = scanThreshold
        self.workbenchBatchSize = workbenchBatchSize
        self.workbenchCleanup = workbenchCleanup
        self.workbenchResultsMode = workbenchResultsMode
        self.workbenchRunQueryMode = workbenchRunQueryMode
        self.holdToQuit = holdToQuit
        self.quitAfterLastWindowClosed = quitAfterLastWindowClosed
    }

    enum CodingKeys: String, CodingKey {
        case theme, dateFormat, timezone, scanThreshold, workbenchBatchSize, workbenchCleanup
        case workbenchResultsMode, workbenchRunQueryMode, holdToQuit, quitAfterLastWindowClosed
    }

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = c.value(.theme, default: d.theme)
        dateFormat = c.value(.dateFormat, default: d.dateFormat)
        timezone = c.value(.timezone, default: d.timezone)
        scanThreshold = c.value(.scanThreshold, default: d.scanThreshold)
        workbenchBatchSize = c.value(.workbenchBatchSize, default: d.workbenchBatchSize)
        workbenchCleanup = c.value(.workbenchCleanup, default: d.workbenchCleanup)
        workbenchResultsMode = c.value(.workbenchResultsMode, default: d.workbenchResultsMode)
        workbenchRunQueryMode = c.value(.workbenchRunQueryMode, default: d.workbenchRunQueryMode)
        holdToQuit = c.value(.holdToQuit, default: d.holdToQuit)
        quitAfterLastWindowClosed = c.value(.quitAfterLastWindowClosed, default: d.quitAfterLastWindowClosed)
    }

    /// SCAN COUNT to use (never below 500).
    public var effectiveScanThreshold: Int { max(scanThreshold, AppSettings.minimumScanThreshold) }

    public var formatOptions: FormatOptions {
        FormatOptions(dateFormat: dateFormat, timeZone: timezone.timeZone)
    }
}

public struct HomeSorting: Codable, Hashable, Sendable {
    public enum Field: String, Codable, Sendable, Hashable, CaseIterable {
        case name, host, connectionType, lastConnection, tags
    }

    public var field: Field
    public var direction: SortOrder

    public init(field: Field = .lastConnection, direction: SortOrder = .asc) {
        self.field = field
        self.direction = direction
    }
}

/// Small UI state persisted app-wide.
public struct UIPreferences: Codable, Hashable, Sendable {
    public static let defaultAutoRefreshRate = 5.0

    public var vectorSearchQueryOnboardingSeen: Bool
    public var vectorSearchSelectKeyOnboardingSeen: Bool
    public var vectorSearchCreateIndexOnboardingSeen: Bool
    public var prodModeCtaActioned: Bool
    /// Seconds per postfix (`keys`, `overview`, `slowlog`, `string`, `hash`, ...). Missing = 5.0.
    public var autoRefreshRates: [String: Double]
    /// Auto-refresh on/off per postfix. Missing = off (overview defaults on in the control).
    public var autoRefreshEnabled: [String: Bool]
    /// `[main, bottom]` percentages.
    public var bottomPanelSizes: [Double]
    /// CLI input history, newest first (max 20).
    public var cliInputHistory: [String]
    public var homeSorting: HomeSorting
    /// Visible Home table column ids; empty = all.
    public var homeShownColumns: [String]
    public var didRunAutoDiscovery: Bool
    /// Pub/Sub messages table page size.
    public var pubSubPageSize: Int

    public init(vectorSearchQueryOnboardingSeen: Bool = false, vectorSearchSelectKeyOnboardingSeen: Bool = false,
                vectorSearchCreateIndexOnboardingSeen: Bool = false, prodModeCtaActioned: Bool = false,
                autoRefreshRates: [String: Double] = [:], autoRefreshEnabled: [String: Bool] = [:],
                bottomPanelSizes: [Double] = [60, 40], cliInputHistory: [String] = [],
                homeSorting: HomeSorting = HomeSorting(), homeShownColumns: [String] = [],
                didRunAutoDiscovery: Bool = false, pubSubPageSize: Int = 10) {
        self.vectorSearchQueryOnboardingSeen = vectorSearchQueryOnboardingSeen
        self.vectorSearchSelectKeyOnboardingSeen = vectorSearchSelectKeyOnboardingSeen
        self.vectorSearchCreateIndexOnboardingSeen = vectorSearchCreateIndexOnboardingSeen
        self.prodModeCtaActioned = prodModeCtaActioned
        self.autoRefreshRates = autoRefreshRates
        self.autoRefreshEnabled = autoRefreshEnabled
        self.bottomPanelSizes = bottomPanelSizes
        self.cliInputHistory = cliInputHistory
        self.homeSorting = homeSorting
        self.homeShownColumns = homeShownColumns
        self.didRunAutoDiscovery = didRunAutoDiscovery
        self.pubSubPageSize = pubSubPageSize
    }

    enum CodingKeys: String, CodingKey {
        case vectorSearchQueryOnboardingSeen, vectorSearchSelectKeyOnboardingSeen, vectorSearchCreateIndexOnboardingSeen
        case prodModeCtaActioned, autoRefreshRates, autoRefreshEnabled, bottomPanelSizes, cliInputHistory
        case homeSorting, homeShownColumns, didRunAutoDiscovery, pubSubPageSize
    }

    public init(from decoder: Decoder) throws {
        let d = UIPreferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vectorSearchQueryOnboardingSeen = c.value(.vectorSearchQueryOnboardingSeen, default: d.vectorSearchQueryOnboardingSeen)
        vectorSearchSelectKeyOnboardingSeen = c.value(.vectorSearchSelectKeyOnboardingSeen, default: d.vectorSearchSelectKeyOnboardingSeen)
        vectorSearchCreateIndexOnboardingSeen = c.value(.vectorSearchCreateIndexOnboardingSeen, default: d.vectorSearchCreateIndexOnboardingSeen)
        prodModeCtaActioned = c.value(.prodModeCtaActioned, default: d.prodModeCtaActioned)
        autoRefreshRates = c.value(.autoRefreshRates, default: d.autoRefreshRates)
        autoRefreshEnabled = c.value(.autoRefreshEnabled, default: d.autoRefreshEnabled)
        bottomPanelSizes = c.value(.bottomPanelSizes, default: d.bottomPanelSizes)
        cliInputHistory = c.value(.cliInputHistory, default: d.cliInputHistory)
        homeSorting = c.value(.homeSorting, default: d.homeSorting)
        homeShownColumns = c.value(.homeShownColumns, default: d.homeShownColumns)
        didRunAutoDiscovery = c.value(.didRunAutoDiscovery, default: d.didRunAutoDiscovery)
        pubSubPageSize = c.value(.pubSubPageSize, default: d.pubSubPageSize)
    }

    public func autoRefreshRate(_ postfix: String) -> Double {
        autoRefreshRates[postfix] ?? UIPreferences.defaultAutoRefreshRate
    }

    public mutating func resetOnboarding() {
        vectorSearchQueryOnboardingSeen = false
        vectorSearchSelectKeyOnboardingSeen = false
        vectorSearchCreateIndexOnboardingSeen = false
        prodModeCtaActioned = false
    }
}

/// Browser preferences shared by all databases.
public struct BrowserGlobalPrefs: Codable, Hashable, Sendable {
    public var viewType: KeyViewType
    public var searchMode: SearchMode
    /// Global value "view format".
    public var valueFormat: ValueFormat

    public init(viewType: KeyViewType = .tree, searchMode: SearchMode = .pattern, valueFormat: ValueFormat = .unicode) {
        self.viewType = viewType
        self.searchMode = searchMode
        self.valueFormat = valueFormat
    }

    enum CodingKeys: String, CodingKey { case viewType, searchMode, valueFormat }

    public init(from decoder: Decoder) throws {
        let d = BrowserGlobalPrefs()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        viewType = c.value(.viewType, default: d.viewType)
        searchMode = c.value(.searchMode, default: d.searchMode)
        valueFormat = c.value(.valueFormat, default: d.valueFormat)
    }
}

/// App-wide observable settings, persisted to `settings.json` on every change.
/// Injected into SwiftUI with `.environment(settingsStore)`; read with `@Environment(SettingsStore.self)`.
@MainActor
@Observable
public final class SettingsStore {
    public var app: AppSettings { didSet { if app != oldValue { save() } } }
    public var ui: UIPreferences { didSet { if ui != oldValue { save() } } }
    public var browser: BrowserGlobalPrefs { didSet { if browser != oldValue { save() } } }

    @ObservationIgnored private let fileURL: URL?

    private struct FileModel: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion = Self.currentSchemaVersion
        var app: AppSettings?
        var ui: UIPreferences?
        var browser: BrowserGlobalPrefs?
        /// Sections that are present but failed to decode.
        var droppedCount = 0

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, app, ui, browser
        }

        init(app: AppSettings?, ui: UIPreferences?, browser: BrowserGlobalPrefs?) {
            self.app = app
            self.ui = ui
            self.browser = browser
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = c.value(.schemaVersion, default: 1)
            app = c.optionalValue(.app)
            ui = c.optionalValue(.ui)
            browser = c.optionalValue(.browser)
            droppedCount = [c.contains(.app) && app == nil, c.contains(.ui) && ui == nil,
                            c.contains(.browser) && browser == nil].filter { $0 }.count
        }

        /// Empty when the file is missing. Backs up the original beside it when the file is unreadable, a section
        /// fails to decode, or the file comes from a newer version.
        static func load(from url: URL) -> FileModel {
            let empty = FileModel(app: nil, ui: nil, browser: nil)
            guard FileManager.default.fileExists(atPath: url.path) else { return empty }
            guard let data = try? Data(contentsOf: url),
                  let model = try? JSONFile.makeDecoder().decode(FileModel.self, from: data) else {
                DataFileBackup.preserve(url, label: "damaged")
                return empty
            }
            if model.schemaVersion > currentSchemaVersion {
                DataFileBackup.preserve(url, label: "v\(model.schemaVersion)")
            } else if model.droppedCount > 0 {
                DataFileBackup.preserve(url, label: "damaged")
            }

            return model
        }
    }

    /// `fileURL == nil` keeps everything in memory (previews).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        let model = fileURL.map(FileModel.load)
        app = model?.app ?? AppSettings()
        ui = model?.ui ?? UIPreferences()
        browser = model?.browser ?? BrowserGlobalPrefs()
    }

    public convenience init(paths: AppPaths) {
        self.init(fileURL: paths.settingsFile)
    }

    /// Records a CLI command (newest first, deduped, max 20) with its passwords masked.
    public func pushCLIHistory(_ command: String) {
        let command = CommandRedaction.redact(command)
        var history = ui.cliInputHistory.filter { $0 != command }
        history.insert(command, at: 0)
        ui.cliInputHistory = Array(history.prefix(20))
    }

    private func save() {
        guard let fileURL else { return }
        try? JSONFile.save(FileModel(app: app, ui: ui, browser: browser), to: fileURL)
    }
}
