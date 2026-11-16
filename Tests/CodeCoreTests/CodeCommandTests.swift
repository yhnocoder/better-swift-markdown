import CodeCore
import Testing

/// Which commands can change the text: all but those that move and select, which are what text that cannot change
/// still takes
@Suite struct CodeCommandTests {
  static let motions: [CodeEditor.Motion] = [.character, .group, .lineBoundary, .lineStart, .line, .page, .document]
  static let moves = motions.flatMap { m in
    [false, true].flatMap { forward in
      [false, true].map { CodeCommand.move(m, forward: forward, extend: $0) }
    }
  }

  static let edits: [CodeCommand] = [
    .deleteBackward, .deleteForward, .deleteToLineEnd, .deleteGroup(forward: false), .deleteGroup(forward: true),
    .deleteLineBoundary(forward: false), .deleteLineBoundary(forward: true), .newline, .indent, .outdent,
    .toggleComment, .indentMore, .indentLess, .moveLines(down: false), .moveLines(down: true),
    .copyLines(down: false), .copyLines(down: true), .deleteLines, .splitLine, .transpose, .undo, .redo,
  ]

  static let all = moves + [.selectLine, .selectAll] + edits

  @Test func everyCommandSaysWhetherItChangesTheText() {
    #expect(Self.all.filter { !$0.changesText } == Self.moves + [.selectLine, .selectAll])
    #expect(Self.all.filter(\.changesText) == Self.edits)
    // every key's command is one of these
    #expect(Set(CodeKeys.mac.values).isSubset(of: Set(Self.all)))
  }

  @Test func aCommandThatDoesNotChangeTheTextLeavesItAsItIs() {
    let text = "def f(x):\n\treturn x  # one\n\nlast"
    for c in Self.all where !c.changesText {
      for selection in [CodeSelection(0), CodeSelection(14), CodeSelection(anchor: 4, head: 20)] {
        var e = CodeEditor(text: text, selection: selection)
        e.insert("y")
        let before = e.text
        e.perform(c, in: PlainCodeLayout(before))
        #expect(e.text == before, "\(c)")
      }
    }
  }
}
