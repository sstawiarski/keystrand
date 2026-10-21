import AppKit
import SwiftUI
import Testing
@testable import RedisUI

@MainActor
final class TextBox {
    var text: String
    init(_ text: String) { self.text = text }
    var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
}

@MainActor
private func host<V: View>(_ view: V) -> (NSWindow, NSView) {
    _ = NSApplication.shared
    let hosting = NSHostingView(rootView: view.frame(width: 420, height: 220))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    return (window, hosting)
}

@MainActor
private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews {
        if let match = find(type, in: subview) { return match }
    }

    return nil
}

@MainActor
private func key(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                     context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                     keyCode: keyCode)!
}

@Suite("Editor runtime", .serialized)
@MainActor
struct EditorRuntimeTests {
    @Test func typingCompletionAcceptAndSubmit() throws {
        let box = TextBox("GE")
        var submitted = 0
        var requested: [(String, Int)] = []
        let editor = CodeEditorView(text: box.binding, language: .redis, completions: { text, cursor in
            requested.append((text, cursor))
            return [CodeCompletion(label: "GET", insertText: "GET ", detail: "key", kind: .command),
                    CodeCompletion(label: "GETDEL", insertText: "GETDEL ", kind: .command)]
        }, onSubmit: { submitted += 1 })
        let (window, root) = host(editor)
        defer { window.close() }
        let textView = try #require(find(EditorTextView.self, in: root))
        #expect(textView.string == "GE")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.insertText("T", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(box.text == "GET")
        #expect(requested.last?.0 == "GET")
        #expect(requested.last?.1 == 3)
        let coordinator = try #require(textView.coordinator)
        #expect(coordinator.popups.completionModel.items.count == 2)

        coordinator.popups.moveSelection(by: 1)
        textView.keyDown(with: key(36, "\r", window: window))
        #expect(box.text == "GETDEL ")

        textView.keyDown(with: key(36, "\r", .command, window: window))
        #expect(submitted == 1)
        textView.keyDown(with: key(36, "\r", .control, window: window))
        #expect(submitted == 2)
        #expect(box.text == "GETDEL ")
    }

    @Test func escapeSuppressesUntilNextWord() throws {
        let box = TextBox("")
        var calls = 0
        let editor = CodeEditorView(text: box.binding, language: .redis, completions: { _, _ in
            calls += 1
            return [CodeCompletion(label: "SET", insertText: "SET ")]
        })
        let (window, root) = host(editor)
        defer { window.close() }
        let textView = try #require(find(EditorTextView.self, in: root))
        window.makeFirstResponder(textView)
        let coordinator = try #require(textView.coordinator)

        textView.insertText("S", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(calls == 1)
        textView.keyDown(with: key(53, "\u{1b}", window: window))
        #expect(coordinator.completionsSuppressed)
        textView.insertText("E", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(calls == 1)
        textView.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!coordinator.completionsSuppressed)
        textView.insertText("k", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(calls == 2)
        #expect(box.text == "SE k")
    }

    @Test func autoCloseAndOvertype() throws {
        let box = TextBox("")
        let (window, root) = host(CodeEditorView(text: box.binding, language: .json))
        defer { window.close() }
        let textView = try #require(find(EditorTextView.self, in: root))
        window.makeFirstResponder(textView)
        for char in ["{", "\"", "a", "\""] {
            textView.insertText(char, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(box.text == "{\"a\"}")
        #expect(textView.selectedRange().location == 4)
        textView.insertText("}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(box.text == "{\"a\"}")
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(box.text == "{[\"a\"}")
        textView.deleteBackward(nil)
        #expect(box.text == "{\"a\"}")
    }

    @Test func historyHooksOnlyOnEdgeLines() throws {
        let box = TextBox("SET a\nGET a")
        var ups = 0
        var downs = 0
        let editor = CodeEditorView(text: box.binding, language: .redis, onHistoryUp: { ups += 1; return true },
                                    onHistoryDown: { downs += 1; return true })
        let (window, root) = host(editor)
        defer { window.close() }
        let textView = try #require(find(EditorTextView.self, in: root))
        window.makeFirstResponder(textView)

        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.keyDown(with: key(125, "\u{F701}", window: window))
        #expect(downs == 1)
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.keyDown(with: key(126, "\u{F700}", window: window))
        #expect(ups == 0)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.keyDown(with: key(125, "\u{F701}", window: window))
        #expect(downs == 1)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.keyDown(with: key(126, "\u{F700}", window: window))
        #expect(ups == 1)
    }

    @Test func controllerInsertAndProgrammaticText() throws {
        let box = TextBox("GET ")
        let controller = CodeEditorController()
        let (window, root) = host(CodeEditorView(text: box.binding, language: .redis, controller: controller))
        defer { window.close() }
        let textView = try #require(find(EditorTextView.self, in: root))
        #expect(controller.isAttached)
        controller.focus()
        controller.moveCaretToEnd()
        controller.insert("key")
        #expect(box.text == "GET key")
        controller.replaceAll(with: "PING")
        #expect(box.text == "PING")
        #expect(textView.string == "PING")
    }

    @Test func rulerTracksLines() throws {
        let box = TextBox("SET a b\n  EX 1\nGET a")
        let (window, root) = host(CodeEditorView(text: box.binding, language: .redis, showsCommandMarkers: true))
        defer { window.close() }
        let ruler = try #require(find(LineNumberRulerView.self, in: root) ?? find(EditorTextView.self, in: root)?
            .enclosingScrollView?.verticalRulerView as? LineNumberRulerView)
        #expect(ruler.lineStarts == [0, 8, 15])
        #expect(ruler.commandLines == [0, 2])
        #expect(ruler.ruleThickness > 20)
    }

    @Test func lineBreakingControlActionsBecomeWhitespace() {
        #expect(EditorLayoutManager.safeAction(for: .lineBreak) == .whitespace)
        #expect(EditorLayoutManager.safeAction(for: [.containerBreak, .lineBreak]) == .whitespace)
        #expect(EditorLayoutManager.safeAction(for: .containerBreak) == .whitespace)
        #expect(EditorLayoutManager.safeAction(for: [.lineBreak, .paragraphBreak]) == [.lineBreak, .paragraphBreak])
        #expect(EditorLayoutManager.safeAction(for: .horizontalTab) == .horizontalTab)
        #expect(EditorLayoutManager.safeAction(for: .zeroAdvancement) == .zeroAdvancement)
    }

    @Test func lineBreakingControlBeforeMarkSurvivesResize() throws {
        let (window, root) = host(CodeEditorView(text: .constant("\u{0B}\u{065C}\n\u{0C}\u{0301}"), isEditable: false,
                                                 showsLineNumbers: false))
        defer { window.close() }
        let textView = try #require(find(EditorTextView.self, in: root))
        let scrollView = try #require(textView.enclosingScrollView)
        for width in [400.0, 390, 380] {
            scrollView.setFrameSize(NSSize(width: width, height: scrollView.frame.height))
        }

        #expect(textView.layoutManager?.numberOfGlyphs == 5)
    }

    @Test func readOnlyTextOpensAtStart() throws {
        let (window, root) = host(CodeEditorView(text: .constant("first\nsecond"), isEditable: false))
        defer { window.close() }
        let textView = try #require(find(EditorTextView.self, in: root))
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
        try #require(textView.coordinator).setTextProgrammatically(String(repeating: "line\n", count: 50))
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func editableTextKeepsCaretAtEnd() throws {
        let (window, root) = host(CodeEditorView(text: .constant("GET key")))
        defer { window.close() }
        let textView = try #require(find(EditorTextView.self, in: root))
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
    }
}

@Suite("Command line field runtime", .serialized)
@MainActor
struct CommandLineFieldRuntimeTests {
    @Test func commandsRouteToCallbacks() throws {
        let box = TextBox("ge")
        var submitted: [String] = []
        var cleared = 0
        var escaped = 0
        let field = CommandLineField(text: box.binding, onSubmit: { submitted.append($0) },
                                     onHistoryUp: { "GET older" }, onHistoryDown: { nil },
                                     onTab: { backwards in backwards ? "GEO" : "GET" },
                                     onEscape: { escaped += 1 }, onClear: { cleared += 1 })
        let (window, root) = host(field)
        defer { window.close() }
        let textField = try #require(find(CommandLineTextField.self, in: root))
        window.makeFirstResponder(textField)
        let editor = try #require(textField.currentEditor() as? NSTextView)
        let coordinator = try #require(textField.coordinator)

        #expect(coordinator.control(textField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(box.text == "GET")
        #expect(coordinator.control(textField, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(box.text == "GEO")
        #expect(coordinator.control(textField, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(box.text == "GET older")
        #expect(coordinator.control(textField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(box.text == "GET older")
        #expect(coordinator.control(textField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submitted == ["GET older"])
        #expect(coordinator.control(textField, textView: editor, doCommandBy: #selector(NSResponder.centerSelectionInVisibleArea(_:))))
        #expect(cleared == 1)
        #expect(coordinator.control(textField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(escaped == 1)
        #expect(!coordinator.control(textField, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    }
}

struct RowItem: Identifiable {
    let id = UUID()
}

@Suite("View construction smoke")
@MainActor
struct ViewSmokeTests {
    @Test func componentsBuildBodies() {
        let box = TextBox("")
        let model = JSONTreeModel(value: .object([JSONMember(key: "a", value: .number("1"))]))
        let views: [AnyView] = [
            AnyView(JSONTreeView(value: .array([.null]))),
            AnyView(JSONTreeView(model: model, actions: JSONTreeActions(setValue: { _, _ in }), keyName: "k")),
            AnyView(SearchField(text: box.binding, debounce: .milliseconds(300), onDebouncedChange: { _ in })),
            AnyView(CopyButton(text: "x")),
            AnyView(TTLText(ttl: 30)),
            AnyView(MarkdownView(markdown: "# Hi\n- a\n```redis\nGET a\n```")),
            AnyView(DonutChartView(slices: [DonutSlice(label: "Hash", value: 3, color: .red), DonutSlice(label: "Set", value: 1)],
                                   centerTitle: "Keys", centerValue: "3")),
            AnyView(BarChartView(bars: [BarDatum(label: "<1 hr", value: 10)])),
            AnyView(CommandGroupBadge(group: "sorted-set")),
            AnyView(Text("root").appAppearance(.system)),
            AnyView(KeyTypeIcon(type: .hash, size: .large)),
            AnyView(KeyTypeLabel(type: .stream)),
            AnyView(EnvironmentLabel(environment: .production)),
            AnyView(EnvironmentLabel(environment: .development, style: .iconOnly)),
            AnyView(TagText(tags: [DatabaseTag(key: "team", value: "core")])),
            AnyView(ModuleSummaryText(modules: [RedisModuleInfo(name: "search")])),
            AnyView(KeyMetadataRow(items: [KeyMetadataItem(label: "Type", value: "Hash"), KeyMetadataItem(label: "TTL", value: "No limit")])),
            AnyView(ErrorStateView(message: "Boom") {}),
            AnyView(InlineMessage("Careful", kind: .warning)),
            AnyView(StatusBar { Text("12 keys") } accessory: { Button("Scan More") {} }),
            AnyView(LoadMoreRow(isLoading: true) {}),
            AnyView(SheetForm(title: "New Key", primaryTitle: "Add Key", errorMessage: "Name exists", onCancel: {}, onPrimary: {}) {
                Form { TextField("Name", text: box.binding) }.formStyle(.grouped)
            } leadingActions: { Button("Test") {} }),
            AnyView(SheetForm(title: "Add Database", primaryTitle: "Add Database",
                              successMessage: "Connection is successful.", onCancel: {}, onPrimary: {}) {
                Text("x")
            } leadingActions: { Button("Test Connection") {} } trailingActions: { Button("Connection Settings…") {} }),
            AnyView(SheetForm(title: "Done", primaryTitle: "Done", isDestructive: true, cancelTitle: nil,
                              onCancel: {}, onPrimary: {}) { Text("x") }),
            AnyView(SearchField(text: box.binding, onMoveSelection: { _ in })),
            AnyView(FilePickerRow(fileURL: .constant(nil))),
            AnyView(JumpToLatestButton {}),
            AnyView(AutoRefreshMenu(postfix: "keys", lastRefresh: .now) {}.environment(AppServices.preview().settings)),
            AnyView(Text("x").productionConfirmations(ConfirmationCenter())),
            AnyView(Text("x").destructiveConfirmation("Delete “a”?", isPresented: .constant(false)) {}),
            AnyView(KeySubheaderBar { Text("a") } trailing: { AddItemsButton("Add Fields") {} }),
            AnyView(ValueFormatPicker(selection: .constant(.unicode), compact: true)),
            AnyView(MultiRowFormList(rows: .constant([RowItem()]), makeRow: { RowItem() }) { _ in Text("row") }),
        ]
        for view in views {
            let (window, _) = host(view)
            window.close()
        }
    }
}
