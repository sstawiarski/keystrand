import Foundation
import Observation
import RedisCore

/// Command Helper state shared with the CLI. Typing shows the matched command; searching overrides it.
@MainActor
@Observable
public final class CommandHelperContext {
    public static let defaultText = "Type a command in the CLI, or search here, to read its reference."
    public static let noResultsText = "No results found."

    public private(set) var catalog: CommandCatalog?
    /// Command matched from the CLI input ("" when none).
    public private(set) var matchedCommand = ""
    /// Command picked from the search results.
    public private(set) var searchedCommand = ""
    public private(set) var searchText = ""
    public private(set) var groupFilter: String?
    public private(set) var isSearching = false
    public private(set) var isEnteringCommand = false
    public private(set) var loadError: String?

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init(catalog: CommandCatalog? = nil) {
        self.catalog = catalog
    }

    public var isLoading: Bool { catalog == nil && loadError == nil }

    /// Loads the bundled command specs off the main actor (first use only).
    public func loadIfNeeded() {
        guard catalog == nil, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { CommandCatalog.shared }.value
            guard let self else { return }
            if loaded.commands.isEmpty {
                self.loadError = "Command specifications could not be loaded."
            } else {
                self.catalog = loaded
            }

            self.loadTask = nil
        }
    }

    // MARK: - Derived state

    /// Name of the command whose details are shown.
    public var displayedCommandName: String {
        if isEnteringCommand, !matchedCommand.isEmpty { return matchedCommand }
        return searchedCommand
    }

    public var displayedSpec: CommandSpec? {
        guard !isSearching, let catalog, !displayedCommandName.isEmpty else { return nil }
        guard let spec = catalog.spec(named: displayedCommandName), !CommandGroups.isDeprecatedCommand(spec) else {
            return nil
        }
        return spec
    }

    public var searchResults: [CommandSpec] {
        guard isSearching, let catalog else { return [] }
        return catalog.search(containing: searchText, group: groupFilter)
    }

    public var visibleGroups: [String] {
        catalog?.visibleGroups ?? []
    }

    /// True when the details came from the search results, so Back returns to them.
    public var canGoBack: Bool {
        !isSearching && displayedCommandName == searchedCommand && !searchedCommand.isEmpty
            && (!searchText.isEmpty || groupFilter != nil)
    }

    // MARK: - CLI

    /// Called on every CLI input change.
    public func cliInputChanged(_ text: String) {
        isEnteringCommand = true
        let name = matchName(for: text)
        if name != matchedCommand {
            matchedCommand = name
            clearSearch()
        } else if isSearching, !name.isEmpty {
            clearSearch()
        }
    }

    /// Spec name matched by a CLI line (first two words, then first word), ignoring a repeat prefix.
    public func matchName(for text: String) -> String {
        guard let catalog else { return "" }
        let line = CLICommandPlanner.strippingRepeat(text)
        guard let spec = catalog.match(line: line), !CommandGroups.isDeprecatedCommand(spec) else { return "" }
        return spec.name
    }

    // MARK: - Search

    public func setSearchText(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty, groupFilter == nil {
            clearSearch()
            isEnteringCommand = true
            return
        }

        searchText = text
        isSearching = true
        isEnteringCommand = false
    }

    /// Selecting the active group again clears the filter.
    public func setGroupFilter(_ group: String?) {
        let next = group == groupFilter ? nil : group
        if next == nil, searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            clearSearch()
            isEnteringCommand = true
            return
        }

        groupFilter = next
        isSearching = true
        isEnteringCommand = false
    }

    public func showDetails(_ name: String) {
        searchedCommand = name
        isSearching = false
        isEnteringCommand = false
    }

    public func backToResults() {
        isSearching = true
        isEnteringCommand = false
    }

    public func clearSearch() {
        searchText = ""
        searchedCommand = ""
        groupFilter = nil
        isSearching = false
    }
}
