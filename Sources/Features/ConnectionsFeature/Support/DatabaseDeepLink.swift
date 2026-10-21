import Foundation
import RedisCore

/// A `keystrand://databases/connect` link with a Redis URL, alias, redirect, and TLS requirements.
public struct DatabaseDeepLink: Hashable, Sendable {
    public static let scheme = "keystrand"

    public var redisURL: ParsedRedisURL
    public var alias: String?
    /// Page to show after connecting (`workbench`, `browser`, …); recorded, the database window opens on Browser.
    public var redirect: String?
    public var requiredTLS: Bool
    public var requiredCACert: Bool
    public var requiredClientCert: Bool

    public init(redisURL: ParsedRedisURL, alias: String? = nil, redirect: String? = nil, requiredTLS: Bool = false,
                requiredCACert: Bool = false, requiredClientCert: Bool = false) {
        self.redisURL = redisURL
        self.alias = alias
        self.redirect = redirect
        self.requiredTLS = requiredTLS
        self.requiredCACert = requiredCACert
        self.requiredClientCert = requiredClientCert
    }

    /// Parses a `keystrand://databases/connect` URL; nil for other actions or an unparsable `redisUrl`.
    public static func parse(_ url: URL) -> DatabaseDeepLink? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = ((components.host ?? "") + components.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard action.lowercased() == "databases/connect" else { return nil }
        let items = components.queryItems ?? []

        func value(_ name: String) -> String? {
            guard let text = items.first(where: { $0.name == name })?.value, !text.isEmpty else { return nil }
            return text
        }

        guard let redisURL = value("redisUrl").flatMap(ConnectionURLParser.parse) else { return nil }
        return DatabaseDeepLink(redisURL: redisURL, alias: value("databaseAlias"), redirect: value("redirect"),
                                requiredTLS: value("requiredTls") == "true",
                                requiredCACert: value("requiredCaCert") == "true",
                                requiredClientCert: value("requiredClientCert") == "true")
    }

    /// TLS certificate fields must be filled in the form before connecting.
    public var requiresCertificateFields: Bool { requiredTLS || requiredCACert || requiredClientCert }

    /// Host, username and password are present and no certificate is required: connect once the user confirms.
    public var canAutoConnect: Bool {
        !requiresCertificateFields && !redisURL.host.isEmpty && !redisURL.username.isEmpty
            && !redisURL.password.isEmpty
    }

    public var databaseName: String { alias ?? redisURL.hostname }

    /// The database created when connecting a link that matches no saved database.
    public func draft() -> DatabaseConfig {
        var config = ConnectionURLParser.draft(from: redisURL)
        config.name = databaseName
        return config
    }

    /// An existing database with the same endpoint, user and logical database.
    public func matchingDatabase(in databases: [DatabaseConfig]) -> DatabaseConfig? {
        let draft = draft()
        return databases.first { config in
            config.host.caseInsensitiveCompare(draft.host) == .orderedSame && config.port == draft.port
                && (config.username ?? "default") == (draft.username ?? "default") && config.dbIndex == draft.dbIndex
        }
    }
}

/// What Home asks before a deep link adds a database or connects to a saved one.
public struct DeepLinkConfirmation: Hashable, Sendable {
    public let link: DatabaseDeepLink
    /// The saved database's name when the link matches one, else the link's alias or host.
    public let databaseName: String
    /// `host:port`, with the logical database when it is not 0.
    public let endpoint: String
    /// The saved database the link matches, which opens instead of a new one being added.
    public let matchID: DatabaseID?
    /// The database runs a pre-connect or post-disconnect shell script.
    public let runsScript: Bool
    public let usesTLS: Bool
    public let redirect: String?

    public init(link: DatabaseDeepLink, match: DatabaseConfig?) {
        let config = match ?? link.draft()
        self.link = link
        databaseName = config.name
        endpoint = config.dbIndex == 0 ? config.hostPort : "\(config.hostPort) (database \(config.dbIndex))"
        matchID = match?.id
        runsScript = ConnectionScriptRunner.runnable(config.preConnectScript) != nil
            || ConnectionScriptRunner.runnable(config.postDisconnectScript) != nil
        usesTLS = config.tls.enabled
        redirect = link.redirect
    }

    public var isSaved: Bool { matchID != nil }

    public var title: String { "Connect to “\(databaseName)”?" }

    public var message: String {
        var sentences = [isSaved ? "This link opens the saved database at \(endpoint)."
            : "This link adds a database at \(endpoint) and connects to it."]
        if runsScript { sentences.append("The database runs a connection script on this Mac.") }
        sentences.append(usesTLS ? "The connection uses TLS." : "The connection does not use TLS.")
        if let redirect { sentences.append("Then it opens “\(redirect)”.") }
        sentences.append("Connect only if you trust where the link came from.")
        return sentences.joined(separator: " ")
    }
}

extension DatabaseFormModel {
    /// Prefills the Add Database form from a deep link that requires certificate fields.
    public func apply(_ link: DatabaseDeepLink) {
        apply(link.redisURL)
        name = link.databaseName
        if link.requiresCertificateFields { tls.enabled = true }
        if link.requiredCACert { tls.caChoice = .addNew }
        if link.requiredClientCert {
            tls.requiresClientAuth = true
            tls.clientChoice = .addNew
        }
    }
}
