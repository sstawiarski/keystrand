import Foundation

/// Reports an unfinished implementation without crashing.
public struct NotImplementedError: Error, LocalizedError, Sendable, Equatable {
    public let symbol: String
    public let file: String

    public init(_ symbol: String = #function, file: String = #fileID) {
        self.symbol = symbol
        self.file = file
    }

    public var errorDescription: String? { "Not implemented yet: \(symbol) (\(file))" }
}
