import Foundation
import RedisCore

/// The parts of a database config that decide which server the CLI talks to and how it authenticates.
struct CLIConnectionFingerprint: Hashable {
    var host: String
    var port: Int
    var db: Int
    var username: String?
    var timeoutMs: Int
    var tls: TLSSettings
    var ssh: SSHOptions?
    var sentinelMaster: SentinelMasterConfig?
    var connectionType: ConnectionType
    var forceStandalone: Bool
    var connectionFamily: ConnectionFamily
    var preConnectScript: String?

    init(_ config: DatabaseConfig) {
        let config = config.withoutSecrets()
        host = config.host
        port = config.port
        db = config.dbIndex
        username = config.username
        timeoutMs = config.timeoutMs
        tls = config.tls
        ssh = config.ssh
        sentinelMaster = config.sentinelMaster
        connectionType = config.connectionType
        forceStandalone = config.forceStandalone
        connectionFamily = config.connectionFamily
        preConnectScript = config.preConnectScript
    }
}
