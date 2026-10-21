import Foundation
import Observation
import RedisUI

/// An open tutorial page: parsed markdown plus its position among the sibling pages.
public struct TutorialPage: Identifiable, Sendable {
    public var node: TutorialNode
    public var blocks: [MarkdownBlock]
    public var baseURL: URL?
    public var parentLabel: String
    public var siblings: [TutorialNode]

    public var id: String { node.id }
    public var index: Int { siblings.firstIndex { $0.id == node.id } ?? 0 }
    public var previous: TutorialNode? { index > 0 && index - 1 < siblings.count ? siblings[index - 1] : nil }
    public var next: TutorialNode? { index + 1 < siblings.count ? siblings[index + 1] : nil }
}

/// What happens when a tutorial code block's Run is pressed.
public enum TutorialRunCheck: Equatable, Sendable {
    case ready
    case needsConfirmation
    case production
    case notExecutable
    case moduleMissing(CommandModuleRequirement)
}

/// Insights > Tutorials state for one database window (tree, open page, search, run confirmation).
@MainActor
@Observable
public final class TutorialsViewModel {
    public static let productionRunTooltip =
        "Turned off on production databases so tutorials can't change data by accident."
    public static let runTooltip = "Runs in Workbench, where the results appear."

    public let session: DatabaseSession
    public private(set) var library: TutorialLibrary?
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public var expandedGroups: Set<String> = []
    public private(set) var page: TutorialPage?
    public private(set) var isLoadingPage = false
    public private(set) var pageError: String?
    public var searchText = ""
    public private(set) var searchResults: [TutorialSearchHit] = []
    public private(set) var skipRunConfirmation = false

    @ObservationIgnored private var pageScroll: (pageID: String, offset: CGFloat)?
    @ObservationIgnored private var contents: [String: String]?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPageID: String?
    @ObservationIgnored private var settingsLoaded = false

    public init(session: DatabaseSession) {
        self.session = session
    }

    public static func shared(for session: DatabaseSession) -> TutorialsViewModel {
        session.scopedObject(TutorialsViewModel.self) { TutorialsViewModel(session: session) }
    }

    public var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - Loading

    public func load() async {
        if !settingsLoaded {
            settingsLoaded = true
            let settings = await session.services.databaseSettingsStore.settings(for: session.id)
            skipRunConfirmation = settings.notShowConfirmationRunTutorial
        }

        guard library == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try TutorialLibrary.bundled() }.value
            library = loaded
            loadError = nil
            expandedGroups = Self.initiallyOpenGroups(loaded.root)
            if let pendingPageID {
                self.pendingPageID = nil
                await open(id: pendingPageID)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    static func initiallyOpenGroups(_ root: TutorialNode) -> Set<String> {
        var out: Set<String> = []

        func walk(_ node: TutorialNode) {
            if node.isGroup, node.args?.initialIsOpen == true { out.insert(node.id) }
            for child in node.children ?? [] { walk(child) }
        }

        walk(root)
        return out
    }

    public func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
    }

    // MARK: - Pages

    /// Opens a page by manifest id (nil shows the tree).
    public func open(id: String?) async {
        guard let id else {
            closePage()
            return
        }
        guard let library else {
            pendingPageID = id
            return
        }
        guard let node = library.node(id: id), node.isPage else {
            pageError = TutorialError.notFound(id).localizedDescription
            return
        }
        isLoadingPage = true
        defer { isLoadingPage = false }
        let parentLabel = library.parent(of: id)?.label ?? library.root.label
        let siblings = library.siblings(of: id)
        do {
            let (blocks, base) = try await Task.detached(priority: .userInitiated) {
                let markdown = try library.markdown(for: node)
                let blocks = Self.droppingTitle(MarkdownParser.parse(markdown))
                return (blocks, library.fileURL(for: node)?.deletingLastPathComponent())
            }.value
            if page?.id != node.id { pageScroll = nil }
            page = TutorialPage(node: node, blocks: blocks, baseURL: base,
                                parentLabel: TutorialLibrary.startCase(parentLabel), siblings: siblings)
            pageError = nil
        } catch {
            pageError = error.localizedDescription
        }
    }

    /// The page view shows the manifest label as the title, so a leading `# Title` is not rendered twice.
    nonisolated static func droppingTitle(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        guard case .heading(level: 1, _)? = blocks.first else { return blocks }
        return Array(blocks.dropFirst())
    }

    public func closePage() {
        page = nil
        pageError = nil
        pageScroll = nil
    }

    /// Scroll offset to restore for the open page (0 for any other page).
    public func scrollOffset(for pageID: String) -> CGFloat {
        guard let pageScroll, pageScroll.pageID == pageID, page?.id == pageID else { return 0 }
        return pageScroll.offset
    }

    public func recordScrollOffset(_ offset: CGFloat, for pageID: String) {
        guard page?.id == pageID else { return }
        pageScroll = (pageID, max(offset, 0))
    }

    /// Relative links to other tutorial pages open in the panel; returns true when handled.
    public func handleLink(_ url: URL) -> Bool {
        guard let library, let current = page?.node,
              let target = library.page(linkedFrom: url, on: current) else { return false }
        Task { await open(id: target.id) }
        return true
    }

    // MARK: - Search

    public func updateSearch(_ text: String) {
        searchText = text
        searchTask?.cancel()
        guard isSearching, let library else {
            searchResults = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            let contents = await self.loadContents(library)
            let hits = await Task.detached { library.search(text, contents: contents) }.value
            guard !Task.isCancelled, self.searchText == text else { return }
            self.searchResults = hits
        }
    }

    /// Waits for the pending debounced search.
    public func waitForSearch() async {
        await searchTask?.value
    }

    private func loadContents(_ library: TutorialLibrary) async -> [String: String] {
        if let contents { return contents }
        let loaded = await Task.detached(priority: .userInitiated) {
            var out: [String: String] = [:]
            for page in library.allPages {
                out[page.id] = try? library.markdown(for: page)
            }

            return out
        }.value
        contents = loaded
        return loaded
    }

    // MARK: - Running code blocks

    public func check(code: String, fence: TutorialFence) -> TutorialRunCheck {
        guard fence.isExecutable else { return .notExecutable }
        if session.isProduction { return .production }
        let commands = (try? WorkbenchScriptParser.parse(code)) ?? []
        for command in commands {
            if let requirement = session.capabilities.missingModule(for: command) {
                return .moduleMissing(requirement)
            }
        }

        if fence.runConfirmation, !skipRunConfirmation { return .needsConfirmation }
        return .ready
    }

    /// Runs the block in this window's Workbench with the fence params and shows the Workbench.
    @discardableResult
    public func run(code: String, fence: TutorialFence) async -> Bool {
        session.navigator.navigate(.workbench(script: nil))
        let workbench = WorkbenchViewModel.shared(for: session)
        return await workbench.run(script: code, params: fence.executeParams, source: .tutorial)
    }

    /// `Don't show again for this database`.
    public func setSkipRunConfirmation(_ skip: Bool) async {
        skipRunConfirmation = skip
        do {
            _ = try await session.services.databaseSettingsStore.update(session.id) {
                $0.notShowConfirmationRunTutorial = skip
            }
        } catch {
            session.toasts.error(error)
        }
    }

    /// Parsed commands of a block (what `Copy` puts on the pasteboard).
    nonisolated public static func copyText(_ code: String) -> String {
        let commands = (try? WorkbenchScriptParser.parse(code)) ?? []
        return commands.isEmpty ? code : commands.joined(separator: "\n")
    }
}
