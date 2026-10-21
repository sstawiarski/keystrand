import RedisUI
import SwiftUI

/// Read-only list of the app's keyboard shortcuts (Help > Keyboard Shortcuts, ⌘/).
public struct KeyboardShortcutsView: View {
    @State private var query = ""

    public init() {}

    public var body: some View {
        let groups = ShortcutCatalog.filtered(query)
        List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        LabeledContent(item.description) {
                            Text(item.keys)
                                .font(.body.monospaced())
                                .foregroundStyle(.primary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Shortcuts")
    }
}
