import AppKit
import RedisUI
import SwiftUI

/// One result: a pinned header (command, view picker, timing, Run Again, actions menu) over its body.
struct ResultSection: View {
    let model: WorkbenchViewModel
    @Bindable var card: WorkbenchCard

    var body: some View {
        Section {
            if card.isOpen {
                CardBodyView(model: model, card: card, isFullscreen: false)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            Divider()
        } header: {
            ResultHeader(model: model, card: card)
        }
    }
}

struct ResultHeader: View {
    let model: WorkbenchViewModel
    @Bindable var card: WorkbenchCard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: SettingsStore { model.session.services.settings }

    var body: some View {
        HStack(spacing: 8) {
            disclosure
            Text(card.title)
                .font(card.isGroup ? .callout : .callout.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .help(WorkbenchResultFormatter.commandTooltip(card.isGroup ? card.execution.command : card.title))
                .layoutPriority(1)
            if let caption = modeCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if let message = card.headerMessage, !message.isEmpty, !card.isOpen {
                Text(WorkbenchResultFormatter.truncatedHeaderMessage(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(message)
            }

            Spacer(minLength: 8)
            if card.isRunning {
                ProgressView().controlSize(.small)
            } else {
                if card.isOpen {
                    ResultViewPicker(model: model, card: card)
                }

                if let time = card.execution.executionTime {
                    Text(WorkbenchResultFormatter.timeLabel(microseconds: time))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(WorkbenchResultFormatter.timeTooltip(microseconds: time))
                }

                Text(timestamp)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            Button {
                Task { await model.rerun(card) }
            } label: {
                Label("Run Again", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(card.isRunning || model.isRunning || card.execution.command.isEmpty)
            .help("Run Again")
            Menu {
                ResultActions(model: model, card: card)
            } label: {
                Label("Result Actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Result Actions")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggle() }
        .contextMenu { ResultActions(model: model, card: card) }
    }

    @ViewBuilder
    private var disclosure: some View {
        let label = card.isOpen ? "Collapse Result" : "Expand Result"
        Button(action: toggle) {
            Label(label, systemImage: "chevron.right")
                .labelStyle(.iconOnly)
                .rotationEffect(.degrees(card.isOpen ? 90 : 0))
                .frame(width: 14)
        }
        .buttonStyle(.borderless)
        .disabled(!card.isExpandable)
        .opacity(card.isExpandable || card.isRunning ? 1 : 0.4)
        .help(label)
    }

    private var modeCaption: String? {
        WorkbenchResultFormatter.modeCaption(mode: card.execution.mode, resultsMode: card.execution.resultsMode)
    }

    private var timestamp: String {
        TimestampFormatter.format(date: card.execution.createdAt, pattern: settings.app.dateFormat,
                                  timeZone: settings.app.timezone.timeZone)
    }

    private func toggle() {
        guard card.isExpandable else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { card.isOpen.toggle() }
    }
}

/// Items shared by the header's ⋯ menu and its context menu.
struct ResultActions: View {
    let model: WorkbenchViewModel
    let card: WorkbenchCard

    var body: some View {
        Button("Copy Command") {
            copyToPasteboard(card.execution.command.replacingOccurrences(of: "\r\n", with: "\n"))
        }
        .disabled(card.execution.command.isEmpty)
        Button("Copy Result") { copyResult(card.execution) }
            .disabled(card.execution.result == nil)
        Button("Open in Editor") {
            model.enqueueScript(card.execution.command.replacingOccurrences(of: "\r\n", with: "\n"))
        }
        .disabled(card.execution.command.isEmpty)
        if isSearchCommand {
            Button("Profile Command") { Task { await model.runGenerated(for: card, explain: false) } }
                .disabled(model.isRunning)
            Button("Explain Command") { Task { await model.runGenerated(for: card, explain: true) } }
                .disabled(model.isRunning)
        }

        Button("Expand…") { model.fullscreenCardID = card.id }
            .disabled(card.isRunning || !card.isExpandable)
        Divider()
        Button("Clear Result", role: .destructive) { Task { await model.delete(card) } }
            .disabled(card.isRunning || model.isClearing)
    }

    private var isSearchCommand: Bool {
        !card.isGroup && !card.isRunning
            && WorkbenchCommandText.isSearchOrAggregate(WorkbenchCommandText.words(card.execution.command).first ?? "")
    }
}

/// The result view menu (Text, Table, JSON, Chart, …), shown when there is more than one option.
struct ResultViewPicker: View {
    let model: WorkbenchViewModel
    @Bindable var card: WorkbenchCard

    var body: some View {
        if !card.isRunning, card.viewOptions.count > 1 {
            Picker("View", selection: Binding(get: { card.selectedView }, set: { model.select($0, for: card) })) {
                ForEach(card.viewOptions) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Result view")
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Copies the redis-cli style text of a result (built off the main actor).
@MainActor
func copyResult(_ execution: CommandExecution) {
    Task {
        let text = await Task.detached { WorkbenchResultFormatter.copyText(for: execution) }.value
        copyToPasteboard(text)
    }
}

struct CardBodyView: View {
    let model: WorkbenchViewModel
    let card: WorkbenchCard
    let isFullscreen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.showsNotStoredWarning {
                InlineMessage(WorkbenchResultFormatter.tooBigToSaveMessage, kind: .warning)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: card.isOpen) {
            if card.isOpen || isFullscreen { await model.loadResultIfNeeded(card) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if card.isRunning {
            EmptyView()
        } else if card.isLoadingResult {
            ProgressView().controlSize(.small)
        } else if let error = card.loadError {
            InlineMessage(error, kind: .error)
        } else if let result = card.result {
            resultContent(result)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func resultContent(_ result: CommandExecutionResult) -> some View {
        let command = card.execution.command
        let notice = card.isGroup ? nil : card.notice
        if case .guidance(let guidance)? = notice {
            GuidanceMessageView(guidance: guidance, navigator: model.session.navigator)
        } else if case .unsupported(let message)? = notice {
            MessageBlock(text: message, isError: true)
        } else if !card.isGroup, result.status == .fail, let requirement = missingModule(command) {
            ModuleMissingView(requirement: requirement)
        } else if result.sizeLimitExceeded == true || card.isGroup || card.selectedView == .text
                    || result.status == .fail {
            ResultTextView(card: card, isFullscreen: isFullscreen)
        } else if case .reply(let node) = result.response {
            VisualizationHost(model: model, card: card, node: node, isFullscreen: isFullscreen)
        } else {
            ResultTextView(card: card, isFullscreen: isFullscreen)
        }
    }

    private func missingModule(_ command: String) -> CommandModuleRequirement? {
        model.session.capabilities.missingModule(for: command)
    }
}

struct MessageBlock: View {
    let text: String
    var isError = false

    var body: some View {
        Text(text)
            .font(.body.monospaced())
            .foregroundStyle(isError ? EditorAppearance.error : EditorAppearance.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// MONITOR / SUBSCRIBE / PSUBSCRIBE / HELLO 3 guidance with a link to the matching tool.
struct GuidanceMessageView: View {
    let guidance: CommandRules.Guidance
    let navigator: DatabaseNavigator

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            switch guidance {
            case .monitor:
                Text("Open the")
                Button("Profiler") { navigator.navigate(.bottomPanel(.profiler)) }.buttonStyle(.link)
                Text("to watch every request the server receives.")
            case .subscribe:
                Text("Subscribe to channels in")
                HStack(spacing: 0) {
                    Button("Pub/Sub") { navigator.navigate(.pubSub) }.buttonStyle(.link)
                    Text(".")
                }
            case .psubscribe:
                Text("Open")
                Button("Pub/Sub") { navigator.navigate(.pubSub) }.buttonStyle(.link)
                Text("to follow messages across every channel of this database.")
            case .resp3:
                Text(guidance.message)
            }

            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// "{Module} is not available for this database".
struct ModuleMissingView: View {
    let requirement: CommandModuleRequirement

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(requirement.title).font(.headline)
            Text(requirement.subtitle).foregroundStyle(.secondary)
            ForEach(requirement.bullets, id: \.self) { bullet in
                Label(bullet, systemImage: "checkmark.circle")
            }
            if let url = requirement.learnMoreURL {
                Link("Learn More", destination: url)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
