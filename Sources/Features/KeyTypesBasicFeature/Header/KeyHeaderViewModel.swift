import Foundation
import Observation
import RedisCore
import RedisUI

/// Key details header: info, rename, TTL, delete, refresh.
@MainActor
@Observable
public final class KeyHeaderViewModel {
    public let context: KeyDetailsContext
    public private(set) var isLoading = false
    public private(set) var isWorking = false
    public var lastRefresh: Date?
    /// Rename hit an existing name; the view asks whether to overwrite.
    public var pendingOverwriteName: Data?
    public private(set) var coveringIndexes: [SearchIndexSummary] = []

    @ObservationIgnored private var support: KeyViewSupport { KeyViewSupport(context: context) }

    public init(context: KeyDetailsContext) {
        self.context = context
    }

    public var info: KeyInfo? { context.state.info }
    public var type: KeyType { context.state.info?.type ?? context.type }
    public var keyNameFormat: KeyNameFormat { support.keyNameFormat }
    public var displayName: String { support.keyDisplayName }

    /// Rename is disabled for names that do not survive a UTF-8 round trip (unless names are shown as HEX).
    public var canRename: Bool {
        keyNameFormat == .hex || FormatterRegistry.isPrintable(context.key)
    }

    public var renameDisabledReason: String? {
        canRename ? nil : ValueEditRules.nonPrintableTitle + "\n" + ValueEditRules.nonPrintableMessage
    }

    /// Delete asks once: no dialog in Development, the production confirmation in Production, a popover otherwise.
    public var skipsDeleteConfirmation: Bool { context.session.environment != .unspecified }

    // MARK: - Info

    public func loadInfo() async {
        isLoading = true
        defer { isLoading = false }
        do {
            context.state.info = try await support.fetchInfo()
            lastRefresh = Date()
        } catch {
            support.report(error)
        }
    }

    /// Header Refresh / auto-refresh: reload info, then ask the type view to reload.
    public func refresh() async {
        guard !context.state.isRefreshDisabled else { return }
        await loadInfo()
        guard context.state.info != nil else { return }
        context.state.requestRefresh()
        context.onKeyChanged()
    }

    // MARK: - Rename

    public func renameDraft() -> String {
        keyNameFormat == .hex ? displayName : String(decoding: context.key, as: UTF8.self)
    }

    /// Parses the edited name in the database's key-name format.
    public func parseName(_ text: String) -> Data? {
        guard !text.isEmpty else { return nil }
        if keyNameFormat == .hex {
            return try? FormatterRegistry.parseEdited(text, as: .hex)
        }

        return Data(text.utf8)
    }

    public func renameValidation(_ text: String) -> String? {
        if text.isEmpty { return "Key name should not be empty" }
        if parseName(text) == nil { return "Enter the key name as hexadecimal bytes" }
        return nil
    }

    /// Returns true when the key was renamed.
    @discardableResult
    public func rename(to text: String, overwrite: Bool = false) async -> Bool {
        guard let newName = parseName(text), newName != context.key else { return false }
        let newDisplay = DisplayName.short(newName, format: keyNameFormat)
        if !overwrite {
            guard await support.confirmProduction(KeyConfirmations.rename(support.shortKeyName, to: newDisplay)) else {
                return false
            }
        }

        isWorking = true
        defer { isWorking = false }
        do {
            try await KeyOperations(session: context.session).rename(context.key, to: newName, overwrite: overwrite)
            pendingOverwriteName = nil
            context.onKeyRenamed(newName)
            return true
        } catch let error as KeyOperationError where error == .newNameInUse {
            pendingOverwriteName = newName
            return false
        } catch {
            support.report(error)
            return false
        }
    }

    /// Returns true when the key was renamed over the existing one.
    @discardableResult
    public func confirmOverwrite() async -> Bool {
        guard let name = pendingOverwriteName else { return false }
        pendingOverwriteName = nil
        return await rename(to: keyNameFormat == .hex ? RedisKeyName(name).displayString(format: .hex)
                                               : String(decoding: name, as: UTF8.self),
                     overwrite: true)
    }

    // MARK: - TTL

    public func ttlDraft() -> String {
        guard let ttl = info?.ttl, ttl >= 0 else { return "" }
        return String(ttl)
    }

    /// `seconds == -1` removes the TTL; 0 deletes the key (the view confirms first).
    public func setTTL(_ seconds: Int) async {
        guard await support.confirmProduction(KeyConfirmations.changeTTL(support.shortKeyName, seconds: seconds)) else {
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await KeyOperations(session: context.session).setTTL(context.key, seconds: seconds)
            if seconds == 0 {
                support.keyWasDeleted()
                return
            }

            if var info = context.state.info {
                info.ttl = seconds
                context.state.info = info
            }

            await loadInfo()
            context.onKeyChanged()
        } catch {
            support.report(error)
        }
    }

    // MARK: - Delete

    public func deleteKey() async {
        guard await support.confirmProduction(KeyConfirmations.deleteKey(support.shortKeyName)) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await KeyOperations(session: context.session).delete([context.key])
            support.keyWasDeleted()
        } catch {
            support.report(error)
        }
    }

    // MARK: - Full screen

    /// The host callback may toggle `state.isFullScreen` itself; either way the state ends up flipped once.
    public func toggleFullScreen() {
        let target = !context.state.isFullScreen
        context.onToggleFullScreen()
        if context.state.isFullScreen != target { context.state.isFullScreen = target }
    }

    // MARK: - Search indexes (View index / Make searchable)

    public var supportsIndexActions: Bool {
        context.session.capabilities.hasSearch && (type == .hash || type == .json)
    }

    public func loadCoveringIndexes() async {
        guard supportsIndexActions else {
            coveringIndexes = []
            return
        }
        coveringIndexes = (try? await SearchIndexService(session: context.session)
            .indexes(coveringKey: context.key, type: type)) ?? []
    }

    public func viewIndex(_ index: SearchIndexSummary) {
        context.session.navigator.navigate(.vectorSearchQuery(indexName: index.name, openIndexPanel: true))
    }

    public func makeSearchable() {
        let keyType: SearchIndexKeyType = type == .json ? .json : .hash
        context.session.navigator.navigate(.vectorSearchCreateIndex(
            .existingData(initialKey: context.key, keyType: keyType, prefix: Self.prefix(of: context.key))))
    }

    /// Key name up to and including the last `:` (nil when there is none).
    public nonisolated static func prefix(of key: Data) -> String? {
        let name = String(decoding: key, as: UTF8.self)
        guard let index = name.lastIndex(of: ":") else { return nil }
        return String(name[...index])
    }
}

/// Header labels per type (pure).
public enum KeyHeaderLabels {
    public struct Stat: Hashable, Sendable {
        public var label: String
        public var shortLabel: String
        public var value: String
    }

    /// Length plus type extras (Vector Set quant type / dim, Array count).
    public static func stats(for info: KeyInfo) -> [Stat] {
        var out: [Stat] = []
        let lengthLabel = info.type.lengthLabel
        if let text = info.lengthString ?? info.length.map({ NumberFormatting.grouped($0) }) {
            out.append(Stat(label: lengthLabel, shortLabel: lengthLabel, value: text))
        }

        if info.type == .vectorSet {
            if let quant = info.quantType { out.append(Stat(label: "Quantization", shortLabel: "Q", value: quant)) }
            if let dim = info.vectorDim { out.append(Stat(label: "Dimensions", shortLabel: "Dim", value: String(dim))) }
        }

        if info.type == .array, let count = info.count {
            out.append(Stat(label: "Count", shortLabel: "Cnt", value: count))
        }

        return out
    }

    /// "Key Size" text: nil when unknown, "-1" handled by the view (too large).
    public static func size(_ bytes: Int?) -> String? {
        guard let bytes, bytes >= 0 else { return nil }
        return ByteFormatter.format(Double(bytes), decimals: 2)
    }

    /// Persists auto-refresh rates separately for each key type.
    public static func refreshPostfix(for type: KeyType) -> String { type.rawValue }

    /// Metadata row of the header: Type, Size, the length label(s) and TTL.
    public static func metadataItems(for info: KeyInfo, sizeTooLargeHelp: String = sizeTooLargeHelp) -> [MetadataItem] {
        var items = [MetadataItem(label: "Type", value: info.type.displayName)]
        if let bytes = info.size {
            if bytes == -1 {
                items.append(MetadataItem(label: "Size", value: "Too large", help: sizeTooLargeHelp))
            } else if let text = size(bytes) {
                items.append(MetadataItem(label: "Size", value: text, help: "\(NumberFormatting.grouped(bytes)) bytes"))
            }
        }

        items += stats(for: info).map { MetadataItem(label: $0.label, value: $0.value) }
        items.append(MetadataItem(label: "TTL", value: TTLText.text(info.ttl),
                                  help: info.ttl >= 0 ? TTLText.secondsTooltip(info.ttl) : nil))
        return items
    }

    public static let sizeTooLargeHelp = "The key is too large to run MEMORY USAGE without affecting performance."

    public struct MetadataItem: Hashable, Sendable {
        public var label: String
        public var value: String
        public var help: String?

        public init(label: String, value: String, help: String? = nil) {
            self.label = label
            self.value = value
            self.help = help
        }
    }

    public static func ttl(_ ttl: Int?) -> String {
        guard let ttl, ttl >= 0 else { return "No limit" }
        return NumberFormatting.grouped(ttl)
    }
}
