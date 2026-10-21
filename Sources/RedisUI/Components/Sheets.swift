import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet size classes.
public enum SheetSize: Sendable {
    /// One to four fields: width 460, fitted.
    case small
    /// Forms: width 580, min height 420.
    case form
    /// Lists and tables: page sizing, min 820×560.
    case large
}

private struct SheetSizeModifier: ViewModifier {
    let size: SheetSize

    func body(content: Content) -> some View {
        switch size {
        case .small:
            content.frame(width: 460).presentationSizing(.fitted)
        case .form:
            content.frame(width: 580).frame(minHeight: 420).presentationSizing(.form)
        case .large:
            content.frame(minWidth: 820, minHeight: 560).presentationSizing(.page)
        }
    }
}

public extension View {
    /// Applies the width and presentation sizing of a sheet size class.
    func sheetSize(_ size: SheetSize) -> some View {
        modifier(SheetSizeModifier(size: size))
    }
}

/// Sheet chrome: a title row, the content (usually a grouped `Form`), an optional inline error or success message
/// (the error wins) and a footer with
/// leading actions, flexible space, Cancel, trailing actions and the primary button. The primary button is the default
/// action unless it is destructive, in which case Cancel is; Esc always calls `onCancel`. A nil `cancelTitle` leaves out
/// Cancel (result and progress pages with a single "Done" or "Stop"); Esc then works only while `isWorking` is false.
public struct SheetForm<Content: View, Leading: View, Trailing: View>: View {
    private let title: String
    private let primaryTitle: String
    private let isPrimaryDisabled: Bool
    private let isWorking: Bool
    private let isDestructive: Bool
    private let cancelTitle: String?
    private let errorMessage: String?
    private let successMessage: String?
    private let onCancel: @MainActor () -> Void
    private let onPrimary: @MainActor () -> Void
    private let content: Content
    private let leadingActions: Leading
    private let trailingActions: Trailing

    public init(title: String, primaryTitle: String, isPrimaryDisabled: Bool = false, isWorking: Bool = false,
                isDestructive: Bool = false, cancelTitle: String? = "Cancel", errorMessage: String? = nil,
                successMessage: String? = nil, onCancel: @escaping @MainActor () -> Void,
                onPrimary: @escaping @MainActor () -> Void, @ViewBuilder content: () -> Content,
                @ViewBuilder leadingActions: () -> Leading, @ViewBuilder trailingActions: () -> Trailing) {
        self.title = title
        self.primaryTitle = primaryTitle
        self.isPrimaryDisabled = isPrimaryDisabled
        self.isWorking = isWorking
        self.isDestructive = isDestructive
        self.cancelTitle = cancelTitle
        self.errorMessage = errorMessage
        self.successMessage = successMessage
        self.onCancel = onCancel
        self.onPrimary = onPrimary
        self.content = content()
        self.leadingActions = leadingActions()
        self.trailingActions = trailingActions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            content
                .disabled(isWorking)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let message = footerMessage {
                InlineMessage(message.text, kind: message.kind)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                leadingActions
                Spacer(minLength: 8)
                if let cancelTitle {
                    Button(cancelTitle, role: .cancel) { onCancel() }
                        .keyboardShortcut(isDestructive ? .defaultAction : .cancelAction)
                }

                trailingActions
                Button(role: isDestructive ? .destructive : nil) { onPrimary() } label: {
                    HStack(spacing: 6) {
                        Text(primaryTitle)
                        if isWorking { ProgressView().controlSize(.small) }
                    }
                }
                .keyboardShortcut(isDestructive ? nil : .defaultAction)
                .disabled(isPrimaryDisabled || isWorking)
            }
            .padding(20)
            .background { escapeCancels }
        }
    }

    private var footerMessage: (text: String, kind: InlineMessage.Kind)? {
        if let errorMessage, !errorMessage.isEmpty { return (errorMessage, .error) }
        if let successMessage, !successMessage.isEmpty { return (successMessage, .success) }
        return nil
    }

    /// Esc needs its own key equivalent when Cancel carries the default action (destructive sheets) or when there is
    /// no Cancel button (result pages, which Esc closes like their "Done" button unless work is running).
    @ViewBuilder
    private var escapeCancels: some View {
        if cancelTitle == nil || isDestructive {
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(cancelTitle == nil && isWorking)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

public extension SheetForm where Trailing == EmptyView {
    init(title: String, primaryTitle: String, isPrimaryDisabled: Bool = false, isWorking: Bool = false,
         isDestructive: Bool = false, cancelTitle: String? = "Cancel", errorMessage: String? = nil,
         successMessage: String? = nil, onCancel: @escaping @MainActor () -> Void,
         onPrimary: @escaping @MainActor () -> Void, @ViewBuilder content: () -> Content,
         @ViewBuilder leadingActions: () -> Leading) {
        self.init(title: title, primaryTitle: primaryTitle, isPrimaryDisabled: isPrimaryDisabled, isWorking: isWorking,
                  isDestructive: isDestructive, cancelTitle: cancelTitle, errorMessage: errorMessage,
                  successMessage: successMessage, onCancel: onCancel, onPrimary: onPrimary, content: content,
                  leadingActions: leadingActions, trailingActions: { EmptyView() })
    }
}

public extension SheetForm where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, primaryTitle: String, isPrimaryDisabled: Bool = false, isWorking: Bool = false,
         isDestructive: Bool = false, cancelTitle: String? = "Cancel", errorMessage: String? = nil,
         successMessage: String? = nil, onCancel: @escaping @MainActor () -> Void,
         onPrimary: @escaping @MainActor () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, primaryTitle: primaryTitle, isPrimaryDisabled: isPrimaryDisabled, isWorking: isWorking,
                  isDestructive: isDestructive, cancelTitle: cancelTitle, errorMessage: errorMessage,
                  successMessage: successMessage, onCancel: onCancel, onPrimary: onPrimary, content: content, leadingActions: { EmptyView() },
                  trailingActions: { EmptyView() })
    }
}

enum FileSelectionRules {
    /// An error message for the file's size and type, or nil when the file is acceptable.
    static func validate(fileSize: Int?, pathExtension: String, allowedTypes: [UTType], maxFileSize: Int?) -> String? {
        if let maxFileSize, let fileSize, fileSize > maxFileSize {
            return "File should not exceed \(ByteFormatter.format(Double(maxFileSize), decimals: 0))."
        }

        if !allowedTypes.contains(.item), !allowedTypes.isEmpty {
            guard let type = UTType(filenameExtension: pathExtension),
                  allowedTypes.contains(where: { type.conforms(to: $0) }) else { return "This file type is not supported." }
        }

        return nil
    }
}

/// "Choose File…" button with the chosen file's name and size; also accepts a dropped file.
public struct FilePickerRow: View {
    @Binding public var fileURL: URL?
    public var allowedTypes: [UTType]
    public var prompt: String
    public var maxFileSize: Int?
    var placeholder: String
    @State private var error: String?

    public init(fileURL: Binding<URL?>, allowedTypes: [UTType] = [.item], prompt: String = "Choose File…",
                maxFileSize: Int? = nil) {
        self.init(fileURL: fileURL, allowedTypes: allowedTypes, prompt: prompt, maxFileSize: maxFileSize,
                  placeholder: "No file chosen")
    }

    init(fileURL: Binding<URL?>, allowedTypes: [UTType], prompt: String, maxFileSize: Int?, placeholder: String) {
        self._fileURL = fileURL
        self.allowedTypes = allowedTypes
        self.prompt = prompt
        self.maxFileSize = maxFileSize
        self.placeholder = placeholder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(prompt) { browse() }
                if let fileURL {
                    Label(fileURL.lastPathComponent, systemImage: "doc")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = Self.fileSize(fileURL) {
                        Text(ByteFormatter.format(Double(size), decimals: 1))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Button { self.fileURL = nil } label: { Label("Remove File", systemImage: "xmark.circle.fill") }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove File")
                } else {
                    Text(placeholder).foregroundStyle(.secondary).lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            if let error {
                InlineMessage(error, kind: .error)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            accept(url)
            return true
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedTypes
        if panel.runModal() == .OK, let url = panel.url { accept(url) }
    }

    private func accept(_ url: URL) {
        error = FileSelectionRules.validate(fileSize: Self.fileSize(url), pathExtension: url.pathExtension,
                                            allowedTypes: allowedTypes, maxFileSize: maxFileSize)
        if error == nil { fileURL = url }
    }
}

/// Floating glass button that scrolls a live log to its end (Profiler, CLI, Pub/Sub). Place it with
/// `.overlay(alignment: .bottomTrailing)`; it pads itself by 12.
public struct JumpToLatestButton: View {
    private let action: @MainActor () -> Void

    public init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    public var body: some View {
        GlassEffectContainer {
            Button { action() } label: { Label("Jump to Latest", systemImage: "arrow.down.to.line") }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .help("Jump to Latest")
        }
        .padding(12)
    }
}
