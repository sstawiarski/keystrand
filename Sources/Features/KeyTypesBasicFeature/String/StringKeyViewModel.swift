import Foundation
import Observation
import RedisCore

/// String value: partial load (GETRANGE 0 4999), Load all, Download, edit (SET KEEPTTL), copy.
@MainActor
@Observable
public final class StringKeyViewModel {
    public let context: KeyDetailsContext
    /// Loaded bytes (the first 5,000 until "Load all").
    public private(set) var value: Data?
    public private(set) var length = 0
    public private(set) var result: FormatResult?
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public private(set) var isEditing = false
    public var editDraft = ""
    public private(set) var isSaving = false
    public private(set) var isDownloading = false
    @ObservationIgnored public var pendingEditAfterFormatChange = false

    /// Keeps the whole value loaded across refreshes after "Load all".
    @ObservationIgnored private var wantsFullValue = false
    @ObservationIgnored private var formatter: ValueDisplayFormatter
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var editOriginalText: String?
    @ObservationIgnored private var lastEncoding: (draft: String, format: ValueFormat, encoded: (data: Data, isValid: Bool))?
    @ObservationIgnored let loads = LoadTaskSlot()

    public init(context: KeyDetailsContext) {
        self.context = context
        self.formatter = KeyViewSupport(context: context).formatter
    }

    private var support: KeyViewSupport { KeyViewSupport(context: context) }
    private var service: StringService { StringService(session: context.session) }

    public var isFullyLoaded: Bool { (value?.count ?? 0) >= length }
    /// Footer with Load all / Download appears for values longer than the initial window.
    public var showsFooter: Bool { length > StringService.initialLoadBytes }
    /// The selected format applies only once the whole value is loaded (partial values show Unicode).
    public var selectedFormat: ValueFormat { formatter.format }
    public var displayFormat: ValueFormat { isFullyLoaded ? formatter.format : .unicode }
    public var isEmpty: Bool { value?.isEmpty ?? false }

    // MARK: - Loading

    /// Starts `load()`, cancelling a load that is still running.
    public func reload() {
        loads.run { [weak self] in await self?.load() }
    }

    /// Header Refresh / auto-refresh: skipped while a load is still running.
    public func refresh() {
        loads.runUnlessRunning { [weak self] in await self?.load() }
    }

    /// Starts `loadAll()`, cancelling a load that is still running.
    public func reloadAll() {
        loads.run { [weak self] in await self?.loadAll() }
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        formatter = support.formatter
        isLoading = true
        loadError = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let snapshot = try await service.load(context.key, end: wantsFullValue ? -1 : nil)
            guard generation == loadGeneration else { return }
            value = snapshot.value
            length = snapshot.length
            if snapshot.isFull {
                let (tips, key) = (context.session.liveTips, context.key)
                Task { await tips.reportStringLoaded(key: key, value: snapshot.value) }
            }

            await render(generation: generation)
        } catch {
            guard generation == loadGeneration, !isCancellation(error) else { return }
            if let keyError = error as? KeyOperationError, keyError == .keyNotFound {
                support.report(error)
                return
            }

            loadError = error.localizedDescription
        }
    }

    public func loadAll() async {
        wantsFullValue = true
        await load()
    }

    public func formatChanged() async {
        formatter = support.formatter
        let pending = pendingEditAfterFormatChange
        pendingEditAfterFormatChange = false
        cancelEdit()
        await render(generation: loadGeneration)
        if pending { beginEdit() }
    }

    private func render(generation: Int) async {
        guard let value else {
            result = nil
            editBlockReason = Self.loadingReason
            return
        }
        let full = isFullyLoaded
        let editFormat = self.formatter.format
        var snapshot = self.formatter
        if !full { snapshot.format = .unicode }
        let formatter = snapshot
        let (formatted, blockReason) = await offMain {
            let rendered = formatter.result(value, expanded: true)
            let reason = ValueEditRules.editBlockReason(value, format: editFormat, isValid: rendered.isValid,
                                                        isCompressed: rendered.isCompressed, isPartial: !full)
            return (rendered, reason)
        }
        guard generation == loadGeneration else { return }
        var rendered = formatted
        if !full, case .text(let text) = rendered.content { rendered.content = .text(text + "…") }
        result = rendered
        editBlockReason = blockReason
    }

    // MARK: - Edit

    private static let loadingReason = "Loading"

    /// Why the value cannot be edited, or nil when editing is allowed; computed off the main actor on each render.
    public private(set) var editBlockReason: String? = StringKeyViewModel.loadingReason

    public var needsNonUnicodeGuard: Bool { ValueEditRules.requiresNonUnicodeGuard(formatter.format) }

    public func beginEdit() {
        guard let value, editBlockReason == nil else { return }
        editDraft = ValueEditRules.editorText(value, format: formatter.format)
        editOriginalText = editDraft
        isEditing = true
        RefreshLock.set(context.state, owner: "value", locked: true)
    }

    public func cancelEdit() {
        isEditing = false
        editDraft = ""
        editOriginalText = nil
        lastEncoding = nil
        RefreshLock.set(context.state, owner: "value", locked: false)
    }

    public var hasUnsavedEdit: Bool { isEditing && editDraft != editOriginalText }

    /// `SET ... KEEPTTL`; an unchanged draft writes nothing (re-encoding would rewrite the stored bytes).
    @discardableResult
    public func saveEdit() async -> Bool {
        guard isEditing else { return false }
        if editDraft == editOriginalText {
            cancelEdit()
            return true
        }

        let ok = await support.confirmProduction(title: "Edit Value in Production?",
                                                 message: "The stored value will be overwritten. This database is marked as production.",
                                                 actionID: KeyConfirmations.editValue, button: "Save")
        guard ok else { return false }
        let data = await encodeDraft().data
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.update(context.key, value: data)
            cancelEdit()
            wantsFullValue = data.count > StringService.initialLoadBytes || wantsFullValue
            await load()
            await support.refreshInfo()
            return true
        } catch {
            support.report(error)
            return false
        }
    }

    /// The draft encoded under the selected format, computed off the main actor and reused while the draft is unchanged.
    public func encodeDraft() async -> (data: Data, isValid: Bool) {
        let (draft, format) = (editDraft, formatter.format)
        if let cached = lastEncoding, cached.format == format, cached.draft == draft { return cached.encoded }
        let encoded = await offMain { ValueEditRules.encode(draft, format: format) }
        lastEncoding = (draft, format, encoded)
        return encoded
    }

    public func viewDidDisappear() {
        loads.cancel()
        RefreshLock.set(context.state, owner: "value", locked: false)
    }

    // MARK: - Copy / download

    public var canCopy: Bool { isFullyLoaded && !isEditing && result != nil }

    /// Displayed text (pretty JSON for tree formats); nil until the whole value is loaded. Evaluate on demand only.
    public var copyText: String? {
        guard isFullyLoaded, !isEditing, let result else { return nil }
        return result.displayText(expanded: true, indent: 2)
    }

    /// `GET` the whole value and write it to `url`.
    @discardableResult
    public func download(to url: URL) async -> Bool {
        isDownloading = true
        defer { isDownloading = false }
        do {
            let data = try await service.fullValue(context.key)
            try await offMain { Result { try data.write(to: url, options: .atomic) } }.get()
            return true
        } catch {
            support.report(error)
            return false
        }
    }
}
