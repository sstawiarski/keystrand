import RedisUI
import SwiftUI

/// JSON key value view.
public struct JSONKeyView: View {
    public let context: KeyDetailsContext

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var body: some View {
        JSONBody(context: context).id(KeyIdentity(context))
    }
}

private struct JSONBody: View {
    let context: KeyDetailsContext
    @State private var model: JSONKeyViewModel

    init(context: KeyDetailsContext) {
        self.context = context
        _model = State(initialValue: JSONKeyViewModel(context: context))
    }

    var body: some View {
        content
            .task { await model.load() }
            .onChange(of: context.state.refreshGeneration) { Task { await model.refresh() } }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage, !model.hasLoaded {
            ErrorStateView(message: error) { Task { await model.load() } }
        } else if !model.hasLoaded {
            LoadingBody()
        } else {
            JSONTreeView(model: model.tree, actions: model.actions, keyName: context.keyText,
                         showsToolbar: true, showsPathBar: true,
                         toolbarAccessory: model.isFullyLoaded ? nil : AnyView(saveToFile),
                         confirmations: context.session.confirmations, errors: context.session.toasts)
        }
    }

    /// Partially loaded documents cannot be copied whole; the subheader offers saving the full value instead.
    @ViewBuilder
    private var saveToFile: some View {
        if model.isDownloading {
            ProgressView().controlSize(.small)
        } else {
            Button("Save to File…") { Task { await model.download() } }
                .help("Large document: nested values load when expanded. Save the whole document to a file.")
        }
    }
}
