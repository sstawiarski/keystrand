import AppKit

/// TextKit 1 layout manager for editors and terminal output. Control characters that break a line or container
/// without ending a paragraph (vertical tab, form feed) lay out as whitespace, because TextKit 1 layout never
/// finishes when a combining mark, joiner, or variation selector follows one of them.
public final class EditorLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override public init() {
        super.init()
        delegate = self
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    public func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: ControlCharacterAction,
                              forControlCharacterAt charIndex: Int) -> ControlCharacterAction {
        Self.safeAction(for: action)
    }

    static func safeAction(for action: ControlCharacterAction) -> ControlCharacterAction {
        let breaks = !action.isDisjoint(with: [.lineBreak, .containerBreak])
        return breaks && !action.contains(.paragraphBreak) ? .whitespace : action
    }
}
