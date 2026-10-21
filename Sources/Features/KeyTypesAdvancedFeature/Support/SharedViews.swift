import AppKit
import RedisUI
import SwiftUI

struct FieldHint: View {
    let text: String
    var isError = false

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct LoadingBody: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PagedStatusBar: View {
    let text: String
    var isLoadingMore = false
    var canLoadMore = false
    var loadMoreTitle = "Load More"
    var onLoadMore: () -> Void = {}

    var body: some View {
        StatusBar {
            Text(text).monospacedDigit()
        } accessory: {
            if isLoadingMore {
                ProgressView().controlSize(.mini)
            } else if canLoadMore {
                Button(loadMoreTitle, action: onLoadMore).buttonStyle(.borderless)
            }
        }
    }
}

struct ValuePreviewItem: Identifiable {
    let id = UUID()
    var title = "Value Preview"
    var result: FormatResult
    var format: ValueFormat?
}

struct ValuePreviewSheet: View {
    let item: ValuePreviewItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetForm(title: item.title, primaryTitle: "Done", cancelTitle: nil, onCancel: { dismiss() },
                  onPrimary: { dismiss() }) {
            Group {
                if case .json(let value) = item.result.content {
                    JSONTreeView(value: value, initiallyExpanded: true)
                } else {
                    ScrollView {
                        Text(item.result.text)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }
                }
            }
        } leadingActions: {
            CopyButton(text: Self.copyText(item.result), help: "Copy Value", title: "Copy")
        }
        .sheetSize(.large)
    }

    static func copyText(_ result: FormatResult) -> String {
        if case .json(let value) = result.content { return JSONLiteral.pretty(value, indent: 2) }
        return result.text
    }
}

enum Pasteboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum FileSaver {
    /// Asks for a destination and writes `data` there. Returns false when cancelled.
    @MainActor
    static func save(_ data: Data, suggestedName: String) throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try data.write(to: url, options: .atomic)
        return true
    }
}

enum KeyDetailsLayout {
    /// Collapses subheader controls to icons below this width.
    static let narrowWidth: CGFloat = 560

    static func isCompact(_ width: CGFloat) -> Bool { width < narrowWidth }

    /// Rows within this distance of the end of a paged table load the next page when they appear.
    static let loadMoreDistance = 20

    static func isNearEnd<ID: Hashable>(_ id: ID, in ids: [ID]) -> Bool {
        ids.suffix(loadMoreDistance).contains(id)
    }
}

extension View {
    func trackingWidth(_ width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.wrappedValue = $0 }
    }

    func loadsMore(when isNearEnd: Bool, action: @escaping () -> Void) -> some View {
        onAppear { if isNearEnd { action() } }
    }
}

enum RemovalText {
    static func title(_ item: String, verb: String = "Remove") -> String {
        "\(verb) “\(Bytes.short(item))”?"
    }

    static func message(keyName: String, lastItemWarning: String?) -> String {
        let base = "It will be removed from “\(Bytes.short(keyName))”."
        guard let lastItemWarning else { return base }
        return base + " " + lastItemWarning
    }
}

/// Type-erased label style so a control can switch between title-and-icon and icon-only.
struct AnyLabelStyle: LabelStyle {
    private let make: @MainActor (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
