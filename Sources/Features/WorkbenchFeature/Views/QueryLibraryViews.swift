import RedisUI
import SwiftUI

/// Saved queries of this database: search, load into the editor, run, delete.
struct QueryLibrarySheet: View {
    let model: WorkbenchViewModel
    let dismiss: @MainActor () -> Void
    @State private var search = ""
    @State private var selection: QueryLibraryItem.ID?
    @State private var pendingDelete: QueryLibraryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Query Library").font(.title3.weight(.semibold))
                if model.isLoadingLibrary { ProgressView().controlSize(.small) }
                Spacer()
                if !model.libraryItems.isEmpty {
                    SearchField(text: $search, placeholder: "Search Queries")
                        .frame(width: 220)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("Load") { if let item = selected { load(item) } }
                    .disabled(selected == nil)
                Button("Run") { if let item = selected { run(item) } }
                    .disabled(selected == nil || model.isRunning)
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .sheetSize(.large)
        .task { await model.loadLibrary() }
        .destructiveConfirmation(item: $pendingDelete, title: { "Delete “\($0.name)”?" },
                                 message: { _ in "The query will be removed from the Query Library." }) { item in
            Task { await model.deleteQuery(item) }
        }
    }

    private var selected: QueryLibraryItem? {
        model.libraryItems.first { $0.id == selection }
    }

    @ViewBuilder
    private var content: some View {
        let items = model.filteredLibrary(search)
        if model.libraryItems.isEmpty, !model.isLoadingLibrary {
            ContentUnavailableView("No Saved Queries", systemImage: "books.vertical",
                                   description: Text("Save a query from the editor to add it here."))
        } else if items.isEmpty, !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            List(items, selection: $selection) { item in
                QueryLibraryRow(item: item)
                    .tag(item.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: QueryLibraryItem.ID.self) { ids in
                if let item = items.first(where: { ids.first == $0.id }) {
                    Button("Load into Editor") { load(item) }
                    Button("Run") { run(item) }
                        .disabled(model.isRunning)
                    Button("Copy Query") { copyToPasteboard(item.query) }
                    Button("Copy Name") { copyToPasteboard(item.name) }
                    Divider()
                    Button("Delete Query…", role: .destructive) { pendingDelete = item }
                }
            } primaryAction: { ids in
                if let item = items.first(where: { ids.first == $0.id }) { load(item) }
            }
            .onDeleteCommand { pendingDelete = selected }
        }
    }

    private func load(_ item: QueryLibraryItem) {
        model.loadQuery(item)
        dismiss()
    }

    private func run(_ item: QueryLibraryItem) {
        dismiss()
        Task { await model.run(script: item.query, source: .generated) }
    }
}

struct QueryLibraryRow: View {
    let item: QueryLibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(item.name).font(.headline).lineLimit(1)
                Text(item.type == .sample ? "Sample" : "Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !item.indexName.isEmpty {
                    Text(item.indexName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let description = item.description, !description.isEmpty {
                Text(description).foregroundStyle(.secondary).lineLimit(1)
            }

            Text(item.query)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(item.query)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct SaveQuerySheet: View {
    let model: WorkbenchViewModel
    let dismiss: @MainActor () -> Void
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        SheetForm(title: "Save Query", primaryTitle: "Save",
                  isPrimaryDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty, isWorking: isSaving,
                  errorMessage: error, onCancel: dismiss, onPrimary: save) {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($focused)
                        .onSubmit(save)
                } footer: {
                    Text("Saved queries appear in the Query Library of this database.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .sheetSize(.small)
        .defaultFocus($focused, true)
        .onAppear { focused = true }
    }

    private func save() {
        guard !isSaving, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSaving = true
        error = nil
        Task {
            do {
                try await model.saveQuery(name: name)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                self.error = error.localizedDescription
            }
        }
    }
}
