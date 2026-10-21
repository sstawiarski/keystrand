import Foundation
import RedisCore
import Synchronization

enum ProfilerLogError: Error, LocalizedError {
    case cannotCreate(String)
    case missing

    var errorDescription: String? {
        switch self {
        case .cannotCreate(let detail): return "The Profiler log file could not be created. \(detail)"
        case .missing: return "The Profiler log file no longer exists."
        }
    }
}

/// Buffers uncapped MONITOR logs, flushing at 64 KB and on `flush()` or `close()`.
final class ProfilerLogFileWriter: Sendable {
    static let flushThreshold = 64 * 1024

    let url: URL

    private struct State {
        var handle: FileHandle?
        var buffer = Data()
        var lineCount = 0
        var writeError: String?
    }

    private let state = Mutex(State())

    init(url: URL) throws {
        self.url = url
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ProfilerLogError.cannotCreate(url.path)
            }
            let handle = try FileHandle(forWritingTo: url)
            state.withLock { $0.handle = handle }
        } catch let error as ProfilerLogError {
            throw error
        } catch {
            throw ProfilerLogError.cannotCreate(error.localizedDescription)
        }
    }

    static let filePrefix = "redis_"
    static let staleAge: TimeInterval = 24 * 3_600

    /// A new log file named `redis_<uuid>.log` in `ProfilerLogs/`. Logs left behind by a quit or crash are removed first.
    static func makeTemporary(paths: AppPaths) throws -> ProfilerLogFileWriter {
        removeStaleLogs(in: paths.profilerLogsDirectory)
        return try ProfilerLogFileWriter(url: paths.profilerLogsDirectory
            .appendingPathComponent("\(filePrefix)\(UUID().uuidString.lowercased()).log"))
    }

    /// Deletes `redis_*.log` files not modified for `age` seconds (a running Profiler keeps its file fresh).
    @discardableResult
    static func removeStaleLogs(in directory: URL, olderThan age: TimeInterval = staleAge, now: Date = Date()) -> Int {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return 0
        }
        var removed = 0
        for file in files where file.lastPathComponent.hasPrefix(filePrefix) && file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            guard now.timeIntervalSince(modified) > age else { continue }
            if (try? manager.removeItem(at: file)) != nil { removed += 1 }
        }

        return removed
    }

    func append(_ line: String) {
        state.withLock { state in
            guard state.handle != nil else { return }
            state.buffer.append(contentsOf: line.utf8)
            state.buffer.append(0x0A)
            state.lineCount += 1
            if state.buffer.count >= Self.flushThreshold { Self.write(&state) }
        }
    }

    func flush() {
        state.withLock { Self.write(&$0) }
    }

    var lineCount: Int { state.withLock { $0.lineCount } }
    var writeError: String? { state.withLock { $0.writeError } }

    func close() {
        state.withLock { state in
            Self.write(&state)
            try? state.handle?.close()
            state.handle = nil
        }
    }

    /// Closes and deletes the temporary log (it is scratch output, not user data, so it skips the Trash).
    func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    /// Copies the log (flushed first) to `destination`. An existing file is replaced only once the copy is
    /// complete, so a failed save leaves it untouched.
    func copy(to destination: URL) throws {
        flush()
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { throw ProfilerLogError.missing }
        guard manager.fileExists(atPath: destination.path) else {
            try manager.copyItem(at: url, to: destination)
            return
        }
        let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(destination.lastPathComponent)
        try manager.copyItem(at: url, to: staged)
        _ = try manager.replaceItemAt(destination, withItemAt: staged)
    }

    private static func write(_ state: inout State) {
        guard !state.buffer.isEmpty, let handle = state.handle else { return }
        do {
            try handle.write(contentsOf: state.buffer)
        } catch {
            state.writeError = error.localizedDescription
        }

        state.buffer.removeAll(keepingCapacity: true)
    }
}
