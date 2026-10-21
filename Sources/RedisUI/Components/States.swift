import SwiftUI

/// Failed content: an exclamation triangle, the message and an optional "Try Again" action.
public struct ErrorStateView: View {
    public var title: String
    public var message: String
    public var retryTitle: String
    public var retry: (@MainActor () -> Void)?

    public init(title: String = "Unable to Load", message: String, retryTitle: String = "Try Again",
                retry: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        } actions: {
            if let retry { Button(retryTitle) { retry() } }
        }
    }
}

/// Background-free inline message: a tinted symbol and callout text.
public struct InlineMessage: View {
    public enum Kind: Sendable {
        case info, success, warning, error

        public var symbolName: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }

        public var tint: Color {
            switch self {
            case .info: return .blue
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            }
        }
    }

    public var text: String
    public var kind: Kind

    public init(_ text: String, kind: Kind = .info) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: kind.symbolName).foregroundStyle(kind.tint)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Finder-style status bar: 22 pt, footnote, secondary; content leading, accessory trailing.
public struct StatusBar<Content: View, Accessory: View>: View {
    private let content: Content
    private let accessory: Accessory

    public init(@ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.content = content()
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: 8) {
            content
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            accessory
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 22)
    }
}

public extension StatusBar where Accessory == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, accessory: { EmptyView() })
    }
}

/// Last row of a cursor-paged list: a small spinner while loading, otherwise a borderless button. Also calls
/// `action` when the row appears and `loadsAutomatically` is true.
public struct LoadMoreRow: View {
    public var title: String
    public var isLoading: Bool
    public var loadsAutomatically: Bool
    public let action: @MainActor () -> Void

    public init(title: String = "Load More", isLoading: Bool, loadsAutomatically: Bool = true,
                action: @escaping @MainActor () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.loadsAutomatically = loadsAutomatically
        self.action = action
    }

    public var body: some View {
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button(title) { action() }.buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear {
            if Self.shouldLoadOnAppear(isLoading: isLoading, loadsAutomatically: loadsAutomatically) { action() }
        }
    }

    nonisolated static func shouldLoadOnAppear(isLoading: Bool, loadsAutomatically: Bool) -> Bool {
        loadsAutomatically && !isLoading
    }
}
