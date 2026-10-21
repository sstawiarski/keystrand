import Foundation
import Observation
import RedisUI

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, workbench, advanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "General"
        case .workbench: return "Workbench"
        case .advanced: return "Advanced"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .workbench: return "terminal"
        case .advanced: return "gearshape.2"
        }
    }

    /// UserDefaults key holding the selected Settings tab.
    public static let selectionDefaultsKey = "settings.selectedTab"

    /// Resolves a deep-link anchor such as `#advanced` or `workbench`.
    public init?(anchor: String) {
        let name = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = name.hasPrefix("#") ? String(name.dropFirst()) : name
        guard let tab = SettingsTab(rawValue: trimmed.lowercased()) else { return nil }
        self = tab
    }

    /// Makes `tab` the visible tab the next time the Settings window shows (and immediately if it is open).
    public static func preselect(_ tab: SettingsTab, defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: selectionDefaultsKey)
    }

    public static func selected(defaults: UserDefaults = .standard) -> SettingsTab {
        defaults.string(forKey: selectionDefaultsKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }
}

public enum DateFormatMode: String, CaseIterable, Identifiable, Sendable {
    case preset, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .preset: return "Pre-selected formats"
        case .custom: return "Custom"
        }
    }
}

/// One auto-refresh preference row (Settings › Advanced).
public struct AutoRefreshEntry: Identifiable, Hashable, Sendable {
    public var postfix: String
    public var title: String
    public var isEnabled: Bool
    public var rate: Double
    public var isCustomized: Bool
    public var id: String { postfix }
}

/// Logic of the Settings window. Every change writes straight to `SettingsStore`, which persists it.
@MainActor
@Observable
public final class SettingsViewModel {
    public static let knownAutoRefreshPostfixes: [(postfix: String, title: String, enabledByDefault: Bool)] = [
        ("overview", "Overview metrics", true),
        ("keys", "Browser key list", false),
    ]

    public let store: SettingsStore
    public private(set) var dateMode: DateFormatMode
    public private(set) var presetFormat: String
    public var customFormat: String
    public private(set) var customSaveSucceeded = false
    public private(set) var didReset = false

    @ObservationIgnored private var successResetTask: Task<Void, Never>?
    @ObservationIgnored let successDisplayDuration: Duration

    public init(store: SettingsStore, successDisplayDuration: Duration = .seconds(5)) {
        self.store = store
        self.successDisplayDuration = successDisplayDuration
        let format = store.app.dateFormat
        if AppSettings.presetDateFormats.contains(format) {
            dateMode = .preset
            presetFormat = format
            customFormat = ""
        } else {
            dateMode = .custom
            presetFormat = AppSettings.defaultDateFormat
            customFormat = format
        }
    }

    // MARK: - General

    public var theme: AppTheme {
        get { store.app.theme }
        set {
            store.app.theme = newValue
            ThemeApplier.apply(newValue)
        }
    }

    /// Title of an appearance choice in the Settings radio group.
    public static func appearanceTitle(_ theme: AppTheme) -> String {
        switch theme {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Appearance choices in display order.
    public static let appearanceChoices: [AppTheme] = [.system, .light, .dark]

    /// Tag of the "Custom" item of the date format menu.
    public static let customFormatTag = "\u{1F}custom"

    /// Selection of the date format menu: one of `presetFormats`, or `customFormatTag`.
    public var formatSelection: String {
        get { dateMode == .custom ? Self.customFormatTag : presetFormat }
        set {
            if newValue == Self.customFormatTag {
                setDateMode(.custom)
            } else {
                selectPreset(newValue)
                setDateMode(.preset)
            }
        }
    }

    public var timezone: AppTimeZone {
        get { store.app.timezone }
        set { store.app.timezone = newValue }
    }

    public var presetFormats: [String] { AppSettings.presetDateFormats }

    public func setDateMode(_ mode: DateFormatMode) {
        guard mode != dateMode else { return }
        dateMode = mode
        switch mode {
        case .custom:
            customFormat = store.app.dateFormat
        case .preset:
            store.app.dateFormat = presetFormat
        }
    }

    public func selectPreset(_ format: String) {
        presetFormat = format
        if dateMode == .preset { store.app.dateFormat = format }
    }

    public var customFormatError: String? { DateFormatValidator.error(for: customFormat) }

    public var canSaveCustomFormat: Bool { DateFormatValidator.canSave(customFormat) }

    /// Explanation shown on the disabled Save button.
    public var saveCustomFormatHelp: String {
        if customFormat.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a format" }
        return customFormatError ?? "Save the custom format"
    }

    @discardableResult
    public func saveCustomFormat() -> Bool {
        guard canSaveCustomFormat else { return false }
        store.app.dateFormat = customFormat.trimmingCharacters(in: .whitespaces)
        customSaveSucceeded = true
        successResetTask?.cancel()
        let duration = successDisplayDuration
        successResetTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.customSaveSucceeded = false
        }
        return true
    }

    public func customFormatEdited() {
        customSaveSucceeded = false
    }

    /// Format the preview uses (the one being edited in Custom mode).
    public var previewFormat: String { dateMode == .custom ? customFormat : presetFormat }

    public func preview(at date: Date = Date()) -> String {
        DateFormatValidator.preview(previewFormat, timeZone: store.app.timezone.timeZone, date: date)
    }

    public func presetExample(_ format: String, at date: Date = Date()) -> String {
        DateFormatValidator.preview(format, timeZone: store.app.timezone.timeZone, date: date)
    }

    public var holdToQuit: Bool {
        get { store.app.holdToQuit }
        set { store.app.holdToQuit = newValue }
    }

    public var quitAfterLastWindowClosed: Bool {
        get { store.app.quitAfterLastWindowClosed }
        set { store.app.quitAfterLastWindowClosed = newValue }
    }

    // MARK: - Workbench

    public var workbenchCleanup: Bool {
        get { store.app.workbenchCleanup }
        set { store.app.workbenchCleanup = newValue }
    }

    public var pipelineBatchSizeText: String { String(store.app.workbenchBatchSize) }

    public func applyPipelineBatchSize(_ text: String) {
        store.app.workbenchBatchSize = NumericSettingParser.pipelineBatchSize(from: text)
    }

    /// "Commands per pipeline" field value; negative input is stored as 0.
    public var pipelineBatchSize: Int {
        get { store.app.workbenchBatchSize }
        set { store.app.workbenchBatchSize = max(newValue, 0) }
    }

    public var resultsMode: ResultsMode {
        get { store.app.workbenchResultsMode }
        set { store.app.workbenchResultsMode = newValue }
    }

    public var rawMode: Bool {
        get { store.app.workbenchRunQueryMode == .raw }
        set { store.app.workbenchRunQueryMode = newValue ? .raw : .ascii }
    }

    // MARK: - Advanced

    public var scanThresholdDisplay: String { NumberFormatting.grouped(store.app.effectiveScanThreshold) }

    public var scanThresholdEditText: String { String(store.app.effectiveScanThreshold) }

    public func applyScanThreshold(_ text: String) {
        store.app.scanThreshold = NumericSettingParser.scanThreshold(from: text)
    }

    /// "Keys to scan" field value: 0 or less restores the default, values below 500 are raised to 500.
    public var scanThreshold: Int {
        get { store.app.effectiveScanThreshold }
        set { store.app.scanThreshold = NumericSettingParser.scanThreshold(value: newValue) }
    }

    public var autoRefreshEntries: [AutoRefreshEntry] {
        var postfixes = Self.knownAutoRefreshPostfixes.map(\.postfix)
        let stored = Set(store.ui.autoRefreshRates.keys).union(store.ui.autoRefreshEnabled.keys)
        postfixes += stored.subtracting(postfixes).sorted()
        return postfixes.map { postfix in
            let defaultEnabled = Self.knownAutoRefreshPostfixes.first { $0.postfix == postfix }?.enabledByDefault ?? false
            return AutoRefreshEntry(postfix: postfix, title: Self.autoRefreshTitle(postfix),
                                    isEnabled: store.ui.autoRefreshEnabled[postfix] ?? defaultEnabled,
                                    rate: store.ui.autoRefreshRate(postfix),
                                    isCustomized: store.ui.autoRefreshRates[postfix] != nil || store.ui.autoRefreshEnabled[postfix] != nil)
        }
    }

    public func setAutoRefresh(_ postfix: String, enabled: Bool) {
        store.ui.autoRefreshEnabled[postfix] = enabled
    }

    @discardableResult
    public func setAutoRefreshRate(_ postfix: String, text: String) -> Bool {
        guard let rate = NumericSettingParser.refreshRate(from: text) else { return false }
        store.ui.autoRefreshRates[postfix] = rate
        return true
    }

    public func resetAutoRefresh(_ postfix: String) {
        store.ui.autoRefreshRates[postfix] = nil
        store.ui.autoRefreshEnabled[postfix] = nil
    }

    public static func autoRefreshTitle(_ postfix: String) -> String {
        if let known = knownAutoRefreshPostfixes.first(where: { $0.postfix == postfix }) { return known.title }
        switch postfix {
        case "slowlog": return "Slow Log"
        case "vs-keys": return "Vector Search keys"
        case "analysis": return "Database Analysis"
        case "cluster": return "Cluster Details"
        default:
            let type = KeyType(rawValue: postfix)
            if case .unknown = type { return postfix }
            return "\(type.displayName) key details"
        }
    }

    /// Restores all Settings window values to defaults.
    public func resetAllSettings() {
        store.app = AppSettings()
        store.ui.autoRefreshRates = [:]
        store.ui.autoRefreshEnabled = [:]
        ThemeApplier.apply(store.app.theme)
        dateMode = .preset
        presetFormat = AppSettings.defaultDateFormat
        customFormat = ""
        customSaveSucceeded = false
        didReset = true
    }

    public func resetOnboarding() {
        store.ui.resetOnboarding()
    }
}
