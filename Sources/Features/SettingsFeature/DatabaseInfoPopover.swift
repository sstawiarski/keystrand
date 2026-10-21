import RedisUI
import SwiftUI

/// Shows connection details, modules, metrics, keyspace, and overview refresh preferences.
public struct DatabaseInfoPopover: View {
    public let session: DatabaseSession
    @State private var model: DatabaseInfoViewModel
    @Environment(\.dismiss) private var dismiss

    public init(session: DatabaseSession) {
        self.session = session
        _model = State(initialValue: DatabaseInfoViewModel(session: session))
    }

    private var settings: SettingsStore { session.services.settings }

    public var body: some View {
        let details = model.details
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(details.name)
                            .font(.headline)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text(details.hostPort)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let error = model.errorMessage {
                        InlineMessage(error, kind: .error)
                    }
                }

                Section("Connection") {
                    LabeledContent("Type", value: details.connectionType)
                    if let version = details.version { LabeledContent(details.versionLabel, value: version) }
                    LabeledContent("User", value: details.user)
                    LabeledContent("Logical Databases") {
                        Text(String(details.databaseCount)).monospacedDigit()
                    }
                    .help(DatabaseInfoDetails.logicalDatabasesHint)
                }

                if !details.modules.isEmpty {
                    Section("Modules") {
                        ForEach(details.modules) { module in
                            LabeledContent(module.name) {
                                Text(module.version.map { "v. \($0)" } ?? "")
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                let metrics = DatabaseInfoMetrics.rows(overview: session.overview, dbIndex: session.effectiveDB)
                if !metrics.isEmpty {
                    Section("Metrics") {
                        ForEach(metrics) { row in
                            LabeledContent(row.label) {
                                Text(row.value).monospacedDigit().textSelection(.enabled)
                            }
                        }
                    }
                }

                if !details.server.isEmpty || !details.memory.isEmpty {
                    Section("Server") {
                        ForEach(details.server + details.memory) { row in
                            LabeledContent(row.label) {
                                Text(row.value)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !details.keyspace.isEmpty {
                    Section("Keyspace") {
                        ForEach(details.keyspace) { row in
                            LabeledContent {
                                Text("\(NumberFormatting.grouped(row.keys)) keys · \(NumberFormatting.grouped(row.expires)) expiring")
                                    .monospacedDigit()
                            } label: {
                                Text(row.isCurrent ? "db\(row.db) (current)" : "db\(row.db)")
                                    .fontWeight(row.isCurrent ? .semibold : .regular)
                            }
                        }
                    }
                }

                Section("Refresh") {
                    Toggle("Auto refresh", isOn: Binding(
                        get: { OverviewRefreshPreferences.isEnabled(settings) },
                        set: { settings.ui.autoRefreshEnabled[OverviewRefreshPreferences.postfix] = $0 }))
                    Picker("Every", selection: Binding(
                        get: { OverviewRefreshPreferences.rate(settings) },
                        set: { settings.ui.autoRefreshRates[OverviewRefreshPreferences.postfix] = $0 })) {
                        ForEach(OverviewRefreshPreferences.presetRates, id: \.self) { rate in
                            Text(AutoRefreshMenu.rateTitle(rate)).tag(rate)
                        }
                        let current = OverviewRefreshPreferences.rate(settings)
                        if !OverviewRefreshPreferences.presetRates.contains(current) {
                            Text(AutoRefreshMenu.rateTitle(current)).tag(current)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!OverviewRefreshPreferences.isEnabled(settings))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                CopyButton(help: "Copy Database Info", title: "Copy Info") { details.plainText }
                    .buttonStyle(.borderless)
                if model.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Edit Database…") { model.editDatabase { dismiss() } }
            }
            .padding(12)
        }
        .frame(width: 340, height: 540)
        .task { await model.load() }
    }
}

/// Metric rows of the database info popover.
public enum DatabaseInfoMetrics {
    public struct Row: Hashable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    public static func rows(overview: DatabaseOverview?, dbIndex: Int) -> [Row] {
        guard let overview else { return [] }
        var rows: [Row] = []
        if let cpu = overview.cpuUsagePercentage {
            rows.append(Row(label: "CPU", value: cpu.map { OverviewFormatting.cpuTooltip($0, max: overview.maxCpuUsagePercentage) }
                                ?? "Calculating…"))
        }

        if let ops = overview.opsPerSecond {
            rows.append(Row(label: "Commands/s", value: NumberFormatting.grouped(ops)))
            rows.append(Row(label: "Network Input", value: OverviewFormatting.network(kbps: overview.networkInKbps)))
            rows.append(Row(label: "Network Output", value: OverviewFormatting.network(kbps: overview.networkOutKbps)))
        }

        if let memory = overview.usedMemory {
            rows.append(Row(label: "Memory", value: OverviewFormatting.memoryTooltip(memory)))
        }

        if let keys = overview.totalKeys {
            var value = NumberFormatting.grouped(keys)
            if let dbKeys = overview.totalKeysPerDb?["db\(dbIndex)"], dbKeys < keys {
                value += " (db\(dbIndex): \(NumberFormatting.grouped(dbKeys)))"
            }

            rows.append(Row(label: "Keys", value: value))
        }

        if let clients = overview.connectedClients {
            rows.append(Row(label: "Clients", value: OverviewFormatting.connectedClients(clients)))
        }

        return rows
    }
}
