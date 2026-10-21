import Darwin
import Foundation
import RESP

/// When a database's user script runs: before connecting, or after its connections are closed.
public enum ConnectionScriptKind: Hashable, Sendable {
    case preConnect
    case postDisconnect

    /// Sentence-case name, for example "Pre-connection script".
    public var title: String {
        switch self {
        case .preConnect: return "Pre-connection script"
        case .postDisconnect: return "Post-disconnect script"
        }
    }
}

public struct ConnectionScriptResult: Hashable, Sendable {
    public var exitCode: Int32
    /// Last 2000 characters of combined stdout/stderr.
    public var outputTail: String
    /// Signal that stopped the script, if any.
    public var signal: Int32?
    public var timedOut: Bool

    public init(exitCode: Int32, outputTail: String, signal: Int32? = nil, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.outputTail = outputTail
        self.signal = signal
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && signal == nil && !timedOut }

    /// Formats the script failure message with the output tail.
    public func failureMessage(_ kind: ConnectionScriptKind, timeout: TimeInterval) -> String {
        let script = "The " + kind.title.lowercased()
        let headline: String
        if timedOut {
            headline = "\(script) did not finish within \(Int(timeout)) seconds."
        } else if let signal {
            let name = String(cString: strsignal(signal))
            headline = "\(script) stopped on signal \(name)."
        } else {
            headline = "\(script) failed with exit code \(exitCode)."
        }

        let tail = outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? headline : headline + "\n" + tail
    }
}

/// Runs a user script with `$SHELL -lc` (timeout kills the whole process group).
/// Concurrent runs of the same script text share one execution.
public struct ConnectionScriptRunner: Sendable {
    public var timeout: TimeInterval
    /// Shell used with `-lc`; nil = `$SHELL`, falling back to `/bin/sh`.
    public var shell: String?

    public init(timeout: TimeInterval = 120, shell: String? = nil) {
        self.timeout = timeout
        self.shell = shell
    }

    /// The script to run, or nil when it is missing or only whitespace.
    public static func runnable(_ script: String?) -> String? {
        let trimmed = script?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public func run(_ script: String) async throws -> ConnectionScriptResult {
        try await ScriptCoalescer.shared.run(script, timeout: timeout, shell: shell)
    }

    /// Runs the script and throws `RedisClientError.scriptFailed` unless it exits with 0.
    public func runOrThrow(_ script: String, kind: ConnectionScriptKind) async throws {
        let result = try await run(script)
        guard result.succeeded else {
            throw RedisClientError.scriptFailed(kind, result.failureMessage(kind, timeout: timeout))
        }
    }

    static func execute(_ script: String, timeout: TimeInterval, shell preferredShell: String?) async throws -> ConnectionScriptResult {
        let shell = (preferredShell ?? ProcessInfo.processInfo.environment["SHELL"]).flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            ?? "/bin/sh"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("keystrand-script-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputURL.path, O_WRONLY | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Reset signal dispositions and the mask so the script is not born ignoring SIGTERM/SIGINT.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [String] = [shell, "-lc", script]
        var cArgs = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { for pointer in cArgs { free(pointer) } }
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var cEnv = environment.map { strdup($0) }
        cEnv.append(nil)
        defer { for pointer in cEnv { free(pointer) } }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, shell, &actions, &attributes, cArgs, cEnv)
        guard spawnStatus == 0 else {
            return ConnectionScriptResult(exitCode: 127, outputTail: "Unable to start \(shell): \(String(cString: strerror(spawnStatus)))")
        }

        let deadline = ContinuousClock.now + .seconds(timeout)
        var status: Int32 = 0
        var timedOut = false
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result < 0 && errno != EINTR { break }
            if Task.isCancelled {
                await terminate(pid, status: &status)
                throw RedisClientError.cancelled
            }

            if ContinuousClock.now >= deadline {
                timedOut = true
                await terminate(pid, status: &status)
                break
            }

            try? await Task.sleep(for: .milliseconds(50))
        }

        let tail = outputTail(of: outputURL)
        let exited = (status & 0x7F) == 0
        let exitCode = exited ? (status >> 8) & 0xFF : -1
        let signal: Int32? = exited || timedOut ? nil : status & 0x7F
        return ConnectionScriptResult(exitCode: exitCode, outputTail: tail, signal: signal, timedOut: timedOut)
    }

    static let terminationGrace: Duration = .milliseconds(500)

    /// Sends SIGTERM to the process group, then SIGKILL after the grace period if needed. Polls with `WNOHANG` without blocking a thread.
    private static func terminate(_ pid: pid_t, status: inout Int32) async {
        kill(-pid, SIGTERM)
        if await reap(pid, status: &status, within: terminationGrace) { return }
        kill(-pid, SIGKILL)
        _ = await reap(pid, status: &status, within: .seconds(5))
    }

    private static func reap(_ pid: pid_t, status: inout Int32, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno != EINTR) { return true }
            if ContinuousClock.now >= deadline { return false }
            await pause(.milliseconds(20))
        }
    }

    /// Waits even if the current task is cancelled.
    private static func pause(_ duration: Duration) async {
        await Task.detached { try? await Task.sleep(for: duration) }.value
    }

    /// The last 2000 characters of the log, decoding invalid UTF-8 with replacement characters.
    static func outputTail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(String(decoding: data, as: UTF8.self).suffix(2000))
    }
}

/// Shares each script-text and shell execution among waiters. Cancels the run when the last waiter cancels.
private actor ScriptCoalescer {
    static let shared = ScriptCoalescer()

    private struct Run {
        let task: Task<ConnectionScriptResult, Error>
        var waiters: Int
    }

    private var running: [String: Run] = [:]

    func run(_ script: String, timeout: TimeInterval, shell: String?) async throws -> ConnectionScriptResult {
        let key = (shell ?? "") + "\u{0}" + script
        let task: Task<ConnectionScriptResult, Error>
        if var existing = running[key] {
            existing.waiters += 1
            running[key] = existing
            task = existing.task
        } else {
            task = Task { try await ConnectionScriptRunner.execute(script, timeout: timeout, shell: shell) }
            running[key] = Run(task: task, waiters: 1)
        }

        defer { finish(key, task: task) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.abandon(key, task: task) }
        }
    }

    private func abandon(_ key: String, task: Task<ConnectionScriptResult, Error>) {
        guard var run = running[key], run.task == task else { return }
        run.waiters -= 1
        if run.waiters > 0 {
            running[key] = run
        } else {
            running[key] = nil
            task.cancel()
        }
    }

    private func finish(_ key: String, task: Task<ConnectionScriptResult, Error>) {
        if running[key]?.task == task { running[key] = nil }
    }
}
