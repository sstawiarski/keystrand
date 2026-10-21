import Foundation
import RedisCore
@testable import SettingsFeature
import Testing

@MainActor
struct SettingsViewModelTests {
    private func tempSettingsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keystrand-settings-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test func defaultsStartInPresetMode() {
        let model = SettingsViewModel(store: SettingsStore(fileURL: nil))
        #expect(model.theme == .system)
        #expect(model.dateMode == .preset)
        #expect(model.presetFormat == AppSettings.defaultDateFormat)
        #expect(model.scanThresholdDisplay == "10,000")
        #expect(model.pipelineBatchSizeText == "5")
        #expect(model.workbenchCleanup)
    }

    @Test func settingsRoundTripThroughDisk() {
        let url = tempSettingsFile()
        let model = SettingsViewModel(store: SettingsStore(fileURL: url))
        model.theme = .dark
        model.timezone = .utc
        model.selectPreset("dd.MM.yyyy HH:mm:ss")
        model.workbenchCleanup = false
        model.applyPipelineBatchSize("12")
        model.applyScanThreshold("200")
        model.resultsMode = .group
        model.rawMode = true
        #expect(model.setAutoRefreshRate("overview", text: "2.5"))
        model.setAutoRefresh("keys", enabled: true)

        let reloaded = SettingsStore(fileURL: url)
        #expect(reloaded.app.theme == .dark)
        #expect(reloaded.app.timezone == .utc)
        #expect(reloaded.app.dateFormat == "dd.MM.yyyy HH:mm:ss")
        #expect(reloaded.app.workbenchCleanup == false)
        #expect(reloaded.app.workbenchBatchSize == 12)
        #expect(reloaded.app.scanThreshold == 500)
        #expect(reloaded.app.workbenchResultsMode == .group)
        #expect(reloaded.app.workbenchRunQueryMode == .raw)
        #expect(reloaded.ui.autoRefreshRate("overview") == 2.5)
        #expect(reloaded.ui.autoRefreshEnabled["keys"] == true)

        let reopened = SettingsViewModel(store: reloaded)
        #expect(reopened.dateMode == .preset)
        #expect(reopened.presetFormat == "dd.MM.yyyy HH:mm:ss")
    }

    @Test func customFormatSaveAndSuccessState() async throws {
        let url = tempSettingsFile()
        let model = SettingsViewModel(store: SettingsStore(fileURL: url), successDisplayDuration: .milliseconds(50))
        model.setDateMode(.custom)
        #expect(model.customFormat == AppSettings.defaultDateFormat)

        model.customFormat = ""
        #expect(!model.canSaveCustomFormat)
        #expect(model.saveCustomFormatHelp == "Enter a format")
        #expect(!model.saveCustomFormat())

        model.customFormat = String(repeating: "y", count: 60)
        #expect(model.customFormatError == "Format should not exceed 50 characters")
        #expect(!model.saveCustomFormat())

        model.customFormat = "HH:mm f"
        #expect(model.customFormatError == "This format is not supported.")
        #expect(model.preview() == "Invalid Format")

        model.customFormat = " yyyy/MM/dd HH:mm "
        #expect(model.saveCustomFormat())
        #expect(model.customSaveSucceeded)
        #expect(model.store.app.dateFormat == "yyyy/MM/dd HH:mm")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!model.customSaveSucceeded)

        let reopened = SettingsViewModel(store: SettingsStore(fileURL: url))
        #expect(reopened.dateMode == .custom)
        #expect(reopened.customFormat == "yyyy/MM/dd HH:mm")
    }

    @Test func switchingBackToPresetAppliesPreset() {
        let model = SettingsViewModel(store: SettingsStore(fileURL: nil))
        model.selectPreset("yyyy-MM-dd HH:mm:ss.sss")
        model.setDateMode(.custom)
        model.customFormat = "HH:mm"
        #expect(model.saveCustomFormat())
        #expect(model.store.app.dateFormat == "HH:mm")
        model.setDateMode(.preset)
        #expect(model.store.app.dateFormat == "yyyy-MM-dd HH:mm:ss.sss")
    }

    @Test func selectingPresetWhileCustomDoesNotOverwrite() {
        let model = SettingsViewModel(store: SettingsStore(fileURL: nil))
        model.setDateMode(.custom)
        model.customFormat = "HH:mm"
        model.saveCustomFormat()
        model.selectPreset("dd.MM.yyyy HH:mm:ss")
        #expect(model.store.app.dateFormat == "HH:mm")
    }

    @Test func previewUsesTimeZone() {
        let model = SettingsViewModel(store: SettingsStore(fileURL: nil))
        model.timezone = .utc
        model.selectPreset("yyyy-MM-dd HH:mm:ss")
        #expect(model.preview(at: Date(timeIntervalSince1970: 0)) == "1970-01-01 00:00:00")
    }

    @Test func autoRefreshEntriesIncludeKnownAndStoredPostfixes() {
        let store = SettingsStore(fileURL: nil)
        store.ui.autoRefreshRates["slowlog"] = 10
        store.ui.autoRefreshEnabled["hash"] = true
        let model = SettingsViewModel(store: store)
        let entries = model.autoRefreshEntries
        #expect(entries.map(\.postfix) == ["overview", "keys", "hash", "slowlog"])
        #expect(entries[0].isEnabled)
        #expect(!entries[0].isCustomized)
        #expect(entries[0].rate == 5)
        #expect(entries.first { $0.postfix == "slowlog" }?.title == "Slow Log")
        #expect(entries.first { $0.postfix == "hash" }?.title == "Hash key details")
        #expect(!model.setAutoRefreshRate("overview", text: "fast"))
        #expect(model.setAutoRefreshRate("overview", text: "0.1"))
        #expect(store.ui.autoRefreshRate("overview") == 1.0)
        model.resetAutoRefresh("slowlog")
        #expect(store.ui.autoRefreshRates["slowlog"] == nil)
        #expect(!model.autoRefreshEntries.contains { $0.postfix == "slowlog" })
    }

    @Test func holdToQuitDefaultsOnAndPersists() throws {
        let url = tempSettingsFile()
        let model = SettingsViewModel(store: SettingsStore(fileURL: url))
        #expect(model.holdToQuit)
        model.holdToQuit = false
        #expect(!SettingsStore(fileURL: url).app.holdToQuit)

        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"dark"}"#.utf8))
        #expect(older.holdToQuit)
    }

    @Test func quitAfterLastWindowClosedDefaultsOnAndPersists() throws {
        let url = tempSettingsFile()
        let model = SettingsViewModel(store: SettingsStore(fileURL: url))
        #expect(model.quitAfterLastWindowClosed)
        model.quitAfterLastWindowClosed = false
        #expect(!SettingsStore(fileURL: url).app.quitAfterLastWindowClosed)

        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"holdToQuit":false}"#.utf8))
        #expect(older.quitAfterLastWindowClosed)
    }

    @Test func resetAllSettingsRestoresDefaults() {
        let url = tempSettingsFile()
        let store = SettingsStore(fileURL: url)
        store.ui.cliInputHistory = ["PING"]
        let model = SettingsViewModel(store: store)
        model.theme = .light
        model.setDateMode(.custom)
        model.customFormat = "HH:mm"
        model.saveCustomFormat()
        model.applyScanThreshold("50000")
        _ = model.setAutoRefreshRate("overview", text: "30")

        model.resetAllSettings()
        #expect(model.didReset)
        #expect(model.dateMode == .preset)
        let reloaded = SettingsStore(fileURL: url)
        #expect(reloaded.app == AppSettings())
        #expect(reloaded.ui.autoRefreshRates.isEmpty)
        #expect(reloaded.ui.cliInputHistory == ["PING"])
    }

    @Test func resetOnboardingClearsFlags() {
        let store = SettingsStore(fileURL: nil)
        store.ui.vectorSearchQueryOnboardingSeen = true
        store.ui.prodModeCtaActioned = true
        SettingsViewModel(store: store).resetOnboarding()
        #expect(!store.ui.vectorSearchQueryOnboardingSeen)
        #expect(!store.ui.prodModeCtaActioned)
    }

}

struct SettingsTabDeepLinkTests {
    @Test func anchorsResolveToTabs() {
        #expect(SettingsTab(anchor: "#general") == .general)
        #expect(SettingsTab(anchor: "#workbench") == .workbench)
        #expect(SettingsTab(anchor: "Advanced") == .advanced)
        #expect(SettingsTab(anchor: "#nope") == nil)
    }

    @Test func preselectWritesDefaults() throws {
        let suite = "keystrand-settings-tab-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SettingsTab.selected(defaults: defaults) == .general)
        SettingsTab.preselect(.advanced, defaults: defaults)
        #expect(SettingsTab.selected(defaults: defaults) == .advanced)
        #expect(defaults.string(forKey: SettingsTab.selectionDefaultsKey) == "advanced")
    }

}

@MainActor
struct SettingsPagesLogicTests {
    @Test func formatMenuSelectionSwitchesModes() {
        let model = SettingsViewModel(store: SettingsStore(fileURL: nil))
        #expect(model.formatSelection == AppSettings.defaultDateFormat)
        model.formatSelection = SettingsViewModel.customFormatTag
        #expect(model.dateMode == .custom)
        model.formatSelection = "dd.MM.yyyy HH:mm:ss"
        #expect(model.dateMode == .preset)
        #expect(model.store.app.dateFormat == "dd.MM.yyyy HH:mm:ss")
    }

    @Test func numericFieldsClampValues() {
        let model = SettingsViewModel(store: SettingsStore(fileURL: nil))
        model.scanThreshold = 100
        #expect(model.scanThreshold == 500)
        model.scanThreshold = 0
        #expect(model.scanThreshold == AppSettings.defaultScanThreshold)
        model.pipelineBatchSize = -3
        #expect(model.pipelineBatchSize == 0)
        model.pipelineBatchSize = 12
        #expect(model.store.app.workbenchBatchSize == 12)
    }

    @Test func settingsTabsAreGeneralWorkbenchAdvanced() {
        #expect(SettingsTab.allCases.map(\.title) == ["General", "Workbench", "Advanced"])
        #expect(SettingsTab(rawValue: "privacy") == nil)
        #expect(SettingsViewModel.appearanceChoices.map(SettingsViewModel.appearanceTitle) == ["System", "Light", "Dark"])
    }
}
