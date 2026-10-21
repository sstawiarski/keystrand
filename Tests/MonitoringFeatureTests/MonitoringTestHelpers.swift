import Foundation
@testable import MonitoringFeature
import RedisCore

@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return condition()
}

actor FakePubSubTransport: PubSubTransport {
    private var continuation: AsyncThrowingStream<PubSubMessage, Error>.Continuation?
    private(set) var patterns: [Data] = []
    private(set) var isClosed = false
    let confirms: Bool

    init(confirms: Bool = true) {
        self.confirms = confirms
    }

    func psubscribe(_ patterns: [Data]) -> AsyncThrowingStream<PubSubMessage, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PubSubMessage.self)
        self.continuation = continuation
        self.patterns = patterns
        if confirms {
            for (index, pattern) in patterns.enumerated() {
                continuation.yield(PubSubMessage(kind: .psubscribe, channel: pattern, pattern: pattern,
                                                 subscriptionCount: index + 1))
            }
        }

        return stream
    }

    func deliver(channel: String, message: Data, pattern: String = "*") {
        continuation?.yield(PubSubMessage(kind: .pmessage, channel: Data(channel.utf8), message: message,
                                          pattern: Data(pattern.utf8)))
    }

    func deliver(channel: String, message: String) {
        deliver(channel: channel, message: Data(message.utf8))
    }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
    }

    func close() {
        isClosed = true
        continuation?.finish()
        continuation = nil
    }
}

actor FakeMonitorTransport: MonitorTransport {
    private var continuation: AsyncThrowingStream<MonitorLine, Error>.Continuation?
    private(set) var isClosed = false
    private(set) var monitorCalls = 0

    func monitor() -> AsyncThrowingStream<MonitorLine, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MonitorLine.self)
        self.continuation = continuation
        monitorCalls += 1
        return stream
    }

    func emit(_ raw: String) throws {
        continuation?.yield(try MonitorLineParser.parse(raw))
    }

    func emit(count: Int, startingAt start: Int = 0) {
        for i in start..<(start + count) {
            if let line = try? MonitorLineParser.parse("1700000000.\(String(format: "%06d", i % 1_000_000)) [0 127.0.0.1:5000] \"get\" \"k\(i)\"") {
                continuation?.yield(line)
            }
        }
    }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
    }

    func endCleanly() {
        continuation?.finish()
    }

    func close() {
        isClosed = true
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
final class FakeMonitorFactory {
    var made: [FakeMonitorTransport] = []
    var failNext: Error?
    var nodeLabels: [String?] = [nil]

    var latest: FakeMonitorTransport? { made.last }

    func connect() throws -> [MonitorNodeConnection] {
        if let error = failNext {
            failNext = nil
            throw error
        }

        return nodeLabels.map { label in
            let transport = FakeMonitorTransport()
            made.append(transport)
            return MonitorNodeConnection(nodeLabel: label, transport: transport)
        }
    }
}

@MainActor
final class FakePubSubFactory {
    var made: [FakePubSubTransport] = []
    var failNext: Error?
    var confirms = true

    var latest: FakePubSubTransport? { made.last }

    func connect() throws -> any PubSubTransport {
        if let error = failNext {
            failNext = nil
            throw error
        }

        let transport = FakePubSubTransport(confirms: confirms)
        made.append(transport)
        return transport
    }
}
