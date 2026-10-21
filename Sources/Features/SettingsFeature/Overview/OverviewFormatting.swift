import Foundation
import RedisUI

/// Formats header overview metrics.
public enum OverviewFormatting {
    /// Floors counts to K, M, or B units; uses plain digits below 1000.
    public static func compactCount(_ value: Int) -> String {
        let magnitude = value.magnitude
        let sign = value < 0 ? "-" : ""
        if magnitude >= 1_000_000_000 { return "\(sign)\(magnitude / 1_000_000_000) B" }
        if magnitude >= 1_000_000 { return "\(sign)\(magnitude / 1_000_000) M" }
        if magnitude >= 1_000 { return "\(sign)\(magnitude / 1_000) K" }
        return String(value)
    }

    /// Formats integers without decimals and other values with `decimals` decimal places.
    public static func percentage(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.\(decimals)f", value)
    }

    /// `0.25 %`.
    public static func cpuDisplay(_ value: Double) -> String {
        "\(percentage(value, decimals: 2)) %"
    }

    /// `0.2512%`, or `0.2512% / 400%` when the maximum is above 100 %.
    public static func cpuTooltip(_ value: Double, max: Int?) -> String {
        let text = "\(percentage(value, decimals: 4))%"
        if let max, max > 100 { return "\(text) / \(max)%" }
        return text
    }

    /// Rounds to `decimals` decimal places and removes trailing zeros.
    public static func bytesParts(_ bytes: Double, decimals: Int, base: Double = 1024) -> (value: String, unit: String) {
        guard bytes.isFinite, bytes >= 0 else { return ("-", "") }
        guard bytes > 0 else { return ("0", ByteFormatter.units[0]) }
        let exponent = min(max(Int(floor(log(bytes) / log(base))), 0), ByteFormatter.units.count - 1)
        let scaled = bytes / pow(base, Double(exponent))
        return (trimmed(scaled, decimals: decimals), ByteFormatter.units[exponent])
    }

    public static func bytes(_ bytes: Double, decimals: Int, base: Double = 1024) -> String {
        let parts = bytesParts(bytes, decimals: decimals, base: base)
        return parts.unit.isEmpty ? parts.value : "\(parts.value) \(parts.unit)"
    }

    /// Formats header memory with no decimal places.
    public static func memory(_ usedMemory: Int) -> String {
        bytes(Double(usedMemory), decimals: 0)
    }

    /// Formats the memory tooltip with up to three decimal places.
    public static func memoryTooltip(_ usedMemory: Int) -> String {
        bytes(Double(usedMemory), decimals: 3)
    }

    /// Multiplies kbps by 1000 and formats with base 1000, up to 3 decimal places, and a lowercase unit plus `/s`.
    public static func network(kbps: Double?) -> String {
        let parts = bytesParts((kbps ?? 0) * 1000, decimals: 3, base: 1000)
        guard !parts.unit.isEmpty else { return parts.value }
        return "\(parts.value) \(parts.unit.lowercased())/s"
    }

    /// Whole numbers as-is; a fractional median becomes `~<rounded>`.
    public static func connectedClients(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded() { return String(Int64(value)) }
        return "~\(Int64(value.rounded()))"
    }

    static func trimmed(_ value: Double, decimals: Int) -> String {
        let factor = pow(10, Double(max(decimals, 0)))
        let rounded = (value * factor).rounded() / factor
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int64(rounded)) }
        var text = String(format: "%.\(max(decimals, 0))f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// One item of the overview bar, already formatted.
public struct OverviewMetric: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case cpu, commands, memory, keys, clients
    }

    public struct Detail: Hashable, Sendable {
        public var label: String
        public var value: String
        public var systemImage: String?

        public init(label: String, value: String, systemImage: String? = nil) {
            self.label = label
            self.value = value
            self.systemImage = systemImage
        }
    }

    public var kind: Kind
    public var title: String
    public var systemImage: String
    /// Text in the bar (`"Calculating…"` while loading).
    public var value: String
    public var isLoading: Bool
    /// Rows of the hover tooltip / click popover.
    public var details: [Detail]

    public var id: Kind { kind }

    /// Plain-text tooltip (`.help`).
    public var tooltip: String {
        ([title] + details.map { detail in detail.label.isEmpty ? detail.value : "\(detail.label): \(detail.value)" })
            .joined(separator: "\n")
    }
}

public enum OverviewMetricsBuilder {
    /// Returns reported metrics in CPU, commands, memory, keys, and clients order.
    public static func metrics(from overview: DatabaseOverview, dbIndex: Int) -> [OverviewMetric] {
        var items: [OverviewMetric] = []

        if let cpu = overview.cpuUsagePercentage {
            if let value = cpu {
                items.append(OverviewMetric(kind: .cpu, title: "CPU", systemImage: "cpu", value: OverviewFormatting.cpuDisplay(value),
                                            isLoading: false,
                                            details: [.init(label: "", value: OverviewFormatting.cpuTooltip(value, max: overview.maxCpuUsagePercentage))]))
            } else {
                items.append(OverviewMetric(kind: .cpu, title: "CPU", systemImage: "cpu", value: "Calculating…", isLoading: true,
                                            details: [.init(label: "", value: "Calculating in progress")]))
            }
        }

        if let ops = overview.opsPerSecond {
            items.append(OverviewMetric(
                kind: .commands, title: "Commands/s", systemImage: "gauge.with.dots.needle.33percent",
                value: String(ops), isLoading: false,
                details: [
                    .init(label: "Commands/s", value: String(ops), systemImage: "gauge.with.dots.needle.33percent"),
                    .init(label: "Network Input", value: OverviewFormatting.network(kbps: overview.networkInKbps),
                          systemImage: "arrow.down.circle"),
                    .init(label: "Network Output", value: OverviewFormatting.network(kbps: overview.networkOutKbps),
                          systemImage: "arrow.up.circle"),
                ]))
        }

        if let memory = overview.usedMemory {
            items.append(OverviewMetric(kind: .memory, title: "Total Memory", systemImage: "memorychip",
                                        value: OverviewFormatting.memory(memory), isLoading: false,
                                        details: [.init(label: "", value: OverviewFormatting.memoryTooltip(memory))]))
        }

        if let total = overview.totalKeys {
            var details: [OverviewMetric.Detail] = [.init(label: "", value: NumberFormatting.grouped(total))]
            if let dbKeys = overview.totalKeysPerDb?["db\(dbIndex)"], dbKeys < total {
                details = [
                    .init(label: "Total Keys", value: NumberFormatting.grouped(total)),
                    .init(label: "db\(dbIndex)", value: NumberFormatting.grouped(dbKeys)),
                ]
            }

            items.append(OverviewMetric(kind: .keys, title: "Total Keys", systemImage: "key",
                                        value: OverviewFormatting.compactCount(total), isLoading: false, details: details))
        }

        if let clients = overview.connectedClients {
            let text = OverviewFormatting.connectedClients(clients)
            items.append(OverviewMetric(kind: .clients, title: "Connected Clients", systemImage: "person.2",
                                        value: text, isLoading: false, details: [.init(label: "", value: text)]))
        }

        return items
    }

    /// Fallback text for a metric missing from the server reply.
    public static func unavailableText(_ kind: OverviewMetric.Kind) -> String {
        switch kind {
        case .cpu: return "CPU is not available"
        case .commands: return "Commands/s are not available"
        case .memory: return "Total Memory is not available"
        case .keys: return "Total Keys are not available"
        case .clients: return "Connected Clients are not available"
        }
    }
}

/// One run of the compact overview text in the window's activity area ("CPU 0.4%", "132 ops/s").
public struct OverviewSummaryPart: Identifiable, Hashable, Sendable {
    public enum Kind: Int, Hashable, Sendable, CaseIterable {
        case version, cpu, commands, memory, keys, clients
    }

    public var kind: Kind
    public var text: String
    public var help: String
    public var id: Kind { kind }

    public init(kind: Kind, text: String, help: String) {
        self.kind = kind
        self.text = text
        self.help = help
    }
}

/// Compact overview text: `Redis 8.10.2 · CPU 0.4% · 132 ops/s · 5.1 MB · 73 keys · 1 client`.
public enum OverviewSummary {
    public static let separator = " · "
    /// Runs dropped one after another when the activity area is too narrow.
    public static let dropOrder: [OverviewSummaryPart.Kind] = [.clients, .keys, .commands, .cpu]

    /// Returns metrics in display order, omitting missing values and CPU until its second sample.
    /// Uses `version` if the overview has no version.
    public static func parts(overview: DatabaseOverview?, version: String?, flavor: ServerFlavor = .redis,
                             dbIndex: Int) -> [OverviewSummaryPart] {
        var parts: [OverviewSummaryPart] = []
        if let version = overview?.version ?? version, !version.isEmpty {
            parts.append(.init(kind: .version, text: DatabaseCapabilities.displayName(flavor: flavor, version: version),
                               help: "\(flavor.displayName) version \(version)"))
        }

        guard let overview else { return parts }
        let metrics = Dictionary(uniqueKeysWithValues: OverviewMetricsBuilder.metrics(from: overview, dbIndex: dbIndex)
            .map { ($0.kind, $0) })
        if let cpu = overview.cpuUsagePercentage ?? nil {
            parts.append(.init(kind: .cpu, text: "CPU \(OverviewFormatting.percentage(cpu, decimals: 1))%",
                               help: metrics[.cpu]?.tooltip ?? "CPU"))
        }

        if let ops = overview.opsPerSecond {
            parts.append(.init(kind: .commands, text: "\(NumberFormatting.grouped(ops)) ops/s",
                               help: metrics[.commands]?.tooltip ?? "Commands/s"))
        }

        if let memory = overview.usedMemory {
            parts.append(.init(kind: .memory, text: OverviewFormatting.bytes(Double(memory), decimals: 1),
                               help: metrics[.memory]?.tooltip ?? "Total Memory"))
        }

        if let keys = overview.totalKeys {
            parts.append(.init(kind: .keys, text: keysText(keys), help: metrics[.keys]?.tooltip ?? "Total Keys"))
        }

        if let clients = overview.connectedClients {
            parts.append(.init(kind: .clients, text: clientsText(clients),
                               help: metrics[.clients]?.tooltip ?? "Connected Clients"))
        }

        return parts
    }

    /// The full text first, then one variant per dropped run (`ViewThatFits` candidates).
    public static func variants(_ parts: [OverviewSummaryPart]) -> [[OverviewSummaryPart]] {
        var out = [parts]
        var dropped = Set<OverviewSummaryPart.Kind>()
        for kind in dropOrder where parts.contains(where: { $0.kind == kind }) {
            dropped.insert(kind)
            out.append(parts.filter { !dropped.contains($0.kind) })
        }

        return out
    }

    public static func text(_ parts: [OverviewSummaryPart]) -> String {
        parts.map(\.text).joined(separator: separator)
    }

    /// `73 keys`, `1 key`, `8.2K keys`.
    public static func keysText(_ count: Int) -> String {
        let number = count < 10_000 ? NumberFormatting.grouped(count)
            : count.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US_POSIX")))
        return count == 1 ? "1 key" : "\(number) keys"
    }

    /// `1 client`, `3 clients`, `~3 clients` for a fractional cluster median.
    public static func clientsText(_ value: Double) -> String {
        let text = OverviewFormatting.connectedClients(value)
        return text == "1" ? "1 client" : "\(text) clients"
    }
}

/// Overview auto-refresh preferences (shared with the database info popover).
public enum OverviewRefreshPreferences {
    public static let postfix = "overview"
    public static let enabledByDefault = true
    public static let presetRates: [Double] = [1, 2, 5, 10, 30, 60]

    @MainActor public static func isEnabled(_ settings: SettingsStore) -> Bool {
        settings.ui.autoRefreshEnabled[postfix] ?? enabledByDefault
    }

    @MainActor public static func rate(_ settings: SettingsStore) -> Double {
        max(settings.ui.autoRefreshRate(postfix), 1)
    }
}
