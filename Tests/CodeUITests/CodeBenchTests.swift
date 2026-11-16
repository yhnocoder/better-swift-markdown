import AppKit
import CodeCore
import Testing

@testable import CodeUI

/// Long texts cost what is drawn of them: opening one, drawing a screenful, a click, selecting all, scrolling and new
/// colours each take about the same at 2000 lines as at 30 000. Times are the thread's CPU time, printed for the log
/// (`CodeBench:`), with budgets far over what they take in a debug build and far under laying the whole text out
extension CodeEditorViewTests {
  /// Made-up Python, the same every time: `lines` lines, each with its colours
  static func code(lines n: Int) -> (text: String, runs: [[CodeRun]]) {
    var lines: [String] = []
    var runs: [[CodeRun]] = []
    lines.reserveCapacity(n)
    runs.reserveCapacity(n)
    for i in 0..<n {
      let indent = String(repeating: "    ", count: 1 + i % 3)
      let line =
        switch i % 5 {
        case 0: "def function_\(i)(alpha, beta=\(i % 89)):  # the \(i)th"
        case 1: indent + "value_\(i) = compute(alpha, \"a string \(i)\") + beta  # note \(i)"
        case 2: indent + "for k in range(\(i % 97)):"
        case 3: indent + "    total += k * value_\(i - 2) - len(\"\(i)\")"
        default: indent + "return total  # \(i)"
        }
      let length = line.utf16.count
      lines.append(line)
      runs.append([CodeRun(columns: 0..<3, style: 1), CodeRun(columns: (length / 2)..<length, style: 1)])
    }
    return (lines.joined(separator: "\n"), runs)
  }

  static func cpu() -> Double {
    var t = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
    return Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1e6
  }

  /// The thread's CPU time `body` takes, in ms, printed
  @discardableResult
  static func measure(_ name: String, _ body: () -> Void) -> Double {
    let start = cpu()
    body()
    let ms = cpu() - start
    print("CodeBench: \(name) \(String(format: "%.2f", ms)) ms")
    return ms
  }

  /// `r` drawn as it would be in a window: only what is in it
  func draw(_ v: NSView, _ r: CGRect) {
    let rep = v.bitmapImageRepForCachingDisplay(in: r)!
    v.cacheDisplay(in: r, to: rep)
  }

  func bench(_ name: String, lines: Int, open budget: Double) {
    let (text, runs) = Self.code(lines: lines)
    print("CodeBench: \(name): \(lines) lines, \(text.utf8.count) bytes")
    var made: CodeEditorView?
    let opening = Self.measure("\(name) open with colours") {
      let v = CodeEditorView(text: text, look: look(), runs: runs)
      v.frame = CGRect(x: 0, y: 0, width: 900, height: v.height)
      made = v
    }
    #expect(opening < budget, "\(name): opening took \(opening) ms")
    guard let v = made else { return }
    var layouts = 0
    v.onLayout = { layouts += 1 }
    let screen = CGSize(width: 900, height: 1000)
    let top = CGRect(origin: .zero, size: screen)
    let middle = CGRect(origin: CGPoint(x: 0, y: (v.height / 2).rounded()), size: screen)
    let first = Self.measure("\(name) first screenful at the top") { draw(v, top) }
    #expect(first < 100)
    // a screenful of lines made, and the caret's
    let shown = Int(screen.height / look().metrics.row) + 2
    #expect(v.layout.madeLines <= shown + 2, "\(name): \(v.layout.madeLines) lines made for a screenful")
    let second = Self.measure("\(name) first screenful in the middle") { draw(v, middle) }
    #expect(second < 100)
    #expect(v.layout.madeLines <= 2 * (shown + 2))
    let row = v.layout.placed(v.layout.rows(in: middle.minY...middle.maxY).lowerBound + 10)
    let p = CGPoint(x: v.gutter + 40, y: row.y + row.height / 2)
    let clicking = Self.measure("\(name) click") {
      v.mouseDown(with: click(v, at: p, count: 1))
      v.mouseUp(with: click(v, at: p, count: 1, .leftMouseUp))
    }
    #expect(clicking < 100 && v.editor.selection.isEmpty && v.editor.selection.head > 0)
    let selecting = Self.measure("\(name) select all and draw a screenful") {
      v.selectAll(nil)
      draw(v, middle)
    }
    #expect(selecting < 100)
    var steps: [Double] = []
    for k in 1...30 {
      let r = top.offsetBy(dx: 0, dy: CGFloat(k) * screen.height)
      steps.append(Self.measure("\(name) scroll step \(k)") { draw(v, r) })
    }
    #expect((steps.max() ?? 0) < 100)
    let other = runs.map { r in r.map { CodeRun(columns: $0.columns, style: 0) } }
    let recolouring = Self.measure("\(name) new colours for every line, and a screenful") {
      v.runs = other
      draw(v, middle)
    }
    #expect(recolouring < 100)
    #expect(layouts == 0, "\(name): laid out again \(layouts) times")
    // what opening cost before: the whole text laid out
    Self.measure("\(name) the whole text laid out, for comparison") { _ = v.layout.lines }
  }

  /// A small text through the same steps, untimed: what the process does once (fonts, AppKit's classes, the first
  /// event) is not the cost of a text, and falls on whichever test comes first
  func warmUp() {
    let (text, runs) = Self.code(lines: 40)
    let v = CodeEditorView(text: text, look: look(), runs: runs)
    v.frame = CGRect(x: 0, y: 0, width: 900, height: v.height)
    draw(v, v.bounds)
    let p = CGPoint(x: v.gutter + 40, y: v.height / 2)
    v.mouseDown(with: click(v, at: p, count: 1))
    v.mouseUp(with: click(v, at: p, count: 1, .leftMouseUp))
    v.selectAll(nil)
    v.runs = []
    draw(v, v.bounds)
  }

  @Test func aLongTextOpensAndScrollsAtTheCostOfWhatIsDrawn() {
    warmUp()
    bench("2000 lines", lines: 2000, open: 50)
    let big = Self.code(lines: 30_000).text.utf8.count
    #expect(big >= 1_200_000)
    bench("30000 lines", lines: 30_000, open: 300)
  }
}
