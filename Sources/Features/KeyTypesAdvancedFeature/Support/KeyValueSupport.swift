import Foundation
import RedisCore
import RedisUI

/// Redis sort direction (Foundation also defines `SortOrder`).
typealias KeySortOrder = RedisCore.SortOrder

/// User-facing errors raised by the advanced key-type services. A missing key is `KeyOperationError.keyNotFound`.
enum KeyValueError: Error, LocalizedError, Equatable {
    case memberNotFound
    case moduleNotLoaded(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .memberNotFound: return "This member no longer exists."
        case .moduleNotLoaded(let module): return "The \(module) module isn't loaded on this server."
        case .invalid(let message): return message
        }
    }
}

/// Helpers that read RESP2 and RESP3 replies the same way.
enum Reply {
    static func items(_ value: RESPValue?) -> [RESPValue] {
        guard let value, !value.isNull else { return [] }
        return value.arrayValue ?? []
    }

    static func map(_ value: RESPValue?) -> [String: RESPValue] {
        guard let value else { return [:] }
        if case .map(let pairs) = value {
            var out: [String: RESPValue] = [:]
            for (k, v) in pairs { if let key = k.stringValue { out[key] = v } }
            return out
        }

        return value.stringKeyedMap ?? [:]
    }

    static func int(_ value: RESPValue?) -> Int {
        guard let raw = value?.intValue else {
            if let d = value?.doubleValue, d.isFinite { return Int(clamping: Int64(d.rounded(.towardZero))) }
            return 0
        }
        return Int(clamping: raw)
    }

    static func optionalInt(_ value: RESPValue?) -> Int? {
        guard let value, !value.isNull else { return nil }
        if let raw = value.intValue { return Int(clamping: raw) }
        return nil
    }

    static func text(_ value: RESPValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        if case .double(let d) = value { return RedisArgument.format(d) }
        return value.stringValue
    }

    static func data(_ value: RESPValue?) -> Data? {
        guard let value, !value.isNull else { return nil }
        return value.dataValue
    }

    /// Returns the reply or throws its error (pipeline replies keep errors in place).
    @discardableResult
    static func checked(_ value: RESPValue) throws -> RESPValue {
        if let error = value.errorValue { throw RedisClientError.server(error) }
        return value
    }

    static func serverMessage(_ error: Error) -> String? {
        if let client = error as? RedisClientError, let server = client.serverError { return server.message }
        return nil
    }

    static func isUnknownCommand(_ error: Error) -> Bool {
        guard let message = serverMessage(error)?.lowercased() else { return false }
        return message.contains("unknown command") || message.contains("unknown subcommand")
    }
}

enum Bytes {
    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// Short name for popovers and notifications (68 chars, last 15 kept).
    static func short(_ data: Data) -> String { short(text(data)) }

    static func short(_ text: String) -> String {
        guard text.count > 68 else { return text }
        return String(text.prefix(50)) + "…" + String(text.suffix(15))
    }
}

/// The current "view format" pipeline settings, captured as a value so it can run off the main actor.
struct ValueFormatContext: Sendable, Equatable {
    var format: ValueFormat
    var compressor: Compressor
    var options: FormatOptions

    init(format: ValueFormat = .unicode, compressor: Compressor = .none, options: FormatOptions = FormatOptions()) {
        self.format = format
        self.compressor = compressor
        self.options = options
    }

    @MainActor
    static func current(_ session: DatabaseSession) -> ValueFormatContext {
        let settings = session.services.settings
        return ValueFormatContext(format: settings.browser.valueFormat, compressor: session.config.compressor,
                                  options: settings.app.formatOptions)
    }

    func format(_ data: Data) -> FormatResult {
        FormatterRegistry.format(data, as: format, compressor: compressor, options: options)
    }

    /// Names (stream fields, vector elements) are never decoded as vectors or decompressed.
    func formatName(_ data: Data) -> FormatResult {
        let nameFormat: ValueFormat = (format == .vector32 || format == .vector64) ? .unicode : format
        return FormatterRegistry.format(data, as: nameFormat, compressor: .none, options: options)
    }

    func formatAll(_ values: [Data], names: Bool = false) async -> [FormatResult] {
        let context = self
        if values.count <= 32 { return values.map { names ? context.formatName($0) : context.format($0) } }
        return await Task.detached(priority: .userInitiated) {
            values.map { names ? context.formatName($0) : context.format($0) }
        }.value
    }

    /// Text used for editing a value in this format, or nil with the reason it cannot be edited.
    func editableText(_ data: Data) -> (text: String?, reason: String?) {
        if !format.allowsEditing { return (nil, "Values shown in this format are read-only") }
        let result = format(data)
        if result.isCompressed { return (nil, "Decompressed values are read-only") }
        if format.isTextView, format != .ascii, !FormatterRegistry.isPrintable(data) {
            return (nil, "This value has non-printable bytes. Edit it in Workbench or the CLI so no bytes are lost.")
        }

        if format.editsRawText { return (String(decoding: data, as: UTF8.self), nil) }
        return (FormatterRegistry.serializeForEdit(data, as: format, compressor: compressor), nil)
    }

    /// Edited text -> bytes; text that is invalid in the format is stored as UTF-8 ("saved as Unicode").
    func parseEdited(_ text: String) throws -> Data {
        if format.editsRawText { return try Decompressor.compress(Data(text.utf8), using: compressor) }
        return try FormatterRegistry.parseEditedLeniently(text, as: format, compressor: compressor)
    }

    /// Edited text -> bytes; throws `FormatterError.invalidInput` when the text is not valid in the format.
    func parseEditedStrictly(_ text: String) throws -> Data {
        if format.editsRawText { return try Decompressor.compress(Data(text.utf8), using: compressor) }
        return try FormatterRegistry.parseEdited(text, as: format, compressor: compressor)
    }

    var requiresNonUnicodeGuard: Bool { format.requiresNonUnicodeGuard }
}

/// Debounces async work on the main actor (latest call wins).
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?
    private let delay: Duration

    init(_ delay: Duration) {
        self.delay = delay
    }

    func schedule(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        let delay = delay
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

extension KeyDetailsContext {
    var keyText: String { Bytes.text(key) }

    @MainActor
    func valueChanged() async {
        await refreshKeyInfo()
        onKeyChanged()
    }
}

typealias KeyIdentity = KeyDetailsIdentity
