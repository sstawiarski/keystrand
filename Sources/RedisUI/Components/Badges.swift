import SwiftUI

public extension KeyType {
    /// System color of the key type's symbol tile.
    var tint: Color {
        switch self {
        case .string: return .purple
        case .hash: return .blue
        case .list: return .green
        case .set: return .orange
        case .zset: return .pink
        case .stream: return .mint
        case .json: return .indigo
        case .timeSeries: return .gray
        case .vectorSet: return .cyan
        case .array: return .teal
        case .graph: return .brown
        case .unknown: return .gray
        }
    }

    /// SF Symbol of the key type.
    var symbolName: String {
        switch self {
        case .string: return "textformat"
        case .hash: return "number"
        case .list: return "list.bullet"
        case .set: return "circle.grid.2x2"
        case .zset: return "list.number"
        case .stream: return "water.waves"
        case .json: return "curlybraces"
        case .timeSeries: return "chart.xyaxis.line"
        case .vectorSet: return "move.3d"
        case .array: return "rectangle.split.3x1"
        case .graph: return "point.3.filled.connected.trianglepath.dotted"
        case .unknown: return "questionmark"
        }
    }
}

/// System Settings–style tile: a rounded rectangle filled with the type's tint gradient and a white symbol.
public struct KeyTypeIcon: View {
    public enum Size: Sendable {
        case small, regular, large

        public var dimension: CGFloat {
            switch self {
            case .small: return 16
            case .regular: return 20
            case .large: return 28
            }
        }

        public var cornerRadius: CGFloat {
            switch self {
            case .small: return 4
            case .regular: return 5
            case .large: return 7
            }
        }
    }

    public let type: KeyType
    public var size: Size

    public init(type: KeyType, size: Size = .small) {
        self.type = type
        self.size = size
    }

    public var body: some View {
        let dimension = size.dimension
        RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            .fill(type.tint.gradient)
            .frame(width: dimension, height: dimension)
            .overlay {
                Image(systemName: type.symbolName)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: dimension * 0.6, height: dimension * 0.6)
            }
            .accessibilityElement()
            .accessibilityLabel(type.displayName)
            .help(type.displayName)
    }
}

/// The type's display name with its tile.
public struct KeyTypeLabel: View {
    public let type: KeyType
    public var size: KeyTypeIcon.Size

    public init(type: KeyType, size: KeyTypeIcon.Size = .small) {
        self.type = type
        self.size = size
    }

    public var body: some View {
        Label {
            Text(type.displayName)
        } icon: {
            KeyTypeIcon(type: type, size: size)
        }
    }
}

/// Production: red shield label; Development: secondary hammer label; unspecified: nothing.
public struct EnvironmentLabel: View {
    public enum Style: Sendable { case titleAndIcon, iconOnly }

    public let environment: DatabaseEnvironment
    public var style: Style

    public init(environment: DatabaseEnvironment, style: Style = .titleAndIcon) {
        self.environment = environment
        self.style = style
    }

    public var body: some View {
        switch environment {
        case .production:
            styled(Label("Production", systemImage: "exclamationmark.shield.fill"))
                .foregroundStyle(.red)
                .help("Production: data changes ask for confirmation first.")
        case .development:
            styled(Label("Development", systemImage: "hammer.fill"))
                .foregroundStyle(.secondary)
                .help("Development: data changes skip the usual confirmations.")
        case .unspecified:
            EmptyView()
        }
    }

    @ViewBuilder
    private func styled(_ label: Label<Text, Image>) -> some View {
        switch style {
        case .titleAndIcon: label
        case .iconOnly: label.labelStyle(.iconOnly)
        }
    }
}

/// Tags as plain text (`team: core, app: web`), middle-truncated, with every tag in the tooltip.
public struct TagText: View {
    public let tags: [DatabaseTag]

    public init(tags: [DatabaseTag]) {
        self.tags = tags
    }

    public init(tag: DatabaseTag) {
        self.tags = [tag]
    }

    public var body: some View {
        Text(Self.text(tags))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(Self.tooltip(tags))
    }

    nonisolated public static func text(_ tags: [DatabaseTag]) -> String {
        tags.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    }

    nonisolated public static func tooltip(_ tags: [DatabaseTag]) -> String {
        tags.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

/// Modules as plain text (`Search, JSON, Time Series +2`) with `<Name> v. <version>` per line in the tooltip.
public struct ModuleSummaryText: View {
    public let modules: [RedisModuleInfo]
    public var maxVisible: Int
    public var flavor: ServerFlavor

    public init(modules: [RedisModuleInfo], maxVisible: Int = 3, flavor: ServerFlavor = .redis) {
        self.modules = modules
        self.maxVisible = maxVisible
        self.flavor = flavor
    }

    public var body: some View {
        Text(Self.summary(modules, maxVisible: maxVisible, flavor: flavor))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(Self.tooltip(modules, flavor: flavor))
    }

    nonisolated public static func summary(_ modules: [RedisModuleInfo], maxVisible: Int,
                                           flavor: ServerFlavor = .redis) -> String {
        let visible = max(maxVisible, 0)
        let names = modules.prefix(visible).map { $0.displayName(on: flavor) }.joined(separator: ", ")
        let hidden = modules.count - min(visible, modules.count)
        guard hidden > 0 else { return names }
        return names.isEmpty ? "+\(hidden)" : "\(names) +\(hidden)"
    }

    nonisolated public static func tooltip(_ modules: [RedisModuleInfo], flavor: ServerFlavor = .redis) -> String {
        modules.map { module in
            let name = module.displayName(on: flavor)
            return module.versionText.map { "\(name) v. \($0)" } ?? name
        }.joined(separator: "\n")
    }
}

/// One label/value pair of `KeyMetadataRow`.
public struct KeyMetadataItem: Identifiable, Sendable, Hashable {
    public var label: String
    public var value: String
    public var help: String?
    public var id: String { label }

    public init(label: String, value: String, help: String? = nil) {
        self.label = label
        self.value = value
        self.help = help
    }
}

/// Key details metadata: one row of label/value pairs, wrapping to a two-column grid when narrow.
public struct KeyMetadataRow: View {
    public let items: [KeyMetadataItem]

    public init(items: [KeyMetadataItem]) {
        self.items = items
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                ForEach(items) { item in cell(item).fixedSize() }
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                ForEach(Self.pairs(items), id: \.first.id) { pair in
                    GridRow {
                        cell(pair.first)
                        if let second = pair.second { cell(second) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
        }
    }

    private func cell(_ item: KeyMetadataItem) -> some View {
        HStack(spacing: 6) {
            Text(item.label).foregroundStyle(.secondary)
            Text(item.value).monospacedDigit().textSelection(.enabled)
        }
        .lineLimit(1)
        .help(item.help ?? "")
        .accessibilityElement(children: .combine)
    }

    nonisolated static func pairs(_ items: [KeyMetadataItem]) -> [(first: KeyMetadataItem, second: KeyMetadataItem?)] {
        stride(from: 0, to: items.count, by: 2).map { index in
            (items[index], index + 1 < items.count ? items[index + 1] : nil)
        }
    }
}

/// Command group name as secondary caption text (Command Helper / completion details).
public struct CommandGroupBadge: View {
    public let group: String

    public init(group: String) {
        self.group = group
    }

    public var body: some View {
        Text(Self.displayName(for: group))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    nonisolated static let displayNames: [String: String] = [
        "hash": "Hash", "list": "List", "set": "Set", "sorted-set": "Sorted Set", "sorted_set": "Sorted Set",
        "string": "String", "json": "JSON", "stream": "Stream", "bitmap": "Bitmap", "cluster": "Cluster",
        "connection": "Connection", "geo": "Geo", "generic": "Generic", "pubsub": "Pub/Sub", "scripting": "Scripting",
        "transactions": "Transactions", "timeseries": "TimeSeries", "server": "Server", "hyperloglog": "HyperLogLog",
        "cms": "CMS", "tdigest": "TDigest", "topk": "TopK", "bf": "Bloom Filter", "cf": "Cuckoo Filter",
        "search": "search",
    ]

    /// Known groups use fixed names; others replace `_` with spaces and capitalize.
    nonisolated public static func displayName(for group: String) -> String {
        if let known = displayNames[group] { return known }
        let spaced = group.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }
}
