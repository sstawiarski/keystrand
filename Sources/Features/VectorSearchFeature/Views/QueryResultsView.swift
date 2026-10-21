import RedisUI
import SwiftUI

/// Results of the query page, newest first: one section per command with a pinned header.
struct QueryResultsView: View {
    let page: QueryPageViewModel

    var body: some View {
        Group {
            if page.cards.isEmpty {
                if page.historyLoaded {
                    ContentUnavailableView {
                        Label("No Results", systemImage: "sparkle.magnifyingglass")
                    } description: {
                        Text(VectorSearchStrings.resultsEmpty)
                    }
                } else {
                    ProgressView()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(page.cards) { card in
                                Section {
                                    if card.isOpen {
                                        ResultBody(card: card, isExpanded: false)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                    }
                                } header: {
                                    ResultHeader(card: card, page: page)
                                }
                                .id(card.id)
                                Divider()
                            }
                        }
                    }
                    .scrollEdgeEffectStyle(.hard, for: .top)
                    .onChange(of: page.scrollToTopToken) {
                        if let first = page.cards.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResultHeader: View {
    let card: ResultCardModel
    let page: QueryPageViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await page.toggle(card) }
            } label: {
                Label(card.isOpen ? "Collapse" : "Expand", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .rotationEffect(.degrees(card.isOpen ? 90 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: card.isOpen)
            }
            .buttonStyle(.borderless)
            .help(card.isOpen ? "Collapse" : "Expand")

            Text(card.title)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Self.tooltip(card.command))

            Spacer(minLength: 8)

            if card.isLoading {
                ProgressView().controlSize(.small)
            }

            if card.isOpen, let content = card.content, content.availableViews.count > 1 {
                ResultViewPicker(card: card, content: content)
            }

            if let time = card.executionTimeText {
                Text(time)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(card.executionTimeTooltip ?? "")
            }

            Text(timestamp)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                Task { await page.rerun(card) }
            } label: {
                Label("Run Again", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(card.command.isEmpty || page.isRunning)
            .help("Run Again")
            Menu {
                ResultActions(card: card, page: page)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.bar)
        .contentShape(.rect)
        .onTapGesture { Task { await page.toggle(card) } }
        .contextMenu { ResultActions(card: card, page: page) }
    }

    private var timestamp: String {
        let app = page.session.services.settings.app
        return TimestampFormatter.format(date: card.execution.createdAt, pattern: app.dateFormat,
                                         timeZone: app.timezone.timeZone)
    }

    static func tooltip(_ command: String) -> String {
        let lines = command.components(separatedBy: CharacterSet.newlines).filter { !$0.isEmpty }
        let clipped = lines.count > 20 ? Array(lines.prefix(18)) + ["…"] + [lines[lines.count - 1]] : lines
        return clipped.enumerated().map { index, line in
            let text = line.count > 497 ? String(line.prefix(497)) + "…" : line
            return lines.count > 1 ? "\(index + 1). \(text)" : text
        }.joined(separator: "\n")
    }
}

struct ResultActions: View {
    let card: ResultCardModel
    let page: QueryPageViewModel

    var body: some View {
        Button("Copy Command") { Pasteboard.copy(card.command) }
            .disabled(card.command.isEmpty)
        Button("Copy Result") { if let content = card.content { Pasteboard.copy(content.copyText) } }
            .disabled(card.content == nil)
        if card.isSearchCommand && page.supportsExplain {
            Button("Profile Command") { Task { await page.profile(card) } }
                .disabled(page.isRunning)
            Button("Explain Command") { Task { await page.explain(card) } }
                .disabled(page.isRunning)
        }

        Button("Expand…") {
            card.isOpen = true
            card.computeContent()
            page.expandedCard = card
        }
        .disabled(card.isLoading)
        Divider()
        Button("Clear Result", role: .destructive) { Task { await page.delete(card) } }
            .disabled(card.isLoading || page.isClearing)
    }
}

struct ResultViewPicker: View {
    let card: ResultCardModel
    let content: ResultContent

    var body: some View {
        Picker("View", selection: Binding(get: { card.effectiveView }, set: { card.selectedView = $0 })) {
            ForEach(content.availableViews) { view in
                Text(view.title).tag(view)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Result View")
    }
}

struct ResultBody: View {
    let card: ResultCardModel
    let isExpanded: Bool

    var body: some View {
        Group {
            if let error = card.loadError {
                Text(error).foregroundStyle(EditorAppearance.error)
            } else if let content = card.content {
                VStack(alignment: .leading, spacing: 6) {
                    if card.execution.isNotStored == true {
                        InlineMessage("This result is too large to keep, so it will be discarded when the app quits.",
                                      kind: .warning)
                    }

                    switch card.effectiveView {
                    case .table:
                        if let table = content.table {
                            SearchTableView(table: table, isExpanded: isExpanded)
                        } else if let info = content.info {
                            if isExpanded {
                                IndexInfoSummary(info: info)
                                IndexAttributesTable(info: info)
                            } else {
                                IndexInfoView(info: info)
                            }
                        }
                    case .json:
                        if let json = content.json {
                            JSONTreeView(value: json, initiallyExpanded: true)
                                .frame(minHeight: 120, maxHeight: isExpanded ? .infinity : 420)
                        }
                    case .text:
                        ResultTextView(content: content, isExpanded: isExpanded)
                    }
                }
            } else if !card.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: card.isOpen) { if card.isOpen { card.computeContent() } }
    }
}

/// redis-cli formatted text.
struct ResultTextView: View {
    let content: ResultContent
    var isExpanded = false

    var body: some View {
        VirtualizedTextLinesView(lines: content.lines) { _, _ in content.isError ? EditorAppearance.error : nil }
            .frame(height: isExpanded ? nil : min(max(CGFloat(content.lines.count) * 17 + 12, 34), 210))
            .frame(maxHeight: isExpanded ? .infinity : nil)
    }
}

struct SearchTableRow: Identifiable {
    let id: Int
    let values: [String: String]
}

/// Search results table: one row per document, the union of fields as columns.
struct SearchTableView: View {
    let table: SearchResultTable
    var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let matched = table.matched { Text("Matched: \(matched)") }
                if let cursor = table.cursorID { Text("Cursor ID: \(cursor)") }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            if table.rows.isEmpty {
                Text("No results found.").foregroundStyle(.secondary)
            } else {
                Table(table.rows.enumerated().map { SearchTableRow(id: $0.offset, values: $0.element) }) {
                    TableColumnForEach(table.columns, id: \.self) { column in
                        TableColumn(column) { row in
                            let value = row.values[column] ?? ""
                            cellText(SearchResultParser.cellPreview(value))
                                .font(.body.monospaced())
                                .lineLimit(1)
                                .help("\(column)\n\(TextTruncation.formatLongName(value))")
                                .contextMenu { Button("Copy Value") { Pasteboard.copy(value) } }
                        }
                        .width(min: 80, ideal: 180)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: isExpanded ? nil : min(CGFloat(table.rows.count) * 24 + 32, 320))
                .frame(maxHeight: isExpanded ? .infinity : nil)
            }
        }
    }

    private func cellText(_ text: String) -> Text {
        guard table.highlights, text.contains("<b>") else { return Text(text) }
        return SearchResultParser.highlightRuns(text).reduce(Text("")) { partial, run in
            Text("\(partial)\(run.1 ? Text(run.0).bold() : Text(run.0))")
        }
    }
}

struct ResultExpandSheet: View {
    let card: ResultCardModel
    let page: QueryPageViewModel

    var body: some View {
        SheetForm(title: card.title, primaryTitle: "Done", cancelTitle: nil, onCancel: { page.expandedCard = nil },
                  onPrimary: { page.expandedCard = nil }) {
            ResultBody(card: card, isExpanded: true)
                .padding(.horizontal, 20)
        } leadingActions: {
            if let content = card.content {
                if content.availableViews.count > 1 { ResultViewPicker(card: card, content: content) }
                CopyButton(text: content.copyText, help: "Copy Result", title: "Copy")
            }
        }
    }
}
