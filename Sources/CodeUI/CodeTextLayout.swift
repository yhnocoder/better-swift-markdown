import CodeCore
import CoreGraphics
import CoreText
import Foundation

/// A whole text laid out as CodeLines lays code out (tabs to their stops, long lines wrapped by their characters' widths, room inserted after lines), with
/// what an editor asks of it: where each offset is drawn, which offset a point is at, the rows of a range. x is in the
/// context the code is drawn into, the code starting at `x`; each row's glyphs are measured as CodeDraw draws them.
/// Only an index is made at first, in one pass over the text (each line's start, how many rows it takes, where each row
/// is); a line's rows, their text and glyphs are made when asked for and kept for a while, so that a text of any length
/// costs about what is drawn of it
public struct CodeTextLayout: CodeLayout {
  /// Where the code starts across
  public let x: CGFloat
  public var pageRows: Int = 20

  /// A line row: its offsets, and at the start of each character in it the offset and where it is in the row's text
  struct Row {
    var range: ClosedRange<Int>
    /// `tab`: the columns a tab takes to its stop (0: not a tab)
    var stops: [(src: Int, u16: Int, tab: Int)]
  }

  /// A line's rows as CodeLines makes them, and their offsets
  struct Line {
    var kinds: [CodeLines.Kind]
    var rows: [Row]
  }

  let text: String
  let style: CodeStyle
  let metrics: CodeLineMetrics
  let wrapWidth: CGFloat?
  let firstNumber: Int
  let top: CGFloat
  let insertions: [CodeLines.Insertion]
  let runs: [[CodeRun]]
  let index: CodeTextIndex
  private let cache = Cache()

  /// Lines (and rows' glyphs) kept at most: past it they are all let go and made again as they are asked for
  static let kept = 4096

  final class Cache {
    var lines: [Int: Line] = [:]
    var glyphs: [Int: CTLine] = [:]
    var whole: CodeLines?
    var lineRows: [CodeLines.Row]?
  }

  /// `runs`: each line's (CodeLines'); `insertions`: room after lines, as CodeLines.insert takes them
  public init(
    text: String, firstNumber: Int = 1, runs: [[CodeRun]] = [], wrapWidth: CGFloat? = nil,
    insertions: [CodeLines.Insertion] = [], top: CGFloat = 0, x: CGFloat, metrics m: CodeLineMetrics, style: CodeStyle
  ) {
    var text = text
    index = text.withUTF8 { bytes in
      CodeTextIndex(
        bytes, firstNumber: firstNumber, insertions: insertions.map { ($0.afterLine, $0.height) }, top: top,
        rowHeight: m.row,
        wrap: wrapWidth.map { CodeTextIndex.Wrap(width: $0, charWidth: m.charWidth, tabWidth: m.tabWidth) }
      ) { line, columns in
        // the widths CodeLines cuts the line by
        let widths =
          columns.map { Array(repeating: m.charWidth, count: $0) }
          ?? CodeLines.expand(String(decoding: line, as: UTF8.self), [], tabWidth: m.tabWidth).map {
            CodeLines.advance($0.char, m)
          }
        return CodeLines.cuts(widths, width: wrapWidth ?? .infinity).count
      }
    }
    self.text = text
    self.x = x
    self.style = style
    metrics = m
    self.wrapWidth = wrapWidth
    self.firstNumber = firstNumber
    self.top = top
    self.insertions = insertions
    self.runs = runs
  }

  private init(_ l: CodeTextLayout, runs: [[CodeRun]]) {
    text = l.text
    x = l.x
    pageRows = l.pageRows
    style = l.style
    metrics = l.metrics
    wrapWidth = l.wrapWidth
    firstNumber = l.firstNumber
    top = l.top
    insertions = l.insertions
    index = l.index
    self.runs = runs
  }

  /// The same rows in other colours: nothing measured again (a row is cut by the code font's widths, whatever its
  /// colours), every line's text and glyphs made anew as they are asked for
  public func recolored(_ runs: [[CodeRun]]) -> CodeTextLayout { CodeTextLayout(self, runs: runs) }

  // MARK: The whole text

  /// The whole text's rows as CodeLines lays them out, the room inserted. It costs the whole text (made once, then
  /// kept): a long one is better asked by its rows (`placed`, `rows(in:)`, `frame(ofLines:width:)`, `span`)
  public var lines: CodeLines {
    if let l = cache.whole { return l }
    var l = CodeLines(
      lines: text.components(separatedBy: "\n"), firstNumber: firstNumber, runs: runs, wrapWidth: wrapWidth, top: top,
      metrics: metrics)
    l.insert(insertions)
    cache.whole = l
    return l
  }

  /// The line rows, in order (CodeLines' rows without the room); the whole text, as `lines`
  public var lineRows: [CodeLines.Row] {
    if let r = cache.lineRows { return r }
    let r = lines.rows.filter { if case .line = $0.kind { true } else { false } }
    cache.lineRows = r
    return r
  }

  // MARK: Lines and rows

  /// The text's lines: one more than its "\n"s
  public var lineCount: Int { index.lineCount }

  /// Under the last row and the room after it (CodeLines' `bottom`)
  public var bottom: CGFloat { index.bottom }

  /// The line rows with some of their height in `y` (a row that only touches it is not)
  public func rows(in y: ClosedRange<CGFloat>) -> Range<Int> { index.rows(in: y) }

  /// Line `number`'s rows (numbered from `firstNumber`); nil when the text has no such line
  public func rows(ofLine number: Int) -> Range<Int>? {
    guard number >= firstNumber, number - firstNumber < lineCount else { return nil }
    return index.firstRows[number - firstNumber]..<index.firstRows[number - firstNumber + 1]
  }

  /// The line a row is of, numbered from `firstNumber`
  public func line(ofRow r: Int) -> Int { firstNumber + index.line(ofRow: r) }

  /// Where `lines` are drawn, as CodeLines' `frame(of:width:)` gives it; nil when the text has none of them
  public func frame(ofLines lines: ClosedRange<Int>, width: CGFloat) -> CodeLines.LineFrame? {
    guard let rows = rows(of: lines) else { return nil }
    let top = index.y(rows.lowerBound)
    let first = CGRect(x: 0, y: top, width: width, height: metrics.row)
    let bottom = index.y(rows.upperBound - 1) + metrics.row
    return CodeLines.LineFrame(
      rect: CGRect(x: 0, y: top, width: width, height: bottom - top), first: first, folded: false)
  }

  /// From the top of the first of `lines` to the bottom of the last one's rows, or of the room inserted `through` when
  /// lower, as CodeLines' `span` gives it; nil when the text has none of them
  public func span(_ lines: ClosedRange<Int>, through: Int? = nil) -> ClosedRange<CGFloat>? {
    guard let rows = rows(of: lines) else { return nil }
    let top = index.y(rows.lowerBound)
    let end = index.y(rows.upperBound - 1) + metrics.row
    let room = through.flatMap { index.roomBottom($0) }
    return top...max(end, room ?? end)
  }

  /// The rows of those of `lines` the text has
  private func rows(of lines: ClosedRange<Int>) -> Range<Int>? {
    guard lines.upperBound >= firstNumber else { return nil }
    let lo = max(lines.lowerBound, firstNumber) - firstNumber
    guard lo < lineCount else { return nil }
    let hi = min(lines.upperBound - firstNumber, lineCount - 1)
    return index.firstRows[lo]..<index.firstRows[hi + 1]
  }

  /// A row's y
  func y(ofRow r: Int) -> CGFloat { index.y(r) }

  /// What to draw again after `old` was drawn, across `width`: nothing (`.null`) when the text and its rows are the
  /// same; everything (`.infinite`) when it is laid out otherwise (x, metrics, wrap width, room, numbers or top);
  /// else from the first line that differs to the last, in either, and on to the bottom when the rows under them moved.
  /// Colours are not compared
  public func changedRect(from old: CodeTextLayout, width: CGFloat) -> CGRect {
    guard
      x == old.x, metrics == old.metrics, wrapWidth == old.wrapWidth, insertions == old.insertions,
      firstNumber == old.firstNumber, top == old.top
    else { return .infinite }
    var (a, b) = (old.text, text)
    let band = a.withUTF8 { was in b.withUTF8 { now in index.changed(from: old.index, was: was, now: now) } }
    guard let band else { return .null }
    return CGRect(x: 0, y: band.lowerBound, width: width, height: band.upperBound - band.lowerBound)
  }

  // MARK: CodeLayout

  public var rowCount: Int { index.rowCount }

  public func row(of q: Int, assoc: Int) -> Int {
    let i = index.line(at: q)
    let first = index.firstRows[i]
    let count = index.firstRows[i + 1] - first
    guard count > 1 else { return first }
    let rows = made(i).rows
    var lo = 0
    var hi = min(rows.count, count) - 1
    // the last row starting at or before q
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if rows[mid].range.lowerBound <= q { lo = mid } else { hi = mid - 1 }
    }
    // a wrap point: the end of the row before, when asked
    if assoc < 0, lo > 0, rows[lo].range.lowerBound == q, rows[lo - 1].range.upperBound == q { return first + lo - 1 }
    return first + lo
  }

  public func x(of q: Int, assoc: Int) -> Double { Double(at(q, row: row(of: q, assoc: assoc))) }

  public func offsets(inRow r: Int) -> ClosedRange<Int> {
    let i = index.line(ofRow: r)
    // a line of one row: the whole line
    if index.firstRows[i + 1] - index.firstRows[i] == 1 { return index.starts16[i]...(index.starts16[i + 1] - 1) }
    return made(row: r).range
  }

  public func offset(inRow r: Int, x px: Double) -> Int {
    let row = made(row: r)
    let line = ctLine(r)
    let i = CTLineGetStringIndexForPosition(line, CGPoint(x: CGFloat(px) - x, y: 0))
    guard let k = Self.last(row.stops, atMost: i, by: { $0.u16 }) else { return row.range.lowerBound }
    let s = row.stops[k]
    if i == s.u16 || k + 1 >= row.stops.count { return s.src }
    // in a tab's spaces: the side of the tab nearer
    if s.tab > 0 {
      let mid = (Double(at(s.src, row: r)) + Double(at(row.stops[k + 1].src, row: r))) / 2
      return px < mid ? s.src : row.stops[k + 1].src
    }
    return min(s.src + (i - s.u16), row.stops[k + 1].src)
  }

  // MARK: What an editor draws

  /// The row's place: its line (and whether it continues one), y and height
  public func placed(_ r: Int) -> CodeLines.Row {
    CodeLines.Row(kind: kind(ofRow: r), y: index.y(r), height: metrics.row)
  }

  /// The caret at an offset: a line's height, at its x, in the row `assoc` says at a wrap point
  public func caret(_ q: Int, assoc: Int) -> CGRect {
    let r = row(of: q, assoc: assoc)
    return CGRect(x: at(q, row: r), y: index.y(r), width: 1, height: metrics.row)
  }

  /// A range's boxes, a row each; past a row's end (its line end, or where it wraps) out to `right`. With `within`, only
  /// those of the rows with some of their height in it
  public func rects(_ range: Range<Int>, right: CGFloat, within: ClosedRange<CGFloat>? = nil) -> [CGRect] {
    guard !range.isEmpty else { return [] }
    var out: [CGRect] = []
    let first = row(of: range.lowerBound, assoc: 1)
    let shown = within.map { index.rows(in: $0) } ?? 0..<rowCount
    var r = max(first, shown.lowerBound)
    while r < shown.upperBound {
      let rr = offsets(inRow: r)
      if rr.lowerBound > range.upperBound || (rr.lowerBound == range.upperBound && r > first) { break }
      // from the row's start, or out to `right`: no glyphs measured
      let a = range.lowerBound <= rr.lowerBound && startsAtX(r) ? x : at(max(range.lowerBound, rr.lowerBound), row: r)
      let b = range.upperBound > rr.upperBound ? right : at(min(range.upperBound, rr.upperBound), row: r)
      if b > a { out.append(CGRect(x: a, y: index.y(r), width: b - a, height: metrics.row)) }
      r += 1
    }
    return out
  }

  /// The offset a point is at, and the side of a wrap point it is drawn on: the row under it (the first above the
  /// rows, the last under them), the character boundary nearest across
  public func offset(at p: CGPoint) -> (offset: Int, assoc: Int) {
    let r = index.row(atY: p.y)
    let q = offset(inRow: r, x: Double(p.x))
    let rr = offsets(inRow: r)
    return (q, q == rr.upperBound && rr.count > 1 ? -1 : 1)
  }

  // MARK: Making lines

  /// Line `i`'s text, a "\r" before its "\n" with it
  private func lineText(_ i: Int) -> String {
    let u = text.utf8
    let a = u.index(u.startIndex, offsetBy: index.starts8[i])
    let b = u.index(u.startIndex, offsetBy: index.starts8[i + 1] - 1)
    return String(decoding: u[a..<b], as: UTF8.self)
  }

  /// Line `i`'s rows, made now or kept from before: CodeLines' of that one line, and their offsets
  func made(_ i: Int) -> Line {
    if let l = cache.lines[i] { return l }
    let s = lineText(i)
    let one = CodeLines(
      lines: [s], firstNumber: firstNumber + i, runs: [i < runs.count ? runs[i] : []], wrapWidth: wrapWidth,
      metrics: metrics)
    let l = Line(kinds: one.rows.map(\.kind), rows: Self.cutRows(s, start: index.starts16[i], wrapWidth, metrics))
    if cache.lines.count >= Self.kept { cache.lines = [:] }
    cache.lines[i] = l
    return l
  }

  /// How many lines are made and kept now
  var madeLines: Int { cache.lines.count }

  /// A line's rows' offsets, from `start`, cut where CodeLines cuts it
  private static func cutRows(_ line: String, start: Int, _ wrapWidth: CGFloat?, _ m: CodeLineMetrics) -> [Row] {
    var out: [Row] = []
    // each character's expanded columns, cut into rows as CodeLines cuts them; a tab cut there has its offset on the
    // row it starts on, the rest of its spaces drawn at the start of the next
    var row: [(src: Int, u16: Int, tab: Int)] = []
    var cols = 0
    var u16 = 0
    var src = start
    func cut(_ end: Int) {
      out.append(Row(range: (row.first?.src ?? end)...end, stops: row + [(end, u16, 0)]))
      (row, u16) = ([], 0)
    }
    // where rows start, in expanded columns: CodeLines' cuts of the same columns
    var breaks = Set<Int>()
    if let wrapWidth {
      var widths: [CGFloat] = []
      for ch in line {
        if ch == "\t" {
          widths += Array(repeating: m.charWidth, count: m.tabWidth - widths.count % m.tabWidth)
        } else {
          widths.append(CodeLines.advance(ch, m))
        }
      }
      var at = 0
      for n in CodeLines.cuts(widths, width: wrapWidth).dropLast() {
        at += n
        breaks.insert(at)
      }
    }
    for ch in line {
      let tab = ch == "\t"
      let n = tab ? m.tabWidth - cols % m.tabWidth : 1
      for k in 0..<n {
        if breaks.contains(cols) { cut(k == 0 ? src : src + 1) }
        if k == 0 { row.append((src, u16, tab ? n : 0)) }
        cols += 1
        u16 += tab ? 1 : ch.utf16.count
      }
      src += ch.utf16.count
    }
    cut(src)
    return out
  }

  /// Row r's offsets
  func made(row r: Int) -> Row {
    let i = index.line(ofRow: r)
    let rows = made(i).rows
    return rows[min(r - index.firstRows[i], rows.count - 1)]
  }

  /// Row r's kind: its line's number, whether it continues the line, its text and runs
  func kind(ofRow r: Int) -> CodeLines.Kind {
    let i = index.line(ofRow: r)
    let kinds = made(i).kinds
    return kinds[min(r - index.firstRows[i], kinds.count - 1)]
  }

  /// A row's glyphs start at `x`: the first row of its line, or one that starts with a character (not the rest of a
  /// tab cut at the row before)
  private func startsAtX(_ r: Int) -> Bool {
    index.firstRows[index.line(ofRow: r)] == r || made(row: r).stops.first?.u16 == 0
  }

  /// The last of `stops` whose `key` is at most `v` (stops go up by both of their offsets)
  private static func last(
    _ stops: [(src: Int, u16: Int, tab: Int)], atMost v: Int, by key: ((src: Int, u16: Int, tab: Int)) -> Int
  ) -> Int? {
    let k = CodeTextIndex.first(stops.count) { key(stops[$0]) > v }
    return k > 0 ? k - 1 : nil
  }

  // MARK: Measuring

  /// x of an offset in a row it is in
  func at(_ q: Int, row r: Int) -> CGFloat {
    let row = made(row: r)
    guard let k = Self.last(row.stops, atMost: q, by: { $0.src }) else { return x }
    let s = row.stops[k]
    let u16 = s.tab > 0 ? s.u16 + (q > s.src ? s.tab : 0) : s.u16 + (q - s.src)
    return x + CTLineGetOffsetForStringIndex(ctLine(r), u16, nil)
  }

  func ctLine(_ r: Int) -> CTLine {
    if let l = cache.glyphs[r] { return l }
    guard case .line(_, _, let s, let runs) = kind(ofRow: r) else { return CodeDraw.line("", style.font) }
    let l = CTLineCreateWithAttributedString(CodeDraw.attributed(s, runs: runs, style: style))
    if cache.glyphs.count >= Self.kept { cache.glyphs = [:] }
    cache.glyphs[r] = l
    return l
  }
}
