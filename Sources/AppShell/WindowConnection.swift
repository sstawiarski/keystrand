import CLIFeature
import Foundation
import MonitoringFeature
import Observation
import RedisUI

enum WindowContentPhase: Equatable {
    case connecting
    case disconnected
    case failed(ConnectionError)
    case content

    /// Sections mount only once connected; a pending first connect shows a spinner, a user disconnect a placeholder.
    static func make(state: SessionState, userDisconnected: Bool) -> WindowContentPhase {
        switch state {
        case .connected: return .content
        case .connecting: return .connecting
        case .failed(let error): return .failed(error)
        case .disconnected: return userDisconnected ? .disconnected : .connecting
        }
    }

    /// The bottom tools (CLI, Profiler) run on their own connections, so they are shown only while connected.
    var showsBottomPanel: Bool { self == .content }
}

/// The parts of a database config that change where or how the window connects.
struct ConnectionFingerprint: Hashable {
    var host: String
    var port: Int
    var db: Int?
    var username: String?
    var timeoutMs: Int
    var tls: TLSSettings
    var ssh: SSHOptions?
    var sentinelMaster: SentinelMasterConfig?
    var forceStandalone: Bool
    var connectionFamily: ConnectionFamily
    var preConnectScript: String?

    init(_ config: DatabaseConfig) {
        let config = config.withoutSecrets()
        host = config.host
        port = config.port
        db = config.db
        username = config.username
        timeoutMs = config.timeoutMs
        tls = config.tls
        ssh = config.ssh
        sentinelMaster = config.sentinelMaster
        forceStandalone = config.forceStandalone
        connectionFamily = config.connectionFamily
        preConnectScript = config.preConnectScript
    }
}

/// Connects on first appearance and after edits. Tracks connection loss while the session still reports connected.
@MainActor
@Observable
final class WindowConnectionModel {
    private(set) var userDisconnected = false
    /// Set when the overview fails and a PING shows the server is unreachable.
    private(set) var lostConnection: ConnectionError?
    @ObservationIgnored private weak var session: DatabaseSession?
    @ObservationIgnored private var didAutoConnect = false
    @ObservationIgnored private var fingerprint: ConnectionFingerprint?
    @ObservationIgnored private var lastReconnect = Date.distantPast
    @ObservationIgnored private var probeGeneration = 0
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var stopDedicatedTools: @MainActor (DatabaseSession) async -> Void = WindowConnectionModel.stopBottomPanelTools

    static let reconnectDebounce: TimeInterval = 1.5

    init(session: DatabaseSession) {
        self.session = session
        fingerprint = ConnectionFingerprint(session.config)
    }

    static func shared(for session: DatabaseSession) -> WindowConnectionModel {
        session.scopedObject(WindowConnectionModel.self) { WindowConnectionModel(session: session) }
    }

    var phase: WindowContentPhase {
        guard let session else { return .disconnected }
        return WindowContentPhase.make(state: session.state, userDisconnected: userDisconnected)
    }

    /// Connects once so tab switches cannot undo a user disconnect.
    @discardableResult
    func connectOnFirstAppearance() async -> Bool {
        guard !didAutoConnect, let session else { return false }
        didAutoConnect = true
        guard session.state == .disconnected, !userDisconnected else { return false }
        await connect()
        return true
    }

    func connect() async {
        guard let session else { return }
        didAutoConnect = true
        userDisconnected = false
        lostConnection = nil
        await session.connect()
    }

    func disconnect() async {
        guard let session else { return }
        didAutoConnect = true
        userDisconnected = true
        lostConnection = nil
        await stopDedicatedTools(session)
        await session.disconnect()
    }

    /// CLI and MONITOR connections are not pooled, so `session.disconnect()` leaves them open.
    static func stopBottomPanelTools(_ session: DatabaseSession) async {
        let bottom = BottomPanelModel.shared(for: session)
        await bottom.stop(.cli, session: session)
        await bottom.stop(.profiler, session: session)
    }

    func reconnect() async {
        guard let session else { return }
        didAutoConnect = true
        userDisconnected = false
        lostConnection = nil
        lastReconnect = now()
        fingerprint = ConnectionFingerprint(session.config)
        await session.reconnect()
    }

    /// Always reconnects after an edit because password-only changes are invisible in `session.config`.
    func databaseWasEdited() async {
        guard !isWithinDebounce else { return }
        await reconnect()
    }

    /// Reconnects if the endpoint or credentials change.
    func configDidChange() async {
        guard let session else { return }
        let current = ConnectionFingerprint(session.config)
        guard current != fingerprint else { return }
        fingerprint = current
        guard !userDisconnected, session.state != .disconnected, !isWithinDebounce else { return }
        await reconnect()
    }

    /// The overview poll failed or recovered; a failing PING marks the connection as lost.
    func overviewErrorDidChange() async {
        guard let session else { return }
        probeGeneration += 1
        let generation = probeGeneration
        guard session.overviewError != nil, session.state.isConnected else {
            lostConnection = nil
            return
        }
        let lost = await Self.probe(session)
        guard generation == probeGeneration else { return }
        lostConnection = lost
    }

    static let probeTimeout: TimeInterval = 5

    /// Nil when the server answers; a server error reply still means the connection works.
    static func probe(_ session: DatabaseSession) async -> ConnectionError? {
        do {
            try await session.ping(timeout: probeTimeout)
            return nil
        } catch RedisClientError.server {
            return nil
        } catch {
            return ConnectionError.classify(error, endpoint: session.config.endpoint)
        }
    }

    private var isWithinDebounce: Bool {
        now().timeIntervalSince(lastReconnect) < Self.reconnectDebounce
    }
}

/// Converts connection error titles from sentence case to title case for window titles.
enum TitleCase {
    private static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or", "the", "to", "up",
    ]

    static func make(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { index, word in
            let isEdge = index == 0 || index == words.count - 1
            return word.split(separator: "-", omittingEmptySubsequences: false).map { part in
                let part = String(part)
                if !isEdge, minorWords.contains(part) { return part }
                return part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: "-")
        }.joined(separator: " ")
    }
}
