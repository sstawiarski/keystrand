import Foundation
import Observation

/// An error from a user-initiated action. AppShell presents each one as an alert.
public struct Toast: Identifiable {
    /// Messages longer than this are cut in the alert, which then offers "Save Full Log…".
    public static let longMessageThreshold = 400

    public var id: String
    public var title: String
    public var message: String?

    public init(id: String = UUID().uuidString, title: String, message: String? = nil) {
        self.id = id
        self.title = title
        self.message = message
    }

    public var hasLongMessage: Bool { (message?.count ?? 0) > Toast.longMessageThreshold }
}

/// Queues errors for one window until the user dismisses them, presenting one alert at a time.
/// Successful actions show their results where the user acted.
@MainActor
@Observable
public final class ToastCenter {
    public private(set) var toasts: [Toast] = []
    /// Sheet-level presenters attached to this queue; only the innermost one presents.
    public let presenters = PresenterDepth()

    public init() {}

    /// Shows an error; an error with an id already shown is dismissed instead of duplicated.
    public func show(_ toast: Toast) {
        if toasts.contains(where: { $0.id == toast.id }) {
            dismiss(id: toast.id)
            return
        }

        toasts.append(toast)
    }

    /// Shows an error. A Redis error reply is explained in a plain sentence with the server's text after it.
    /// Pass the failed action as `title` ("Delete Key Failed"); without one, the title names the error kind.
    public func error(_ message: String, title: String? = nil) {
        show(Self.toast(message: message, title: title))
    }

    public func error(_ error: Error, title: String? = nil) {
        self.error(error.localizedDescription, title: title)
    }

    /// Waits for the current innermost sheet presenter to detach so the remaining presenter shows the error.
    /// Without a sheet, shows the error immediately.
    public func errorAfterSheetCloses(_ error: Error, title: String? = nil) {
        let level = presenters.depth
        guard level > 0 else { return self.error(error, title: title) }
        let toast = Self.toast(message: error.localizedDescription, title: title)
        let presenters = presenters
        Task { [weak self] in
            for await depth in Observations({ presenters.depth }) where depth < level { break }
            self?.show(toast)
        }
    }

    public func dismiss(id: String) {
        toasts.removeAll { $0.id == id }
    }

    /// Dismisses the front error only when it is `id`, so a repeated dismissal of one alert cannot drop the next.
    public func dismissFront(id: Toast.ID?) {
        guard let id, toasts.first?.id == id else { return }
        toasts.removeFirst()
    }

    public func dismissAll() {
        toasts.removeAll()
    }

    nonisolated static func toast(message: String, title: String?) -> Toast {
        let explained = ServerErrorText.explain(message)
        return Toast(title: title ?? explained?.title ?? ServerErrorText.defaultTitle,
                     message: explained?.message ?? message)
    }
}

/// Plain-language text for Redis error replies (`WRONGTYPE …`, `NOPERM …`), keeping the server's text second.
public enum ServerErrorText {
    /// Used only when the caller passes no title and the message is not a known Redis error.
    public static let defaultTitle = "Error"

    /// Error code (the reply's first word) → alert title and explanation.
    static let known: [String: (title: String, sentence: String)] = [
        "WRONGTYPE": ("Wrong Key Type", "The key holds a different data type than this command works with."),
        "NOPERM": ("Permission Denied", "The current user is not allowed to run this command or access this key."),
        "READONLY": ("Read-Only Replica", "This server is a read-only replica, so it does not accept writes."),
        "NOAUTH": ("Authentication Required", "The server requires a password. Edit the database to set the username and password."),
        "ERR": ("Command Failed", "Redis rejected the command."),
        "MOVED": ("Key on Another Node", "The key belongs to another node of the cluster."),
        "LOADING": ("Server Loading", "The server is still loading its data into memory. Try again in a moment."),
        "BUSY": ("Server Busy", "The server is busy running a script or function."),
        "OOM": ("Out of Memory", "The server reached its memory limit (maxmemory) and rejected the command."),
        "MISCONF": ("Writes Disabled", "The server cannot save to disk, so it rejects writes until saving works again."),
    ]

    /// `nil` when `message` does not start with a known Redis error code.
    public static func explain(_ message: String) -> (title: String, message: String)? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = String(trimmed.prefix { !$0.isWhitespace })
        guard let entry = known[code] else { return nil }
        return (entry.title, "\(entry.sentence)\n\nServer reply: \(trimmed)")
    }
}

/// Counts the presenters that sheets attach to an alert queue. The window root presents at depth 0 and each sheet
/// presenter at the depth `push()` returned, so a request shows in the frontmost sheet instead of queuing behind it.
@MainActor
@Observable
public final class PresenterDepth {
    public private(set) var depth = 0

    public init() {}

    public func push() -> Int {
        depth += 1
        return depth
    }

    public func pop() {
        depth = max(0, depth - 1)
    }
}
