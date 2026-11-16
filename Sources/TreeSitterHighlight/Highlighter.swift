import Foundation
import TreeSitterCore

/// The colour classes of code: one per code colour of a theme (the web editor's `--k-*` variables), named after its CSS
/// classes in the comments.
public enum TokenClass: UInt8, Sendable, Hashable, CaseIterable {
  /// `kw`, `--k-kw`. Also C / C++ / CUDA operators and built-in types.
  case keyword
  /// `kw op`: `--k-kw`, or `--nc-op` where operators have a colour of their own.
  case `operator`
  /// `fn`, `--k-fn`: function names, and type names.
  case function
  /// `str`, `--k-str`
  case string
  /// `com`, `--k-com`. Also Python docstrings.
  case comment
  /// `num`, `--k-num`: numbers and constants, and Python decorators (`dec`, drawn in this colour).
  case number
  /// `self`, `--k-self`: self, cls, this.
  case receiver
  /// `p`, `--k-p`
  case punctuation
}

public struct Token: Sendable, Hashable {
  /// UTF-16 columns within the line
  public var columns: Range<Int>
  public var kind: TokenClass

  public init(columns: Range<Int>, kind: TokenClass) {
    self.columns = columns
    self.kind = kind
  }
}

/// Highlights code with tree-sitter. Make one and share it: it holds the compiled queries, and every call parses on its
/// own, so calls may run at the same time on any tasks.
public struct Highlighter: Sendable {
  private let byName: [String: Grammar]

  /// The built-in grammars (Python, Rust, C, C++ and CUDA) and `grammars`, which win for a name both have
  public init(grammars: [Grammar] = []) {
    var all: [String: Grammar] = [:]
    for g in [Grammar.python, .rust, .cuda] + grammars {
      for n in g.names { all[n] = g }
    }
    byName = all
  }

  /// The grammar that colours `language`
  public func grammar(_ language: String) -> Grammar? { byName[language] }

  /// The coloured tokens of each line; text between them is plain. `lines` are all the lines of the piece of code,
  /// hidden ones included: a hidden range can open or close a string. An unknown language gives no tokens.
  public func tokens(lines: [String], language: String) -> [[Token]] {
    guard let grammar = grammar(language) else { return lines.map { _ in [] } }
    let slice = Slice(lines, dedent: grammar.dedent)
    guard let (tree, offset) = bestParse(grammar, slice.text) else { return lines.map { _ in [] } }
    return color(slice, lines.indices, tree, offset, grammar)
  }

  /// The tokens of the slice's lines `wanted`, from the parse of a text that has the slice's from `offset` on: only what
  /// can colour them is looked at
  fileprivate func color(
    _ slice: Slice, _ wanted: Range<Int>, _ tree: SyntaxTree, _ offset: Int, _ grammar: Grammar
  ) -> [[Token]] {
    guard let first = wanted.first.map({ slice.lines[$0] }), let last = wanted.last.map({ slice.lines[$0] }) else {
      return []
    }
    var spans: [Span] = []
    let from = max(0, offset + first.start - 1)
    collect(grammar, tree.root, at: 0, into: &spans, units: from..<(offset + last.start + last.count))
    let classes = paint(spans, count: tree.units.count, in: from..<(offset + last.start + last.count))
    return slice.lines[wanted].map { line in
      let start = offset + line.start
      let indent = line.cut > 0 && start > 0 ? classes[start - 1] : nil
      return runs(Array(repeating: indent, count: line.cut) + classes[start..<start + line.count])
    }
  }

  /// A piece of code is usually cut from the middle of a file, and parsed alone it may start inside a multi-line string or
  /// comment. When the plain parse has errors, try the slice after each opening of one, and keep the parse that places
  /// the most text. Other errors (a slice of statements from a function body) need nothing: the query still colours
  /// the tokens inside ERROR nodes, as the tests check against whole files.
  private func bestParse(_ grammar: Grammar, _ body: [UInt16]) -> (SyntaxTree, Int)? {
    Highlighter.best(grammar, body) { text, _ in grammar.language.parse(text) }
  }

  /// The plain parse when it has no errors, else the one of it and the parses after each opening that places the most
  /// text, with where the body starts in its text; `parse` gives the parse of a text (and the opening's index, -1 for
  /// none)
  fileprivate static func best(
    _ grammar: Grammar, _ body: [UInt16], parse: ([UInt16], Int) -> SyntaxTree?
  ) -> (SyntaxTree, Int)? {
    guard let plain = parse(body, -1) else { return nil }
    guard plain.root.hasError else { return (plain, 0) }
    var best = (plain, 0)
    var cost = plain.errorCost
    for (k, opening) in grammar.openings.enumerated() {
      guard let tree = parse(Array(opening.utf16) + [newline] + body, k) else { continue }
      let c = tree.errorCost
      if c < cost { (best, cost) = ((tree, opening.utf16.count + 1), c) }
    }
    return best
  }
}

/// Highlights one text as it is written: each call parses again only what changed since the one before (tree-sitter's
/// incremental parsing, every parse `Highlighter.tokens` tries kept and edited), and colours only the lines asked
/// for, with the same tokens `Highlighter.tokens` gives them. Calls take turns
public final class HighlightSession: @unchecked Sendable {
  private let highlighter: Highlighter
  private let lock = NSLock()
  /// The grammar of the last call, and a parser of its language
  private var parsing: (grammar: Grammar, parser: Parser)?
  private var body: [UInt16] = []
  /// By opening (-1: none), parsed for `body`
  private var trees: [Int: SyntaxTree] = [:]

  public init(_ highlighter: Highlighter) { self.highlighter = highlighter }

  /// The tokens of `lines[wanted]`
  public func tokens(lines: [String], language: String, wanted: Range<Int>) -> [[Token]] {
    lock.withLock {
      let wanted = wanted.clamped(to: lines.indices)
      guard let g = highlighter.grammar(language) else { return wanted.map { _ in [] } }
      let slice = Slice(lines, dedent: g.dedent)
      let parser: Parser
      if let parsing, parsing.grammar.names == g.names {
        edit(from: body, to: slice.text, openings: g.openings)
        parser = parsing.parser
      } else {
        guard let p = Parser(g.language) else { return wanted.map { _ in [] } }
        (parsing, body, trees) = ((g, p), [], [:])
        parser = p
      }
      body = slice.text
      var kept: [Int: SyntaxTree] = [:]
      let best = Highlighter.best(g, slice.text) { text, k in
        let t = parser.parse(text, old: trees[k])
        kept[k] = t
        return t
      }
      trees = kept
      guard let (tree, offset) = best else { return wanted.map { _ in [] } }
      return highlighter.color(slice, wanted, tree, offset, g)
    }
  }

  /// Every kept parse edited from the old text to the new: what lies between their common start and end
  private func edit(from a: [UInt16], to b: [UInt16], openings: [String]) {
    if a == b { return }
    let e = diffEdit(a, b)
    for (k, tree) in trees {
      // A parse after an opening has the opening and a newline before the body
      let shift = k < 0 ? 0 : openings[k].utf16.count + 1
      func moved(_ p: TreeEdit.Point) -> TreeEdit.Point {
        TreeEdit.Point(row: p.row + (shift > 0 ? 1 : 0), column: p.column)
      }
      tree.edit(
        TreeEdit(
          startIndex: shift + e.startIndex, oldEndIndex: shift + e.oldEndIndex, newEndIndex: shift + e.newEndIndex,
          startPosition: moved(e.startPosition), oldEndPosition: moved(e.oldEndPosition),
          newEndPosition: moved(e.newEndPosition)))
    }
  }
}

private let newline = unit("\n")
private func unit(_ c: Unicode.Scalar) -> UInt16 { UInt16(c.value) }

/// The lines as one UTF-16 text, joined by newlines, with the indent they all share taken off for Python (whose
/// grammar reads an indented first line as an error).
private struct Slice {
  struct Line {
    /// Where the line starts in `text`, how long it is there, and how many leading code units were taken off
    var start: Int, count: Int, cut: Int
  }
  var text: [UInt16] = []
  var lines: [Line] = []

  init(_ source: [String], dedent: Bool) {
    let units = source.map { Array($0.utf16) }
    let blank = { (u: [UInt16]) in u.allSatisfy(isSpace) }
    var common: ArraySlice<UInt16>?
    if dedent {
      for u in units where !blank(u) {
        let ws = u.prefix(while: isSpace)
        common = common.map { $0.prefix(zip($0, ws).prefix { $0 == $1 }.count) } ?? ws
      }
    }
    let shared = common?.count ?? 0
    for (i, u) in units.enumerated() {
      if i > 0 { text.append(newline) }
      let cut = min(shared, u.prefix(while: isSpace).count)
      lines.append(Line(start: text.count, count: u.count - cut, cut: cut))
      text += u[cut...]
    }
  }
}

private func isSpace(_ u: UInt16) -> Bool { u == unit(" ") || u == unit("\t") }

private struct Span {
  var range: Range<Int>
  var kind: TokenClass?
  var pattern: Int
  /// Painted after all others: a construct that is one colour whatever is inside
  var whole = false
}

/// The query's spans over the tree of a text that starts at `base` in the text being painted; `units`: only those that
/// meet these code units of it
private func collect(
  _ grammar: Grammar, _ root: Node, at base: Int, into spans: inout [Span], units: Range<Int>? = nil
) {
  let text = root.units
  grammar.query.forEachMatch(under: root, units: units) { match in
    let pattern = match.pattern
    for capture in match.captures {
      let node = capture.node
      let range = node.range
      func add(_ r: Range<Int>, _ kind: TokenClass?, whole: Bool = false) {
        if !r.isEmpty {
          spans.append(
            Span(range: base + r.lowerBound..<base + r.upperBound, kind: kind, pattern: pattern, whole: whole))
        }
      }
      switch grammar.actions[capture.index] {
      case .paint(let kind): add(range, kind)
      case .callee: if let name = calleeName(node) { add(name.range, .function) }
      case .macro:
        let parent = node.parent?.type
        guard parent == "preproc_def" || parent == "preproc_function_def", !node.text.allSatisfy(\.isWhitespace),
          let tree = grammar.language.parse(Array(text[range]))
        else { break }
        collect(grammar, tree.root, at: base + range.lowerBound, into: &spans)
      case .stringPrefix:
        let letters = text[range].prefix { $0 != unit("\"") && $0 != unit("'") }.count
        add(range.lowerBound..<range.lowerBound + letters, .keyword)
      case .placeholders:
        let prefix = (node.parent?.child(0)?.text ?? "").lowercased()
        guard !prefix.contains("f"), !prefix.contains("r") else { break }
        let s = node.text
        for re in prefix.contains("b") ? [percentPlaceholder] : [percentPlaceholder, bracePlaceholder] {
          for m in re.matches(in: s, range: NSRange(location: 0, length: s.utf16.count)) {
            add(range.lowerBound + m.range.location..<range.lowerBound + m.range.location + m.range.length, .number)
          }
        }
      case .docstring: add(range, .comment, whole: true)
      case .decorator:
        let expression = node.namedChild(0)
        let function = expression?.type == "call" ? expression?.field("function") : nil
        add(range.lowerBound..<(function?.range.upperBound ?? range.upperBound), .number, whole: true)
      }
    }
  }
}

// MagicPython's placeholders (string-formatting, string-brace-formatting), which VS Code colours as constants
private let percentPlaceholder = regex(#"%(\([\w\s]*\))?[- #+0]*(\d+|\*)?(\.(\d+|\*))?[Lhl]?[%EFGXa-giorsux]"#)
private let bracePlaceholder = regex(
  #"\{\{|\}\}|\{\w*(\.[_[:alpha:]]\w*|\[[^\]"']+\])*(![ars])?(:\w?[<=>^]?[- +]?#?\d*,?(\.\d+)?[%EFGXb-gnosx]?)?\}"#)

/// Outer spans first, inner ones over them, equal lengths in pattern order; the last paint of a code unit wins.
private func paint(_ spans: [Span], count: Int, in range: Range<Int>) -> [TokenClass?] {
  var classes = [TokenClass?](repeating: nil, count: count)
  let spans = spans.filter { $0.range.overlaps(range) }
  let ordered = spans.sorted { a, b in
    if a.whole != b.whole { return b.whole }
    if a.range.count != b.range.count { return a.range.count > b.range.count }
    return a.pattern < b.pattern
  }
  for span in ordered {
    for i in span.range.clamped(to: range.clamped(to: 0..<count)) { classes[i] = span.kind }
  }
  return classes
}

private func runs(_ classes: [TokenClass?]) -> [Token] {
  var tokens: [Token] = []
  for (col, kind) in classes.enumerated() {
    guard let kind else { continue }
    if let last = tokens.last, last.kind == kind, last.columns.upperBound == col {
      tokens[tokens.count - 1].columns = last.columns.lowerBound..<col + 1
    } else {
      tokens.append(Token(columns: col..<col + 1, kind: kind))
    }
  }
  return tokens
}
