import Foundation
import RESP
import Synchronization

/// A connection that executes Redis commands.
public protocol RedisClient: AnyObject, Sendable {
    /// Sends one command and returns its reply.
    /// Throws `RedisClientError.server` when Redis answers with an error reply.
    func execute(_ args: [RedisArgument]) async throws -> RESPValue

    /// Sends several commands in one round trip. Error replies are returned in place as `.error`;
    /// only transport failures throw. Result order matches command order.
    func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue]

    /// Closes sockets and tunnels. Safe to call more than once.
    func close() async
}

public extension RedisClient {
    func execute(_ args: RedisArgument...) async throws -> RESPValue {
        try await execute(args)
    }

    func execute(_ args: [Data]) async throws -> RESPValue {
        try await execute(args.redisArguments)
    }

    func pipeline(_ commands: [[Data]]) async throws -> [RESPValue] {
        try await pipeline(commands.map(\.redisArguments))
    }

    /// Returns server error replies as `.error` instead of throwing.
    func send(_ args: [RedisArgument]) async throws -> RESPValue {
        let replies = try await pipeline([args])
        return replies.first ?? .null
    }
}

/// Throws `RedisClientError.timeout` if `operation` exceeds `seconds`. The operation continues in the background.
/// Prefer the connection’s command timeout when available.
public func withDeadline<T: Sendable>(seconds: TimeInterval,
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let state = DeadlineState(continuation)
        Task {
            do {
                state.resume(.success(try await operation()))
            } catch {
                state.resume(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(max(seconds, 0)))
            state.resume(.failure(RedisClientError.timeout))
        }
    }
}

/// Resumes its continuation once, with whichever of the operation and the deadline finishes first.
private final class DeadlineState<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Error>?>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ result: Result<T, Error>) {
        let pending = continuation.withLock { value in
            let current = value
            value = nil
            return current
        }
        pending?.resume(with: result)
    }
}
