import Foundation

/// A server error reply (`-ERR ...`, `-WRONGTYPE ...`, `-MOVED 3999 127.0.0.1:6381`, RESP3 blob errors).
public struct RESPError: Error, LocalizedError, Hashable, Sendable, CustomStringConvertible {
    /// Full error text as sent by the server, without the leading `-` and trailing CRLF.
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    /// First word of the message when it is all uppercase (`ERR`, `WRONGTYPE`, `MOVED`, `ASK`, `NOPERM`, ...).
    public var code: String? {
        guard let first = message.split(separator: " ", maxSplits: 1).first else { return nil }
        let word = String(first)
        return word == word.uppercased() && word.rangeOfCharacter(from: .letters) != nil ? word : nil
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
