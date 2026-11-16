import AppKit
import CodeCore
import CodeUI
import Testing

/// What reaches the responder after the view: the keys it passes on
private final class Keys: NSResponder {
  var got: [UInt16] = []
  override func keyDown(with e: NSEvent) { got.append(e.keyCode) }
}

/// Code that is only read: nothing the user does changes it, selecting, copying and finding still work, and the keys it
/// does not use go on to its host
extension CodeEditorViewTests {
  fileprivate func reader(_ text: String) -> (CodeEditorView, Keys) {
    let v = CodeEditorView(text: text, look: look(), editable: false)
    v.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
    let next = Keys()
    v.nextResponder = next
    return (v, next)
  }

  /// A pasteboard of the test's own
  func ownPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("code-tests-\(UUID().uuidString)"))
  }

  @Test func readOnlyNothingTheUserDoesChangesTheText() {
    let (v, next) = reader("alpha\nbeta")
    var said: [String] = []
    v.onChange = { said.append($0) }
    let none = NSRange(location: NSNotFound, length: 0)
    v.insertText("x", replacementRange: none)
    v.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
    #expect(!v.hasMarkedText() && v.inputContext == nil)
    // ⌫, ↩, ⇥, ⌥↑, ⇧⌘K, ⌘Z, ⌘X, ⌘V and a letter: all passed on
    let keys = [
      key(51, "\u{7f}"), key(36, "\r"), key(48, "\t"), key(126, "", .option), key(40, "k", [.command, .shift]),
      key(6, "z", .command), key(7, "x", .command), key(9, "v", .command), key(0, "a"),
    ]
    v.keyDown(with: key(0, "a", .command))
    for k in keys { v.keyDown(with: k) }
    #expect(next.got == keys.map(\.keyCode))
    let pb = ownPasteboard()
    pb.clearContents()
    pb.setString("pasted", forType: .string)
    v.pasteboard = pb
    v.cut(nil)
    v.paste(nil)
    v.undo(nil)
    v.redo(nil)
    for c in [CodeCommand.deleteLines, .newline, .indent, .toggleComment, .moveLines(down: true), .deleteBackward] {
      v.perform(c)
    }
    v.findLook = FindBar.Look(fill: CGColor(gray: 1, alpha: 1), line: CGColor(gray: 0.5, alpha: 1), radius: 6)
    v.keyDown(with: key(3, "f", .command))
    v.findBar?.query.stringValue = "a"
    v.findBar?.replacement.stringValue = "b"
    v.replaceFound(all: true)
    v.findBar?.perform(.replaceAll)
    #expect(v.editor.text == "alpha\nbeta" && said.isEmpty)
    #expect(pb.string(forType: .string) == "pasted")
  }

  @Test func readOnlyTheMouseShiftKeysAndCopySelect() {
    let (v, next) = reader("alpha beta\ngamma")
    #expect(v.editor.selection == CodeSelection(0))
    let row = v.layout.placed(0)
    let p = CGPoint(x: v.layout.caret(7, assoc: 1).minX + 1, y: row.y + row.height / 2)
    v.mouseDown(with: click(v, at: p, count: 2))
    #expect(v.editor.selection == CodeSelection(anchor: 6, head: 10))
    v.keyDown(with: key(124, "", .shift))
    #expect(v.editor.selection == CodeSelection(anchor: 6, head: 11))
    let pb = ownPasteboard()
    v.pasteboard = pb
    v.copy(nil)
    #expect(pb.string(forType: .string) == "beta\n")
    // a plain move is the host's
    v.keyDown(with: key(125, ""))
    #expect(next.got == [125] && v.editor.selection == CodeSelection(anchor: 6, head: 11))
    v.keyDown(with: key(0, "a", .command))
    #expect(v.editor.selection == CodeSelection(anchor: 0, head: 16))
    v.keyDown(with: key(8, "c", .command))
    #expect(pb.string(forType: .string) == "alpha beta\ngamma")
    // a click places the caret, as in text that can change
    v.mouseDown(with: click(v, at: p, count: 1))
    #expect(v.editor.selection == CodeSelection(7))
    var exited = false
    v.onExit = { exited = true }
    v.keyDown(with: key(53, "\u{1b}"))
    #expect(exited)
  }

  /// No caret and no background behind its line: the same picture as a look without one
  @Test func readOnlyDrawsNoCurrentLine() {
    let text = "def f(x):\n\treturn x + 1\n"
    var l = look()
    l.currentLine = CGColor(red: 1, green: 0.9, blue: 0.5, alpha: 1)
    func drawn(_ look: CodeEditorView.Look, editable: Bool) -> Data {
      let v = CodeEditorView(text: text, look: look, editable: editable)
      v.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
      return pixels(v)
    }
    #expect(drawn(l, editable: false) == drawn(look(), editable: false))
    // editable, the line is drawn
    #expect(drawn(l, editable: true) != drawn(look(), editable: true))
  }

  @Test func readOnlyFindsButDoesNotReplace() throws {
    let (v, _) = reader("one two one")
    v.findLook = FindBar.Look(fill: CGColor(gray: 1, alpha: 1), line: CGColor(gray: 0.5, alpha: 1), radius: 6)
    // ⌘H opens it without the replacement
    v.keyDown(with: key(4, "h", .command))
    let bar = try #require(v.findBar)
    #expect(!bar.isHidden && !bar.replacing && !bar.canReplace)
    bar.setReplacing(true)
    bar.perform(.toggleReplace)
    #expect(!bar.replacing)
    bar.query.stringValue = "one"
    v.findNext(forward: true)
    #expect(v.editor.selection == CodeSelection(anchor: 0, head: 3))
    v.findNext(forward: true)
    #expect(v.editor.selection == CodeSelection(anchor: 8, head: 11))
    bar.replacement.stringValue = "two"
    bar.perform(.replace)
    v.replaceFound(all: false)
    #expect(v.editor.text == "one two one")
    // editable again: the bar can replace
    v.isEditable = true
    #expect(bar.canReplace)
    v.replaceFound(all: true)
    #expect(v.editor.text == "two two two")
  }

  @Test func readOnlyMenusOfferCopyOnly() {
    let (v, _) = reader("alpha")
    func valid(_ action: Selector) -> Bool {
      v.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }
    let actions = [
      #selector(CodeEditorView.cut(_:)), #selector(CodeEditorView.copy(_:)), #selector(CodeEditorView.paste(_:)),
      #selector(CodeEditorView.undo(_:)), #selector(CodeEditorView.redo(_:)),
    ]
    #expect(actions.map(valid) == [false, false, false, false, false])
    v.selectAll(nil)
    #expect(actions.map(valid) == [false, true, false, false, false])
    v.isEditable = true
    #expect(actions.map(valid) == [true, true, true, false, false])
    v.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(actions.map(valid) == [false, false, true, true, false])
  }
}
