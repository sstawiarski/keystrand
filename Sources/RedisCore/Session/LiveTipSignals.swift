import Foundation
import Observation

/// A live recommendation trigger fired by a feature (Browser scan, key details, CLI, ...).
public struct LiveTipSignal: Hashable, Sendable {
    public var name: RecommendationName
    /// The key the tip refers to, when there is one (big hash, big set, ...).
    public var key: Data?

    public init(_ name: RecommendationName, key: Data? = nil) {
        self.name = name
        self.key = key
    }
}

/// Per-session bus for live tip triggers. Buffers signals until a handler is installed.
/// Delivers each tip name at most once per session; the receiver deduplicates per database.
@MainActor
@Observable
public final class LiveTipSignals {
    /// Names delivered (or buffered) so far in this session.
    public private(set) var reportedNames: Set<RecommendationName> = []
    @ObservationIgnored private var buffered: [LiveTipSignal] = []
    @ObservationIgnored private var handler: (@MainActor (LiveTipSignal) -> Void)?

    public init() {}

    public func report(_ signal: LiveTipSignal) {
        guard reportedNames.insert(signal.name).inserted else { return }
        if let handler { handler(signal) } else { buffered.append(signal) }
    }

    public func report(_ name: RecommendationName, key: Data? = nil) {
        report(LiveTipSignal(name, key: key))
    }

    /// Installs the receiver and delivers buffered signals; `nil` removes it.
    public func setHandler(_ handler: (@MainActor (LiveTipSignal) -> Void)?) {
        self.handler = handler
        guard let handler, !buffered.isEmpty else { return }
        let pending = buffered
        buffered.removeAll()
        for signal in pending { handler(signal) }
    }

    /// Forgets delivered names (the database changed) so triggers can fire again.
    public func reset() {
        reportedNames.removeAll()
        buffered.removeAll()
        checkedNames.removeAll()
    }

    @ObservationIgnored private var checkedNames: Set<RecommendationName> = []

    /// True the first time per session for a trigger that costs a server round trip (searchJSON runs FT._LIST).
    public func beginCheck(_ name: RecommendationName) -> Bool {
        !reportedNames.contains(name) && checkedNames.insert(name).inserted
    }

    // MARK: - Trigger sites

    /// Key details info: big sets, big strings, long lists.
    public func reportKeyInfo(_ info: KeyInfo) {
        if let name = LiveTipRules.keyInfoTip(info) { report(name, key: info.name) }
    }

    /// Hash fields loaded with the hash's total field count.
    public func reportHashLoaded(key: Data, total: Int) {
        if total > LiveTipRules.bigHashesLength { report(.bigHashes, key: key) }
    }

    /// String value loaded: JSON object or array text suggests RedisJSON. Parses off the main actor.
    public func reportStringLoaded(key: Data, value: Data) async {
        await reportStringLoaded(key: key, value: value, isJSON: LiveTipRules.isJSONContainer)
    }

    func reportStringLoaded(key: Data, value: Data, isJSON: @escaping @Sendable (Data) -> Bool) async {
        guard !reportedNames.contains(.stringToJson) else { return }
        let matches = await Task.detached(priority: .utility) { isJSON(value) }.value
        if matches { report(.stringToJson, key: key) }
    }

    /// Sorted set members loaded: timestamp-like members or scores among the first few suggest Redis Time Series.
    public func reportZSetLoaded(key: Data, members: [(member: Data, score: String)]) async {
        await reportZSetLoaded(key: key, members: members, looksLikeTimeSeries: LiveTipRules.looksLikeTimeSeries)
    }

    func reportZSetLoaded(key: Data, members: [(member: Data, score: String)],
                          looksLikeTimeSeries: @escaping @Sendable ([(member: Data, score: String)]) -> Bool) async {
        guard !reportedNames.contains(.rts), !members.isEmpty else { return }
        let sample = Array(members.prefix(LiveTipRules.timeSeriesSampleSize))
        let matches = await Task.detached(priority: .utility) { looksLikeTimeSeries(sample) }.value
        if matches { report(.rts, key: key) }
    }

    /// CLI command sent: search and time-series reads have Workbench visualizations.
    public func reportCLICommand(_ commandLine: String) {
        if LiveTipRules.isSearchVisualizationCommand(commandLine) { report(.searchVisualization) }
    }
}

/// Size limits and command sets that trigger live tips.
public enum LiveTipRules {
    public static let bigHashesLength = 5_000
    public static let bigSetsLength = 1_000
    public static let compressionForListLength = 1_000
    public static let bigStringsMemory = 100_000
    public static let searchVisualizationCommands: Set<String> = [
        "FT.INFO", "FT.SEARCH", "FT.AGGREGATE", "FT.PROFILE", "FT.EXPLAIN", "TS.RANGE", "TS.MRANGE",
    ]

    public static func keyInfoTip(_ info: KeyInfo) -> RecommendationName? {
        switch info.type {
        case .set where (info.length ?? 0) > bigSetsLength: return .bigSets
        case .string where (info.size ?? 0) > bigStringsMemory: return .bigStrings
        case .list where (info.length ?? 0) > compressionForListLength: return .compressionForList
        default: return nil
        }
    }

    /// Sorted set members checked for the Redis Time Series tip.
    public static let timeSeriesSampleSize = 10

    public static func isJSONContainer(_ value: Data) -> Bool {
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }
        guard let first = value.first(where: { !isSpace($0) }), let last = value.last(where: { !isSpace($0) }),
              (first == UInt8(ascii: "{") && last == UInt8(ascii: "}"))
                || (first == UInt8(ascii: "[") && last == UInt8(ascii: "]")) else { return false }
        return (try? JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])) != nil
    }

    public static func looksLikeTimeSeries(_ members: [(member: Data, score: String)]) -> Bool {
        members.contains { item in
            TimestampDetector.isTimestamp(String(decoding: item.member, as: UTF8.self))
                || TimestampDetector.isTimestamp(item.score)
        }
    }

    public static func isSearchVisualizationCommand(_ commandLine: String) -> Bool {
        let verb = commandLine.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first
        return verb.map { searchVisualizationCommands.contains($0.uppercased()) } ?? false
    }
}
