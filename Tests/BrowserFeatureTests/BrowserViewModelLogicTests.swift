import Foundation
@testable import BrowserFeature
import RedisCore
import TestSupport
import Testing

@MainActor
struct BrowserViewModelLogicTests {
    private func folder(_ display: String, options: KeyTreeOptions) throws -> KeyTreeNode {
        let roots = KeyTreeBuilder.build([KeyTreeInput(name: Data(display.utf8), display: display)], options: options)
        return try #require(roots.first { !$0.isLeaf })
    }

    @Test func folderPatternEscapesGlobDelimiters() async throws {
        let model = BrowserViewModel(session: RedisTestServer.mockSession())
        await model.ensureSettingsLoaded()
        let cases: [(String, String)] = [("?", #"a\?*"#), ("*", #"a\**"#), ("[", #"a\[*"#), (":", "a:*")]
        for (delimiter, expected) in cases {
            model.applyTreeSettings(delimiters: [delimiter], prefixLength: 0, sort: .asc)
            let node = try folder("a\(delimiter)b", options: model.treeOptions)
            #expect(model.folderPattern(node) == expected)
        }

        model.applyTreeSettings(delimiters: [":"], prefixLength: 0, sort: .asc)
        let node = try folder("x*y:z", options: model.treeOptions)
        #expect(model.folderPattern(node) == #"x\*y:*"#)
    }

    @Test func searchPagingStopsAtMaxResults() {
        #expect(BrowserViewModel.searchNextOffset(500, maxResults: nil) == 500)
        #expect(BrowserViewModel.searchNextOffset(500, maxResults: 1_000) == 500)
        #expect(BrowserViewModel.searchNextOffset(1_000, maxResults: 1_000) == nil)
        #expect(BrowserViewModel.searchNextOffset(1_200, maxResults: 1_000) == nil)
        #expect(BrowserViewModel.searchNextOffset(nil, maxResults: 1_000) == nil)
    }

    @Test func searchLimitNoticeOnlyInSearchMode() {
        let model = BrowserViewModel(session: RedisTestServer.mockSession())
        #expect(model.searchLimitNotice == nil)
    }

    @Test func indexPickerFiltersByName() {
        let indexes = ["idx:trails", "idx:Recipes", "users"].map { Data($0.utf8) }
        #expect(SearchIndexPicker.filtered(indexes, query: "") == indexes)
        #expect(SearchIndexPicker.filtered(indexes, query: "  ") == indexes)
        #expect(SearchIndexPicker.filtered(indexes, query: "recipes") == [Data("idx:Recipes".utf8)])
        #expect(SearchIndexPicker.filtered(indexes, query: "idx").count == 2)
        #expect(SearchIndexPicker.filtered(indexes, query: "nothing").isEmpty)
    }

    @Test func searchModeUnavailableWithoutModule() {
        let model = BrowserViewModel(session: RedisTestServer.mockSession())
        #expect(!model.isSearchAvailable)
        #expect(model.searchUnavailableReason == .moduleNotLoaded)
        #expect(model.searchUnavailableReason?.title == "Redis Search Not Available")
        #expect(SearchUnavailableReason.versionTooOld.title == "Redis Search Version Too Old")
        model.setSearchMode(.redisearch)
        #expect(model.searchMode == .pattern)
    }

    @Test func wheelScanIsIgnoredWithoutFilter() {
        let model = BrowserViewModel(session: RedisTestServer.mockSession())
        #expect(!model.wantsWheelScanMore)
        model.listScrolledDown()
        #expect(!model.isScanningMore)
    }
}

@MainActor
struct AddKeySubmitTests {
    private static let deniedExpire = "NOPERM User u has no permissions to run the 'expire' command"

    private func form(_ reply: RESPValue) -> AddKeyViewModel {
        let form = AddKeyViewModel(session: RedisTestServer.mockSession(MockRedisClient(responses: ["EVAL": reply])))
        form.type = .set
        form.keyName = "k"
        form.ttlText = "60"
        form.setMembers = [AddKeyTextRow(value: "a")]
        return form
    }

    @Test func keyCreatedWithoutTTLCountsAsAddedAndReportsTheError() async throws {
        let form = form(.array([.integer(2), .bulk(Self.deniedExpire)]))
        let result = try #require(await form.submit())
        #expect(result.name == Data("k".utf8))
        #expect(result.type == .set)
        #expect(form.errorMessage == nil)
        let toasts = form.session.toasts.toasts
        #expect(toasts.map(\.title) == [KeyOperationError.createdWithoutTTLTitle])
        #expect(toasts.first?.message == KeyOperationError.createdWithoutTTL(Self.deniedExpire).localizedDescription)
    }

    @Test func ttlErrorWaitsUntilTheSheetCloses() async throws {
        let form = form(.array([.integer(2), .bulk(Self.deniedExpire)]))
        let toasts = form.session.toasts
        _ = toasts.presenters.push()
        #expect(await form.submit() != nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(toasts.toasts.isEmpty)
        toasts.presenters.pop()
        #expect(await waitUntil { !toasts.toasts.isEmpty })
        #expect(toasts.toasts.map(\.title) == [KeyOperationError.createdWithoutTTLTitle])
    }

    @Test func existingKeyKeepsTheFormOpenWithAnInlineError() async {
        let form = form(.integer(0))
        #expect(await form.submit() == nil)
        #expect(form.errorMessage == "This key name is already in use.")
        #expect(form.session.toasts.toasts.isEmpty)
    }

    @Test func failedCreationShowsTheServerErrorInline() async {
        let wrongType = "WRONGTYPE Operation against a key holding the wrong kind of value"
        let form = form(.array([.integer(1), .bulk(wrongType)]))
        #expect(await form.submit() == nil)
        #expect(form.errorMessage == wrongType)
        #expect(form.session.toasts.toasts.isEmpty)
    }
}
