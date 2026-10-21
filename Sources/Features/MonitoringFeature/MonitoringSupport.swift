import Foundation
import RedisCore
import Synchronization

enum MonitoringError: Error, LocalizedError, Equatable {
    case noConnection
    case connectionLost
    case forbidden

    static let noConnectionMessage = "Couldn't open a connection to the database."
    static let forbiddenMessage = "The Profiler can't start: this user isn't allowed to run MONITOR."
    static let connectionLostMessage = "Error: the connection dropped"

    var errorDescription: String? {
        switch self {
        case .noConnection: return Self.noConnectionMessage
        case .connectionLost: return Self.connectionLostMessage
        case .forbidden: return Self.forbiddenMessage
        }
    }
}

enum MonitoringTimeouts {
    /// Timeout for opening Pub/Sub and MONITOR connections.
    static let connect: Duration = .seconds(25)
    /// The same limit at the connector level (dedicated connections do not retry).
    static let connectSeconds: TimeInterval = 25
    static let flushInterval: Duration = .milliseconds(50)
}

/// Thread-safe FIFO for background readers and main-actor batch drains.
/// If queued payloads exceed `capacity`, drops the oldest and counts them per generation.
/// A nil `dropGeneration` result marks a control event, which is never dropped.
final class PendingQueue<Element: Sendable>: Sendable {
    struct Batch {
        var items: [Element]
        var dropped: [Int: Int]

        func droppedCount(generation: Int) -> Int { dropped[generation] ?? 0 }
    }

    private struct State {
        var items: [Element] = []
        var droppableCount = 0
        var dropped: [Int: Int] = [:]
    }

    let capacity: Int
    private let dropGeneration: @Sendable (Element) -> Int?
    private let compactionThreshold: Int
    private let storage = Mutex(State())

    init(capacity: Int = .max, dropGeneration: @escaping @Sendable (Element) -> Int? = { _ in nil }) {
        self.capacity = max(capacity, 0)
        self.dropGeneration = dropGeneration
        let slack = max(self.capacity / 4, 64)
        self.compactionThreshold = self.capacity > Int.max - slack ? .max : self.capacity + slack
    }

    func append(_ element: Element) {
        let droppable = dropGeneration(element) != nil
        storage.withLock { state in
            state.items.append(element)
            guard droppable else { return }
            state.droppableCount += 1
            if state.droppableCount > compactionThreshold { compact(&state) }
        }
    }

    func drain() -> [Element] {
        drainBatch().items
    }

    /// Everything queued so far plus how many payload rows were dropped (per generation) since the last drain.
    func drainBatch() -> Batch {
        storage.withLock { state in
            if state.droppableCount > capacity { compact(&state) }
            let batch = Batch(items: state.items, dropped: state.dropped)
            state = State()
            return batch
        }
    }

    var count: Int { storage.withLock { $0.items.count } }

    /// Keeps every control element and the newest `capacity` payload rows, preserving order.
    private func compact(_ state: inout State) {
        var toDrop = state.droppableCount - capacity
        guard toDrop > 0 else { return }
        var kept: [Element] = []
        kept.reserveCapacity(state.items.count - toDrop)
        for element in state.items {
            if toDrop > 0, let generation = dropGeneration(element) {
                state.dropped[generation, default: 0] += 1
                toDrop -= 1
            } else {
                kept.append(element)
            }
        }

        state.items = kept
        state.droppableCount = capacity
    }
}

enum CappedBuffer {
    static func append<T>(_ newItems: [T], to items: inout [T], cap: Int) {
        guard cap > 0 else {
            items.removeAll()
            return
        }
        if newItems.count >= cap {
            items = Array(newItems.suffix(cap))
            return
        }

        items.append(contentsOf: newItems)
        let overflow = items.count - cap
        if overflow > 0 { items.removeFirst(overflow) }
    }
}

/// Throws `MonitoringError.noConnection` if `operation` exceeds `timeout` without awaiting it further.
/// The detached operation continues; `discard` receives any value returned after timeout or cancellation.
func withConnectTimeout<T: Sendable>(_ timeout: Duration = MonitoringTimeouts.connect,
                                     discard: @escaping @Sendable (T) async -> Void = { _ in },
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = ConnectRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            guard race.install(continuation) else { return }
            let timer = Task {
                try await Task.sleep(for: timeout)
                race.finish(.failure(MonitoringError.noConnection))
            }
            Task {
                do {
                    let value = try await operation()
                    timer.cancel()
                    if !race.finish(.success(value)) { await discard(value) }
                } catch {
                    timer.cancel()
                    race.finish(.failure(error))
                }
            }
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// First-result-wins handoff between the connector, the timer, and caller cancellation.
private final class ConnectRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var isDecided = false
    }

    private let state = Mutex(State())

    /// Returns false (after resuming with `CancellationError`) when the caller was cancelled before installing.
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        let installed = state.withLock { state -> Bool in
            guard !state.isDecided else { return false }
            state.continuation = continuation
            return true
        }
        if !installed { continuation.resume(throwing: CancellationError()) }
        return installed
    }

    /// Resumes the caller with `result` unless the race was already decided; returns whether it won.
    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        let continuation = state.withLock { state -> CheckedContinuation<T, Error>?? in
            guard !state.isDecided else { return .none }
            state.isDecided = true
            defer { state.continuation = nil }
            return .some(state.continuation)
        }
        guard let continuation else { return false }
        continuation?.resume(with: result)
        return true
    }
}

enum BinaryText {
    /// Full text: UTF-8 when valid, otherwise `\xHH`-escaped invalid bytes.
    static func full(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return render(data, limit: nil, mode: .plain).text
    }

    /// Single-line preview: valid UTF-8 kept, invalid bytes as `\xHH`, control characters as spaces.
    static func preview(_ data: Data, limit: Int = 300) -> String {
        let result = render(data, limit: limit, mode: .singleLine)
        return result.truncated ? result.text + "…" : result.text
    }

    /// `"arg"` with `"`, `\` and control characters escaped (redis-cli / MONITOR style), truncated to `limit`.
    static func quoted(_ data: Data, limit: Int? = 300) -> String {
        let result = render(data, limit: limit, mode: .quoted)
        return "\"" + result.text + (result.truncated ? "…" : "") + "\""
    }

    enum Mode {
        case plain
        case singleLine
        case quoted
    }

    static func render(_ data: Data, limit: Int?, mode: Mode) -> (text: String, truncated: Bool) {
        let bytes = [UInt8](limit.map { data.prefix($0 * 4 + 4) } ?? data[...])
        var out = String.UnicodeScalarView()
        var characters = 0
        var i = 0
        let hex = Array("0123456789abcdef".unicodeScalars)

        func appendHex(_ b: UInt8) {
            out.append("\\")
            out.append("x")
            out.append(hex[Int(b >> 4)])
            out.append(hex[Int(b & 0x0F)])
        }

        while i < bytes.count {
            if let limit, characters >= limit { return (String(out), true) }
            let b = bytes[i]
            if b < 0x80 {
                let scalar = Unicode.Scalar(b)
                switch mode {
                case .plain:
                    out.append(scalar)
                case .singleLine:
                    out.append(b < 0x20 || b == 0x7F ? " " : scalar)
                case .quoted:
                    switch b {
                    case 0x22: out.append("\\"); out.append("\"")
                    case 0x5C: out.append("\\"); out.append("\\")
                    case 0x0A: out.append("\\"); out.append("n")
                    case 0x0D: out.append("\\"); out.append("r")
                    case 0x09: out.append("\\"); out.append("t")
                    case 0x07: out.append("\\"); out.append("a")
                    case 0x08: out.append("\\"); out.append("b")
                    case 0x00..<0x20, 0x7F: appendHex(b)
                    default: out.append(scalar)
                    }
                }

                characters += 1
                i += 1
                continue
            }

            if let (scalar, length) = decodeScalar(bytes, at: i) {
                out.append(scalar)
                i += length
            } else if i + 4 > bytes.count, limit != nil, bytes.count < data.count {
                // A multi-byte sequence cut by the preview window.
                return (String(out), true)
            } else {
                appendHex(b)
                i += 1
            }

            characters += 1
        }

        let truncated = bytes.count < data.count
        return (String(out), truncated)
    }

    static func decodeScalar(_ bytes: [UInt8], at index: Int) -> (Unicode.Scalar, Int)? {
        let lead = bytes[index]
        let length: Int
        var value: UInt32
        switch lead {
        case 0xC2...0xDF: length = 2; value = UInt32(lead & 0x1F)
        case 0xE0...0xEF: length = 3; value = UInt32(lead & 0x0F)
        case 0xF0...0xF4: length = 4; value = UInt32(lead & 0x07)
        default: return nil
        }

        guard index + length <= bytes.count else { return nil }
        for offset in 1..<length {
            let c = bytes[index + offset]
            guard c & 0xC0 == 0x80 else { return nil }
            value = (value << 6) | UInt32(c & 0x3F)
        }

        let minimum: UInt32 = length == 2 ? 0x80 : (length == 3 ? 0x800 : 0x10000)
        guard value >= minimum, let scalar = Unicode.Scalar(value) else { return nil }
        return (scalar, length)
    }
}
