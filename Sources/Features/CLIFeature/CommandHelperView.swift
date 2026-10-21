import RedisUI
import SwiftUI

/// Inspector > Commands pane: command search, group filter and Quick Help style command documentation.
public struct CommandHelperView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var body: some View {
        CommandHelperContentView(context: session.scopedObject(CommandHelperContext.self) { CommandHelperContext() })
    }
}

struct CommandHelperContentView: View {
    let context: CommandHelperContext
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            searchRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            context.loadIfNeeded()
            searchText = context.searchText
        }
        .onChange(of: context.searchText) { _, newValue in
            if newValue != searchText { searchText = newValue }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            SearchField(text: $searchText, placeholder: "Search Commands",
                        debounce: .milliseconds(150),
                        onDebouncedChange: { context.setSearchText($0) })
                .disabled(context.isLoading)
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty { context.setSearchText("") }
                }
            groupFilterMenu
        }
    }

    private var groupFilterMenu: some View {
        Menu {
            Toggle("All Groups", isOn: Binding(get: { context.groupFilter == nil }, set: { _ in
                if let group = context.groupFilter { context.setGroupFilter(group) }
            }))
            Divider()
            ForEach(context.visibleGroups, id: \.self) { group in
                Toggle(CommandGroups.displayName(group), isOn: Binding(
                    get: { context.groupFilter == group },
                    set: { _ in context.setGroupFilter(group) }))
            }
        } label: {
            Label("Filter by Group", systemImage: context.groupFilter == nil
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(context.isLoading)
        .help(context.groupFilter.map { "Filtered by \(CommandGroups.displayName($0))" } ?? "Filter by Group")
    }

    @ViewBuilder
    private var content: some View {
        if let error = context.loadError {
            ErrorStateView(message: error)
        } else if context.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if context.isSearching {
            CommandSearchResultsView(results: context.searchResults, searchText: context.searchText) {
                context.showDetails($0)
            }
        } else if let spec = context.displayedSpec {
            CommandDetailView(spec: spec, canGoBack: context.canGoBack) { context.backToResults() }
        } else {
            ContentUnavailableView("Command Helper", systemImage: "book",
                                   description: Text("Type a command in the CLI or search to see its documentation."))
        }
    }
}

struct CommandSearchResultsView: View {
    let results: [CommandSpec]
    let searchText: String
    let onSelect: (String) -> Void
    @State private var selection: String?

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(results, id: \.name, selection: $selection) { spec in
                CommandSearchRow(spec: spec)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { selection = nil }
            .onChange(of: selection) { _, name in
                if let name { onSelect(name) }
            }
            .contextMenu(forSelectionType: String.self) { names in
                if let name = names.first, let spec = results.first(where: { $0.name == name }) {
                    Button("Show Documentation") { onSelect(name) }
                    Divider()
                    Button("Copy Command Name") { copy(spec.name) }
                    Button("Copy Syntax") { copy(CommandSyntax.render(spec)) }
                }
            } primaryAction: { names in
                if let name = names.first { onSelect(name) }
            }
        }
    }
}

struct CommandSearchRow: View {
    let spec: CommandSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.name)
                .font(.body.monospaced().weight(.semibold))
            Text(CommandSyntax.argumentsLine(spec) ?? spec.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
        .help(spec.summary)
        .accessibilityElement(children: .combine)
    }
}

struct CommandDetailView: View {
    let spec: CommandSpec
    let canGoBack: Bool
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if canGoBack {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to Search Results")
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(spec.name)
                        .font(.title3.weight(.semibold).monospaced())
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    CopyButton(text: CommandSyntax.render(spec), help: "Copy Syntax")
                }
                Text(CommandSyntax.render(spec))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !spec.summary.isEmpty {
                    Text(spec.summary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    detailRow("Group", CommandGroups.displayName(spec.group))
                    if let complexity = spec.complexity, !complexity.isEmpty {
                        detailRow("Complexity", complexity)
                    }

                    if let since = spec.since, !since.isEmpty {
                        detailRow("Since", since)
                    }
                }
                .font(.callout)
                if !spec.arguments.isEmpty {
                    Divider()
                    Text("Arguments").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(spec.arguments.enumerated()), id: \.offset) { _, argument in
                            ArgumentRow(argument: argument)
                        }
                    }
                }

                if let url = CommandSyntax.docURL(for: spec.name) {
                    Link("Read More", destination: url)
                        .help(url.absoluteString)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ArgumentRow: View {
    let argument: CommandArgument

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(CommandSyntax.syntax(argument, pureName: true))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(CommandSyntax.kindLabel(argument))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(argument.summary ?? "")
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
