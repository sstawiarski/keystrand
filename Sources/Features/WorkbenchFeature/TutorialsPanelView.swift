import RedisUI
import SwiftUI

/// Inspector > Tutorials pane: bundled markdown tutorials with runnable code blocks.
public struct TutorialsPanelView: View {
    public let session: DatabaseSession

    public init(session: DatabaseSession) {
        self.session = session
    }

    public var body: some View {
        TutorialsContent(model: TutorialsViewModel.shared(for: session), navigator: session.navigator)
    }
}

struct TutorialsContent: View {
    let model: TutorialsViewModel
    let navigator: DatabaseNavigator

    var body: some View {
        Group {
            if let page = model.page {
                TutorialPageView(model: model, page: page)
            } else {
                TutorialsRootView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.load() }
        .onAppear(perform: consumeNavigation)
        .onChange(of: navigator.pending?.id) { _, _ in consumeNavigation() }
    }

    private func consumeNavigation() {
        let request = navigator.consume { request in
            if case .tutorial = request { return true }
            return false
        }
        if case .tutorial(let id)? = request {
            Task { await model.open(id: id) }
        }
    }
}

// MARK: - Root

struct TutorialsRootView: View {
    let model: TutorialsViewModel
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $search, placeholder: "Search Tutorials", debounce: .milliseconds(150)) { text in
                model.updateSearch(text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { search = model.searchText }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView()
        } else if let error = model.loadError {
            ErrorStateView(message: error) { Task { await model.load() } }
        } else if let error = model.pageError {
            ContentUnavailableView {
                Label("Tutorial Unavailable", systemImage: "doc.questionmark")
            } description: {
                Text(error)
            } actions: {
                Button("Show All Tutorials") { model.closePage() }
            }
        } else if model.isSearching {
            searchResults
        } else if let library = model.library {
            List {
                ForEach(library.root.children ?? []) { child in
                    TutorialNodeRow(model: model, node: child)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.searchResults.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            List(model.searchResults) { hit in
                Button {
                    Task { await model.open(id: hit.node.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.node.label)
                        if !hit.groupPath.isEmpty {
                            Text(hit.groupPath.joined(separator: " › "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let excerpt = hit.excerpt {
                            Text(excerpt).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
            .listStyle(.sidebar)
        }
    }
}

/// A manifest group (disclosure with a folder) or a page link.
struct TutorialNodeRow: View {
    let model: TutorialsViewModel
    let node: TutorialNode

    var body: some View {
        if node.isGroup {
            DisclosureGroup(isExpanded: Binding(
                get: { model.expandedGroups.contains(node.id) },
                set: { if $0 != model.expandedGroups.contains(node.id) { model.toggleGroup(node.id) } })) {
                ForEach(node.children ?? []) { child in
                    TutorialNodeRow(model: model, node: child)
                }
            } label: {
                Label(node.label, systemImage: "folder")
                    .help(node.summary ?? node.label)
            }
        } else if node.isPage {
            Button {
                Task { await model.open(id: node.id) }
            } label: {
                Label(node.label, systemImage: "doc.text")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(node.summary ?? node.label)
        }
    }
}

// MARK: - Page

struct TutorialPageView: View {
    let model: TutorialsViewModel
    let page: TutorialPage
    @State private var position = ScrollPosition(edge: .top)
    @State private var restoredPageID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.closePage()
                } label: {
                    Label(page.parentLabel, systemImage: "chevron.left")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .help("Back to All Tutorials")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(page.node.label)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    MarkdownView(blocks: page.blocks, baseURL: page.baseURL, codeBlock: { block in
                        if let fence = TutorialFence.parse(info: block.info) {
                            return AnyView(TutorialCodeBlockView(model: model, block: block, fence: fence))
                        }

                        return AnyView(MarkdownCodeView(code: block))
                    }, onOpenLink: { url in model.handleLink(url) })
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(page.id)
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, offset in
                guard restoredPageID == page.id else { return }
                model.recordScrollOffset(offset, for: page.id)
            }
            .task(id: page.id) { await restoreScroll() }
            if page.siblings.count > 1 {
                Divider()
                pageBar
            }
        }
    }

    private func restoreScroll() async {
        let target = model.scrollOffset(for: page.id)
        if target > 0 {
            try? await Task.sleep(for: .milliseconds(50))
            position.scrollTo(y: target)
        } else {
            position = ScrollPosition(edge: .top)
        }

        restoredPageID = page.id
    }

    private var pageBar: some View {
        HStack {
            Button {
                if let previous = page.previous { Task { await model.open(id: previous.id) } }
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(page.previous == nil)
            .help(page.previous?.label ?? "Previous")
            Spacer()
            Menu("\(page.index + 1) of \(page.siblings.count)") {
                ForEach(page.siblings) { sibling in
                    Toggle(sibling.label, isOn: Binding(get: { sibling.id == page.node.id }, set: { _ in
                        Task { await model.open(id: sibling.id) }
                    }))
                }
            }
            .menuStyle(.button)
            .fixedSize()
            Spacer()
            Button {
                if let next = page.next { Task { await model.open(id: next.id) } }
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .disabled(page.next == nil)
            .help(page.next?.label ?? "Next")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - Code block

/// A ```` ```redis ```` block: label, Copy, Run (with run confirmation, production and module checks), and code.
struct TutorialCodeBlockView: View {
    let model: TutorialsViewModel
    let block: MarkdownCodeBlock
    let fence: TutorialFence

    enum RunState { case idle, running, done }

    @State private var runState: RunState = .idle
    @State private var showsConfirmation = false
    @State private var dontAskAgain = false
    @State private var missingModule: MissingModuleItem?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(fence.displayLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .help(fence.label)
                Spacer()
                CopyButton(help: "Copy Commands", title: "Copy") { TutorialsViewModel.copyText(block.code) }
                if fence.isExecutable {
                    runButton
                }
            }
            .controlSize(.small)
            ScrollView(.horizontal) {
                Text(SyntaxAttributedString.make(block.code, language: .redis))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .contextMenu {
                Button("Copy Commands") { copyToPasteboard(TutorialsViewModel.copyText(block.code)) }
                Button("Open in Workbench") {
                    model.session.navigator.navigate(.workbench(script: block.code))
                }
            }
        }
        .confirmationDialog("Run Commands?", isPresented: $showsConfirmation, titleVisibility: .visible) {
            Button("Run") {
                Task {
                    if dontAskAgain { await model.setSkipRunConfirmation(true) }
                    await execute()
                }
            }
            Button("Change Database") { model.session.navigator.navigate(.home) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running this tutorial's commands writes to this database. Continue?")
        }
        .dialogSuppressionToggle("Don't ask again for this database", isSuppressed: $dontAskAgain)
        .alert(missingModule?.requirement.title ?? "", isPresented: Binding(
            get: { missingModule != nil }, set: { if !$0 { missingModule = nil } }), presenting: missingModule) { item in
            if let url = item.requirement.learnMoreURL {
                Button("Learn More") { openURL(url) }
            }

            Button("OK", role: .cancel) {}
        } message: { item in
            Text(([item.requirement.subtitle] + item.requirement.bullets.map { "• \($0)" }).joined(separator: "\n"))
        }
    }

    private var isProduction: Bool { model.session.isProduction }

    private var runButton: some View {
        Button(action: requestRun) {
            switch runState {
            case .idle: Label("Run", systemImage: "play.fill")
            case .running: Label { Text("Run") } icon: { ProgressView().controlSize(.mini) }
            case .done: Label("Run", systemImage: "checkmark")
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .disabled(isProduction || runState == .running)
        .help(isProduction ? TutorialsViewModel.productionRunTooltip : TutorialsViewModel.runTooltip)
    }

    private func requestRun() {
        switch model.check(code: block.code, fence: fence) {
        case .ready: Task { await execute() }
        case .needsConfirmation:
            dontAskAgain = false
            showsConfirmation = true
        case .moduleMissing(let requirement): missingModule = MissingModuleItem(requirement: requirement)
        case .production, .notExecutable: break
        }
    }

    private func execute() async {
        runState = .running
        let ran = await model.run(code: block.code, fence: fence)
        guard ran else {
            runState = .idle
            return
        }
        runState = .done
        try? await Task.sleep(for: .seconds(5))
        if runState == .done { runState = .idle }
    }
}

struct MissingModuleItem: Identifiable {
    let requirement: CommandModuleRequirement
    var id: String { requirement.title }
}
