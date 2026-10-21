import Foundation
import RESP

public enum RunQueryMode: String, Codable, Sendable, Hashable, CaseIterable {
    case ascii = "ASCII"
    case raw = "RAW"
}

/// A formatted command reply as stored in history and displayed by CLI / Workbench.
public indirect enum ReplyNode: Codable, Hashable, Sendable {
    case null
    /// Decimal text (preserves the full i64/u64 range).
    case integer(String)
    /// Already escaped (ASCII mode) or UTF-8 decoded (raw mode / human-readable commands).
    case string(String)
    case array([ReplyNode])
    case error(String)
}

/// Builds replies with ASCII-safe escaping or UTF-8 by mode. Human-readable commands such as INFO always use UTF-8.
public enum ReplyNodeBuilder {
    /// Commands whose replies use UTF-8 text.
    public static let humanReadableCommands = [
        "info", "lolwut", "debug hstats", "debug hstats-key", "memory doctor", "memory malloc-stats",
        "cluster nodes", "cluster info", "client list", "latency graph", "latency doctor", "proxy info",
    ]

    public static func build(_ value: RESPValue, mode: RunQueryMode, command: String) throws -> ReplyNode {
        let utf8 = mode == .raw || isHumanReadable(command)
        return node(value, utf8: utf8)
    }

    /// `command` is the command line (or `"{name} {arg0}"`); matching is case-insensitive.
    public static func isHumanReadable(_ command: String) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .lowercased()
        return humanReadableCommands.contains { normalized.hasPrefix($0) }
    }

    private static func node(_ value: RESPValue, utf8: Bool) -> ReplyNode {
        func text(_ data: Data) -> ReplyNode {
            utf8 ? .string(String(decoding: data, as: UTF8.self)) : .string(ASCIISafeEscaping.escapeBytes([UInt8](data)))
        }

        switch value {
        case .null, .bulkString(nil), .array(nil):
            return .null
        case .simpleString(let s):
            return text(Data(s.utf8))
        case .bulkString(let d?):
            return text(d)
        case .verbatimString(_, let d):
            return text(d)
        case .error(let e):
            return .error(e.message)
        case .integer(let i):
            return .integer(String(i))
        case .bigNumber(let s):
            return .integer(s)
        case .boolean(let b):
            return .integer(b ? "1" : "0")
        case .double(let d):
            return .string(RedisArgument.format(d))
        case .array(let items?):
            return .array(items.map { node($0, utf8: utf8) })
        case .set(let items), .push(let items):
            return .array(items.map { node($0, utf8: utf8) })
        case .map(let pairs):
            return .array(pairs.flatMap { [node($0.0, utf8: utf8), node($0.1, utf8: utf8)] })
        }
    }
}

/// Formats replies as redis-cli text, such as `(integer) 1` or `1) "a"`, with nested indentation.
public enum ReplyTextFormatter {
    /// Commands whose top-level string replies print without quotes.
    public static let bulkReplyCommands = ["LOLWUT", "INFO", "CLIENT", "CLUSTER", "MEMORY", "MONITOR", "PSUBSCRIBE"]

    public static func text(_ node: ReplyNode) throws -> String {
        text(node, command: "")
    }

    public static func text(_ node: ReplyNode, command: String) -> String {
        switch node {
        case .null: return "(nil)"
        case .integer(let n): return "(integer) \(n)"
        case .error(let message): return message
        case .array: return arrayText(node, level: 0)
        case .string(let s):
            let upper = command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return bulkReplyCommands.contains(where: { upper.hasPrefix($0) }) ? s : "\"\(s)\""
        }
    }

    private static func arrayText(_ node: ReplyNode, level: Int) -> String {
        switch node {
        case .array(let items):
            if items.isEmpty { return "(empty list or set)" }
            let margin = String(repeating: "   ", count: level)
            return items.enumerated().map { index, item in
                let prefix = (index > 0 ? margin : "") + "\(index + 1))"
                return prefix + " " + arrayText(item, level: level + 1)
            }.joined(separator: "\n")
        case .integer(let n): return "(integer) \(n)"
        case .null: return "(nil)"
        case .error(let message): return "(error) \(message)"
        case .string(let s): return "\"\(s)\""
        }
    }
}

/// `sdscatrepr`-style escaping without surrounding quotes, and its inverse.
public enum ASCIISafeEscaping {
    public static func escape(_ data: Data) throws -> String {
        escapeBytes([UInt8](data))
    }

    public static func unescape(_ text: String) throws -> Data {
        Data(unescapeBytes(text))
    }

    static func escapeBytes(_ bytes: [UInt8]) -> String {
        let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for b in bytes {
            switch b {
            case 0x07: out += [0x5C, UInt8(ascii: "a")]
            case 0x08: out += [0x5C, UInt8(ascii: "b")]
            case 0x09: out += [0x5C, UInt8(ascii: "t")]
            case 0x0A: out += [0x5C, UInt8(ascii: "n")]
            case 0x0D: out += [0x5C, UInt8(ascii: "r")]
            case 0x22: out += [0x5C, 0x22]
            case 0x5C: out += [0x5C, 0x5C]
            case 0x20...0x7E: out.append(b)
            default: out += [0x5C, UInt8(ascii: "x"), hexDigits[Int(b >> 4)], hexDigits[Int(b & 0x0F)]]
            }
        }

        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes valid `\xHH` bytes and `\a \" \\ \b \t \n \r` escapes; preserves other text as literal UTF-8.
    static func unescapeBytes(_ text: String) -> [UInt8] {
        let input = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let c = input[i]
            if c == 0x5C, i + 1 < input.count {
                let n = input[i + 1]
                if n == UInt8(ascii: "x"), i + 3 < input.count, let h = hexDigit(input[i + 2]), let l = hexDigit(input[i + 3]) {
                    out.append(h << 4 | l)
                    i += 4
                    continue
                }

                switch n {
                case UInt8(ascii: "a"): out.append(0x07); i += 2; continue
                case UInt8(ascii: "b"): out.append(0x08); i += 2; continue
                case UInt8(ascii: "t"): out.append(0x09); i += 2; continue
                case UInt8(ascii: "n"): out.append(0x0A); i += 2; continue
                case UInt8(ascii: "r"): out.append(0x0D); i += 2; continue
                case 0x22, 0x5C: out.append(n); i += 2; continue
                default: break
                }
            }

            out.append(c)
            i += 1
        }

        return out
    }
}

public enum CommandLineSplitterError: Error, LocalizedError, Sendable, Equatable {
    /// A quoted argument was never closed.
    case unbalancedQuotes
    /// A closing quote was followed by something other than a space.
    case invalidArguments

    public var errorDescription: String? {
        switch self {
        case .unbalancedQuotes: return "Invalid arguments: a quote is never closed."
        case .invalidArguments: return "Invalid arguments: add a space after the closing quote."
        }
    }
}

/// Splits arguments with redis-cli quoting and `\xHH` / `\n` escapes. Output is binary-safe.
public enum CommandLineSplitter {
    public static func split(_ line: String) throws -> [Data] {
        try split(bytes: Array(line.utf8))
    }

    /// `split` over raw bytes, for lines that are not valid UTF-8.
    public static func split(bytes p: [UInt8]) throws -> [Data] {
        var i = 0
        var args: [Data] = []
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C }
        while true {
            while i < p.count, isSpace(p[i]) { i += 1 }
            guard i < p.count else { return args }
            var inDouble = false
            var inSingle = false
            var done = false
            var current: [UInt8] = []
            while !done {
                if inDouble {
                    guard i < p.count else { throw CommandLineSplitterError.unbalancedQuotes }
                    if p[i] == 0x5C, i + 3 < p.count, p[i + 1] == UInt8(ascii: "x"),
                       let h = hexDigit(p[i + 2]), let l = hexDigit(p[i + 3]) {
                        current.append(h << 4 | l)
                        i += 3
                    } else if p[i] == 0x5C, i + 1 < p.count {
                        i += 1
                        switch p[i] {
                        case UInt8(ascii: "n"): current.append(0x0A)
                        case UInt8(ascii: "r"): current.append(0x0D)
                        case UInt8(ascii: "t"): current.append(0x09)
                        case UInt8(ascii: "b"): current.append(0x08)
                        case UInt8(ascii: "a"): current.append(0x07)
                        default: current.append(p[i])
                        }
                    } else if p[i] == 0x22 {
                        if i + 1 < p.count, !isSpace(p[i + 1]) { throw CommandLineSplitterError.invalidArguments }
                        done = true
                    } else {
                        current.append(p[i])
                    }
                } else if inSingle {
                    guard i < p.count else { throw CommandLineSplitterError.unbalancedQuotes }
                    if p[i] == 0x5C, i + 1 < p.count, p[i + 1] == 0x27 {
                        i += 1
                        current.append(0x27)
                    } else if p[i] == 0x27 {
                        if i + 1 < p.count, !isSpace(p[i + 1]) { throw CommandLineSplitterError.invalidArguments }
                        done = true
                    } else {
                        current.append(p[i])
                    }
                } else {
                    if i >= p.count {
                        done = true
                    } else {
                        switch p[i] {
                        case 0x20, 0x0A, 0x0D, 0x09, 0x00: done = true
                        case 0x22: inDouble = true
                        case 0x27: inSingle = true
                        default: current.append(p[i])
                        }
                    }
                }

                if i < p.count { i += 1 }
            }

            args.append(Data(current))
        }
    }

    /// Splits and decodes each argument as UTF-8 (lossy), for display and command-name lookups.
    public static func splitStrings(_ line: String) throws -> [String] {
        try split(line).map { String(decoding: $0, as: UTF8.self) }
    }
}
