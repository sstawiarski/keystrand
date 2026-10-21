import Foundation
import Observation
import RedisCore

public enum CACertificateChoice: Hashable, Sendable {
    case none
    case addNew
    case existing(String)
}

public enum ClientCertificateChoice: Hashable, Sendable {
    case addNew
    case existing(String)
}

/// Saved CA and client certificates offered by the TLS pickers.
@MainActor
@Observable
public final class CertificateCatalog {
    public private(set) var caCertificates: [CACertificate] = []
    public private(set) var clientCertificates: [ClientCertificate] = []
    public var errorMessage: String?

    @ObservationIgnored private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public func load() async {
        do {
            caCertificates = try await services.certificateStore.listCA().sorted { $0.name < $1.name }
            clientCertificates = try await services.certificateStore.listClient().sorted { $0.name < $1.name }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes the certificate, detaches it from databases and drops their clients.
    public func delete(id: String, isCA: Bool) async -> Bool {
        do {
            try await services.deleteCertificate(id: id, isCA: isCA)
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func caName(_ id: String) -> String? { caCertificates.first { $0.id == id }?.name }
    public func clientName(_ id: String) -> String? { clientCertificates.first { $0.id == id }?.name }
}

/// TLS section state shared by the database form and the Sentinel form.
@MainActor
@Observable
public final class TLSFormModel {
    public var enabled = false

    public var useSNI = false {
        didSet { if useSNI && !oldValue && servername.isEmpty { servername = sniDefault() } }
    }

    public var servername = "" { didSet { let v = InputRules.compact(servername, 200); if v != servername { servername = v } } }
    public var verifyServerCert = false
    public var caChoice: CACertificateChoice = .none

    public var newCAName = "" {
        didSet { let v = Self.sanitizeCertificateName(newCAName); if v != newCAName { newCAName = v } }
    }

    public var newCACertificate = ""
    public var requiresClientAuth = false
    public var clientChoice: ClientCertificateChoice = .addNew

    public var newClientName = "" {
        didSet { let v = Self.sanitizeCertificateName(newClientName); if v != newClientName { newClientName = v } }
    }

    public var newClientCertificate = ""
    public var newClientKey = ""

    /// Host used to prefill the SNI server name.
    @ObservationIgnored public var sniDefault: @MainActor () -> String = { "" }

    public init() {}

    public init(settings: TLSSettings) {
        enabled = settings.enabled
        servername = settings.servername ?? ""
        useSNI = !(settings.servername ?? "").isEmpty
        verifyServerCert = settings.verifyServerCert
        caChoice = settings.caCertID.map { .existing($0) } ?? .none
        requiresClientAuth = settings.clientCertID != nil
        clientChoice = settings.clientCertID.map { .existing($0) } ?? .addNew
    }

    /// Replaces every field with the given settings (new-certificate inputs cleared).
    public func load(_ settings: TLSSettings) {
        enabled = settings.enabled
        servername = settings.servername ?? ""
        useSNI = !(settings.servername ?? "").isEmpty
        verifyServerCert = settings.verifyServerCert
        caChoice = settings.caCertID.map { .existing($0) } ?? .none
        requiresClientAuth = settings.clientCertID != nil
        clientChoice = settings.clientCertID.map { .existing($0) } ?? .addNew
        newCAName = ""
        newCACertificate = ""
        newClientName = ""
        newClientCertificate = ""
        newClientKey = ""
        pendingCA = nil
        pendingClient = nil
    }

    /// Strips characters outside `[ a-zA-Z0-9!@#$%^&*-_()[]]` and limits to 200 characters.
    nonisolated public static func sanitizeCertificateName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: " abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*-_()[]")
        let filtered = String(String.UnicodeScalarView(name.unicodeScalars.filter(allowed.contains)))
        return String(filtered.prefix(200))
    }

    /// Required fields by display name.
    public var missingFields: [String] {
        guard enabled else { return [] }
        var missing: [String] = []
        if useSNI && servername.isEmpty { missing.append("Server Name") }
        if caChoice == .addNew {
            if newCAName.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("CA Certificate Name") }
            if newCACertificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("CA certificate") }
        }

        if requiresClientAuth && clientChoice == .addNew {
            if newClientName.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("Client Certificate Name") }
            if newClientCertificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missing.append("Client Certificate")
            }

            if newClientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("Private Key") }
        }

        return missing
    }

    /// Settings with existing certificate ids; new certificates get their ids from `persistNewCertificates`.
    public var settings: TLSSettings {
        guard enabled else { return TLSSettings() }
        var caID: String?
        if case .existing(let id) = caChoice { caID = id }
        var clientID: String?
        if requiresClientAuth, case .existing(let id) = clientChoice { clientID = id }
        return TLSSettings(enabled: true, servername: useSNI && !servername.isEmpty ? servername : nil,
                           verifyServerCert: verifyServerCert, caCertID: caID, clientCertID: clientID)
    }

    /// Unsaved certificates entered in the form (ids are generated now and kept when persisted).
    public private(set) var pendingCA: CACertificate?
    public private(set) var pendingClient: ClientCertificate?

    public var hasNewCertificates: Bool {
        enabled && (caChoice == .addNew || (requiresClientAuth && clientChoice == .addNew))
    }

    /// Certificates to connect with: new ones built from the form, existing ones loaded with their keys.
    public func resolveCertificates(_ services: AppServices, catalog: CertificateCatalog) async throws
        -> (ca: CACertificate?, client: ClientCertificate?) {
        guard enabled else { return (nil, nil) }
        var ca: CACertificate?
        switch caChoice {
        case .none: break
        case .addNew:
            let name = newCAName.trimmingCharacters(in: .whitespaces)
            if catalog.caCertificates.contains(where: { $0.name == name }) {
                throw CertificateStoreError.duplicateCAName
            }

            let pending = pendingCA.map { CACertificate(id: $0.id, name: name, certificate: newCACertificate) }
                ?? CACertificate(name: name, certificate: newCACertificate)
            pendingCA = pending
            ca = pending
        case .existing(let id):
            ca = try await services.certificateStore.caCertificate(id)
        }

        var client: ClientCertificate?
        if requiresClientAuth {
            switch clientChoice {
            case .addNew:
                let name = newClientName.trimmingCharacters(in: .whitespaces)
                if catalog.clientCertificates.contains(where: { $0.name == name }) {
                    throw CertificateStoreError.duplicateClientName
                }

                let pending = pendingClient.map {
                    ClientCertificate(id: $0.id, name: name, certificate: newClientCertificate, key: newClientKey)
                } ?? ClientCertificate(name: name, certificate: newClientCertificate, key: newClientKey)
                pendingClient = pending
                client = pending
            case .existing(let id):
                client = try await services.certificateStore.clientCertificate(id)
            }
        }

        return (ca, client)
    }

    /// Saves new certificates and returns TLS settings referencing them. Selects them in the form afterwards.
    public func persistNewCertificates(_ services: AppServices, ca: CACertificate?, client: ClientCertificate?) async throws
        -> TLSSettings {
        var result = settings
        guard enabled else { return result }
        if caChoice == .addNew, let ca {
            let saved = try await services.certificateStore.addCA(ca)
            result.caCertID = saved.id
            caChoice = .existing(saved.id)
            pendingCA = nil
        }

        if requiresClientAuth, clientChoice == .addNew, let client {
            let saved = try await services.certificateStore.addClient(client)
            result.clientCertID = saved.id
            clientChoice = .existing(saved.id)
            pendingClient = nil
        }

        return result
    }

    /// Resets the selection after a saved certificate was deleted.
    public func certificateDeleted(id: String, isCA: Bool) {
        if isCA, caChoice == .existing(id) { caChoice = .none }
        if !isCA, clientChoice == .existing(id) { clientChoice = .addNew }
    }
}
