import RedisUI
import SwiftUI

struct QueryLibraryView: View {
    @Bindable var page: QueryPageViewModel

    var body: some View {
        VStack(spacing: 0) {
            if page.showsLibrarySearch {
                SearchField(text: $page.librarySearch, placeholder: "Search Queries")
                    .padding(8)
                Divider()
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .destructiveConfirmation(item: $page.pendingLibraryDelete,
                                 title: { "Delete “\(TextTruncation.formatLongName($0.name, maxLength: 60, tail: 10))”?" },
                                 message: { _ in "The saved query will be removed. Your index and data are not affected." }) { item in
            Task { await page.deleteLibraryItem(item) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if page.isLoadingLibrary && !page.libraryLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if page.libraryError != nil {
            ErrorStateView(message: "The Query Library could not be loaded.") { Task { await page.loadLibrary() } }
        } else if page.filteredLibrary.isEmpty {
            if page.libraryItems.isEmpty {
                ContentUnavailableView("No Saved Queries", systemImage: "books.vertical",
                                       description: Text(page.libraryEmptyMessage))
            } else {
                ContentUnavailableView.search(text: page.librarySearch)
            }
        } else {
            List {
                ForEach(page.filteredLibrary) { item in
                    LibraryItemRow(item: item, page: page)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct LibraryItemRow: View {
    let item: QueryLibraryItem
    let page: QueryPageViewModel

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { page.expandedLibraryItemID == item.id },
                                            set: { _ in page.toggleLibraryItem(item) })) {
            CodeEditorView(text: .constant(item.query), language: .redis, isEditable: false, showsLineNumbers: false,
                           minHeight: 34, maxHeight: 180)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                        .help(TextTruncation.formatLongName(item.name))
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(TextTruncation.formatLongName(description))
                    }
                }
                Spacer(minLength: 8)
                Text(item.type == .sample ? "Sample" : "Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Load") { page.load(item) }
                    .buttonStyle(.borderless)
                    .help("Load into the query editor")
                Button("Run") { Task { await page.run(item) } }
                    .buttonStyle(.borderless)
                    .disabled(page.isRunning)
                    .help("Run this query")
            }
            .accessibilityElement(children: .combine)
        }
        .contextMenu {
            Button("Load") { page.load(item) }
            Button("Run") { Task { await page.run(item) } }.disabled(page.isRunning)
            Divider()
            Button("Copy Name") { Pasteboard.copy(item.name) }
            Button("Copy Query") { Pasteboard.copy(item.query) }
            Divider()
            Button("Delete Query…", role: .destructive) { page.pendingLibraryDelete = item }
        }
    }
}
