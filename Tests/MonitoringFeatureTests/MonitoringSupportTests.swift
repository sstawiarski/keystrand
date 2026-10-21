import Foundation
@testable import MonitoringFeature
import RedisCore
import Synchronization
import TestSupport
import Testing

/// Ignores cancellation until the test opens the gate.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class Recorder<T: Sendable>: Sendable {
    private let storage = Mutex<[T]>([])
    func add(_ value: T) { storage.withLock { $0.append(value) } }
    var values: [T] { storage.withLock { $0 } }
}

struct ConnectTimeoutTests {
    @Test func returnsTheValueWhenFasterThanTheTimeout() async throws {
        let discarded = Recorder<Int>()
        let value = try await withConnectTimeout(.seconds(5), discard: { discarded.add($0) }) { 42 }
        #expect(value == 42)
        #expect(discarded.values.isEmpty)
    }

    @Test func propagatesOperationErrors() async {
        await #expect(throws: RedisClientError.self) {
            try await withConnectTimeout(.seconds(5)) { () async throws -> Int in
                throw RedisClientError.connectionClosed
            }
        }
    }

    @Test func timesOutWithoutWaitingForAnUncancellableOperation() async throws {
        let gate = Gate()
        let discarded = Recorder<Int>()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: MonitoringError.noConnection) {
            try await withConnectTimeout(.milliseconds(100), discard: { discarded.add($0) }) { () async throws -> Int in
                await Task { await gate.wait() }.value
                return 7
            }
        }
        #expect(clock.now - start < .seconds(2))
        #expect(discarded.values.isEmpty)

        await gate.open()
        let deadline = clock.now + .seconds(5)
        while discarded.values.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(discarded.values == [7])
    }

    @Test func callerCancellationDiscardsTheLateValue() async throws {
        let gate = Gate()
        let discarded = Recorder<Int>()
        let caller = Task {
            try await withConnectTimeout(.seconds(30), discard: { discarded.add($0) }) { () async throws -> Int in
                await Task { await gate.wait() }.value
                return 9
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        await gate.open()
        let deadline = ContinuousClock.now + .seconds(5)
        while discarded.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(discarded.values == [9])
    }
}

struct PendingQueueCapacityTests {
    private enum Event: Equatable, Sendable {
        case row(Int, generation: Int)
        case control(String)

        var droppableGeneration: Int? {
            if case .row(_, let generation) = self { return generation }
            return nil
        }
    }

    @Test func dropsOldestRowsButKeepsControlEventsInOrder() {
        let queue = PendingQueue<Event>(capacity: 3, dropGeneration: { $0.droppableGeneration })
        queue.append(.control("start"))
        for i in 0..<10 { queue.append(.row(i, generation: 1)) }
        queue.append(.control("end"))
        let batch = queue.drainBatch()
        #expect(batch.items == [.control("start"), .row(7, generation: 1), .row(8, generation: 1),
                                .row(9, generation: 1), .control("end")])
        #expect(batch.droppedCount(generation: 1) == 7)
        #expect(batch.droppedCount(generation: 2) == 0)
        #expect(queue.drainBatch().items.isEmpty)
    }

    @Test func staysBoundedWhileNobodyDrains() {
        let capacity = 100
        let queue = PendingQueue<Event>(capacity: capacity, dropGeneration: { $0.droppableGeneration })
        for i in 0..<100_000 { queue.append(.row(i, generation: 3)) }
        #expect(queue.count <= capacity + max(capacity / 4, 64))
        let batch = queue.drainBatch()
        #expect(batch.items.count == capacity)
        #expect(batch.items.last == .row(99_999, generation: 3))
        #expect(batch.droppedCount(generation: 3) == 100_000 - capacity)
    }

    @Test func countsDropsPerGeneration() {
        let queue = PendingQueue<Event>(capacity: 2, dropGeneration: { $0.droppableGeneration })
        queue.append(.row(0, generation: 1))
        queue.append(.row(1, generation: 1))
        queue.append(.row(2, generation: 2))
        queue.append(.row(3, generation: 2))
        let batch = queue.drainBatch()
        #expect(batch.items == [.row(2, generation: 2), .row(3, generation: 2)])
        #expect(batch.dropped == [1: 2])
    }
}
