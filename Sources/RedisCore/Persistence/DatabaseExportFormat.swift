import Foundation

/// RedisInsight-compatible database exports and lenient import mapping.
enum DatabaseExportFormat {
    struct ImportedCertificate {
        var name: String
        var certificate: String
        var key: String?
    }

    struct Mapped {
        var config: DatabaseConfig
        var caCertificate: ImportedCertificate?
        var clientCertificate: ImportedCertificate?
        var errors: [String] = []
    }

    // MARK: - Export

    static func object(for config: DatabaseConfig, ca: CACertificate?, client: ClientCertificate?,
                       includeSecrets: Bool) -> [String: Any] {
        var o: [String: Any] = [
            "id": config.id.rawValue,
            "host": config.host,
            "port": config.port,
            "name": config.name,
            "connectionType": config.connectionType.rawValue,
            "modules": config.modules.map { module -> [String: Any] in
                var m: [String: Any] = ["name": module.name]
                if let version = module.version { m["version"] = version }
                if let semantic = module.semanticVersion { m["semanticVersion"] = semantic }
                return m
            },
            "tls": config.tls.enabled,
            "verifyServerCert": config.tls.verifyServerCert,
            "ssh": config.ssh != nil,
            "compressor": config.compressor.rawValue,
            "forceStandalone": config.forceStandalone,
            "tags": config.tags.map { ["key": $0.key, "value": $0.value] },
            "environment": config.environment.rawValue,
            "connectionFamily": config.connectionFamily.rawValue,
            "keyNameFormat": config.keyNameFormat.rawValue,
            "timeout": config.timeoutMs,
        ]
        if let db = config.db { o["db"] = db }
        if let username = config.username { o["username"] = username }
        if includeSecrets, let password = config.password { o["password"] = password }
        if let name = config.nameFromProvider { o["nameFromProvider"] = name }
        if let provider = config.provider { o["provider"] = provider.rawValue }
        if let last = config.lastConnection { o["lastConnection"] = ISO8601DateFormatter().string(from: last) }
        if let servername = config.tls.servername { o["tlsServername"] = servername }
        if includeSecrets, let script = config.preConnectScript { o["preConnectScript"] = script }
        if includeSecrets, let script = config.postDisconnectScript { o["postDisconnectScript"] = script }
        if let nodes = config.nodes { o["nodes"] = nodes.map { ["host": $0.host, "port": $0.port] } }
        if let master = config.sentinelMaster {
            var m: [String: Any] = ["name": master.name]
            if let username = master.username { m["username"] = username }
            if includeSecrets, let password = master.password { m["password"] = password }
            o["sentinelMaster"] = m
        }

        if let ca {
            o["caCert"] = ["id": ca.id, "name": ca.name, "certificate": ca.certificate]
        }

        if let client {
            var c: [String: Any] = ["id": client.id, "name": client.name, "certificate": client.certificate]
            if includeSecrets, let key = client.key { c["key"] = key }
            o["clientCert"] = c
        }

        if let ssh = config.ssh {
            var s: [String: Any] = ["host": ssh.host, "port": ssh.port, "username": ssh.username]
            if includeSecrets {
                switch ssh.auth {
                case .password(let password): if let password { s["password"] = password }
                case .privateKey(let pem, let passphrase):
                    if let pem { s["privateKey"] = pem }
                    if let passphrase { s["passphrase"] = passphrase }
                }
            }

            o["sshOptions"] = s
        }

        return o
    }

    // MARK: - Import

    /// Missing paths return nil; JSON `null` returns `NSNull`.
    static func lookup(_ object: [String: Any], _ path: String) -> Any? {
        var current: Any? = object
        for part in path.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(part)]
        }

        return current
    }

    static func first(_ object: [String: Any], _ paths: [String]) -> Any? {
        for path in paths { if let value = lookup(object, path) { return value } }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased())
        case is [String: Any]: return true
        default: return nil
        }
    }

    static func mapImport(_ o: [String: Any]) -> Mapped {
        var errors: [String] = []
        let host = string(first(o, ["host"])) ?? ""
        let port = int(first(o, ["port"])) ?? 6379
        var config = DatabaseConfig(host: host, port: port)
        config.name = string(first(o, ["name", "connectionName"])) ?? "\(host):\(port)"
        config.username = string(first(o, ["username"]))
        config.password = string(first(o, ["password", "auth"]))
        config.db = int(first(o, ["db"]))
        config.isNew = true
        config.nameFromProvider = string(first(o, ["nameFromProvider"]))
        config.provider = string(first(o, ["provider"])).flatMap(HostingProvider.init(rawValue:))
        if let timeout = int(first(o, ["timeout"])), timeout >= 1_000 { config.timeoutMs = timeout }
        config.preConnectScript = string(first(o, ["preConnectScript"]))
        config.postDisconnectScript = string(first(o, ["postDisconnectScript"]))
        config.forceStandalone = bool(first(o, ["forceStandalone"])) ?? false
        if let env = string(first(o, ["environment"])).flatMap(DatabaseEnvironment.init(rawValue:)) { config.environment = env }
        if let family = string(first(o, ["connectionFamily"])).flatMap(ConnectionFamily.init(rawValue:)) {
            config.connectionFamily = family
        }

        if let format = string(first(o, ["keyNameFormat"])).flatMap(KeyNameFormat.init(rawValue:)) { config.keyNameFormat = format }
        if let tags = first(o, ["tags"]) as? [[String: Any]] {
            config.tags = tags.compactMap { tag in
                guard let key = string(tag["key"]) else { return nil }
                return DatabaseTag(key: key, value: string(tag["value"]) ?? "")
            }
        }

        if let modules = first(o, ["modules"]) as? [[String: Any]] {
            config.modules = modules.compactMap { m in
                guard let name = string(m["name"]) else { return nil }
                return RedisModuleInfo(name: name, version: int(m["version"]), semanticVersion: string(m["semanticVersion"]))
            }
        }

        if let rawCompressor = first(o, ["compressor"]), !(rawCompressor is NSNull) {
            if let compressor = string(rawCompressor).flatMap(Compressor.init(rawValue:)) {
                config.compressor = compressor
            } else {
                config.compressor = .none
                errors.append("Invalid compressor")
            }
        }

        if let nodes = first(o, ["nodes"]) as? [[String: Any]] {
            config.nodes = nodes.compactMap { node in
                guard let h = string(node["host"]), let p = int(node["port"]) else { return nil }
                return RedisEndpoint(host: h, port: p)
            }
        }

        let sentinelName = string(first(o, ["sentinelMaster.name", "sentinelOptions.masterName", "sentinelOptions.name"]))
        if let explicit = string(first(o, ["connectionType"])) {
            config.connectionType = ConnectionType(rawValue: explicit.uppercased()) ?? .notConnected
        } else if let type = string(first(o, ["type"]))?.lowercased() {
            switch type {
            case "cluster": config.connectionType = .cluster
            case "sentinel": config.connectionType = .sentinel
            case "standalone": config.connectionType = .standalone
            default: config.connectionType = .notConnected
            }
        } else if bool(first(o, ["cluster"])) == true {
            config.connectionType = .cluster
        } else if sentinelName != nil {
            config.connectionType = .sentinel
        } else {
            config.connectionType = .notConnected
        }

        if let sentinelName {
            config.sentinelMaster = SentinelMasterConfig(
                name: sentinelName, username: string(first(o, ["sentinelMaster.username"])),
                password: string(first(o, ["sentinelMaster.password", "sentinelOptions.nodePassword",
                                           "sentinelOptions.sentinelPassword"])))
        }

        let sshHost = string(first(o, ["sshOptions.host", "ssh_host", "sshHost"]))
        let agent = string(first(o, ["ssh_agent_path"]))
        if sshHost != nil || agent != nil {
            if agent != nil {
                errors.append("SSH Agents are not supported")
            } else if let sshHost, let sshPort = int(first(o, ["sshOptions.port", "ssh_port", "sshPort"])),
                      let sshUser = string(first(o, ["sshOptions.username", "ssh_user", "sshUser"])) {
                let password = string(first(o, ["sshOptions.password", "ssh_password", "sshPassword"]))
                let keySource = string(first(o, ["sshOptions.privateKey", "sshOptions.privatekey", "ssh_private_key_path",
                                                 "sshKeyFile"]))
                if let keySource {
                    if let pem = pemOrFile(keySource, isValid: isPrivateKey) {
                        let passphrase = string(first(o, ["sshOptions.passphrase", "sshKeyPassphrase"])) ?? password
                        config.ssh = SSHOptions(host: sshHost, port: sshPort, username: sshUser,
                                                auth: .privateKey(pem: pem.text, passphrase: passphrase))
                    } else {
                        errors.append("Invalid SSH private key body")
                    }
                } else {
                    config.ssh = SSHOptions(host: sshHost, port: sshPort, username: sshUser, auth: .password(password))
                }
            } else {
                errors.append("Invalid SSH body")
            }
        }

        var mapped = Mapped(config: config)
        var tls = bool(first(o, ["tls", "ssl"])) ?? false
        if let caSource = string(first(o, ["caCert.certificate", "caCert", "sslOptions.ca", "ssl_ca_cert_path"])) {
            if let pem = pemOrFile(caSource, isValid: { $0.hasPrefix("-----BEGIN CERTIFICATE-----") }) {
                let name = string(first(o, ["caCert.name"])) ?? pem.fileName ?? "\(host):\(port) CA"
                mapped.caCertificate = ImportedCertificate(name: name, certificate: pem.text)
                tls = true
            } else {
                errors.append("Invalid CA body")
            }
        }

        if let certSource = string(first(o, ["clientCert.certificate", "certificate", "sslOptions.cert", "ssl_local_cert_path"])) {
            let keySource = string(first(o, ["clientCert.key", "keyFile", "sslOptions.key", "ssl_private_key_path"]))
            if let pem = pemOrFile(certSource, isValid: { $0.hasPrefix("-----BEGIN CERTIFICATE-----") }) {
                if let keySource, let key = pemOrFile(keySource, isValid: isPrivateKey) {
                    let name = string(first(o, ["clientCert.name"])) ?? pem.fileName ?? "\(host):\(port) client"
                    mapped.clientCertificate = ImportedCertificate(name: name, certificate: pem.text, key: key.text)
                    tls = true
                } else {
                    errors.append("Invalid private key")
                }
            } else {
                errors.append("Invalid certificate body")
            }
        }

        mapped.config.tls.enabled = tls
        if tls {
            let verify = first(o, ["verifyServerCert", "sslOptions.rejectUnauthorized"])
            if verify == nil {
                mapped.config.tls.verifyServerCert = true
            } else if verify is NSNull {
                mapped.config.tls.verifyServerCert = false
            } else {
                mapped.config.tls.verifyServerCert = bool(verify) ?? false
            }

            mapped.config.tls.servername = string(first(o, ["tlsServername"]))
        }

        mapped.errors = errors
        return mapped
    }

    static func isPrivateKey(_ text: String) -> Bool {
        text.hasPrefix("-----BEGIN") && text.contains("PRIVATE KEY-----")
    }

    /// The PEM text itself, or the contents of a readable file at that path.
    static func pemOrFile(_ source: String, isValid: (String) -> Bool) -> (text: String, fileName: String?)? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValid(trimmed) { return (trimmed, nil) }
        let path = (trimmed as NSString).expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(text) else { return nil }
        return (text, ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    static func validate(_ config: DatabaseConfig) throws {
        if config.host.trimmingCharacters(in: .whitespaces).isEmpty {
            throw DatabaseStoreError.importFailed("host should not be empty")
        }

        if !(0...65_535).contains(config.port) { throw DatabaseStoreError.importFailed("port must not be greater than 65535") }
        if let db = config.db, db < 0 { throw DatabaseStoreError.importFailed("db must not be less than 0") }
        if config.name.count > 500 { throw DatabaseStoreError.importFailed("name must be shorter than or equal to 500 characters") }
    }
}
