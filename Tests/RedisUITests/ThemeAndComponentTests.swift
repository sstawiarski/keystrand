import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import RedisUI

@Suite("Theme and small components")
struct ThemeAndComponentTests {
    @Test func themeModeMapping() {
        #expect(ThemeMode.system.colorScheme == nil)
        #expect(ThemeMode.dark.colorScheme == .dark)
        #expect(ThemeMode.light.colorScheme == .light)
        #expect(ThemeMode.system.appearance == nil)
        #expect(ThemeMode.dark.appearance?.name == .darkAqua)
    }

    @Test func launchAppearanceOverridesSavedMode() {
        #expect(ThemeApplier.effectiveMode(saved: .system, launchOverride: nil) == .system)
        #expect(ThemeApplier.effectiveMode(saved: .system, launchOverride: .dark) == .dark)
        #expect(ThemeApplier.effectiveMode(saved: .dark, launchOverride: .light) == .light)
    }

    @Test func editorAppearanceUsesDynamicSystemColors() {
        #expect(EditorAppearance.nsBackground == .textBackgroundColor)
        #expect(EditorAppearance.nsText == .textColor)
        #expect(EditorAppearance.gutterText == .tertiaryLabelColor)
        #expect(EditorAppearance.gutterActiveText == .secondaryLabelColor)
        #expect(EditorAppearance.commandMarker == .systemGreen)
        #expect(EditorAppearance.Syntax.keyword == .systemPink)
        #expect(EditorAppearance.Syntax.function == .systemPurple)
        #expect(EditorAppearance.Syntax.string == .systemRed)
        #expect(EditorAppearance.Syntax.number == .systemBlue)
        #expect(EditorAppearance.Syntax.params == .systemOrange)
        #expect(EditorAppearance.Syntax.operatorToken == .systemTeal)
        #expect(EditorAppearance.Syntax.color(for: .comment) == .secondaryLabelColor)
        #expect(EditorAppearance.font().isFixedPitch)
        #expect(EditorAppearance.font().pointSize == NSFont.systemFontSize)

        func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor? {
            var result: NSColor?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB)
            }
            return result
        }

        let light = resolved(EditorAppearance.nsBackground, .aqua)
        let dark = resolved(EditorAppearance.nsBackground, .darkAqua)
        #expect(light != nil && dark != nil)
        #expect(light != dark)
        #expect((light?.brightnessComponent ?? 0) > (dark?.brightnessComponent ?? 1))
    }

    @Test func keyTypeSymbolsAndEverySymbolInTheDesignExist() {
        let types: [KeyType] = [.string, .hash, .list, .set, .zset, .stream, .json, .timeSeries, .vectorSet, .array,
                                .graph, .unknown("MBbloom--")]
        for type in types {
            #expect(NSImage(systemSymbolName: type.symbolName, accessibilityDescription: nil) != nil, "\(type.symbolName)")
        }

        let designSymbols = [
            "arrow.clockwise", "arrow.counterclockwise", "arrow.down.doc", "arrow.triangle.2.circlepath", "arrow.up.circle",
            "arrow.up.doc", "bolt.horizontal.circle", "book", "building.2", "cart", "chart.pie", "chart.xyaxis.line",
            "checkmark", "checkmark.circle.fill", "checkmark.seal", "chevron.left", "chevron.left.forwardslash.chevron.right",
            "chevron.right", "clock", "cylinder.split.1x2", "doc.on.doc", "doc.text", "dot.radiowaves.left.and.right",
            "ellipsis.circle", "exclamationmark.circle.fill", "exclamationmark.shield", "exclamationmark.shield.fill",
            "exclamationmark.triangle", "exclamationmark.triangle.fill", "folder", "folder.fill", "gearshape",
            "gearshape.2", "info.circle", "info.circle.fill", "key", "lightbulb", "line.3.horizontal.decrease.circle",
            "line.3.horizontal.decrease.circle.fill", "list.bullet", "list.bullet.indent", "list.bullet.rectangle",
            "magnifyingglass", "minus.circle", "nosign", "number", "pause.circle", "play.circle", "play.fill", "plus",
            "plus.circle", "questionmark.circle", "questionmark.square.dashed", "record.circle",
            "rectangle.bottomthird.inset.filled", "rectangle.split.3x1", "server.rack", "shield.lefthalf.filled",
            "sidebar.trailing", "sparkle.magnifyingglass", "square.and.arrow.down", "square.and.arrow.up",
            "square.grid.3x3", "square.stack", "stop.circle", "terminal", "text.alignleft", "text.and.command.macwindow",
            "textformat", "tortoise", "tray", "water.waves", "waveform.path.ecg", "xmark", "xmark.octagon",
            "xmark.octagon.fill", "trash", "hammer", "hammer.fill", "tag", "film", "doc", "bolt", "externaldrive",
            "internaldrive", "graduationcap", "books.vertical", "doc.questionmark", "timer", "pencil", "clear",
            "arrow.down.to.line", "xmark.circle.fill", "arrow.down.right.and.arrow.up.left",
            "arrow.up.left.and.arrow.down.right",
        ]
        let missing = designSymbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        #expect(missing.isEmpty, "Missing SF Symbols: \(missing)")
    }

    @Test func commandGroupNames() {
        #expect(CommandGroupBadge.displayName(for: "sorted-set") == "Sorted Set")
        #expect(CommandGroupBadge.displayName(for: "pubsub") == "Pub/Sub")
        #expect(CommandGroupBadge.displayName(for: "bf") == "Bloom Filter")
        #expect(CommandGroupBadge.displayName(for: "search") == "search")
        #expect(CommandGroupBadge.displayName(for: "my_group") == "My group")
        #expect(CommandGroupBadge.displayName(for: "") == "")
    }

    @Test func tagAndModuleSummaries() {
        let tags = [DatabaseTag(key: "team", value: "core"), DatabaseTag(key: "app", value: "web")]
        #expect(TagText.text(tags) == "team: core, app: web")
        #expect(TagText.tooltip(tags) == "team: core\napp: web")
        #expect(TagText.text([]) == "")
        let modules = [RedisModuleInfo(name: "search", semanticVersion: "8.2.0"), RedisModuleInfo(name: "ReJSON"),
                       RedisModuleInfo(name: "timeseries"), RedisModuleInfo(name: "bf"), RedisModuleInfo(name: "vectorset")]
        #expect(ModuleSummaryText.summary(modules, maxVisible: 3) == "Redis Search, JSON, Time Series +2")
        #expect(ModuleSummaryText.summary(Array(modules.prefix(2)), maxVisible: 3) == "Redis Search, JSON")
        #expect(ModuleSummaryText.summary(modules, maxVisible: 0) == "+5")
        #expect(ModuleSummaryText.summary([], maxVisible: 3) == "")
        #expect(ModuleSummaryText.tooltip(Array(modules.prefix(2))) == "Redis Search v. 8.2.0\nJSON")
    }

    @Test func metadataRowPairsForNarrowGrid() {
        let items = ["Type", "Size", "Length"].map { KeyMetadataItem(label: $0, value: "1") }
        let pairs = KeyMetadataRow.pairs(items)
        #expect(pairs.count == 2)
        #expect(pairs[0].first.label == "Type" && pairs[0].second?.label == "Size")
        #expect(pairs[1].first.label == "Length" && pairs[1].second == nil)
        #expect(KeyMetadataRow.pairs([]).isEmpty)
    }

    @Test func chartPaletteCycles() {
        #expect(ChartPalette.colors.count == 12)
        #expect(ChartPalette.color(at: 0) == .blue)
        #expect(ChartPalette.color(at: 12) == .blue)
        #expect(ChartPalette.color(at: 13) == .green)
        #expect(ChartPalette.color(at: -1) == .red)
    }

    @Test func autoRefreshRules() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(AutoRefreshMenu.relative(from: now, now: now) == "now")
        #expect(AutoRefreshMenu.relative(from: now.addingTimeInterval(-30), now: now) == "30 s")
        #expect(AutoRefreshMenu.relative(from: now.addingTimeInterval(-90), now: now) == "< 1 min")
        #expect(AutoRefreshMenu.relative(from: now.addingTimeInterval(-600), now: now) == "10 min")
        #expect(AutoRefreshMenu.helpText(lastRefresh: nil, now: now) == "Refresh (⌘R)")
        #expect(AutoRefreshMenu.helpText(lastRefresh: now.addingTimeInterval(-30), now: now) == "Refresh (⌘R) · Last refreshed 30 s")
        #expect(AutoRefreshMenu.parseRate("12.34") == 12.3)
        #expect(AutoRefreshMenu.parseRate("0.2") == 1.0)
        #expect(AutoRefreshMenu.parseRate("5000") == 999.9)
        #expect(AutoRefreshMenu.parseRate("2,5") == 2.5)
        #expect(AutoRefreshMenu.parseRate("abc") == nil)
        #expect(AutoRefreshMenu.parseRate("3", minimum: 5) == 5)
        #expect(AutoRefreshMenu.rateTitle(1) == "1 second")
        #expect(AutoRefreshMenu.rateTitle(30) == "30 seconds")
        #expect(AutoRefreshMenu.rateTitle(2.5) == "2.5 seconds")
    }

    @Test func confirmationTexts() {
        let message = ConfirmationText.typeToConfirmMessage("Delete **all** keys", confirmationText: "prod-db")
        #expect(message == "Delete all keys\n\nType “prod-db” to confirm.\n\nTip: Restrict dangerous commands per user with Redis ACLs.")
        #expect(ConfirmationText.typeToConfirmMessage(nil, confirmationText: "x").hasPrefix("Type “x” to confirm."))
        #expect(ConfirmationText.matches("prod-db", expected: "prod-db"))
        #expect(!ConfirmationText.matches("prod-d", expected: "prod-db"))
        #expect(!ConfirmationText.matches("", expected: ""))
    }

    @Test func loadMoreAndFileRules() {
        #expect(LoadMoreRow.shouldLoadOnAppear(isLoading: false, loadsAutomatically: true))
        #expect(!LoadMoreRow.shouldLoadOnAppear(isLoading: true, loadsAutomatically: true))
        #expect(!LoadMoreRow.shouldLoadOnAppear(isLoading: false, loadsAutomatically: false))
        #expect(FileSelectionRules.validate(fileSize: 10, pathExtension: "json", allowedTypes: [.json], maxFileSize: 100) == nil)
        #expect(FileSelectionRules.validate(fileSize: 200, pathExtension: "json", allowedTypes: [.json], maxFileSize: 100) != nil)
        #expect(FileSelectionRules.validate(fileSize: 1, pathExtension: "png", allowedTypes: [.json], maxFileSize: nil) != nil)
        #expect(FileSelectionRules.validate(fileSize: 1, pathExtension: "png", allowedTypes: [.item], maxFileSize: nil) == nil)
        #expect(AddItemsButton.displayTitle("Add Fields") == "Add Fields…")
        #expect(AddItemsButton.displayTitle("Add Fields…") == "Add Fields…")
        #expect(AddItemsButton.displayTitle("Add...") == "Add…")
    }

    @Test func rangeSliderValueMapping() {
        #expect(RangeSliderView.value(at: 0, width: 100, bounds: 0...10, step: nil) == 0)
        #expect(RangeSliderView.value(at: 50, width: 100, bounds: 0...10, step: nil) == 5)
        #expect(RangeSliderView.value(at: 500, width: 100, bounds: 0...10, step: nil) == 10)
        #expect(RangeSliderView.value(at: 33, width: 100, bounds: 0...10, step: 1) == 3)
    }

    @Test func ttlText() {
        #expect(TTLText.text(nil) == "")
        #expect(TTLText.text(-1) == "No limit")
        #expect(TTLText.text(3_725) == "1 h")
        #expect(TTLText.text(3_725, full: true) == "1 h 2 min 5 s")
        #expect(TTLText.tooltip(-1) == "No limit")
        let reference = Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss, d MMM yyyy"
        let expected = "1 min\nExpires at " + formatter.string(from: Date(timeIntervalSince1970: 60))
        #expect(TTLText.tooltip(60, referenceDate: reference) == expected)
    }

    @Test func donutPercent() {
        #expect(DonutChartView.percent(1, of: 4) == "25%")
        #expect(DonutChartView.percent(1, of: 30) == "3.3%")
        #expect(DonutChartView.percent(1, of: 0) == "0%")
    }

    @Test func commandLineFieldTextWidth() {
        #expect(CommandLineField.textWidth("", fontSize: 13) == 0)
        #expect(CommandLineField.textWidth("GET", fontSize: 13) > 0)
        #expect(CommandLineField.textWidth("GET key", fontSize: 13) > CommandLineField.textWidth("GET", fontSize: 13))
    }
}

@Suite("QA launch options")
struct QALaunchOptionsTests {
    @Test func emptyArgumentsAreInactive() {
        let options = QALaunchOptions(arguments: ["Keystrand"])
        #expect(!options.isActive)
        #expect(options == QALaunchOptions(arguments: []))
        #expect(options.tools.isEmpty && options.section == nil && options.appearance == nil)
    }

    @Test func parsesEveryFlag() {
        let options = QALaunchOptions(arguments: [
            "Keystrand", "--open", "127.0.0.1:6390/4", "--section", "Workbench", "--tool", "cli", "--tool", "profiler",
            "--inspector", "tips", "--sheet", "new-key", "--appearance", "dark", "--window-size", "1280x800",
        ])
        #expect(options.isActive)
        #expect(options.section == "workbench")
        #expect(options.tools == ["cli", "profiler"])
        #expect(options.inspector == "tips")
        #expect(options.sheet == "new-key")
        #expect(options.appearance == .dark)
        #expect(options.windowSize == CGSize(width: 1280, height: 800))
        #expect(!options.home && !options.shortcuts && options.settingsPage == nil)
    }

    @Test func keyImpliesBrowserAndKeepsCase() {
        let options = QALaunchOptions(arguments: ["--open", "h:1", "--key", "User:1001"])
        #expect(options.key == "User:1001")
        #expect(options.section == "browser")
    }

    @Test func homeSettingsAndShortcuts() {
        let home = QALaunchOptions(arguments: ["--home", "--add-database"])
        #expect(home.home && home.addDatabase && home.isActive)
        #expect(QALaunchOptions(arguments: ["--settings"]).settingsPage == "")
        #expect(QALaunchOptions(arguments: ["--settings", "--shortcuts"]).settingsPage == "")
        #expect(QALaunchOptions(arguments: ["--settings", "Advanced"]).settingsPage == "advanced")
        #expect(QALaunchOptions(arguments: ["--shortcuts"]).shortcuts)
        #expect(QALaunchOptions(arguments: ["--appearance", "light"]).appearance == .light)
        #expect(QALaunchOptions(arguments: ["--appearance", "sepia"]).appearance == nil)
        #expect(QALaunchOptions(arguments: ["--open-id", "abc"]).isActive)
    }

    @Test func malformedValues() {
        #expect(QALaunchOptions(arguments: ["--window-size", "big"]).windowSize == nil)
        #expect(QALaunchOptions(arguments: ["--window-size", "0x10"]).windowSize == nil)
        let missing = QALaunchOptions(arguments: ["--section", "--tool"])
        #expect(missing.section == nil && missing.tools.isEmpty && missing.isActive)
    }
}

@Suite("JSON tree navigation")
struct JSONTreeNavigationTests {
    private var rows: [JSONTreeRow] {
        let root = JSONTreeNode.value(.object([JSONMember(key: "a", value: .number("1")),
                                               JSONMember(key: "b", value: .array([.bool(true)]))]))
        return JSONTreeFlattener.rows(for: root, expanded: [.root, JSONPath([.key("b")])], includeAddRows: false)
    }

    @Test func upAndDownSkipClosingRows() {
        let paths = JSONTreeNavigation.nodePaths(rows)
        #expect(paths == [.root, JSONPath([.key("a")]), JSONPath([.key("b")]), JSONPath([.key("b"), .index(0)])])
        #expect(JSONTreeNavigation.move(from: nil, offset: 1, in: rows) == .root)
        #expect(JSONTreeNavigation.move(from: nil, offset: -1, in: rows) == JSONPath([.key("b"), .index(0)]))
        #expect(JSONTreeNavigation.move(from: JSONPath([.key("a")]), offset: 1, in: rows) == JSONPath([.key("b")]))
        #expect(JSONTreeNavigation.move(from: .root, offset: -1, in: rows) == .root)
        #expect(JSONTreeNavigation.move(from: nil, offset: 1, in: []) == nil)
    }

    @Test func leftCollapsesThenSelectsParent() {
        let b = JSONPath([.key("b")])
        #expect(JSONTreeNavigation.left(from: b, isExpandedContainer: true) == .collapse(b))
        #expect(JSONTreeNavigation.left(from: b.appending(index: 0), isExpandedContainer: false) == .select(b))
        #expect(JSONTreeNavigation.left(from: .root, isExpandedContainer: false) == .none)
    }

    @Test func doubleClickOnChevronIsDetectedAtEachDepth() {
        #expect(JSONTreeRowView.isOnDisclosure(x: 8, depth: 0))
        #expect(JSONTreeRowView.isOnDisclosure(x: 23, depth: 0))
        #expect(!JSONTreeRowView.isOnDisclosure(x: 24, depth: 0))
        #expect(!JSONTreeRowView.isOnDisclosure(x: 7, depth: 0))
        #expect(JSONTreeRowView.isOnDisclosure(x: 8 + 24, depth: 2))
        #expect(!JSONTreeRowView.isOnDisclosure(x: 8, depth: 2))
        #expect(JSONTreeRowView.isOnDisclosure(x: 8 + 96, depth: 20))
    }
}
