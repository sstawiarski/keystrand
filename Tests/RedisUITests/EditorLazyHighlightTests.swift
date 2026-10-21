import AppKit
import SwiftUI
import Testing
@testable import RedisUI

@Suite("Editor lazy highlighting", .serialized)
@MainActor
struct EditorLazyHighlightTests {
    private func hostEditor(_ text: String) throws -> (NSWindow, EditorTextView) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: CodeEditorView(text: .constant(text), language: .json, isEditable: false)
            .frame(width: 420, height: 220))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, try #require(Self.find(in: hosting)))
    }

    private static func find(in view: NSView) -> EditorTextView? {
        if let match = view as? EditorTextView { return match }
        return view.subviews.lazy.compactMap { find(in: $0) }.first
    }

    private func color(at index: Int, in textView: NSTextView) -> Any? {
        textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil)
    }

    @Test func firstTokenSearchFindsTheTokenCoveringALocation() {
        let tokens = [0, 10, 20].map { SyntaxToken(kind: .string, range: NSRange(location: $0, length: 5)) }
        #expect(CodeEditorView.Coordinator.firstToken(endingAfter: 0, in: tokens) == 0)
        #expect(CodeEditorView.Coordinator.firstToken(endingAfter: 5, in: tokens) == 1)
        #expect(CodeEditorView.Coordinator.firstToken(endingAfter: 12, in: tokens) == 1)
        #expect(CodeEditorView.Coordinator.firstToken(endingAfter: 30, in: tokens) == 3)
    }

    @Test func largeDocumentColorsOnlyTheVisibleText() async throws {
        let lines = (0..<4_000).map { "  \"value number \($0)\"," }
        let text = "[\n" + lines.joined(separator: "\n") + "\n  0\n]"
        #expect((text as NSString).length > CodeEditorView.Coordinator.lazyHighlightLength)
        let (window, textView) = try hostEditor(text)
        defer { window.close() }
        for _ in 0..<200 where color(at: 4, in: textView) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(color(at: 4, in: textView) != nil)
        #expect(color(at: (text as NSString).length - 3, in: textView) == nil)
    }

    @Test func smallDocumentColorsEverythingAtOnce() throws {
        let (window, textView) = try hostEditor("[\"a\", 1]")
        defer { window.close() }
        #expect(color(at: 1, in: textView) != nil)
        #expect(color(at: 6, in: textView) != nil)
    }
}
