import AppKit
import RedisUI
import SwiftUI

/// Bottom panel CLI (dedicated connection, history, Tab completion).
public struct CLIView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var body: some View {
        CLIContentView(model: CLIViewModel.shared(for: session))
    }
}

struct CLIContentView: View {
    @Bindable var model: CLIViewModel
    @State private var controller = CodeEditorController()
    @State private var isScrolledAway = false
    @State private var scrollToEndToken = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            CLIOutputTextView(
                buffer: model.output,
                scrollToEndToken: scrollToEndToken,
                onLink: { model.open($0) },
                onClickWithoutSelection: focusInput,
                onClear: { model.clearOutput() },
                onScrolledAwayChange: { isScrolledAway = $0 })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if isScrolledAway {
                    JumpToLatestButton { scrollToEndToken += 1 }
                }
            }
            inputRow
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .background(EditorAppearance.background)
        .frame(minWidth: 230)
        .onAppear { model.open() }
        .confirmationDialog(
            model.pendingFlush.map { "Run \($0.verb)?" } ?? "",
            isPresented: Binding(
                get: { model.pendingFlush != nil },
                set: { presented in
                    // Deferred so a button's explicit answer always lands before the dismissal fallback.
                    guard !presented, let pending = model.pendingFlush else { return }
                    Task { @MainActor in model.dismissFlush(pending.id) }
                }),
            titleVisibility: .visible,
            presenting: model.pendingFlush
        ) { _ in
            Button("Run", role: .destructive) { model.resolveFlush(confirmed: true) }
            Button("Cancel", role: .cancel) { model.resolveFlush(confirmed: false) }
        } message: { pending in
            Text(pending.message)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("CLI")
                .font(.headline)
                .help(model.endpointLabel)
            Spacer(minLength: 0)
            Button {
                model.clearOutput()
            } label: {
                Label("Clear", systemImage: "clear")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.output.isEmpty)
            .help("Clear (⌘K)")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    @ViewBuilder
    private var inputRow: some View {
        switch model.connectionState {
        case .failed(let message):
            HStack(spacing: 8) {
                InlineMessage(message, kind: .error)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Reconnect") { Task { await model.reconnect() } }
                    .controlSize(.small)
            }
        case .idle, .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        case .connected:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(model.prompt)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if model.isExecuting {
                    Text("Executing command…")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Cancel") { model.cancelExecution() }
                        .controlSize(.small)
                        .help("Stop waiting for the reply; the CLI connection is re-created (⌘.)")
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    CommandLineField(
                        text: Binding(get: { model.input }, set: { model.setInput($0) }),
                        placeholder: "",
                        isEnabled: model.canType,
                        trailingHint: model.hint,
                        controller: controller,
                        autoFocus: true,
                        onSubmit: { _ in model.submitInput() },
                        onHistoryUp: { model.historyUp() },
                        onHistoryDown: { model.historyDown() },
                        onTab: { model.complete(backwards: $0) },
                        onEscape: { NSApp.keyWindow?.makeFirstResponder(nil) },
                        onClear: { model.clearOutput() })
                    .accessibilityLabel("CLI command input")
                }
            }
        }
    }

    private func focusInput() {
        guard model.canType else { return }
        controller.focus()
        controller.moveCaretToEnd()
    }
}
