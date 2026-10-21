import Foundation
import RedisCore

@MainActor
struct KeyViewSupport {
    let context: KeyDetailsContext

    var session: DatabaseSession { context.session }
    var settings: SettingsStore { session.services.settings }
    var key: Data { context.key }
    var keyNameFormat: KeyNameFormat { session.config.keyNameFormat }
    var keyDisplayName: String { context.keyDisplayName }
    var shortKeyName: String { context.keyShortName }
    var format: ValueFormat { settings.browser.valueFormat }

    var formatter: ValueDisplayFormatter {
        ValueDisplayFormatter(format: format, compressor: session.config.compressor, options: settings.app.formatOptions)
    }

    func report(_ error: Error, title: String = "Error") {
        context.report(error, title: title)
    }

    func keyWasDeleted() {
        context.keyWasDeleted()
    }

    /// Whether the Browser shows the Size column (header runs MEMORY USAGE unconditionally only then).
    func includeSize() async -> Bool {
        let settings = await session.services.databaseSettingsStore.settings(for: session.config.id)
        if session.environment == .production && !settings.didUserConfigureColumns { return false }
        return settings.browserShownColumns.contains(.size)
    }

    func fetchInfo() async throws -> KeyInfo {
        try await KeyMetadataService(session: session).keyInfo(key, includeSize: await includeSize(),
                                                               typeHint: context.state.info?.type)
    }

    func refreshInfo() async {
        do {
            context.state.info = try await fetchInfo()
        } catch let error as KeyOperationError where error == .keyNotFound {
            report(error)
            return
        } catch {
            // The value view stays usable; the header keeps the previous info.
        }

        context.onKeyChanged()
    }

    func confirmProduction(title: String, message: String, actionID: String, button: String) async -> Bool {
        await context.confirmWrite(title: title, message: message, button: button, actionID: actionID)
    }

    func confirmProduction(_ request: ConfirmationRequest) async -> Bool {
        await context.confirmProduction(request)
    }
}

func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated, operation: work).value
}

typealias KeyViewIdentity = KeyDetailsIdentity

/// Combines the "editing" flags of the header and the type view into `state.isRefreshDisabled`.
@MainActor
enum RefreshLock {
    static func set(_ state: KeyDetailsState, owner: String, locked: Bool) {
        state.setRefreshLock(owner: owner, locked: locked)
    }
}

/// One cancellable load at a time for a type view: a new load cancels the previous one,
/// a refresh is skipped while a load is still running, and leaving the view cancels it.
@MainActor
final class LoadTaskSlot {
    private var task: Task<Void, Never>?
    private var token = 0

    var isRunning: Bool { task != nil }

    func run(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        token += 1
        let current = token
        task = Task { [weak self] in
            await work()
            guard let self, self.token == current else { return }
            self.task = nil
        }
    }

    func runUnlessRunning(_ work: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        run(work)
    }

    func cancel() {
        task?.cancel()
        task = nil
        token += 1
    }

    func wait() async {
        await task?.value
    }
}

func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || Task.isCancelled
}
