import RedisUI
import SwiftUI

/// Why search by values is unavailable for this database.
public enum SearchUnavailableReason: String, Identifiable, Sendable {
    case moduleNotLoaded
    case versionTooOld

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .moduleNotLoaded: return "Redis Search Not Available"
        case .versionTooOld: return "Redis Search Version Too Old"
        }
    }

    var message: String {
        switch self {
        case .moduleNotLoaded:
            return "Redis Search adds queries, secondary indexes, full-text search, aggregation, numeric and geo filters, "
                + "and vector similarity search. Open a database with Redis Search to search the values of keys."
        case .versionTooOld:
            return "Value search uses Redis Search commands introduced in version 2.0. Redis 6 and later include a compatible version."
        }
    }
}

struct KeyTypeFilterMenu: View {
    @Bindable var model: BrowserViewModel

    nonisolated static func types(capabilities: DatabaseCapabilities) -> [KeyType] {
        var out: [KeyType] = [.hash, .list, .set, .zset, .string, .json, .stream]
        if capabilities.supportsVectorSets { out.append(.vectorSet) }
        out.append(.timeSeries)
        if capabilities.hasGraph { out.append(.graph) }
        if capabilities.supportsArray { out.append(.array) }
        return out
    }

    private var isEnabled: Bool { model.isTypeFilterSupported && model.searchMode == .pattern }

    var body: some View {
        Menu {
            Picker("Key Type", selection: Binding(get: { model.typeFilter }, set: { model.setTypeFilter($0) })) {
                Text("All Types").tag(KeyType?.none)
                ForEach(Self.types(capabilities: model.session.capabilities)) { type in
                    Label(type.displayName, systemImage: type.symbolName).tag(KeyType?.some(type))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.typeFilter.map { "Filter: \($0.displayName)" } ?? "Filter",
                  systemImage: model.typeFilter == nil ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
        }
        .disabled(!isEnabled)
        .help(helpText)
    }

    private var helpText: String {
        if !model.isTypeFilterSupported { return "The key type filter needs Redis 6 or newer." }
        if model.searchMode != .pattern { return "The key type filter applies to key name search." }
        return model.typeFilter.map { "Key Type: \($0.displayName)" } ?? "Filter by Key Type"
    }
}

struct SearchIndexMenu: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        Menu {
            if model.indexes.isEmpty {
                Text(model.isLoadingIndexes ? "Loading…" : "No Indexes")
            }

            Picker("Index", selection: Binding(get: { model.selectedIndex }, set: { model.selectIndex($0) })) {
                ForEach(model.indexes, id: \.self) { index in
                    Text(SearchIndexPicker.label(index)).tag(Data?.some(index))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Refresh Indexes") { Task { await model.loadIndexes() } }
                .disabled(model.isLoadingIndexes)
            Button("Create Index…") {
                model.session.navigator.navigate(.vectorSearchCreateIndex(
                    .existingData(initialKey: nil, keyType: nil, prefix: nil)))
            }
        } label: {
            Label(model.selectedIndex.map(SearchIndexPicker.label) ?? "Choose Index", systemImage: "sparkle.magnifyingglass")
                .labelStyle(.titleAndIcon)
        }
        .help(model.selectedIndex.map { "Index: \(String(decoding: $0, as: UTF8.self))" } ?? "Choose Index")
    }
}

enum SearchIndexPicker {
    static func label(_ name: Data) -> String {
        let text = String(decoding: name, as: UTF8.self)
        if text.isEmpty { return "(empty name)" }
        return TextTruncation.formatLongName(text, maxLength: 40, tail: 10)
    }

    /// Indexes whose name contains `query` (case-insensitive); all of them for an empty query.
    static func filtered(_ indexes: [Data], query: String) -> [Data] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return indexes }
        return indexes.filter { String(decoding: $0, as: UTF8.self).localizedCaseInsensitiveContains(needle) }
    }
}
