import Foundation
import Observation
import RedisUI

enum CreateIndexViewMode: String, CaseIterable, Identifiable, Hashable {
    case table
    case command
    var id: String { rawValue }
    var title: String { self == .table ? "Table" : "Command" }
}

@Observable
@MainActor
final class CreateIndexViewModel {
    struct PendingKey: Equatable, Identifiable {
        var key: Data
        var type: SearchIndexKeyType
        var id: Data { key }
    }

    let session: DatabaseSession
    let request: CreateIndexRequest
    private let existingIndexNames: @MainActor () -> Set<String>

    private(set) var mode: CreateIndexMode = .probing
    private(set) var sampleDataset: SampleDataset?
    var indexName = "idx:myindex"
    var prefix = ""
    var keyType: SearchIndexKeyType = .hash
    private(set) var fields: [IndexFieldDraft] = []
    var selected: Set<String> = []
    private(set) var skippedFields: [String] = []
    private(set) var isDirty = false
    var viewMode: CreateIndexViewMode = .table
    private(set) var selectedKey: Data?
    private(set) var isLoadingFields = false
    private(set) var fieldsError: String?
    private(set) var probeError: String?
    var pendingKey: PendingKey?
    private(set) var isCreating = false
    var fieldEditor: FieldEditorDraft?

    var isEditingName = false
    var nameDraft = ""
    private(set) var nameError: String?

    let keys: KeysPickerViewModel
    private var loadGeneration = 0

    init(session: DatabaseSession, request: CreateIndexRequest,
         existingIndexNames: @escaping @MainActor () -> Set<String> = { [] }) {
        self.session = session
        self.request = request
        self.existingIndexNames = existingIndexNames
        self.keys = KeysPickerViewModel(session: session)
    }

    // MARK: - Derived state

    var isSampleMode: Bool {
        if case .sampleData = mode { return true }
        return false
    }

    var checkedFields: [IndexFieldDraft] {
        isSampleMode ? fields : fields.filter { selected.contains($0.name) }
    }

    var command: String {
        if let sampleDataset, isSampleMode { return sampleDataset.createCommand }
        return FTCreateBuilder.command(indexName: indexName, keyType: keyType, prefix: prefix, fields: checkedFields)
    }

    var trimmedIndexName: String { indexName.trimmingCharacters(in: .whitespaces) }

    var isDuplicateName: Bool { existingIndexNames().contains(trimmedIndexName) }

    var showsNameEditor: Bool {
        switch mode {
        case .manual: return true
        case .browse, .preselected: return !fields.isEmpty
        default: return false
        }
    }

    var title: String {
        if let sampleDataset, isSampleMode { return "Sample Index: \(sampleDataset.displayName)" }
        return "New Index"
    }

    var createDisabledReason: String? {
        if let reason = QuerySafety.indexCreationBlockedReason(session) { return reason }
        if isSampleMode { return nil }
        if checkedFields.isEmpty {
            return mode == .browse && selectedKey == nil ? VectorSearchStrings.selectKeyReason : VectorSearchStrings.addFieldReason
        }

        if isDuplicateName { return VectorSearchStrings.duplicateIndexName }
        return nil
    }

    var skippedNotice: String? { FieldTypeInference.skippedNotice(skippedFields) }

    var emptySchemaText: String {
        mode == .manual
            ? "Add the fields you want to index, then set the index name and the key prefix."
            : "Choose a key on the left to suggest an indexing schema."
    }

    var supportsFloat16: Bool { session.capabilities.supportsFloat16Vectors }

    // MARK: - Start

    func start() async {
        switch request {
        case .sampleData(let id):
            guard let dataset = SampleDatasets.dataset(id) else {
                session.toasts.error(SampleDatasetsError.resourceMissing(id.rawValue))
                return
            }
            applySample(dataset)
        case .existingData(let initialKey, let initialType, let initialPrefix):
            if let initialKey {
                mode = .preselected
                await selectKey(initialKey, type: initialType, force: true)
                if let initialPrefix { prefix = initialPrefix }
            } else {
                if let initialPrefix { prefix = initialPrefix }
                await probe()
            }
        }
    }

    func applySample(_ dataset: SampleDataset) {
        sampleDataset = dataset
        mode = .sampleData(dataset.id)
        indexName = dataset.indexName
        prefix = dataset.indexPrefix
        keyType = dataset.keyType
        fields = dataset.fieldDrafts
        selected = Set(fields.map(\.name))
    }

    /// Browse mode unless the database has no HASH / JSON keys (then manual). Failures keep browse mode.
    func probe() async {
        mode = .probing
        probeError = nil
        do {
            let hasKeys = try await Self.hasIndexableKeys(session)
            mode = hasKeys ? .browse : .manual
        } catch {
            probeError = error.localizedDescription
            mode = .browse
        }

        if mode == .browse { await keys.refresh() }
    }

    static func hasIndexableKeys(_ session: DatabaseSession) async throws -> Bool {
        for node in try await session.nodes(role: .primary) {
            let replies = try await node.pipeline([
                ["SCAN", "0", "MATCH", "*", "COUNT", "500", "TYPE", "hash"],
                ["SCAN", "0", "MATCH", "*", "COUNT", "500", "TYPE", "ReJSON-RL"],
            ])
            for reply in replies {
                if let error = reply.errorValue { throw RedisClientError.server(error) }
                let parts = reply.arrayValue ?? []
                let cursor = parts.first?.stringValue ?? "0"
                let keys = parts.count > 1 ? (parts[1].arrayValue ?? []) : []
                if !keys.isEmpty || cursor != "0" { return true }
            }
        }
        return false
    }

    // MARK: - Key selection

    /// Picks a key; with unsaved field edits the choice waits for confirmation in `pendingKey`.
    func selectKey(_ key: Data, type: SearchIndexKeyType?, force: Bool = false) async {
        var resolved = type
        if resolved == nil {
            let reply = try? await session.execute(["TYPE", .data(key)])
            switch reply?.stringValue.flatMap(KeyType.init(typeReply:)) {
            case .hash?: resolved = .hash
            case .json?: resolved = .json
            default: resolved = nil
            }
        }

        guard let resolvedType = resolved else {
            fieldsError = "Only HASH and JSON keys can be indexed."
            return
        }
        if !force, isDirty, key != selectedKey {
            pendingKey = PendingKey(key: key, type: resolvedType)
            return
        }

        await load(key: key, type: resolvedType)
    }

    func confirmPendingKey(_ pending: PendingKey) async {
        pendingKey = nil
        await load(key: pending.key, type: pending.type)
    }

    func cancelPendingKey() {
        pendingKey = nil
    }

    func load(key: Data, type: SearchIndexKeyType) async {
        loadGeneration += 1
        let token = loadGeneration
        selectedKey = key
        keyType = type
        let display = RedisKeyName(key).displayString()
        prefix = FieldTypeInference.prefix(forKey: display)
        indexName = FieldTypeInference.defaultIndexName(prefix: prefix)
        isLoadingFields = true
        fieldsError = nil
        defer { if token == loadGeneration { isLoadingFields = false } }
        do {
            let result = try await Self.loadFields(session: session, key: key, type: type)
            guard token == loadGeneration else { return }
            fields = result.fields
            skippedFields = result.skipped
            selected = Set(result.fields.map(\.name))
            isDirty = false
        } catch {
            guard token == loadGeneration else { return }
            fields = []
            skippedFields = []
            selected = []
            fieldsError = error.localizedDescription
        }
    }

    static func loadFields(session: DatabaseSession, key: Data,
                           type: SearchIndexKeyType) async throws -> (fields: [IndexFieldDraft], skipped: [String]) {
        switch type {
        case .hash:
            let reply = try await session.execute(["HSCAN", .data(key), "0", "MATCH", "*", "COUNT", "500"])
            let items = reply.arrayValue.flatMap { $0.count > 1 ? $0[1].arrayValue : nil } ?? []
            let flat = items.compactMap(\.dataValue)
            return await Task.detached(priority: .userInitiated) {
                let pairs = stride(from: 0, to: flat.count - 1, by: 2).map { (field: flat[$0], value: flat[$0 + 1]) }
                return (FieldTypeInference.inferHash(pairs), [String]())
            }.value
        case .json:
            let reply = try await session.execute(["JSON.GET", .data(key), "$"])
            guard let data = reply.dataValue else { return ([], []) }
            return try await Task.detached(priority: .userInitiated) {
                let value = try JSONParser.parse(data)
                return FieldTypeInference.inferJSON(value)
            }.value
        }
    }

    // MARK: - Fields

    func isChecked(_ field: IndexFieldDraft) -> Bool { selected.contains(field.name) }

    func setChecked(_ field: IndexFieldDraft, _ checked: Bool) {
        guard mode.isEditable else { return }
        if checked { selected.insert(field.name) } else { selected.remove(field.name) }
    }

    var allChecked: Bool { !fields.isEmpty && fields.allSatisfy { selected.contains($0.name) } }

    func setAllChecked(_ checked: Bool) {
        guard mode.isEditable else { return }
        selected = checked ? Set(fields.map(\.name)) : []
    }

    func beginAddField() {
        guard mode.isEditable else { return }
        fieldEditor = FieldEditorDraft(field: nil)
    }

    func beginEdit(_ field: IndexFieldDraft) {
        guard mode.isEditable else { return }
        fieldEditor = FieldEditorDraft(field: field)
    }

    func fieldErrors(_ draft: FieldEditorDraft) -> [FieldEditorDraft.Input: String] {
        draft.errors(existingNames: Set(fields.map(\.name)), supportsFloat16: supportsFloat16)
    }

    @discardableResult
    func commitFieldEditor(_ draft: FieldEditorDraft) -> Bool {
        guard fieldErrors(draft).isEmpty else { return false }
        let field = draft.makeField()
        if draft.isNew {
            fields.append(field)
            selected.insert(field.name)
        } else if let index = fields.firstIndex(where: { $0.name == draft.originalName }) {
            fields[index] = field
        }

        isDirty = true
        fieldEditor = nil
        return true
    }

    func removeField(_ field: IndexFieldDraft) {
        guard mode.isEditable else { return }
        fields.removeAll { $0.name == field.name }
        selected.remove(field.name)
        isDirty = true
    }

    // MARK: - Index name

    func beginEditingName() {
        guard !isSampleMode else { return }
        nameDraft = indexName
        nameError = nil
        isEditingName = true
    }

    @discardableResult
    func commitName() -> Bool {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        if existingIndexNames().contains(trimmed) {
            nameError = VectorSearchStrings.duplicateIndexName
            return false
        }

        indexName = trimmed
        nameError = nil
        isEditingName = false
        return true
    }

    func validateNameDraft() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        nameError = existingIndexNames().contains(trimmed) ? VectorSearchStrings.duplicateIndexName : nil
    }

    func cancelEditingName() {
        nameError = nil
        isEditingName = false
    }

    // MARK: - Create

    /// Runs the generated FT.CREATE through the Search history. Returns the new index name on success.
    func create() async -> Data? {
        guard !isSampleMode, createDisabledReason == nil, !isCreating else { return nil }
        isCreating = true
        defer { isCreating = false }
        let executor = CommandExecutor(session: session, history: session.services.commandHistoryStore, type: .search)
        let params = ExecuteParams(batchSize: 1, mode: .ascii, resultsMode: .default, clearEditor: false)
        do {
            let executions = try await executor.run([command], params: params, settings: session.services.settings.app)
            if let result = executions.first?.result?.first, result.status == .fail {
                session.toasts.error(Self.message(result) ?? VectorSearchStrings.createFailedMessage,
                                     title: VectorSearchStrings.createFailedTitle)
                return nil
            }

            isDirty = false
            SearchIndexService(session: session).invalidateSummaries()
            return Data(trimmedIndexName.utf8)
        } catch {
            session.toasts.error(error.localizedDescription, title: VectorSearchStrings.createFailedTitle)
            return nil
        }
    }

    static func message(_ result: CommandExecutionResult) -> String? {
        switch result.response {
        case .reply(.error(let message)): return message
        case .message(let message): return message
        default: return nil
        }
    }
}
