import Foundation
import RedisCore

/// Result of parsing a `redis://`, `rediss://` or `host:port` connection string.
public struct ParsedRedisURL: Hashable, Sendable {
    public var scheme: String
    public var username: String
    public var password: String
    public var host: String
    public var port: Int?
    public var db: Int?

    public init(scheme: String = "redis", username: String = "", password: String = "", host: String,
                port: Int? = nil, db: Int? = nil) {
        self.scheme = scheme
        self.username = username
        self.password = password
        self.host = host
        self.port = port
        self.db = db
    }

    public var tls: Bool { scheme == "rediss" }

    /// `host:port` when a port was given, else the host (IPv6 literals bracketed).
    public var hostname: String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        guard let port else { return shownHost }
        return "\(shownHost):\(port)"
    }
}

/// Parses Redis connection URLs, including bracketed IPv6 literals.
public enum ConnectionURLParser {
    public static let supportedFormats = [
        "redis://[[username]:[password]]@host:port",
        "rediss://[[username]:[password]]@host:port",
        "host:port",
    ]

    public static let unsupportedMessage =
        "The connection URL format is not supported. Use Connection Settings instead."

    private static let pure = regex(#"^([^:]+):(\d+)$"#)
    private static let pureIPv6 = regex(#"^\[([0-9a-fA-F:.%]+)\]:(\d+)$"#)
    private static let url = regex(#"^(rediss?):\/\/(?:(.+)?@)?(?:.*@)?([^:\/@\[\]]+|\[[0-9a-fA-F:.%]+\])(?::(\d+))?(?:\/(\d+))?$"#)
    private static let userInfo = regex(#"^(.*?)(?::(.*))?$"#)

    public static func parse(_ text: String) -> ParsedRedisURL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let groups = match(pure, trimmed) ?? match(pureIPv6, trimmed),
           let host = groups[1], let portText = groups[2], let port = Int(portText) {
            return ParsedRedisURL(host: host, port: port)
        }

        guard let groups = match(url, trimmed), let scheme = groups[1], var host = groups[3] else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var username = ""
        var password = ""
        if let info = groups[2], let parts = match(userInfo, info) {
            username = parts[1] ?? ""
            password = parts[2] ?? ""
        }

        let port = groups[4].flatMap { Int($0) }
        let db = groups[5].flatMap { Int($0) }
        return ParsedRedisURL(scheme: scheme, username: username, password: password, host: host, port: port, db: db)
    }

    /// True when `text` is empty or parses.
    public static func isAcceptable(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parse(text) != nil
    }

    /// Creates the draft for Add Database on the start screen.
    public static func draft(from parsed: ParsedRedisURL?) -> DatabaseConfig {
        let host = parsed?.host ?? "127.0.0.1"
        let port = parsed?.port ?? 6379
        let username = parsed.map { $0.username.isEmpty ? "default" : $0.username } ?? "default"
        let password = parsed.flatMap { $0.password.isEmpty ? nil : $0.password }
        return DatabaseConfig(
            name: parsed?.hostname ?? "127.0.0.1:6379", host: host, port: port, db: parsed?.db,
            username: username, password: password, timeoutMs: 30_000, connectionType: .standalone,
            tls: TLSSettings(enabled: parsed?.tls ?? false))
    }

    // MARK: - Regex helpers

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }

    private static func match(_ regex: NSRegularExpression?, _ text: String) -> [String?]? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            let nsRange = result.range(at: index)
            guard nsRange.location != NSNotFound, let swiftRange = Range(nsRange, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}
