import AppKit
import RedisUI
import SwiftUI
import UniformTypeIdentifiers

/// Bottom panel Profiler with window-scoped MONITOR state.
public struct ProfilerView: View {
    public let session: DatabaseSession
    /// Hides the Profiler pane after `close(session:)` stopped MONITOR; nil removes it from the open bottom tools.
    public var onClose: (@MainActor () -> Void)?

    public init(session: DatabaseSession, onClose: (@MainActor () -> Void)? = nil) {
        self.session = session
        self.onClose = onClose
    }

    public var body: some View {
        let model = Self.model(for: session)
        let onClose = self.onClose
        return ProfilerContentView(model: model)
            .onAppear { model.onClose = onClose }
    }

    /// True while MONITOR is starting, running or paused.
    @MainActor
    public static func isRunning(session: DatabaseSession) -> Bool {
        model(for: session).phase.isStarted
    }

    /// Stops MONITOR, discards the log, and hides the Profiler pane.
    @MainActor
    public static func close(session: DatabaseSession) async {
        await model(for: session).close()
    }

    /// Stops MONITOR and hides the pane, asking first if its log is unsaved.
    @MainActor
    public static func requestClose(session: DatabaseSession) {
        model(for: session).requestClose()
    }

    @MainActor
    private static func model(for session: DatabaseSession) -> ProfilerViewModel {
        session.scopedObject(ProfilerViewModel.self) { ProfilerViewModel(session: session) }
    }
}

struct ProfilerContentView: View {
    @Bindable var model: ProfilerViewModel

    var body: some View {
        VStack(spacing: 0) {
            ProfilerHeader(model: model, onSaveLog: saveLog)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusedSceneValue(\.profilerCommands, model.commands)
        .confirmationDialog("Start Profiler on a Production Database?", isPresented: $model.isConfirmingProductionStart,
                            titleVisibility: .visible) {
            Button("Run") { Task { await model.start() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Profiling decreases throughput and may affect the clients of this database.")
        }
        .confirmationDialog("Discard the Profiler Log?",
                            isPresented: Binding(get: { model.pendingDiscard != nil },
                                                 set: { if !$0 { model.pendingDiscard = nil } }),
                            titleVisibility: .visible) {
            Button("Save Log…") { saveLog() }
            Button(model.pendingDiscard == .close ? "Close Without Saving" : "Reset Without Saving",
                   role: .destructive) {
                Task { await model.confirmDiscard() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The log file has \(NumberFormatting.grouped(model.logLineCount)) lines that have not been saved.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView {
                Label("Profiler", systemImage: "waveform.path.ecg")
            } description: {
                Text("Watch each command the server receives as it happens. Profiling lowers throughput, so avoid it on production.")
            } actions: {
                Button("Start Profiler") { model.requestStart() }
            }
        case .forbidden:
            ContentUnavailableView {
                Label("Profiler Unavailable", systemImage: "nosign")
            } description: {
                Text("This user has no permission to run MONITOR.")
            } actions: {
                Button("Try Again") { model.requestStart() }
            }
        case .starting, .running, .paused:
            VStack(spacing: 0) {
                if model.entries.isEmpty && !model.isPaused {
                    ProgressView("Waiting for commands…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(EditorAppearance.background)
                } else {
                    ProfilerLogList(model: model)
                }

                Divider()
                ProfilerStatusBar(model: model)
            }
        }
    }

    private func saveLog() {
        model.flushLogFile()
        let panel = NSSavePanel()
        panel.title = "Save Profiler Log"
        panel.nameFieldStringValue = model.suggestedDownloadName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.copyLog(to: url)
        } catch {
            model.session.toasts.error(error, title: "Profiler Log Not Saved")
        }
    }
}

// MARK: - Header

struct ProfilerHeader: View {
    @Bindable var model: ProfilerViewModel
    let onSaveLog: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Profiler").font(.headline)
            Button {
                model.primaryAction()
            } label: {
                Label(model.primaryActionTitle, systemImage: model.primaryActionSymbol)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!model.isPrimaryActionEnabled)
            .help(primaryHelp)
            Button {
                model.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .disabled(!model.canClear)
            .help("Clear the Profiler output")
            Spacer(minLength: 8)
            if !model.isStarted {
                Toggle("Save Log", isOn: $model.saveToFile)
                    .toggleStyle(.checkbox)
                    .help("Write the full output to a log file you can save after pausing. The file is deleted when the Profiler is reset.")
            }

            if model.isPaused {
                if model.logFileURL != nil {
                    Button(action: onSaveLog) {
                        Label("Save Log…", systemImage: "square.and.arrow.down")
                    }
                    .labelStyle(.iconOnly)
                    .help("Save a copy of the full Profiler log")
                }

                Button {
                    model.requestReset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .labelStyle(.iconOnly)
                .help("Stop the Profiler, delete its log, and start over")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var primaryHelp: String {
        if model.isPaused && model.isResumeLocked { return "The connection was lost. Reset the Profiler to start again." }
        switch model.phase {
        case .idle, .forbidden: return "Start profiling every command sent to this database"
        case .starting, .running: return "Pause the Profiler"
        case .paused: return "Resume the Profiler"
        }
    }
}

// MARK: - Status bar

struct ProfilerStatusBar: View {
    let model: ProfilerViewModel

    var body: some View {
        StatusBar {
            if model.isPaused, let summary = model.pausedSummary {
                Text("\(summary.start) – \(summary.paused) · \(summary.duration) running time")
                    .monospacedDigit()
                    .help("Running time counts only the time the Profiler was not paused")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Running · \(ProfilerFormatting.runningTime(model.runningTime(now: context.date)))")
                        .monospacedDigit()
                }
            }

            if model.isTrimmed {
                Text("· last \(NumberFormatting.grouped(model.entries.count)) of \(NumberFormatting.grouped(model.totalLines)) lines")
                    .monospacedDigit()
                    .help("The pane keeps the newest \(NumberFormatting.grouped(ProfilerViewModel.lineLimit)) lines. Turn on Save Log before starting to keep everything.")
            }
        } accessory: {
            if let url = model.logFileURL {
                Label("Saving Log", systemImage: "doc.text")
                    .labelStyle(.iconOnly)
                    .help("The full output is being written to \(url.lastPathComponent)")
            }
        }
    }
}

// MARK: - Log list

struct ProfilerLogList: View {
    let model: ProfilerViewModel
    @State private var position = ScrollPosition(edge: .bottom)
    /// Follows new lines until the user scrolls away from the end; scrolling back to the end resumes it.
    @State private var follows = true
    @State private var isAtBottom = true
    @State private var isUserScrolling = false
    @State private var width: CGFloat = 1_000

    var body: some View {
        let compact = model.session.navigator.openBottomTools.count > 1
        let showTime = width > 460
        let showContext = width > 360
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.entries) { entry in
                    ProfilerRow(entry: entry, showTime: showTime, showContext: showContext,
                                nodeColor: model.nodeColorIndex(entry.nodeLabel).map { ChartPalette.color(at: $0) })
                }
            }
            .font(compact ? .caption.monospaced() : .callout.monospaced())
            .textSelection(.enabled)
            .padding(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(EditorAppearance.background)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 4
        } action: { _, atBottom in
            isAtBottom = atBottom
            if isUserScrolling { follows = atBottom }
        }
        .onScrollPhaseChange { _, phase in
            isUserScrolling = phase != .idle && phase != .animating
            if phase == .idle { follows = isAtBottom }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: model.entriesVersion) {
            if follows { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !follows && !model.entries.isEmpty {
                JumpToLatestButton {
                    follows = true
                    position.scrollTo(edge: .bottom)
                }
            }
        }
    }
}

struct ProfilerRow: View {
    let entry: ProfilerEntry
    let showTime: Bool
    let showContext: Bool
    let nodeColor: Color?

    var body: some View {
        line
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Copy Line") { copy(entry.copyText) }
                if !entry.isError {
                    Button("Copy Raw MONITOR Line") { copy(entry.raw) }
                }
            }
    }

    private var line: Text {
        let node = entry.nodeLabel.map { label in
            Text("[\(label)] ").foregroundStyle(nodeColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        } ?? Text("")
        let time = showTime ? Text(entry.timeText + " ").foregroundStyle(.tertiary) : Text("")
        if entry.isError {
            return Text("\(time)\(node)\(Text(entry.commandText).foregroundStyle(EditorAppearance.error))")
        }

        let context = showContext ? Text(entry.contextText + " ").foregroundStyle(.secondary) : Text("")
        let command = Text(entry.commandText).foregroundStyle(.primary).fontWeight(.semibold)
        let args = entry.argumentsText.isEmpty ? Text("") : Text(" " + entry.argumentsText).foregroundStyle(.secondary)
        return Text("\(time)\(node)\(context)\(command)\(args)")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
