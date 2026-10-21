import Foundation

public enum CertificateStoreError: Error, LocalizedError, Sendable, Equatable {
    case duplicateCAName
    case duplicateClientName
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateCAName: return "A CA certificate with this name already exists."
        case .duplicateClientName: return "A client certificate with this name already exists."
        case .notFound: return "The certificate was not found."
        }
    }
}

/// CA and client certificates in `certificates.json`; client private keys in the `SecretStore`.
public actor CertificateStore {
    private struct FileModel: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion = Self.currentSchemaVersion
        var ca: [CACertificate] = []
        var client: [ClientCertificate] = []
        /// Certificates that failed to decode and were left out.
        var droppedCount = 0

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, ca, client
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = c.value(.schemaVersion, default: Self.currentSchemaVersion)
            let caResult: (values: [CACertificate], dropped: Int) = c.lossyArrayCountingDropped(.ca)
            let clientResult: (values: [ClientCertificate], dropped: Int) = c.lossyArrayCountingDropped(.client)
            ca = caResult.values
            client = clientResult.values
            droppedCount = caResult.dropped + clientResult.dropped
        }
    }

    private let paths: AppPaths
    private let secrets: any SecretStore
    private var cache: FileModel?

    public init(paths: AppPaths, secrets: any SecretStore) {
        self.paths = paths
        self.secrets = secrets
    }

    public func listCA() throws -> [CACertificate] { try load().ca }

    /// Client certificates without private keys.
    public func listClient() throws -> [ClientCertificate] { try load().client }

    public func caCertificate(_ id: String) throws -> CACertificate? { try load().ca.first { $0.id == id } }

    /// Client certificate with its private key loaded.
    public func clientCertificate(_ id: String) throws -> ClientCertificate? {
        guard var cert = try load().client.first(where: { $0.id == id }) else { return nil }
        cert.key = try secrets.secret(for: SecretAccount.clientCertificateKey(id))
        return cert
    }

    @discardableResult
    public func addCA(_ cert: CACertificate) throws -> CACertificate {
        var model = try load()
        guard !model.ca.contains(where: { $0.name == cert.name }) else { throw CertificateStoreError.duplicateCAName }
        model.ca.append(cert)
        try save(model)
        return cert
    }

    @discardableResult
    public func addClient(_ cert: ClientCertificate) throws -> ClientCertificate {
        var model = try load()
        guard !model.client.contains(where: { $0.name == cert.name }) else { throw CertificateStoreError.duplicateClientName }
        try secrets.setSecret(cert.key, for: SecretAccount.clientCertificateKey(cert.id))
        var stored = cert
        stored.key = nil
        model.client.append(stored)
        try save(model)
        return stored
    }

    public func deleteCA(_ id: String) throws {
        var model = try load()
        model.ca.removeAll { $0.id == id }
        try save(model)
    }

    /// Deletes the certificate and its private key.
    public func deleteClient(_ id: String) throws {
        var model = try load()
        model.client.removeAll { $0.id == id }
        try secrets.setSecret(nil, for: SecretAccount.clientCertificateKey(id))
        try save(model)
    }

    private func load() throws -> FileModel {
        if let cache { return cache }
        let url = paths.certificatesFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache = FileModel()
            return FileModel()
        }
        var model = FileModel()
        if let data = try? Data(contentsOf: url), let decoded = try? JSONFile.makeDecoder().decode(FileModel.self, from: data) {
            model = decoded
            if decoded.schemaVersion > FileModel.currentSchemaVersion {
                DataFileBackup.preserve(url, label: "v\(decoded.schemaVersion)")
            } else if decoded.droppedCount > 0 {
                DataFileBackup.preserve(url, label: "damaged")
            }
        } else {
            DataFileBackup.preserve(url, label: "damaged")
        }

        model.schemaVersion = FileModel.currentSchemaVersion
        model.droppedCount = 0
        cache = model
        return model
    }

    private func save(_ model: FileModel) throws {
        try JSONFile.save(model, to: paths.certificatesFile)
        cache = model
    }
}
