import Foundation
import RedisCore

/// A dedicated connection that can enter Pub/Sub mode.
protocol PubSubTransport: Sendable {
    func psubscribe(_ patterns: [Data]) async -> AsyncThrowingStream<PubSubMessage, Error>
    func close() async
}

extension RedisConnection: PubSubTransport {}

struct PubSubEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let channel: Data
    let message: Data
    let pattern: Data?
    let receivedAt: Date
    /// Single-line previews built off the main actor (payloads can be megabytes).
    let channelText: String
    let messagePreview: String

    init(_ message: PubSubMessage) {
        self.id = message.id
        self.channel = message.channel
        self.message = message.message
        self.pattern = message.pattern
        self.receivedAt = message.receivedAt
        self.channelText = BinaryText.preview(message.channel, limit: 200)
        self.messagePreview = BinaryText.preview(message.message, limit: 300)
    }

    var channelFullText: String { BinaryText.full(channel) }
    var messageFullText: String { BinaryText.full(message) }

    /// Tooltip body: the full message, capped so huge payloads do not freeze the tooltip.
    var messageTooltip: String {
        let limit = 2_000
        if message.count <= limit { return messageFullText }
        return BinaryText.preview(message, limit: limit)
    }
}

enum PubSubStatus: Equatable, Sendable {
    case unsubscribed
    case subscribing
    case subscribed
    case unsubscribing

    var isActive: Bool { self == .subscribing || self == .subscribed }
    var isBusy: Bool { self == .subscribing || self == .unsubscribing }
}

struct PublishResult: Equatable, Sendable {
    let id = UUID()
    /// Receivers reported by PUBLISH; nil on clusters (the per-node count is meaningless there).
    let receivers: Int?

    var statusText: String {
        guard let receivers else { return "Message published" }
        return "Published to \(receivers) \(receivers == 1 ? "client" : "clients")"
    }

    var detailText: String {
        guard let receivers else { return "Message published to the cluster" }
        return "Message published to \(receivers) \(receivers == 1 ? "subscriber" : "subscribers")"
    }
}

/// Pattern input handling (all entries are subscribed with PSUBSCRIBE).
enum PubSubPatterns {
    static let defaultPattern = "*"

    /// Space-separated tokens, deduplicated in order; empty input means `*`.
    static func parse(_ input: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in input.split(whereSeparator: { $0.isWhitespace }) {
            let pattern = String(token)
            if seen.insert(pattern).inserted { out.append(pattern) }
        }

        return out.isEmpty ? [defaultPattern] : out
    }

    static func normalizedInput(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPattern : input
    }

    static func headerText(_ patterns: [String]) -> String {
        if patterns == [defaultPattern] { return "Patterns: All" }
        return "Patterns: \(patterns.count)"
    }

    static func subscribedText(_ patterns: [String]) -> String {
        if patterns.isEmpty || patterns == [defaultPattern] { return "Subscribed to all channels" }
        if patterns.count == 1 { return "Subscribed to \(patterns[0])" }
        return "Subscribed to \(patterns.count) patterns"
    }

    static func tooltip(_ patterns: [String]) -> String {
        patterns.joined(separator: "\n")
    }
}

enum PubSubEvent: Sendable {
    case confirmed(generation: Int)
    case message(generation: Int, PubSubEntry)
    case ended(generation: Int, errorMessage: String?)

    /// Messages may be dropped from a backed-up queue; control events never are.
    var droppableGeneration: Int? {
        if case .message(let generation, _) = self { return generation }
        return nil
    }
}
