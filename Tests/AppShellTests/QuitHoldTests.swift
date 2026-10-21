import AppKit
@testable import AppShell
import Testing

@MainActor
struct QuitHoldTests {
    private func keyDown(_ characters: String, _ modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: isRepeat, keyCode: 12)
    }

    @Test func matchesCommandQOnly() {
        #expect(QuitShortcut.matches(modifiers: .command, characters: "q"))
        #expect(QuitShortcut.matches(modifiers: [.command, .shift], characters: "Q"))
        #expect(QuitShortcut.matches(modifiers: [.command, .option], characters: "q"))
        #expect(!QuitShortcut.matches(modifiers: [], characters: "q"))
        #expect(!QuitShortcut.matches(modifiers: .command, characters: "w"))
        #expect(!QuitShortcut.matches(modifiers: .command, characters: nil))
    }

    @Test func quitsAtOnceWhenOffOrNotAKeyPress() {
        let controller = QuitHoldController.shared
        #expect(!controller.shouldDefer(keyDown("q", .command), isEnabled: false))
        #expect(!controller.shouldDefer(keyDown("q", .command, isRepeat: true), isEnabled: true))
        #expect(!controller.shouldDefer(keyDown("w", .command), isEnabled: true))
        #expect(!controller.shouldDefer(nil, isEnabled: true))
    }
}
