import Foundation
import Observation
import RedisCore

/// Navigation and start-screen logic of the Add Database sheet.
@MainActor
@Observable
public final class AddDatabaseFlowModel {
    public enum Screen: Equatable, Sendable {
        case start
        case form
        case sentinel
        case importFile
        case software
    }

    public static let defaultURL = "redis://default@127.0.0.1:6379"
    public static let testSucceededMessage = "Connection is successful."

    public var screen: Screen = .start
    public var urlText = AddDatabaseFlowModel.defaultURL
    public private(set) var isTesting = false
    public private(set) var isAdding = false
    public var error: ConnectionError?
    public var testSucceeded = false

    public private(set) var form: DatabaseFormModel
    public private(set) var sentinel: SentinelFlowModel?
    public private(set) var importModel: ImportModel?
    public private(set) var software: SoftwareDiscoveryModel?

    @ObservationIgnored public let services: AppServices
    @ObservationIgnored private let factory: DatabaseFactory

    public init(services: AppServices, initialScreen: Screen = .start, importFile: URL? = nil,
                deepLink: DatabaseDeepLink? = nil) {
        self.services = services
        self.factory = DatabaseFactory(clientFactory: services.clientFactory)
        self.form = DatabaseFormModel(mode: .add, services: services)
        switch initialScreen {
        case .importFile: openImport(file: importFile)
        case .sentinel: openSentinel()
        case .software: openSoftware()
        case .form:
            openConnectionSettings()
            if let deepLink { form.apply(deepLink) }
        case .start: break
        }
    }

    // MARK: - Start screen

    public var parsedURL: ParsedRedisURL? { ConnectionURLParser.parse(urlText) }

    public var isURLEmpty: Bool { urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Disabled reason for Test / Add buttons, or nil.
    public var urlDisabledReason: String? {
        if isURLEmpty { return "Enter a connection URL" }
        return parsedURL == nil ? ConnectionURLParser.unsupportedMessage : nil
    }

    /// "Connection settings" is allowed with an empty URL (blank form) but not with an invalid one.
    public var settingsDisabledReason: String? {
        ConnectionURLParser.isAcceptable(urlText) ? nil : ConnectionURLParser.unsupportedMessage
    }

    public func testURL() async {
        guard urlDisabledReason == nil, !isTesting, !isAdding else { return }
        isTesting = true
        error = nil
        testSucceeded = false
        defer { isTesting = false }
        let draft = ConnectionURLParser.draft(from: parsedURL)
        do {
            try await factory.test(draft)
            testSucceeded = true
        } catch {
            self.error = ConnectionError.classify(error, endpoint: draft.endpoint)
        }
    }

    /// Creates the database straight from the URL. Returns the saved config, or nil (error / sentinel switch).
    public func addFromURL() async -> DatabaseConfig? {
        guard urlDisabledReason == nil, !isTesting, !isAdding else { return nil }
        isAdding = true
        error = nil
        defer { isAdding = false }
        let draft = ConnectionURLParser.draft(from: parsedURL)
        do {
            var detected = try await factory.createDetected(draft)
            detected.isNew = true
            try await services.saveDatabase(detected)
            return detected
        } catch DatabaseFactoryError.sentinelMasterRequired {
            await switchToSentinelDiscovery(draft: draft, tls: nil)
            return nil
        } catch {
            self.error = DatabaseFormModel.connectionError(error, endpoint: draft.endpoint)
            return nil
        }
    }

    public func openConnectionSettings() {
        let model = DatabaseFormModel(mode: .add, services: services)
        if let parsed = parsedURL { model.apply(parsed) }
        form = model
        error = nil
        screen = .form
    }

    public func openSentinel() {
        sentinel = SentinelFlowModel(services: services)
        screen = .sentinel
    }

    public func openImport(file: URL? = nil) {
        importModel = ImportModel(services: services, fileURL: file)
        screen = .importFile
    }

    public func openSoftware() {
        software = SoftwareDiscoveryModel(services: services)
        screen = .software
    }

    public func backToStart() {
        error = nil
        testSucceeded = false
        screen = .start
    }

    /// The server is a Sentinel: discover its primary groups with the same endpoint, credentials and TLS.
    public func switchToSentinelDiscovery(draft: DatabaseConfig, tls: TLSFormModel?) async {
        let model = SentinelFlowModel(services: services, certificates: tls == nil ? nil : form.certificates,
                                      tls: tls, prefill: draft)
        sentinel = model
        screen = .sentinel
        await model.certificates.load()
        await model.discover()
    }
}
