import Foundation
import Observation
import RedisCore

public enum SlowLogCount: Hashable, Sendable, CaseIterable, Identifiable {
    case ten, twentyFive, fifty, hundred, max

    public var id: Self { self }

    public var label: String {
        switch self {
        case .ten: return "10"
        case .twentyFive: return "25"
        case .fifty: return "50"
        case .hundred: return "100"
        case .max: return "Max"
        }
    }

    public var menuTitle: String { "Show \(label)" }

    public func value(maxLen: Int?) -> Int {
        switch self {
        case .ten: return 10
        case .twentyFive: return 25
        case .fifty: return 50
        case .hundred: return 100
        case .max: return Swift.max(maxLen ?? 128, 1)
        }
    }
}

@Observable
@MainActor
public final class SlowLogViewModel {
    public let session: DatabaseSession
    let service: SlowLogService

    public private(set) var entries: [SlowLogEntry] = []
    public private(set) var config: SlowLogConfig?
    public private(set) var durationUnit: SlowLogDurationUnit = .milliseconds
    public private(set) var isLoading = false
    public private(set) var isSavingConfig = false
    public private(set) var lastRefresh: Date?
    public private(set) var errorMessage: String?
    public private(set) var hasLoaded = false
    public var count: SlowLogCount = .fifty

    public init(session: DatabaseSession) {
        self.session = session
        self.service = SlowLogService(session: session)
    }

    public static func shared(for session: DatabaseSession) -> SlowLogViewModel {
        session.scopedObject(SlowLogViewModel.self) { SlowLogViewModel(session: session) }
    }

    public var isCluster: Bool { session.isCluster }

    public var countHelp: String {
        isCluster ? "Number of entries to show per node" : "Number of entries to show"
    }

    /// Unit, config and entries.
    public func load() async {
        let settings = await session.services.databaseSettingsStore.settings(for: session.id)
        durationUnit = settings.slowLogDurationUnit
        await loadConfig()
        await refresh()
        hasLoaded = true
    }

    public func loadConfig() async {
        do {
            config = try await service.config()
        } catch {
            config = nil
        }
    }

    /// Errors of a user-initiated refresh become an alert when rows are shown (otherwise the page shows them
    /// inline); auto-refresh errors stay inline.
    public func refresh(userInitiated: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.fetch(count: count.value(maxLen: config?.slowlogMaxLen))
            entries = result.entries
            errorMessage = result.failureMessage
            lastRefresh = Date()
        } catch {
            errorMessage = error.localizedDescription
            if userInitiated && !entries.isEmpty { session.toasts.error(error) }
        }
    }

    /// Auto-refresh tick: skipped while the window is not visible or a load is running.
    public func autoRefresh(isWindowVisible: Bool) async {
        guard isWindowVisible else { return }
        await refresh(userInitiated: false)
    }

    /// Clear asks once: production databases use the type-to-confirm production confirmation inside `clear()`,
    /// every other database shows the view's own dialog first.
    public var clearNeedsDialog: Bool { !session.isProduction }

    public func clear() async -> Bool {
        let confirmed = await session.confirm(ConfirmationRequest(
            title: "Clear Slow Log?", message: "The Slow Log will be cleared for \(session.confirmationName).",
            actionID: "slowlog-reset", confirmButtonTitle: "Clear"))
        guard confirmed else { return false }
        do {
            try await service.reset()
            entries = []
            lastRefresh = Date()
            return true
        } catch {
            session.toasts.error(error, title: "Clear Slow Log Failed")
            return false
        }
    }

    /// Saves the server config and the chosen unit; returns true on success.
    public func saveConfig(_ form: SlowLogConfigForm) async -> Bool {
        guard form.isValid, let slowerThan = form.slowerThanMicroseconds else { return false }
        let confirmed = await session.confirm(ConfirmationRequest(
            title: "Change Slow Log Configuration?",
            message: "CONFIG SET will change slowlog-log-slower-than and slowlog-max-len on \(session.confirmationName).",
            actionID: "slowlog-config", confirmButtonTitle: "Save"))
        guard confirmed else { return false }
        isSavingConfig = true
        defer { isSavingConfig = false }
        let maxLen = form.maxLenValue
        do {
            try await service.setConfig(slowerThanUs: slowerThan, maxLen: maxLen)
            let unit = form.unit
            try await session.services.databaseSettingsStore.update(session.id) { $0.slowLogDurationUnit = unit }
            durationUnit = unit
            config = SlowLogConfig(slowlogMaxLen: maxLen, slowlogLogSlowerThan: slowerThan)
            await refresh()
            return true
        } catch {
            session.toasts.error(error, title: "Save Slow Log Configuration Failed")
            return false
        }
    }

    // MARK: - Display

    public var durationHeader: String { "Duration (\(durationUnit.shortLabel))" }

    public func durationText(_ entry: SlowLogEntry) -> String {
        AnalyticsFormat.duration(microseconds: entry.durationUs, unit: durationUnit)
    }

    public func timestampText(_ entry: SlowLogEntry) -> String {
        AnalyticsFormat.date(Date(timeIntervalSince1970: TimeInterval(entry.time)), settings: session.services.settings)
    }

    public var slowerThanText: String {
        guard let config else { return "-" }
        if config.slowlogLogSlowerThan < 0 { return String(config.slowlogLogSlowerThan) }
        return AnalyticsFormat.duration(microseconds: config.slowlogLogSlowerThan, unit: durationUnit)
    }

    /// Status bar: `12 entries since 13:40:01 · Logging commands slower than 10 ms · Max length 128`.
    public var statusText: String {
        var parts: [String] = []
        if let oldest = entries.map(\.time).min() {
            let word = entries.count == 1 ? "entry" : "entries"
            let date = AnalyticsFormat.date(Date(timeIntervalSince1970: TimeInterval(oldest)), settings: session.services.settings)
            parts.append("\(NumberFormatting.grouped(entries.count)) \(word) since \(date)")
        } else {
            parts.append("No entries")
        }

        if !isCluster, let config {
            if config.slowlogLogSlowerThan < 0 {
                parts.append("Slow Log is disabled")
            } else {
                parts.append("Logging commands slower than \(slowerThanText) \(durationUnit.shortLabel)")
            }

            parts.append("Max length \(NumberFormatting.grouped(config.slowlogMaxLen))")
        }

        return parts.joined(separator: " · ")
    }

    public var emptyText: String {
        "No commands took longer than \(slowerThanText) \(durationUnit.shortLabel), or the Slow Log is disabled."
    }
}

extension SlowLogDurationUnit {
    /// "µs" or "ms".
    public var shortLabel: String { self == .microseconds ? "µs" : "ms" }
}
