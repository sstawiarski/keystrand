import Foundation

public enum CommandArgumentType: Hashable, Sendable {
    case key
    case string
    case integer
    case double
    case pattern
    case unixTime
    case posixTime
    case pureToken
    case oneof
    case block
    case enumeration
    case command
    case function
    /// Missing or unrecognized `type` (raw text kept; empty when absent).
    case unknown(String)

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "key": self = .key
        case "string": self = .string
        case "integer": self = .integer
        case "double": self = .double
        case "pattern": self = .pattern
        case "unix-time": self = .unixTime
        case "posix time": self = .posixTime
        case "pure-token": self = .pureToken
        case "oneof": self = .oneof
        case "block": self = .block
        case "enum": self = .enumeration
        case "command": self = .command
        case "function": self = .function
        default: self = .unknown(raw ?? "")
        }
    }
}

public struct CommandArgument: Hashable, Sendable, Decodable {
    public var name: String
    public var type: CommandArgumentType
    public var token: String?
    public var displayText: String?
    public var optional: Bool
    public var multiple: Bool
    public var multipleToken: Bool
    /// Children of `block` / `oneof` (JSON `arguments`, or legacy `block`).
    public var arguments: [CommandArgument]
    public var enumValues: [String]?
    public var summary: String?
    public var since: String?
    public var deprecatedSince: String?
    public var keySpecIndex: Int?
    public var expression: Bool
    public var dsl: String?

    public init(name: String, type: CommandArgumentType, token: String? = nil, displayText: String? = nil,
                optional: Bool = false, multiple: Bool = false, multipleToken: Bool = false,
                arguments: [CommandArgument] = [], enumValues: [String]? = nil, summary: String? = nil,
                since: String? = nil, deprecatedSince: String? = nil, keySpecIndex: Int? = nil,
                expression: Bool = false, dsl: String? = nil) {
        self.name = name
        self.type = type
        self.token = token
        self.displayText = displayText
        self.optional = optional
        self.multiple = multiple
        self.multipleToken = multipleToken
        self.arguments = arguments
        self.enumValues = enumValues
        self.summary = summary
        self.since = since
        self.deprecatedSince = deprecatedSince
        self.keySpecIndex = keySpecIndex
        self.expression = expression
        self.dsl = dsl
    }

    enum CodingKeys: String, CodingKey {
        case name, type, token, optional, multiple, arguments, block, summary, since, expression, dsl
        case displayText = "display_text"
        case multipleToken = "multiple_token"
        case enumValues = "enum"
        case deprecatedSince = "deprecated_since"
        case keySpecIndex = "key_spec_index"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        type = CommandArgumentType(raw: try? c.decodeIfPresent(String.self, forKey: .type))
        token = try? c.decodeIfPresent(String.self, forKey: .token)
        displayText = try? c.decodeIfPresent(String.self, forKey: .displayText)
        optional = (try? c.decodeIfPresent(Bool.self, forKey: .optional)) ?? false
        multiple = (try? c.decodeIfPresent(Bool.self, forKey: .multiple)) ?? false
        multipleToken = (try? c.decodeIfPresent(Bool.self, forKey: .multipleToken)) ?? false
        arguments = (try? c.decodeIfPresent([CommandArgument].self, forKey: .arguments))
            ?? (try? c.decodeIfPresent([CommandArgument].self, forKey: .block)) ?? []
        enumValues = try? c.decodeIfPresent([String].self, forKey: .enumValues)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        since = try? c.decodeIfPresent(String.self, forKey: .since)
        deprecatedSince = try? c.decodeIfPresent(String.self, forKey: .deprecatedSince)
        keySpecIndex = try? c.decodeIfPresent(Int.self, forKey: .keySpecIndex)
        expression = (try? c.decodeIfPresent(Bool.self, forKey: .expression)) ?? false
        dsl = try? c.decodeIfPresent(String.self, forKey: .dsl)
    }
}

public struct CommandHistoryEntry: Hashable, Sendable {
    public var version: String
    public var description: String

    public init(version: String, description: String) {
        self.version = version
        self.description = description
    }
}

public struct CommandSpec: Hashable, Sendable, Identifiable, Decodable {
    /// Uppercased full name, e.g. `GET`, `CLIENT LIST`, `FT.SEARCH`.
    public var name: String
    public var summary: String
    public var since: String?
    public var group: String
    /// Joined with ", " when the JSON has an array.
    public var complexity: String?
    public var arguments: [CommandArgument]
    /// `main` for redis.json, otherwise the file name without extension (`redisearch`, `redisjson`, ...).
    public var provider: String
    public var history: [CommandHistoryEntry]
    public var aclCategories: [String]
    public var arity: Int?
    public var commandFlags: [String]
    public var deprecatedSince: String?
    public var replacedBy: String?

    public var id: String { name }

    public init(name: String, summary: String = "", since: String? = nil, group: String = "generic",
                complexity: String? = nil, arguments: [CommandArgument] = [], provider: String = "main",
                history: [CommandHistoryEntry] = [], aclCategories: [String] = [], arity: Int? = nil,
                commandFlags: [String] = [], deprecatedSince: String? = nil, replacedBy: String? = nil) {
        self.name = name.uppercased()
        self.summary = summary
        self.since = since
        self.group = group
        self.complexity = complexity
        self.arguments = arguments
        self.provider = provider
        self.history = history
        self.aclCategories = aclCategories
        self.arity = arity
        self.commandFlags = commandFlags
        self.deprecatedSince = deprecatedSince
        self.replacedBy = replacedBy
    }

    enum CodingKeys: String, CodingKey {
        case summary, since, group, complexity, arguments, history, arity, provider
        case aclCategories = "acl_categories"
        case commandFlags = "command_flags"
        case deprecatedSince = "deprecated_since"
        case replacedBy = "replaced_by"
    }

    /// Decodes the value of one entry; `name` and `provider` are filled in by the loader.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = ""
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        since = try? c.decodeIfPresent(String.self, forKey: .since)
        group = (try? c.decodeIfPresent(String.self, forKey: .group)) ?? "generic"
        if let s = try? c.decodeIfPresent(String.self, forKey: .complexity) {
            complexity = s
        } else if let list = try? c.decodeIfPresent([String].self, forKey: .complexity) {
            complexity = list.joined(separator: ", ")
        } else {
            complexity = nil
        }

        arguments = (try? c.decodeIfPresent([CommandArgument].self, forKey: .arguments)) ?? []
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? "main"
        let rawHistory = (try? c.decodeIfPresent([[String]].self, forKey: .history)) ?? []
        history = rawHistory.compactMap { $0.count >= 2 ? CommandHistoryEntry(version: $0[0], description: $0[1]) : nil }
        aclCategories = (try? c.decodeIfPresent([String].self, forKey: .aclCategories)) ?? []
        arity = try? c.decodeIfPresent(Int.self, forKey: .arity)
        commandFlags = (try? c.decodeIfPresent([String].self, forKey: .commandFlags)) ?? []
        deprecatedSince = try? c.decodeIfPresent(String.self, forKey: .deprecatedSince)
        replacedBy = try? c.decodeIfPresent(String.self, forKey: .replacedBy)
    }

    /// First word of a container command (`CLIENT` for `CLIENT LIST`), or nil for a single-word name.
    public var containerName: String? {
        let parts = name.split(separator: " ")
        return parts.count > 1 ? String(parts[0]) : nil
    }

    public var isDangerous: Bool { aclCategories.contains { $0.lowercased() == "@dangerous" } }
}
