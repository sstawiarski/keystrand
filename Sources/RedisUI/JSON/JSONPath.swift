import Foundation

public enum JSONPathComponent: Hashable, Sendable {
    case key(String)
    case index(Int)

    /// Row label: the key itself or the array index.
    public var label: String {
        switch self {
        case .key(let key): return key
        case .index(let index): return String(index)
        }
    }
}

public enum JSONPathParseError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let path): return "Invalid JSON path: \(path)"
        }
    }
}

/// Location of a node inside a JSON document, rendered as a display path or as a RedisJSON command path.
public struct JSONPath: Hashable, Sendable, CustomStringConvertible {
    public var components: [JSONPathComponent]

    public static let root = JSONPath([])

    public init(_ components: [JSONPathComponent] = []) {
        self.components = components
    }

    public var isRoot: Bool { components.isEmpty }
    public var depth: Int { components.count }
    public var last: JSONPathComponent? { components.last }

    public var parent: JSONPath? {
        guard !components.isEmpty else { return nil }
        return JSONPath(Array(components.dropLast()))
    }

    public func appending(_ component: JSONPathComponent) -> JSONPath {
        JSONPath(components + [component])
    }

    public func appending(key: String) -> JSONPath { appending(.key(key)) }
    public func appending(index: Int) -> JSONPath { appending(.index(index)) }

    /// True when `self` equals `other` or lies inside it.
    public func isDescendant(ofOrEqualTo other: JSONPath) -> Bool {
        components.count >= other.components.count && Array(components.prefix(other.components.count)) == other.components
    }

    /// Display path: `$.a.b[0]`; keys that are not identifiers use brackets (`$["first name"]`).
    public var dotted: String {
        var result = "$"
        for component in components {
            switch component {
            case .key(let key):
                result += Self.isIdentifier(key) ? "." + key : "[" + Self.quote(key) + "]"
            case .index(let index):
                result += "[\(index)]"
            }
        }

        return result
    }

    /// RedisJSON v2 JSONPath with every component bracketed: `$["a"]["b"][0]` (`['k"x']` when the key contains `"`).
    public var bracketed: String {
        var result = "$"
        for component in components {
            switch component {
            case .key(let key): result += "[" + Self.quote(key) + "]"
            case .index(let index): result += "[\(index)]"
            }
        }

        return result
    }

    /// RedisJSON v1 legacy path: `.` for the root, otherwise the bracketed path without the leading `$`.
    public var legacy: String {
        isRoot ? "." : String(bracketed.dropFirst())
    }

    /// Path for JSON module commands: JSONPath (`$…`) when the module speaks it, else RedisJSON v1 legacy syntax.
    public func redisPath(jsonPath: Bool) -> String {
        jsonPath ? bracketed : legacy
    }

    public var description: String { dotted }

    static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let letters = CharacterSet.letters.union(CharacterSet(charactersIn: "_"))
        guard letters.contains(first), first.isASCII else { return false }
        return key.unicodeScalars.allSatisfy { $0.isASCII && (letters.contains($0) || CharacterSet.decimalDigits.contains($0)) }
    }

    static func quote(_ key: String) -> String {
        if key.contains("\""), !key.contains("'") {
            return "'" + key.replacingOccurrences(of: "\\", with: "\\\\") + "'"
        }

        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// Parses `$`, `.`, `$.a.b[0]`, `$["a"]['b'][0]`, `.a[1]`, `["a"]` and `a.b` (legacy, no leading `$`).
    public init(parsing text: String) throws {
        let chars = Array(text.trimmingCharacters(in: .whitespaces))
        var components: [JSONPathComponent] = []
        var i = 0
        if i < chars.count, chars[i] == "$" { i += 1 }
        var expectSegment = i == 0
        while i < chars.count {
            let c = chars[i]
            if c == "." {
                if i + 1 < chars.count, chars[i + 1] == "." { throw JSONPathParseError.invalid(text) }
                i += 1
                expectSegment = true
                if i == chars.count, components.isEmpty { break }
                continue
            }

            if c == "[" {
                i += 1
                guard i < chars.count else { throw JSONPathParseError.invalid(text) }
                if chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    var key = ""
                    var closed = false
                    while i < chars.count {
                        if chars[i] == "\\", i + 1 < chars.count {
                            key.append(chars[i + 1])
                            i += 2
                            continue
                        }

                        if chars[i] == quote {
                            closed = true
                            i += 1
                            break
                        }

                        key.append(chars[i])
                        i += 1
                    }

                    guard closed, i < chars.count, chars[i] == "]" else { throw JSONPathParseError.invalid(text) }
                    components.append(.key(key))
                } else {
                    var digits = ""
                    while i < chars.count, chars[i] != "]" {
                        digits.append(chars[i])
                        i += 1
                    }

                    guard i < chars.count, let index = Int(digits.trimmingCharacters(in: .whitespaces)) else {
                        throw JSONPathParseError.invalid(text)
                    }
                    components.append(.index(index))
                }

                i += 1
                expectSegment = false
                continue
            }

            guard expectSegment else { throw JSONPathParseError.invalid(text) }
            var key = ""
            while i < chars.count, chars[i] != ".", chars[i] != "[" {
                key.append(chars[i])
                i += 1
            }

            guard !key.isEmpty else { throw JSONPathParseError.invalid(text) }
            components.append(.key(key))
            expectSegment = false
        }

        self.components = components
    }
}
