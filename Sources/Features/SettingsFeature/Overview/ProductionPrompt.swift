import Foundation
import Observation
import RedisUI

/// "Looks like production" signals for the one-time "Treat this database as production?" prompt.
public enum ProductionHeuristic {
    public static let keyCountThreshold = 10_000
    public static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]

    public struct Signals: Hashable, Sendable {
        public var hasKeyCountSignal: Bool
        public var isRemoteHost: Bool
        public var hasTLS: Bool
        public var isClustered: Bool
        public var hasAuth: Bool

        public var hasConnectionSignal: Bool { isRemoteHost || hasTLS || isClustered || hasAuth }
    }

    public static func signals(host: String?, tls: Bool, connectionKind: ConnectionKind, username: String?,
                               hasPassword: Bool, totalKeys: Int?) -> Signals {
        let trimmedHost = host?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return Signals(hasKeyCountSignal: (totalKeys ?? 0) > keyCountThreshold,
                       isRemoteHost: !trimmedHost.isEmpty && !localHosts.contains(trimmedHost),
                       hasTLS: tls,
                       isClustered: connectionKind != .standalone,
                       hasAuth: !(username ?? "").isEmpty || hasPassword)
    }

    /// Key count alone would match a local dev database loaded with sample data, so one connection signal is required too.
    public static func looksLikeProduction(_ signals: Signals) -> Bool {
        signals.hasKeyCountSignal && signals.hasConnectionSignal
    }
}

/// Controls the production prompt and preserves dismissal for the window lifetime.
@MainActor
@Observable
public final class ProductionPromptModel {
    public static let title = "Treat This Database as Production?"
    public static let message = "Marking it as production makes Keystrand ask before data changes and adds a typed "
        + "check before dangerous commands. Only the app's behavior changes; nothing on the server is modified."
    public static let dismissLabel = "Not Now"
    public static let confirmLabel = "Mark as Production…"

    public let session: DatabaseSession
    public private(set) var isOpen = false
    private var isDismissed = false
    @ObservationIgnored private var cachedHasPassword: Bool?

    public init(session: DatabaseSession) {
        self.session = session
    }

    public static func shared(for session: DatabaseSession) -> ProductionPromptModel {
        session.scopedObject(ProductionPromptModel.self) { ProductionPromptModel(session: session) }
    }

    private var settings: SettingsStore { session.services.settings }

    /// Changes when the production-prompt decision needs reevaluation.
    public var triggerKey: String {
        let manyKeys = (session.overview?.totalKeys ?? 0) > ProductionHeuristic.keyCountThreshold
        return "\(manyKeys)|\(session.environment.rawValue)|\(session.state.isConnected)|\(settings.ui.prodModeCtaActioned)"
    }

    public func evaluate() async {
        guard !isDismissed else {
            isOpen = false
            return
        }
        let promote = await shouldPromote()
        isOpen = promote && !isDismissed
    }

    func shouldPromote() async -> Bool {
        guard !settings.ui.prodModeCtaActioned, session.state.isConnected, session.environment == .unspecified else {
            return false
        }
        let config = session.config
        var signals = ProductionHeuristic.signals(host: config.host, tls: config.tls.enabled,
                                                  connectionKind: session.connectionKind, username: config.username,
                                                  hasPassword: !(config.password ?? "").isEmpty,
                                                  totalKeys: session.overview?.totalKeys)
        guard signals.hasKeyCountSignal else { return false }
        guard let databases = try? await session.services.databaseStore.list(),
              databases.contains(where: { $0.id == session.id }) else { return false }
        if !signals.hasConnectionSignal {
            signals.hasAuth = await hasSavedPassword()
        }

        return ProductionHeuristic.looksLikeProduction(signals)
    }

    private func hasSavedPassword() async -> Bool {
        if let cachedHasPassword { return cachedHasPassword }
        let full = try? await session.services.databaseStore.get(session.id)
        let hasPassword = !(full?.password ?? "").isEmpty
        cachedHasPassword = hasPassword
        return hasPassword
    }

    public func notNow() {
        settings.ui.prodModeCtaActioned = true
        close()
    }

    public func openDatabaseSettings() {
        settings.ui.prodModeCtaActioned = true
        close()
        session.navigator.navigate(.editDatabase(focusEnvironment: true))
    }

    /// Hides the prompt for this window without saving a choice.
    public func close() {
        isDismissed = true
        isOpen = false
    }
}
