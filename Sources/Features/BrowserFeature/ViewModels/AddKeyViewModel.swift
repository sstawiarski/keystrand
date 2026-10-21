import Foundation
import Observation
import RedisCore

/// Rows of the Add Key forms.
public struct AddKeyTextRow: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var value = ""
    public init(value: String = "") { self.value = value }
}

public struct AddKeyPairRow: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var name = ""
    public var value = ""
    /// Hash field TTL (seconds, digits) or a sorted-set score.
    public var extra = ""

    public init(name: String = "", value: String = "", extra: String = "") {
        self.name = name
        self.value = value
        self.extra = extra
    }
}

/// "New Key" panel state, validation, and submit (every type via `KeyOperations.create`).
@MainActor
@Observable
public final class AddKeyViewModel {
    /// Types in the order the Add Key type menu lists them.
    public static let offeredTypes: [KeyType] = [.hash, .list, .set, .zset, .string, .json, .stream, .timeSeries, .vectorSet]
    public static let duplicatePolicies = ["", "BLOCK", "FIRST", "LAST", "MIN", "MAX", "SUM"]
    public static let encodings = ["", "COMPRESSED", "UNCOMPRESSED"]

    public let session: DatabaseSession

    public var type: KeyType = .hash {
        didSet { if type != oldValue { errorMessage = nil } }
    }

    public var keyName = ""

    public var ttlText = "" {
        didSet {
            let clean = BrowserFormatting.sanitizeTTL(ttlText)
            if clean != ttlText { ttlText = clean }
        }
    }

    public var stringValue = ""
    public var hashRows = [AddKeyPairRow()]
    public var listDestination: ListDestination = .tail
    public var listElements = [AddKeyTextRow()]
    public var setMembers = [AddKeyTextRow()]
    public var zsetRows = [AddKeyPairRow()]

    public var jsonText = "" {
        didSet { if jsonText != oldValue { validateJSON() } }
    }

    /// Whether `jsonText` parses; large text is checked off the main actor after typing pauses.
    public private(set) var jsonIsValid = true
    @ObservationIgnored private var jsonValidationTask: Task<Void, Never>?
    static let backgroundJSONValidationLength = 32_768
    public var streamID = "*"
    public var streamRows = [AddKeyPairRow()]
    public var tsRetention = ""
    public var tsDuplicatePolicy = ""
    public var tsEncoding = ""
    public var tsLabels = [AddKeyPairRow()]
    public var tsSamples = [AddKeyPairRow(name: "*")]

    public private(set) var isSaving = false
    public var errorMessage: String?

    public init(session: DatabaseSession) {
        self.session = session
    }

    // MARK: - Capabilities

    public func isAvailable(_ type: KeyType) -> Bool {
        switch type {
        case .json: return true
        default: return type.isCreatable(with: session.capabilities)
        }
    }

    public func unavailableReason(_ type: KeyType) -> String? {
        guard !isAvailable(type) else { return nil }
        switch type {
        case .vectorSet: return "Requires Redis 8.0+"
        case .stream: return "Requires Redis 5.0+"
        case .timeSeries: return "Requires the Redis TimeSeries module"
        default: return "Not supported by this database"
        }
    }

    public var supportsHashFieldTTL: Bool { session.capabilities.supportsHashFieldTTL }

    /// JSON is selected without the required module.
    public var jsonModuleMissing: Bool { type == .json && !session.capabilities.hasJSON }

    public var keyNameData: Data { Data(keyName.utf8) }

    public var ttl: Int? {
        guard let value = Int(ttlText), value > 0 else { return nil }
        return value
    }

    /// The Vector Set form is injected and has its own submit button.
    public var usesInjectedForm: Bool { type == .vectorSet }

    // MARK: - Validation

    /// First problem that blocks "Add Key", or nil.
    public var validationMessage: String? {
        if keyName.isEmpty { return "Enter a key name" }
        if !isAvailable(type) { return unavailableReason(type) }
        switch type {
        case .hash:
            if supportsHashFieldTTL, hashRows.contains(where: { !$0.extra.isEmpty && Int($0.extra) == nil }) {
                return "Field TTL should be a number"
            }
        case .zset:
            if zsetRows.contains(where: { BrowserFormatting.parseScore($0.extra) == nil }) {
                return "Enter a valid score for every member"
            }
        case .json:
            if jsonModuleMissing { return "JSON keys can't be created because this database has no JSON support." }
            if !jsonText.contains(where: { !$0.isWhitespace }) { return "Enter a JSON value" }
            if !jsonIsValid { return "Enter valid JSON." }
        case .stream:
            if !BrowserFormatting.isValidStreamID(streamID) { return "Entry ID format is incorrect" }
            if streamRows.allSatisfy({ $0.name.isEmpty }) { return "Enter at least one field" }
        case .timeSeries:
            if !tsRetention.isEmpty && Int(tsRetention) == nil { return "Retention should be a number" }
            for sample in tsSamples where !(sample.name.isEmpty && sample.value.isEmpty) {
                if !BrowserFormatting.isValidTimestamp(sample.name) { return "Timestamp should be * or milliseconds" }
                if Double(sample.value) == nil { return "Sample value should be a number" }
            }

            if tsLabels.contains(where: { $0.name.isEmpty != $0.value.isEmpty }) { return "Labels need a name and a value" }
        default:
            break
        }

        return nil
    }

    public var isValid: Bool { validationMessage == nil }

    /// Inline message under the JSON editor.
    public var jsonValidationMessage: String? {
        !jsonText.isEmpty && !jsonIsValid ? "Enter valid JSON." : nil
    }

    private func validateJSON() {
        jsonValidationTask?.cancel()
        let text = jsonText
        guard text.utf8.count > Self.backgroundJSONValidationLength else {
            let valid = JSONParser.isValid(text)
            if valid != jsonIsValid { jsonIsValid = valid }
            return
        }
        jsonValidationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let valid = await Task.detached(priority: .userInitiated) { JSONParser.isValid(text) }.value
            guard !Task.isCancelled, let self, self.jsonText == text else { return }
            if valid != self.jsonIsValid { self.jsonIsValid = valid }
        }
    }

    // MARK: - Draft

    public func makeDraft() throws -> NewKeyDraft {
        if let message = validationMessage { throw KeyOperationError.invalid(message) }
        let value: NewKeyDraft.Value
        switch type {
        case .string:
            value = .string(Data(stringValue.utf8))
        case .hash:
            value = .hash(hashRows.map { row in
                HashField(field: Data(row.name.utf8), value: Data(row.value.utf8),
                          expire: supportsHashFieldTTL ? Int(row.extra) : nil)
            })
        case .list:
            value = .list(listDestination, listElements.map { Data($0.value.utf8) })
        case .set:
            value = .set(setMembers.map { Data($0.value.utf8) })
        case .zset:
            value = .zset(zsetRows.map { row in
                ZSetMemberDraft(member: Data(row.name.utf8), score: BrowserFormatting.parseScore(row.extra) ?? 0)
            })
        case .json:
            guard JSONParser.isValid(jsonText) else { throw KeyOperationError.invalid("Enter valid JSON.") }
            value = .json(jsonText)
        case .stream:
            let id = streamID.trimmingCharacters(in: .whitespaces)
            value = .stream(id: id.isEmpty ? "*" : id, fields: streamRows.filter { !$0.name.isEmpty }.map {
                StreamFieldDraft(name: Data($0.name.utf8), value: Data($0.value.utf8))
            })
        case .timeSeries:
            let samples = tsSamples.filter { !($0.name.isEmpty && $0.value.isEmpty) }.compactMap { row -> TimeSeriesDraft.Sample? in
                guard let number = Double(row.value) else { return nil }
                let stamp = row.name.trimmingCharacters(in: .whitespaces)
                return TimeSeriesDraft.Sample(timestamp: stamp.isEmpty ? "*" : stamp, value: number)
            }
            let labels = tsLabels.filter { !$0.name.isEmpty }.map { TimeSeriesDraft.Label(name: $0.name, value: $0.value) }
            value = .timeSeries(TimeSeriesDraft(retentionMs: Int(tsRetention), encoding: tsEncoding.isEmpty ? nil : tsEncoding,
                                                duplicatePolicy: tsDuplicatePolicy.isEmpty ? nil : tsDuplicatePolicy,
                                                labels: labels, samples: samples))
        default:
            throw KeyOperationError.invalid("This key type cannot be created here.")
        }

        return NewKeyDraft(name: keyNameData, ttl: ttl, value: value)
    }

    /// Creates the key. Returns the new name and type on success; sets `errorMessage` on failure. A key created
    /// without its TTL counts as added; the TTL failure is reported as an error alert.
    @discardableResult
    public func submit() async -> (name: Data, type: KeyType)? {
        guard !isSaving else { return nil }
        errorMessage = nil
        let draft: NewKeyDraft
        do {
            draft = try makeDraft()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try await KeyOperations(session: session).create(draft)
        } catch KeyOperationError.keyAlreadyExists {
            errorMessage = "This key name is already in use."
            return nil
        } catch {
            guard case KeyOperationError.createdWithoutTTL = error else {
                errorMessage = error.localizedDescription
                return nil
            }
            session.toasts.errorAfterSheetCloses(error, title: KeyOperationError.createdWithoutTTLTitle)
        }

        return (draft.name, draft.type)
    }

    /// JSON "Choose File…": loads a .json / .txt file into the editor.
    public func loadJSONFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            jsonText = String(decoding: data, as: UTF8.self)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
