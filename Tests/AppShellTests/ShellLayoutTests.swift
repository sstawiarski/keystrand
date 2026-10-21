@testable import AppShell
import Foundation
import RedisCore
import RedisUI
import TestSupport
import Testing

struct BottomPanelSplitTests {
    @Test func defaultsToSixtyForty() {
        #expect(BottomPanelSplit.bottomFraction(from: BottomPanelSplit.defaultSizes) == 0.4)
        #expect(BottomPanelSplit.bottomFraction(from: []) == 0.4)
        #expect(BottomPanelSplit.bottomFraction(from: [0, 0]) == 0.4)
        #expect(BottomPanelSplit.bottomFraction(from: [.nan, 40]) == 0.4)
    }

    @Test func clampsToBounds() {
        #expect(BottomPanelSplit.bottomFraction(from: [99, 1]) == 0.1)
        #expect(BottomPanelSplit.bottomFraction(from: [1, 99]) == 0.8)
        #expect(BottomPanelSplit.clamp(.infinity) == 0.4)
    }

    @Test func persistsMainFloorBottomCeil() {
        #expect(BottomPanelSplit.sizes(forBottomFraction: 0.4) == [60, 40])
        #expect(BottomPanelSplit.sizes(forBottomFraction: 0.403) == [59, 41])
        #expect(BottomPanelSplit.sizes(bottomHeight: 250, totalHeight: 1000) == [75, 25])
        #expect(BottomPanelSplit.sizes(bottomHeight: 250, totalHeight: 0) == nil)
    }
}

struct DrawerLayoutTests {
    @Test func keepsBothPanesAtTheirMinimums() {
        #expect(DrawerLayout.clampedBottom(300, total: 800) == 300)
        #expect(DrawerLayout.clampedBottom(20, total: 800) == DrawerLayout.minBottomHeight)
        #expect(DrawerLayout.clampedBottom(780, total: 800) == 800 - DrawerLayout.minMainHeight - DrawerDivider.thickness)
    }

    @Test func drawerKeepsItsMinimumWhenTheWindowIsTooShort() {
        #expect(DrawerLayout.clampedBottom(300, total: 300) == DrawerLayout.minBottomHeight)
    }
}

@MainActor
struct BottomPanelModelTests {
    @Test func showingAnEmptyPanelOpensTheCLI() {
        let navigator = DatabaseNavigator()
        let model = BottomPanelModel()
        #expect(!model.isShown(navigator))
        model.toggleVisible(navigator: navigator)
        #expect(navigator.openBottomTools == [.cli])
        #expect(model.isShown(navigator))
        #expect(model.hasOpenedCLI)
    }

    @Test func hidingThePanelKeepsToolsOpen() {
        let navigator = DatabaseNavigator()
        let model = BottomPanelModel()
        model.open(.profiler, navigator: navigator)
        model.setVisible(false, navigator: navigator)
        #expect(navigator.openBottomTools == [.profiler])
        #expect(!model.isShown(navigator))
        model.setVisible(true, navigator: navigator)
        #expect(navigator.openBottomTools == [.profiler])
        #expect(model.isToolShown(.profiler, navigator: navigator))
    }

    @Test func togglingAVisibleToolClosesItAndHidesAnEmptyPanel() {
        let navigator = DatabaseNavigator()
        let model = BottomPanelModel()
        #expect(model.toggle(.cli, navigator: navigator) == nil)
        #expect(model.toggle(.profiler, navigator: navigator) == nil)
        #expect(model.openTools(navigator) == [.cli, .profiler])
        #expect(model.toggle(.cli, navigator: navigator) == .cli)
        #expect(model.isShown(navigator))
        #expect(model.toggle(.profiler, navigator: navigator) == .profiler)
        #expect(!model.isShown(navigator))
        #expect(!model.isVisible)
    }

    @Test func togglingAHiddenToolShowsThePanelWithoutClosingIt() {
        let navigator = DatabaseNavigator()
        let model = BottomPanelModel()
        model.open(.cli, navigator: navigator)
        model.setVisible(false, navigator: navigator)
        #expect(model.toggle(.cli, navigator: navigator) == nil)
        #expect(model.isToolShown(.cli, navigator: navigator))
    }

    @Test func menuHideKeepsTheToolOpen() {
        let navigator = DatabaseNavigator()
        let model = BottomPanelModel()
        model.open(.cli, navigator: navigator)
        model.open(.profiler, navigator: navigator)
        model.toggleShown(.cli, navigator: navigator)
        #expect(navigator.openBottomTools == [.cli, .profiler])
        #expect(model.displayedTools(navigator) == [.profiler])
        #expect(!model.isToolShown(.cli, navigator: navigator))
        model.toggleShown(.profiler, navigator: navigator)
        #expect(navigator.openBottomTools == [.cli, .profiler])
        #expect(!model.isShown(navigator))
        model.toggleShown(.cli, navigator: navigator)
        #expect(model.displayedTools(navigator) == [.cli])
        model.setVisible(true, navigator: navigator)
        #expect(model.displayedTools(navigator) == [.cli, .profiler])
    }

    @Test func navigationRequestRevealsAHiddenTool() {
        let navigator = DatabaseNavigator()
        let model = BottomPanelModel()
        model.open(.profiler, navigator: navigator)
        model.toggleShown(.profiler, navigator: navigator)
        navigator.navigate(.bottomPanel(.profiler))
        #expect(navigator.bottomToolRequest != nil)
        model.open(.profiler, navigator: navigator)
        #expect(model.isToolShown(.profiler, navigator: navigator))
    }

    @Test func navigationRequestsShowThePanel() {
        let navigator = DatabaseNavigator()
        let model = BottomPanelModel()
        navigator.navigate(.bottomPanel(.profiler))
        model.sync(navigator)
        #expect(model.isShown(navigator))
        navigator.openBottomTools.remove(.profiler)
        model.sync(navigator)
        #expect(!model.isVisible)
    }
}

@MainActor
struct InspectorStateTests {
    @Test func tutorialRequestsOpenTheTutorialsPane() {
        let navigator = DatabaseNavigator()
        let state = InspectorState()
        navigator.navigate(.tutorial(id: nil))
        state.pull(from: navigator)
        #expect(state.isShown)
        #expect(state.pane == .tutorials)
    }

    @Test func commandHelperIsNotAnInsightsPane() {
        let navigator = DatabaseNavigator()
        let state = InspectorState()
        state.show(.commandHelper)
        state.push(to: navigator)
        #expect(!navigator.isInsightsOpen)
        state.pull(from: navigator)
        #expect(state.isShown)
        state.select(.tips)
        state.push(to: navigator)
        #expect(navigator.isInsightsOpen)
        #expect(navigator.insightsTab == .tips)
    }

    @Test func closingInsightsHidesTheTipsPane() {
        let navigator = DatabaseNavigator()
        let state = InspectorState()
        state.show(.tips)
        state.push(to: navigator)
        navigator.isInsightsOpen = false
        state.pull(from: navigator)
        #expect(!state.isShown)
    }

    @Test func menuToggleHidesOnlyTheShownPane() {
        let state = InspectorState()
        state.toggle(.tips)
        #expect(state.isShown && state.pane == .tips)
        state.toggle(.tutorials)
        #expect(state.isShown && state.pane == .tutorials)
        state.toggle(.tutorials)
        #expect(!state.isShown)
    }
}

struct DatabaseSidebarItemTests {
    @Test func mapsOntoSectionsAndAnalyticsTabs() {
        for item in DatabaseSidebarItem.allCases {
            #expect(DatabaseSidebarItem(section: item.section, analyticsTab: item.analyticsTab ?? .databaseAnalysis) == item)
        }

        #expect(DatabaseSidebarItem.slowLog.section == .analytics)
        #expect(DatabaseSidebarItem.slowLog.analyticsTab == .slowLog)
        #expect(DatabaseSidebarItem.vectorSearch.analyticsTab == nil)
    }

    @Test func clusterDetailsOnlyForClusters() {
        #expect(!DatabaseSidebarItem.visibleItems(isCluster: false).contains(.clusterDetails))
        #expect(DatabaseSidebarItem.visibleItems(isCluster: true).count == 7)
        #expect(DatabaseSidebarItem.clusterDetails.resolved(isCluster: false) == .databaseAnalysis)
        #expect(DatabaseSidebarItem.clusterDetails.resolved(isCluster: true) == .clusterDetails)
    }

    @Test func shortcutsFollowSidebarOrder() {
        #expect(DatabaseSidebarItem.browser.shortcutKey.character == "1")
        #expect(DatabaseSidebarItem.pubSub.shortcutKey.character == "7")
        #expect(DatabaseSidebarItem.allCases.map(\.group) == [.data, .data, .data, .analytics, .analytics, .analytics, .messaging])
    }

    @MainActor
    @Test func applyUpdatesTheNavigator() {
        let navigator = DatabaseNavigator()
        DatabaseSidebarItem.slowLog.apply(to: navigator)
        #expect(navigator.section == .analytics)
        #expect(navigator.analyticsTab == .slowLog)
        #expect(DatabaseSidebarItem.current(navigator) == .slowLog)
        navigator.navigate(.pubSub)
        #expect(DatabaseSidebarItem.current(navigator) == .pubSub)
    }

    @Test func titlesAndSubtitles() {
        #expect(DatabaseWindowTitle.title(name: "local", dbIndex: 0) == "local")
        #expect(DatabaseWindowTitle.title(name: "local", dbIndex: 2) == "local [db2]")
        #expect(DatabaseWindowTitle.title(name: String(repeating: "a", count: 40), dbIndex: 0).count == 33)
        #expect(DatabaseWindowTitle.subtitle(item: .browser, host: "127.0.0.1", port: 6390) == "Browser · 127.0.0.1:6390")
        #expect(DatabaseWindowTitle.subtitle(item: .databaseAnalysis, host: "h", port: 1) == "Database Analysis · h:1")
    }
}

struct LaunchOptionsTests {
    @Test func parsesOpenTargets() {
        #expect(LaunchOptions(arguments: ["app", "--open", "127.0.0.1:6390/4"]).target
            == .endpoint(host: "127.0.0.1", port: 6390, db: 4))
        #expect(LaunchOptions(arguments: ["app", "--open-id", "abc"]).target == .id(DatabaseID(rawValue: "abc")))
        #expect(LaunchOptions(arguments: ["app", "--open", "nohost"]).target == nil)
        #expect(LaunchOptions(arguments: ["app"]).isActive == false)
    }

    @Test func parsesQAFlags() {
        let options = LaunchOptions(arguments: [
            "app", "--open", "127.0.0.1:6390", "--section", "slowlog", "--tool", "cli", "--tool", "profiler",
            "--tool", "helper", "--inspector", "tips", "--appearance", "light", "--window-size", "1280x800",
            "--sheet", "new-key",
        ])
        #expect(options.isActive)
        #expect(options.section == .slowLog)
        #expect(options.tools == [.cli, .profiler, .commandHelper])
        #expect(options.inspector == .tips)
        #expect(options.appearance == .light)
        #expect(options.windowSize == CGSize(width: 1280, height: 800))
        #expect(options.sheet == "new-key")
        #expect(options.suppressesHome)
    }

    @Test func keyImpliesBrowser() {
        let options = LaunchOptions(arguments: ["app", "--open", "h:1", "--key", "user:1"])
        #expect(options.key == "user:1")
        #expect(options.section == .browser)
    }

    @Test func homeFlags() {
        let settings = LaunchOptions(arguments: ["app", "--settings"])
        #expect(settings.settingsPage == "")
        #expect(!settings.suppressesHome)
        #expect(LaunchOptions(arguments: ["app", "--settings", "advanced"]).settingsPage == "advanced")
        #expect(LaunchOptions(arguments: ["app", "--settings", "--shortcuts"]).shortcuts)
        let home = LaunchOptions(arguments: ["app", "--home", "--add-database", "--open", "h:1"])
        #expect(home.addDatabase)
        #expect(!home.suppressesHome)
    }

    @Test func sectionFlagValues() {
        #expect(DatabaseSidebarItem(flag: "analysis") == .databaseAnalysis)
        #expect(DatabaseSidebarItem(flag: "cluster") == .clusterDetails)
        #expect(DatabaseSidebarItem(flag: "vectorsearch") == .vectorSearch)
        #expect(DatabaseSidebarItem(flag: "pubsub") == .pubSub)
        #expect(DatabaseSidebarItem(flag: "nope") == nil)
        #expect(InspectorPane(flag: "helper") == .commandHelper)
        #expect(LaunchOptions(arguments: ["app", "--window-size", "12x800"]).windowSize == nil)
    }

    @Test func valuesAreCaseInsensitive() {
        let options = LaunchOptions(arguments: [
            "app", "--section", "SlowLog", "--tool", "CLI", "--appearance", "Dark", "--sheet", "New-Key",
            "--settings", "Advanced", "--window-size", "1280X800",
        ])
        #expect(options.section == .slowLog)
        #expect(options.tools == [.cli])
        #expect(options.appearance == .dark)
        #expect(options.sheet == "new-key")
        #expect(options.settingsPage == "advanced")
        #expect(options.windowSize == CGSize(width: 1280, height: 800))
        #expect(LaunchOptions(arguments: ["app", "--settings", "nope"]).settingsPage == "")
    }
}

struct ActivityViewTests {
    @Test func alertMessagesAreTruncated() {
        let long = String(repeating: "x", count: 500)
        #expect(ErrorAlerts.alertMessage(long)?.count == 401)
        #expect(ErrorAlerts.alertMessage("short") == "short")
        #expect(ErrorAlerts.alertMessage("") == nil)
    }

    @MainActor
    @Test func dismissingAnAlertTwiceKeepsTheNextError() {
        let center = ToastCenter()
        center.error("first")
        center.error("second")
        let first = center.toasts.first?.id
        center.dismissFront(id: first)
        center.dismissFront(id: first)
        #expect(center.toasts.map(\.message) == ["second"])
        center.dismissFront(id: nil)
        #expect(center.toasts.count == 1)
    }

    @Test func longMessagePredicateMatchesTheAlertCut() {
        let exact = String(repeating: "x", count: Toast.longMessageThreshold)
        #expect(!Toast(title: "t", message: exact).hasLongMessage)
        #expect(ErrorAlerts.alertMessage(exact) == exact)
        #expect(Toast(title: "t", message: exact + "y").hasLongMessage)
    }

    @Test func quitWaitsLongerForPostDisconnectScripts() {
        var plain = DatabaseConfig(host: "h", port: 1)
        #expect(AppShellDelegate.quitWait([plain], scriptTimeout: 120) == .seconds(2))
        plain.postDisconnectScript = "  "
        #expect(AppShellDelegate.quitWait([plain], scriptTimeout: 120) == .seconds(2))
        var scripted = plain
        scripted.postDisconnectScript = "echo bye"
        #expect(AppShellDelegate.quitWait([plain, scripted], scriptTimeout: 120) == .seconds(122))
    }

    @Test func lastWindowCloseAsksOnlyWhileADatabaseIsConnected() {
        #expect(LastWindowCloseGuard.message(connectedDatabases: []) == nil)
        #expect(LastWindowCloseGuard.message(connectedDatabases: ["cache"])
                == "Closing the last window disconnects from “cache” and quits Keystrand.")
        #expect(LastWindowCloseGuard.message(connectedDatabases: ["cache", "queue"])
                == "Closing the last window disconnects from 2 databases and quits Keystrand.")
    }

    @Test func activityConnectionStatus() {
        #expect(ActivityConnectionStatus.make(phase: .content, isLost: false) == .connected)
        #expect(ActivityConnectionStatus.make(phase: .content, isLost: true) == .lost)
        #expect(ActivityConnectionStatus.make(phase: .failed(.timeout), isLost: false) == .failed)
        #expect(ActivityConnectionStatus.make(phase: .connecting, isLost: false) == .connecting)
    }

    @Test func logicalDatabaseMenuIndexes() {
        #expect(LogicalDatabasePicker.menuIndexes(count: 16, current: 0) == Array(0..<16))
        #expect(LogicalDatabasePicker.menuIndexes(count: 100, current: 70).count == 65)
        #expect(LogicalDatabasePicker.menuIndexes(count: 0, current: 0) == [0])
    }
}

struct RecentDatabasesTests {
    @MainActor
    @Test func newestTenAfterClear() {
        let now = Date()
        let configs = (0..<14).map { index in
            DatabaseConfig(name: "db\(index)", host: "h", port: 1, lastConnection: now.addingTimeInterval(Double(index)))
        } + [DatabaseConfig(name: "never", host: "h", port: 1)]
        let recent = RecentDatabases.recent(configs, clearedAt: nil)
        #expect(recent.count == 10)
        #expect(recent.first?.name == "db13")
        #expect(RecentDatabases.recent(configs, clearedAt: now.addingTimeInterval(11.5)).map(\.name) == ["db13", "db12"])
    }
}
