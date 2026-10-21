import Foundation

public enum DatabaseFactoryError: Error, LocalizedError, Sendable {
    /// The endpoint is a Sentinel and no master name was given: show Sentinel discovery.
    case sentinelMasterRequired
    case connection(ConnectionError)

    public var errorDescription: String? {
        switch self {
        case .sentinelMasterRequired: return ConnectionError.sentinelMasterRequired.message
        case .connection(let e): return e.message
        }
    }
}

/// Connection testing and type detection for the Add and Edit Database forms.
public struct DatabaseFactory: Sendable {
    public let clientFactory: RedisClientFactory

    public init(clientFactory: RedisClientFactory = RedisClientFactory()) {
        self.clientFactory = clientFactory
    }

    /// Connects with the draft (secrets included) and disconnects. Sentinel endpoints without master succeed.
    /// Returns once every connection is closed and the post-disconnect script has run.
    public func test(_ draft: DatabaseConfig, caCertificate: CACertificate? = nil,
                     clientCertificate: ClientCertificate? = nil) async throws {
        do {
            _ = try await createDetected(draft, caCertificate: caCertificate, clientCertificate: clientCertificate)
        } catch DatabaseFactoryError.sentinelMasterRequired {
            return
        }
    }

    /// Detects standalone / cluster / sentinel, fills `connectionType`, `nodes`, `modules`, `version`, `provider`.
    /// Throws `.sentinelMasterRequired` for a Sentinel without `sentinelMaster`. Runs the post-disconnect script
    /// once its connections are closed, also when detection fails.
    public func createDetected(_ draft: DatabaseConfig, caCertificate: CACertificate? = nil,
                               clientCertificate: ClientCertificate? = nil) async throws -> DatabaseConfig {
        try await withPostDisconnectScript(draft) {
            try await createDetectedForSession(draft, caCertificate: caCertificate, clientCertificate: clientCertificate)
        }
    }

    /// `createDetected` without the post-disconnect script, which the session runs when it disconnects.
    func createDetectedForSession(_ draft: DatabaseConfig, caCertificate: CACertificate?,
                                  clientCertificate: ClientCertificate?) async throws -> DatabaseConfig {
        let endpoint = draft.endpoint
        do {
            return try await detect(draft, caCertificate: caCertificate, clientCertificate: clientCertificate)
        } catch let error as DatabaseFactoryError {
            throw error
        } catch {
            throw DatabaseFactoryError.connection(ConnectionError.classify(error, endpoint: endpoint))
        }
    }

    /// Masters monitored by the sentinel at the draft's endpoint, sorted by name.
    public func sentinelMasters(_ draft: DatabaseConfig) async throws -> [SentinelMasterInfo] {
        try await withPostDisconnectScript(draft) { try await fetchSentinelMasters(draft) }
    }

    private func fetchSentinelMasters(_ draft: DatabaseConfig) async throws -> [SentinelMasterInfo] {
        let probe = try await probeConnection(draft, caCertificate: nil, clientCertificate: nil)
        do {
            let reply = try await probe.execute(["SENTINEL", "MASTERS"])
            await probe.close()
            return SentinelResolver.parseMasters(reply).sorted { $0.name < $1.name }
        } catch let error as RedisClientError {
            await probe.close()
            if let server = error.serverError, server.message.lowercased().contains("unknown command") {
                throw DatabaseFactoryError.connection(ConnectionError(
                    code: .failed, title: "Not a Sentinel",
                    message: "This endpoint didn't answer as a Redis Sentinel. Add it as a regular database with its host and port instead."))
            }

            throw DatabaseFactoryError.connection(ConnectionError.classify(error, endpoint: draft.endpoint))
        } catch {
            await probe.close()
            throw DatabaseFactoryError.connection(ConnectionError.classify(error, endpoint: draft.endpoint))
        }
    }

    /// Runs the post-disconnect script after `work` closes its connections, even if `work` fails.
    /// An error from `work` takes precedence over a script failure.
    private func withPostDisconnectScript<T: Sendable>(_ draft: DatabaseConfig,
                                                       _ work: () async throws -> T) async throws -> T {
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await work())
        } catch {
            outcome = .failure(error)
        }

        do {
            try await clientFactory.runPostDisconnectScript(draft.postDisconnectScript)
        } catch {
            if case .success = outcome {
                throw DatabaseFactoryError.connection(ConnectionError.classify(error, endpoint: draft.endpoint))
            }
        }

        return try outcome.get()
    }

    // MARK: - Detection

    private func detect(_ draft: DatabaseConfig, caCertificate: CACertificate?,
                        clientCertificate: ClientCertificate?) async throws -> DatabaseConfig {
        var result = draft
        let probe = try await probeConnection(draft, caCertificate: caCertificate, clientCertificate: clientCertificate)
        let finalClient: any RedisClient
        do {
            if let mastersReply = try? await probe.execute(["SENTINEL", "MASTERS"]), mastersReply.arrayValue != nil {
                guard let master = draft.sentinelMaster, !master.name.isEmpty else {
                    await probe.close()
                    throw DatabaseFactoryError.sentinelMasterRequired
                }
                let masters = SentinelResolver.parseMasters(mastersReply)
                guard masters.contains(where: { $0.name == master.name }) else {
                    await probe.close()
                    throw DatabaseFactoryError.connection(ConnectionError(
                        code: .failed, title: "Primary group not found",
                        message: "The Sentinel has no primary group with this name."))
                }
                let sentinels = (try? await probe.execute(["SENTINEL", "SENTINELS", .string(master.name)]))
                    .map(SentinelResolver.parseSentinels) ?? []
                result.connectionType = .sentinel
                result.nodes = sentinels.filter { $0 != draft.endpoint }
            } else if !draft.forceStandalone, let clusterInfo = try? await probe.execute(["CLUSTER", "INFO"]),
                      DatabaseInfoService.text(clusterInfo).contains("cluster_state:ok") {
                let slots = (try? await probe.execute(["CLUSTER", "SLOTS"])).map {
                    ClusterTopologyParser.parseSlots($0, seedHost: draft.host)
                } ?? []
                var seen = Set<RedisEndpoint>()
                result.nodes = slots.map(\.endpoint).filter { seen.insert($0).inserted }
                if result.nodes?.isEmpty ?? true { result.nodes = [draft.endpoint] }
                result.connectionType = .cluster
            } else {
                result.connectionType = .standalone
            }

            if result.provider == nil || result.provider == .unknown {
                let info = try? await DatabaseInfoService(client: probe).info()
                result.provider = DatabaseInfoService.detectProvider(host: draft.host, info: info)
            }

            await probe.close()
            finalClient = try await clientFactory.makeClient(
                result.clientDescriptor(caCertificate: caCertificate, clientCertificate: clientCertificate,
                                        clientName: "keystrand-detect"))
        } catch {
            await probe.close()
            throw error
        }

        let service = DatabaseInfoService(client: finalClient)
        let serverInfo = try? await service.info(section: "server")
        result.modules = (try? await service.modules(flavor: serverInfo?.serverFlavor ?? .redis)) ?? []
        if let serverInfo { result.version = serverInfo.serverVersion }
        result.lastConnection = Date()
        await finalClient.close()
        return result
    }

    /// Standalone connection to the configured endpoint (db 0, no ready check) used to inspect the server.
    private func probeConnection(_ draft: DatabaseConfig, caCertificate: CACertificate?,
                                 clientCertificate: ClientCertificate?) async throws -> RedisConnection {
        var probe = draft
        probe.connectionType = .standalone
        probe.forceStandalone = true
        probe.sentinelMaster = nil
        var descriptor = probe.clientDescriptor(caCertificate: caCertificate, clientCertificate: clientCertificate,
                                                clientName: "keystrand-detect", dbOverride: 0)
        descriptor.connection.readyCheck = false
        do {
            return try await clientFactory.makeDedicatedConnection(descriptor)
        } catch {
            throw DatabaseFactoryError.connection(ConnectionError.classify(error, endpoint: draft.endpoint))
        }
    }
}
