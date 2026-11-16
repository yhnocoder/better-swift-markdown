import CodeUI
import CoreGraphics
import CoreText
import Foundation
import Testing

/// The editor's layout made line by line as it is asked gives what the whole text laid out at once gives: the same
/// rows, places, offsets and frames, whatever the text, the wrapping, the room after lines and the numbering
@Suite struct CodeTextLayoutTests {
  static let font = CodeFont(CTFontCreateWithName("Menlo" as CFString, 11, nil))
  static let style = CodeStyle(
    font: font, ink: CGColor(gray: 0.1, alpha: 1),
    runs: [nil, .init(color: CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1))])
  /// The code font measuring what is not ASCII; a row height that does not add up exactly
  static let metrics: CodeLineMetrics = {
    let font = CodeTextLayoutTests.font
    var m = CodeLineMetrics(
      row: 15.4, fold: 24, padLeft: 17, numberGap: 22, padRight: 18, charWidth: CodeDraw.width("0", font))
    m.font = font
    return m
  }()

  static let texts = [
    "", "x", "def f(x):\n\treturn x + 1\n", "a\tb\t\tc\n\t\tindented\tmore\n\n",
    "中文中文中文中文 and ascii 😀😀 e\u{301}\n第二行", "one\r\ntwo\r\n\r\nthree",
    String(repeating: "long_identifier_", count: 12) + "\nshort\n" + String(repeating: "\tx = 1", count: 9),
  ]

  /// Each line's runs: its first half in style 1
  static func runs(_ text: String) -> [[CodeRun]] {
    text.components(separatedBy: "\n").map { l in
      l.utf16.count > 1 ? [CodeRun(columns: 0..<(l.utf16.count / 2), style: 1)] : []
    }
  }

  static func insertions(first: Int, lines: Int) -> [[CodeLines.Insertion]] {
    [
      [],
      // before the first line, two after one line, after the last
      [
        .init(afterLine: first - 1, height: 10), .init(afterLine: first, height: 5.5),
        .init(afterLine: first, height: 3.3), .init(afterLine: first + lines + 5, height: 7),
      ],
      [.init(afterLine: first + lines - 1, height: 9.9), .init(afterLine: 0, height: 1.1)],
    ]
  }

  /// Every layout the cases make: text, wrap width, room and numbering
  static func cases() -> [(name: String, text: String, layout: CodeTextLayout, whole: CodeLines)] {
    var out: [(name: String, text: String, layout: CodeTextLayout, whole: CodeLines)] = []
    let cw = metrics.charWidth
    for text in texts {
      let lines = text.components(separatedBy: "\n")
      for wrap in [nil, 6 * cw, 11 * cw, 23 * cw] as [CGFloat?] {
        for first in [1, 40] {
          for room in insertions(first: first, lines: lines.count) {
            let layout = CodeTextLayout(
              text: text, firstNumber: first, runs: runs(text), wrapWidth: wrap, insertions: room, top: 6, x: 30,
              metrics: metrics, style: style)
            var whole = CodeLines(
              lines: lines, firstNumber: first, runs: runs(text), wrapWidth: wrap, top: 6, metrics: metrics)
            whole.insert(room)
            let name = "\(text.debugDescription) wrap \(String(describing: wrap)) from \(first) room \(room.count)"
            out.append((name, text, layout, whole))
          }
        }
      }
    }
    return out
  }

  @Test func rowsPlacesAndTheBottomAreTheWholeLayouts() {
    for (name, text, l, whole) in Self.cases() {
      let rows = whole.rows.filter { if case .line = $0.kind { true } else { false } }
      #expect(l.rowCount == rows.count, "\(name)")
      #expect(l.bottom == whole.bottom, "\(name)")
      #expect(l.lineCount == text.components(separatedBy: "\n").count, "\(name)")
      #expect(l.lines == whole && l.lineRows == rows, "\(name)")
      guard l.rowCount == rows.count else { continue }
      for r in 0..<l.rowCount {
        #expect(l.placed(r) == rows[r], "\(name) row \(r)")
        if case .line(let n, _, _, _) = rows[r].kind {
          #expect(l.line(ofRow: r) == n && l.rows(ofLine: n)?.contains(r) == true, "\(name) row \(r)")
        }
      }
    }
  }

  /// A row's offsets follow on from the row before's: across a wrap point the same offset ends one and starts the
  /// next, across a line end the "\n" between them
  @Test func eachRowsOffsetsFollowOnFromTheRowBefore() {
    for (name, text, l, _) in Self.cases() {
      #expect(l.offsets(inRow: 0).lowerBound == 0, "\(name)")
      #expect(l.offsets(inRow: l.rowCount - 1).upperBound == text.utf16.count, "\(name)")
      for r in 1..<max(1, l.rowCount) {
        let gap = l.line(ofRow: r) == l.line(ofRow: r - 1) ? 0 : 1
        #expect(l.offsets(inRow: r).lowerBound == l.offsets(inRow: r - 1).upperBound + gap, "\(name) row \(r)")
      }
    }
  }

  @Test func framesAndSpansOfLinesAreTheWholeLayouts() {
    for (name, _, l, whole) in Self.cases() {
      let first = l.line(ofRow: 0)
      let last = first + l.lineCount - 1
      for lo in (first - 2)...(last + 2) {
        for hi in lo...(last + 3) {
          #expect(
            l.frame(ofLines: lo...hi, width: 300) == whole.frame(of: lo...hi, width: 300), "\(name) \(lo)...\(hi)")
          for through in [nil, 0, 1, 2, 3, 7] as [Int?] {
            #expect(l.span(lo...hi, through: through) == whole.span(lo...hi, through: through), "\(name) \(lo)...\(hi)")
          }
        }
      }
      #expect(l.rows(ofLine: first - 1) == nil && l.rows(ofLine: last + 1) == nil)
    }
  }

  /// Rows found by y, offsets by row, and the offset at a point, as a scan of every row finds them
  @Test func rowsAndOffsetsAreFoundAsAScanFindsThem() {
    for (name, text, l, _) in Self.cases() {
      let ys = (0..<l.rowCount).map { l.placed($0).y }
      let h = Self.metrics.row
      for a in stride(from: -20, through: l.bottom + 20, by: 7.3) {
        for b in [a, a + 0.5, a + h, a + 90] {
          let scan = ys.indices.filter { ys[$0] < b && ys[$0] + h > a }
          #expect(Array(l.rows(in: a...b)) == scan, "\(name) \(a)...\(b)")
        }
        // the offset at a point: the last row whose top is above it, as near across as the row has
        let r = ys.lastIndex { $0 <= a } ?? 0
        for x in [0, 33, 61.5, 140, 500] as [CGFloat] {
          let q = l.offset(inRow: r, x: Double(x))
          let rr = l.offsets(inRow: r)
          let got = l.offset(at: CGPoint(x: x, y: a))
          #expect(got.offset == q && got.assoc == (q == rr.upperBound && rr.count > 1 ? -1 : 1), "\(name)")
        }
      }
      let ranges = (0..<l.rowCount).map { l.offsets(inRow: $0) }
      for q in -1...(text.utf16.count + 1) {
        for assoc in [-1, 1] {
          // the last row starting at or before q; at a wrap point the one before when asked
          var r = ranges.lastIndex { $0.lowerBound <= q } ?? 0
          if assoc < 0, r > 0, ranges[r].lowerBound == q, ranges[r - 1].upperBound == q { r -= 1 }
          #expect(l.row(of: q, assoc: assoc) == r, "\(name) offset \(q)")
        }
      }
    }
  }

  /// A range's boxes in a band of y are its boxes there
  @Test func aRangesBoxesInABandAreItsBoxesThere() {
    for (name, text, l, _) in Self.cases() {
      let n = text.utf16.count
      for (a, b) in [(0, n), (0, n / 2), (n / 3, n), (1, max(1, n - 1)), (n / 2, n / 2 + 3)] where a < b {
        let all = l.rects(a..<b, right: 400)
        for top in stride(from: -10, through: l.bottom, by: 23.1) {
          let band = top...(top + 40)
          let ys = Set(l.rows(in: band).map { l.placed($0).y })
          #expect(
            l.rects(a..<b, right: 400, within: band) == all.filter { ys.contains($0.minY) }, "\(name) \(a)..<\(b)")
        }
      }
    }
  }

  @Test func newColoursKeepTheRows() {
    for (name, _, l, _) in Self.cases() {
      let other = l.recolored([])
      #expect(other.rowCount == l.rowCount && other.bottom == l.bottom, "\(name)")
      #expect(other.changedRect(from: l, width: 300) == .null, "\(name)")
      for r in 0..<l.rowCount {
        let (a, b) = (l.placed(r), other.placed(r))
        #expect(a.y == b.y && a.height == b.height, "\(name) row \(r)")
        guard case .line(let n, let wrapped, let s, _) = a.kind else { continue }
        #expect(b.kind == .line(number: n, wrapped: wrapped, text: s, runs: []), "\(name) row \(r)")
      }
    }
    // the runs each line is given now
    let l = CodeTextLayout(text: "abc\ndef", x: 0, metrics: Self.metrics, style: Self.style)
    let colored = l.recolored([[], [CodeRun(columns: 0..<2, style: 1)]])
    #expect(
      colored.placed(1).kind == .line(number: 2, wrapped: false, text: "def", runs: [CodeRun(columns: 0..<2, style: 1)])
    )
    #expect(l.placed(1).kind == .line(number: 2, wrapped: false, text: "def", runs: []))
  }

  /// What an edit draws again: the lines it changed, down to the bottom when the lines under them moved
  @Test func anEditDrawsAgainTheLinesItChanged() {
    func layout(_ s: String, x: CGFloat = 30) -> CodeTextLayout {
      CodeTextLayout(text: s, top: 6, x: x, metrics: Self.metrics, style: Self.style)
    }
    // the rows' y are added up row by row: compared to a hair
    func near(_ r: CGRect, _ top: CGFloat, _ bottom: CGFloat) -> Bool {
      r.minX == 0 && r.width == 300 && abs(r.minY - top) < 1e-9 && abs(r.maxY - bottom) < 1e-9
    }
    let h = Self.metrics.row
    let old = layout("alpha\nbeta\ngamma\ndelta")
    #expect(layout("alpha\nbeta\ngamma\ndelta").changedRect(from: old, width: 300) == .null)
    #expect(layout("alpha\nbeta\ngamma\ndelta", x: 31).changedRect(from: old, width: 300) == .infinite)
    // one line edited: its row
    let y1 = old.placed(1).y
    #expect(near(layout("alpha\nbetA\ngamma\ndelta").changedRect(from: old, width: 300), y1, y1 + h))
    // a line put in: from it down to the bottom
    let more = layout("alpha\nbeta\nnew\ngamma\ndelta")
    #expect(near(more.changedRect(from: old, width: 300), old.placed(2).y, more.bottom))
    // a line taken out: down to the bottom it had
    #expect(near(layout("alpha\ngamma\ndelta").changedRect(from: old, width: 300), y1, old.bottom))
  }
}
