import Foundation

/// Destinations of the links printed in the CLI output.
public enum CLILink: String, Hashable, Sendable, CaseIterable {
    case workbench
    case profiler
    case pubSub

    var url: URL {
        URL(string: "keystrand-cli://\(rawValue)") ?? URL(fileURLWithPath: "/")
    }

    init?(url: URL) {
        guard url.scheme == "keystrand-cli", let host = url.host else { return nil }
        self.init(rawValue: host)
    }
}

/// How a run of CLI output text is drawn.
public enum CLITextStyle: Hashable, Sendable {
    /// Regular terminal text (prompts, status lines).
    case plain
    /// The echoed command line (bold).
    case command
    /// A successful reply.
    case reply
    /// Error replies and failures.
    case error
    /// The green "Try Workbench" intro.
    case intro
    /// Dimmed notes (truncation notices).
    case muted
}

public struct CLIOutputSegment: Hashable, Sendable {
    public var text: String
    public var style: CLITextStyle
    public var link: CLILink?

    public init(_ text: String, style: CLITextStyle = .plain, link: CLILink? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }
}

/// One append to the output (a command echo, a reply, a status message).
public struct CLIOutputChunk: Identifiable, Hashable, Sendable {
    public let id: Int
    public let segments: [CLIOutputSegment]
    public let lineCount: Int
    /// UTF-16 length of the chunk's text.
    public let characterCount: Int

    public var text: String { segments.map(\.text).joined() }
}

/// Append-only terminal output with a line cap and a UTF-16 character cap. Oldest chunks are dropped once
/// either cap is exceeded, the newest chunk is always kept.
public struct CLIOutputBuffer: Hashable, Sendable {
    public static let defaultMaxLines = 20_000
    public static let defaultMaxCharacters = 5_000_000

    public private(set) var chunks: [CLIOutputChunk] = []
    /// Changes on `clear()`, so renderers know to start over instead of appending.
    public private(set) var generation = 0
    public private(set) var lineCount = 0
    public private(set) var characterCount = 0
    public private(set) var droppedChunkCount = 0
    public var maxLines: Int
    public var maxCharacters: Int
    private var nextID = 0

    public init(maxLines: Int = CLIOutputBuffer.defaultMaxLines,
                maxCharacters: Int = CLIOutputBuffer.defaultMaxCharacters) {
        self.maxLines = max(1, maxLines)
        self.maxCharacters = max(1, maxCharacters)
    }

    public var isEmpty: Bool { chunks.isEmpty }

    public var plainText: String { chunks.map(\.text).joined() }

    public mutating func append(_ segments: [CLIOutputSegment]) {
        let nonEmpty = segments.filter { !$0.text.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        let lines = nonEmpty.reduce(0) { $0 + $1.text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } }
        let characters = nonEmpty.reduce(0) { $0 + $1.text.utf16.count }
        chunks.append(CLIOutputChunk(id: nextID, segments: nonEmpty, lineCount: lines, characterCount: characters))
        nextID += 1
        lineCount += lines
        characterCount += characters
        trim()
    }

    public mutating func append(_ text: String, style: CLITextStyle = .plain) {
        append([CLIOutputSegment(text, style: style)])
    }

    public mutating func clear() {
        chunks.removeAll()
        lineCount = 0
        characterCount = 0
        generation += 1
    }

    private mutating func trim() {
        guard lineCount > maxLines || characterCount > maxCharacters else { return }
        var drop = 0
        var lines = lineCount
        var characters = characterCount
        while lines > maxLines || characters > maxCharacters, drop < chunks.count - 1 {
            lines -= chunks[drop].lineCount
            characters -= chunks[drop].characterCount
            drop += 1
        }

        guard drop > 0 else { return }
        chunks.removeFirst(drop)
        droppedChunkCount += drop
        lineCount = lines
        characterCount = characters
    }
}
