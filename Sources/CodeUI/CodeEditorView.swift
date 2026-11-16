import AppKit
import CodeCore

/// Code edited in place, or only read: a CodeEditor drawn as CodeLines lays the code out and CodeDraw draws it, the
/// same rows and glyphs as the code shown without editing, with the caret, the selection, an input method's
/// composition, the line numbers and the current line's background. Keys are CodeKeys.mac's, typing and input methods
/// come through NSTextInputClient, the mouse places, selects words and lines and drags. Lines are laid out as they are
/// drawn (CodeTextLayout), so a text of any length opens at once; new colours and a moved selection lay nothing out.
/// Read only (`isEditable` false) it selects, copies and finds, and passes on the keys it does not use (for its host
/// to scroll with). It does not scroll itself: the host sizes it to `height` (`onHeight`) and puts it in a scroll view,
/// or scales it with `place(_:zoom:)` without laying it out again
@MainActor
public final class CodeEditorView: NSView {
  /// How it looks, in the host's values
  public struct Look {
    public var style: CodeStyle
    public var metrics: CodeLineMetrics
    public var numberColor: CGColor
    public var selection: CGColor
    /// Behind the caret's line, all of its rows, across the gutter too; nil for none
    public var currentLine: CGColor?
    public var band: CodeBandShape
    /// Above the first row and under the last
    public var padTop: CGFloat
    public var padBottom: CGFloat

    public init(
      style: CodeStyle, metrics: CodeLineMetrics, numberColor: CGColor, selection: CGColor, currentLine: CGColor?,
      band: CodeBandShape, padTop: CGFloat, padBottom: CGFloat
    ) {
      self.style = style
      self.metrics = metrics
      self.numberColor = numberColor
      self.selection = selection
      self.currentLine = currentLine
      self.band = band
      self.padTop = padTop
      self.padBottom = padBottom
    }
  }

  public private(set) var editor: CodeEditor
  public private(set) var layout: CodeTextLayout
  public var look: Look {
    didSet {
      relayout()
      needsDisplay = true
    }
  }
  /// Long lines cut to the width
  public var wrap = false { didSet { relayout() } }
  public var firstNumber = 1 { didSet { relayout() } }
  public var decorations = CodeDecorations() { didSet { if decorations != oldValue { needsDisplay = true } } }
  /// Room after lines (the host draws what goes in it)
  public var insertions: [CodeLines.Insertion] = [] { didSet { relayout() } }
  /// The text's colours while it changes; without, what `runs` gives
  public var colors: CodeColors? {
    didSet {
      colors?.ready = { [weak self] in self?.recolor() }
      recolor()
    }
  }
  /// Each line's colours when there is no `colors`: new ones are drawn without laying the text out again
  public var runs: [[CodeRun]] {
    get { lineRuns }
    set {
      lineRuns = newValue
      recolor()
    }
  }
  private var lineRuns: [[CodeRun]]
  /// What the user does can change the text; false: it is only read (selected, copied, found in), and the keys it does
  /// not use go on to the next responder. The host's `change` and `reset` still change it
  public var isEditable = true {
    didSet {
      guard isEditable != oldValue else { return }
      findBar?.canReplace = isEditable
      if !isEditable, editor.composition != nil {
        super.inputContext?.discardMarkedText()
        change { $0.cancelMarked() }
      }
      // the caret and its line's background shown or hidden
      redraw(marked)
      placeCaret()
    }
  }
  public var onChange: ((String) -> Void)?
  /// Escape, ⌘↩
  public var onExit: (() -> Void)?
  public var onHeight: ((CGFloat) -> Void)?
  /// The lines are laid out again (their text, the width, room after them): what `frame(ofLines:)` answers may have
  /// changed. Not for new colours or a moved selection
  public var onLayout: (() -> Void)?
  /// Presses of a multi-click that began outside the view and goes on in it (the click that opened it): they count from
  /// the first press made here, so the second press of the double-click that opened the editor only places the caret.
  /// A single press ends it
  public var continuing = 0
  /// How the find bar looks; nil: there is none
  public var findLook: FindBar.Look?
  /// The host's buttons for the find bar (FindBar.buttons), made with it
  public var findButtons: (() -> NSView)?
  public private(set) var findBar: FindBar?
  /// A match was found and selected: where it is in the view, for the host to bring it into view
  public var onFound: ((CGRect) -> Void)?
  /// Where the selection began when the bar opened: typing finds from there on
  private var findFrom = 0
  /// Where copy, cut and paste go (tests give their own)
  public var pasteboard = NSPasteboard.general
  /// The code's height: its rows and padding
  public private(set) var height: CGFloat = 0
  public private(set) var gutter: CGFloat = 0

  private let caret = NSTextInsertionIndicator()
  /// The width the rows are cut to (unscaled): laid out again only when it changes
  private var laidWidth: CGFloat = -1
  private var placing = false
  /// What the selection, the caret's line and the composition were last drawn over
  private var marked = CGRect.null
  /// Redrawn only in view: what is still to draw out of it
  private var stale: [CGRect] = []

  /// Laid out once, with all of these: `firstNumber` and `wrap` set after lay the text out again (`runs` set after
  /// only colours it again). Not `editable`: the selection at the start, else at the end
  public init(
    text: String, look: Look, firstNumber: Int = 1, wrap: Bool = false, editable: Bool = true, runs: [[CodeRun]] = []
  ) {
    editor = CodeEditor(text: text, selection: CodeSelection(editable ? text.utf16.count : 0))
    self.look = look
    self.firstNumber = firstNumber
    self.wrap = wrap
    isEditable = editable
    lineRuns = runs
    // laid out once, by relayout below
    layout = CodeTextLayout(text: "", x: 0, metrics: look.metrics, style: look.style)
    super.init(frame: .zero)
    caret.displayMode = .hidden
    addSubview(caret)
    relayout()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { true }
  /// A press in a window that is not key places the caret at once, as a press on a text field does
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  /// None while the text cannot change: no input method composes in it
  public override var inputContext: NSTextInputContext? { isEditable ? super.inputContext : nil }

  public override func becomeFirstResponder() -> Bool {
    defer { placeCaret() }
    return true
  }

  public override func resignFirstResponder() -> Bool {
    caret.displayMode = .hidden
    return true
  }

  /// The host's own edit of the editor (a language set, a selection restored, an edit it made)
  public func change(_ f: (inout CodeEditor) -> Void) {
    let before = editor.text
    let composed = editor.composition
    f(&editor)
    changed(before, composed)
  }

  /// Another text in the view, with its colours, laid out once: the selection at its start, the undo history and any
  /// composition let go, the editor's settings and the find bar kept. `onChange` is not called: the host gave the text
  public func reset(text: String, runs: [[CodeRun]] = []) {
    if editor.composition != nil { inputContext?.discardMarkedText() }
    var e = CodeEditor(text: text, clock: editor.clock)
    e.indentUnit = editor.indentUnit
    e.tabWidth = editor.tabWidth
    e.lineComment = editor.lineComment
    editor = e
    lineRuns = runs
    findFrom = 0
    relayout()
    count()
  }

  /// Puts the view at `frame` in its superview, its content drawn `zoom` times its size: laid out again only when the
  /// width the rows are cut to changes
  public func place(_ frame: CGRect, zoom: CGFloat) {
    placing = true
    self.frame = frame
    bounds.size = CGSize(width: frame.width / zoom, height: frame.height / zoom)
    placing = false
    if wrap, bounds.width != laidWidth { relayout() }
    drawSeen(visibleRect)
    placeFindBar()
  }

  public override func setFrameSize(_ s: NSSize) {
    super.setFrameSize(s)
    if !placing, wrap, bounds.width != laidWidth { relayout() }
  }

  // MARK: Layout

  /// The text as drawn: with the composition in it
  private var shown: (text: String, at: Int, length: Int) {
    guard let c = editor.composition else { return (editor.text, 0, 0) }
    let s = (editor.text as NSString).replacingCharacters(in: NSRange(location: c.at, length: 0), with: c.text)
    return (s, c.at, (c.text as NSString).length)
  }

  /// An offset of the text in the text as drawn
  private func drawn(_ q: Int) -> Int {
    guard let c = editor.composition, q >= c.at else { return q }
    return q + (c.text as NSString).length
  }

  /// The text indexed again (its lines, rows and where they are) and what changed drawn again: for a new text or
  /// composition, width to wrap to, numbering, room or look
  private func relayout() {
    let m = look.metrics
    let text = shown.text
    gutter = CodeLines.gutter(lastNumber: firstNumber + CodeTextIndex.count(linesOf: text) - 1, metrics: m)
    let widthChanged = laidWidth != bounds.width
    laidWidth = bounds.width
    let before = layout
    layout = CodeTextLayout(
      text: text, firstNumber: firstNumber, runs: currentRuns(),
      wrapWidth: wrap ? CodeLines.wrapWidth(width: bounds.width, gutter: gutter, metrics: m) : nil,
      insertions: insertions, top: look.padTop, x: gutter, metrics: m, style: look.style)
    let h = layout.bottom + look.padBottom
    if h != height {
      height = h
      onHeight?(h)
    }
    // only what changed is drawn again: the lines that differ, and the marks where they were and are
    let now = marks()
    redraw(widthChanged ? bounds : layout.changedRect(from: before, width: bounds.width).union(marked).union(now))
    marked = now
    placeCaret()
    placeFindBar()
    onLayout?()
  }

  /// New colours on the rows as they are: what is in view drawn again, the rest as it comes into view
  private func recolor() {
    layout = layout.recolored(currentRuns())
    redraw(bounds)
  }

  /// The selection moved, the text as it was: its marks drawn again where they were and are, nothing laid out
  private func reselect() {
    let now = marks()
    redraw(marked.union(now))
    marked = now
    placeCaret()
  }

  /// Each line's colours as they are now, for the text as drawn
  private func currentRuns() -> [[CodeRun]] {
    var out = colors?.runs(for: editor.text, visible: visibleLines()) ?? lineRuns
    if let c = editor.composition, !c.text.isEmpty {
      // the composed line keeps the colours before the composition
      let ns = editor.text as NSString
      let start = ns.lineRange(for: NSRange(location: c.at, length: 0)).location
      let line = ns.substring(to: start).utf16.count { $0 == 0x0A }
      if line < out.count { out[line] = out[line].filter { $0.columns.upperBound <= c.at - start } }
    }
    return out
  }

  /// The selection, the caret's line and the composition, as they are drawn now: the rows they are on, across
  private func marks() -> CGRect {
    let w = bounds.width
    let h = layout.metrics.row
    func across(_ rows: ClosedRange<Int>) -> CGRect {
      let top = layout.y(ofRow: rows.lowerBound)
      return CGRect(x: 0, y: top, width: w, height: layout.y(ofRow: rows.upperBound) + h - top)
    }
    func rows(_ range: Range<Int>) -> ClosedRange<Int> {
      let a = layout.row(of: range.lowerBound, assoc: 1)
      return a...max(a, layout.row(of: range.upperBound, assoc: -1))
    }
    var r = CGRect.null
    let s = editor.selection.range
    if !s.isEmpty { r = across(rows(drawn(s.lowerBound)..<drawn(s.upperBound))) }
    if let line = caretLine() { r = r.union(across(line.lowerBound...(line.upperBound - 1))) }
    let (_, at, n) = shown
    if n > 0 { r = r.union(across(rows(at..<(at + n))).insetBy(dx: 0, dy: -3)) }
    return r
  }

  /// The rows of the caret's line
  private func caretLine() -> Range<Int>? {
    layout.rows(ofLine: layout.line(ofRow: layout.row(of: drawn(editor.selection.head), assoc: editor.assoc)))
  }

  /// Draws `r` again, now where it is in view and when it comes into view for the rest: code thousands of
  /// points tall is drawn a screenful at a time
  private func redraw(_ r: CGRect) {
    let r = r.intersection(bounds)
    guard !r.isNull, !r.isEmpty else { return }
    stale.append(r)
    drawSeen(window == nil ? bounds : visibleRect)
  }

  /// Draws what is stale in `seen`, and keeps the rest of it (above and below what is seen) for later
  private func drawSeen(_ seen: CGRect) {
    guard !stale.isEmpty else { return }
    var rest: [CGRect] = []
    for r in stale {
      let now = r.intersection(seen)
      guard !now.isNull, !now.isEmpty else {
        rest.append(r)
        continue
      }
      setNeedsDisplay(now)
      guard seen.minX <= r.minX, seen.maxX >= r.maxX else {
        rest.append(r)
        continue
      }
      if r.minY < seen.minY { rest.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: seen.minY - r.minY)) }
      if r.maxY > seen.maxY { rest.append(CGRect(x: r.minX, y: seen.maxY, width: r.width, height: r.maxY - seen.maxY)) }
    }
    stale = rest
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    watchAncestors()
    stale = [bounds]
    drawSeen(visibleRect)
  }

  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    watchAncestors()
  }

  /// Every view holding it watched for being scrolled or resized: what is stale is drawn as it comes into view
  private func watchAncestors() {
    let center = NotificationCenter.default
    center.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
    center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    guard window != nil else { return }
    var v = superview
    while let a = v {
      center.addObserver(self, selector: #selector(ancestorMoved), name: NSView.frameDidChangeNotification, object: a)
      center.addObserver(self, selector: #selector(ancestorMoved), name: NSView.boundsDidChangeNotification, object: a)
      v = a.superview
    }
  }

  @objc private func ancestorMoved(_ n: Notification) {
    drawSeen(visibleRect)
    placeFindBar()
  }

  /// Where `lines` are drawn in the view (its own points, at zoom 1); nil when none is shown
  public func frame(ofLines lines: ClosedRange<Int>) -> CodeLines.LineFrame? {
    layout.frame(ofLines: lines, width: bounds.width)
  }

  /// The lines in view (by the rows as last laid out), all of them before there is a view
  private func visibleLines() -> Range<Int> {
    let v = visibleRect
    let all = 0..<layout.lineCount
    guard !v.isEmpty else { return all }
    let rows = layout.rows(in: v.minY...v.maxY)
    guard !rows.isEmpty else { return all }
    return layout.index.line(ofRow: rows.lowerBound)..<(layout.index.line(ofRow: rows.upperBound - 1) + 1)
  }

  private func placeCaret() {
    guard isEditable else {
      caret.displayMode = .hidden
      return
    }
    let s = editor.selection
    let showing = window?.firstResponder === self && s.isEmpty
    let q = editor.composition.map { $0.at + $0.selected.lowerBound } ?? s.head
    var r = layout.caret(q, assoc: editor.assoc)
    r.size.width = 2
    caret.frame = r
    caret.displayMode = showing && editor.composition?.selected.isEmpty != false ? .automatic : .hidden
  }

  /// After the editor changed: the text laid out again when it or the composition changed, else only the selection's
  /// marks drawn again
  private func changed(_ before: String, _ composed: CodeEditor.Composition?) {
    let edited = editor.text != before
    if edited { onChange?(editor.text) }
    if edited || editor.composition != composed { relayout() } else { reselect() }
    if editor.composition == nil { inputContext?.invalidateCharacterCoordinates() }
  }

  // MARK: Drawing

  public override func draw(_ dirty: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    // lines come into view: their colours asked for, if not coloured yet
    colors?.see(visibleLines())
    let w = bounds.width
    let h = layout.metrics.row
    let band = dirty.minY...dirty.maxY
    let rows = layout.rows(in: band)
    // the caret's line, all of its rows
    if isEditable, let color = look.currentLine, editor.composition == nil, let line = caretLine() {
      ctx.setFillColor(color)
      for r in line.clamped(to: rows) { ctx.fill(CGRect(x: 0, y: layout.y(ofRow: r), width: w, height: h)) }
    }
    CodeDraw.decorations(
      decorations, of: layout, in: ctx, dirty: dirty, gutter: gutter, width: w, band: look.band, markX: 2,
      markSize: min(14, look.metrics.padLeft - 2))
    let s = editor.selection.range
    ctx.setFillColor(look.selection)
    for r in layout.rects(drawn(s.lowerBound)..<drawn(s.upperBound), right: w, within: band) where r.intersects(dirty) {
      ctx.fill(r)
    }
    let numberRight = gutter - look.metrics.numberGap
    for r in rows {
      let row = layout.placed(r)
      guard case .line(let n, let wrapped, let text, let runs) = row.kind else { continue }
      let mid = row.y + row.height / 2
      if !wrapped {
        CodeDraw.number(
          n, in: ctx, right: numberRight, midY: mid, font: look.style.font,
          color: decorations.numbers[n] ?? look.numberColor)
      }
      CodeDraw.line(text, runs: runs, in: ctx, x: gutter, midY: mid, style: look.style)
    }
    // the composition underlined
    let (_, at, n) = shown
    if n > 0 {
      ctx.setFillColor(look.style.ink)
      let f = look.style.font.ct
      for r in layout.rects(at..<(at + n), right: w, within: band) {
        let base = r.midY + (CTFontGetAscent(f) - CTFontGetDescent(f)) / 2 + 2
        ctx.fill(CGRect(x: r.minX, y: base, width: r.width, height: 1))
      }
    }
  }

  // MARK: Keys

  /// A key event's name as CodeKeys has them
  static func name(_ e: NSEvent) -> String {
    let keys: [UInt16: String] = [
      123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp", 51: "Backspace", 117: "Delete",
      36: "Enter", 76: "Enter", 48: "Tab", 53: "Escape", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
    ]
    let f = e.modifierFlags
    let key = keys[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").lowercased()
    return CodeKeys.name(
      key, shift: f.contains(.shift), command: f.contains(.command), control: f.contains(.control),
      option: f.contains(.option))
  }

  public override func keyDown(with e: NSEvent) {
    // an input method's keys are its own while it composes
    guard editor.composition == nil else { return interpretKeyEvents([e]) }
    let name = Self.name(e)
    if find(name) { return }
    switch name {
    case "Escape", "Meta-Enter":
      onExit?()
      return
    case "Meta-c": return copy(nil)
    case "Meta-x" where isEditable: return cut(nil)
    case "Meta-v" where isEditable: return paste(nil)
    default: break
    }
    if let c = CodeKeys.mac[name], isEditable || Self.selects(c) { return perform(c) }
    // read only: typing, editing keys and plain moves are the host's (to scroll with)
    if isEditable { interpretKeyEvents([e]) } else { super.keyDown(with: e) }
  }

  /// What a command does to text that cannot change: it selects (a move that extends the selection, the line, all)
  private static func selects(_ c: CodeCommand) -> Bool {
    if case .move(_, _, let extend) = c { return extend }
    return !c.changesText
  }

  /// ⌘F, ⌘G and ⇧⌘G come as key equivalents first, while the editor or its find bar has the keys
  public override func performKeyEquivalent(with e: NSEvent) -> Bool {
    let r = window?.firstResponder
    guard r === self || (findBar.map { (r as? NSView)?.isDescendant(of: $0) == true } ?? false) else { return false }
    return find(Self.name(e))
  }

  private func find(_ name: String) -> Bool {
    guard let look = findLook else { return false }
    switch name {
    // ⌥⌘F and ⌘H with the replacement (find.ts findKey), when the text can change
    case "Meta-f", "Meta-Alt-f", "Meta-h":
      let bar = findBar ?? makeFindBar()
      findFrom = editor.selection.range.lowerBound
      bar.show(replace: name != "Meta-f", look: look, in: .zero)
      placeFindBar()
      count()
    case "Meta-g", "Shift-Meta-g":
      guard findBar?.isHidden == false else { return false }
      findNext(forward: name == "Meta-g")
    default: return false
    }
    return true
  }

  private func makeFindBar() -> FindBar {
    let bar = FindBar()
    bar.canReplace = isEditable
    bar.onChange = { [weak self] in
      guard let self else { return }
      self.change { $0.select(CodeSelection(self.findFrom)) }
      self.findNext(forward: true)
    }
    bar.onStep = { [weak self] in self?.findNext(forward: $0) }
    bar.onReplace = { [weak self] in self?.replaceFound(all: $0) }
    bar.onCase = { [weak self] _ in self?.count() }
    bar.onResize = { [weak self] in self?.placeFindBar() }
    bar.onClose = { [weak self] in self?.closeFind() }
    bar.buttons = findButtons?()
    addSubview(bar)
    findBar = bar
    return bar
  }

  /// The next (or the one before) of what the find bar holds
  public func findNext(forward: Bool) {
    guard let q = findBar?.query.stringValue, !q.isEmpty else { return count() }
    let cs = findBar?.caseSensitive ?? false
    var found = false
    change { found = $0.find(q, forward: forward, caseSensitive: cs) }
    count()
    if found { revealFound() }
  }

  /// The match selected replaced by what the bar's replacement holds and the next one selected, or every match
  /// replaced (one step for undo); nothing when the text cannot change
  public func replaceFound(all: Bool) {
    guard isEditable, let bar = findBar, !bar.query.stringValue.isEmpty else { return }
    let (q, with, cs) = (bar.query.stringValue, bar.replacement.stringValue, bar.caseSensitive)
    var found = false
    change {
      if all {
        $0.replaceAll(q, with: with, caseSensitive: cs)
      } else {
        found = $0.replaceMatch(q, with: with, caseSensitive: cs)
      }
    }
    count()
    if found { revealFound() }
  }

  /// The match selected, for the host to bring into view
  private func revealFound() {
    let s = editor.selection.range
    if let r = firstBox(drawn(s.lowerBound)..<drawn(s.upperBound)) { onFound?(r) }
  }

  /// A range's first box: on the row it starts in (or the next, when it has none there)
  private func firstBox(_ range: Range<Int>) -> CGRect? {
    let top = layout.y(ofRow: layout.row(of: range.lowerBound, assoc: 1))
    return layout.rects(range, right: bounds.width, within: top...(top + 2 * layout.metrics.row)).first
  }

  /// "this match / all of them" in the bar
  private func count() {
    guard let bar = findBar else { return }
    let q = bar.query.stringValue
    guard !q.isEmpty else {
      bar.count.stringValue = ""
      return
    }
    let ns = editor.text as NSString
    var all: [Int] = []
    var r = NSRange(location: 0, length: ns.length)
    while true {
      let m = ns.range(of: q, options: bar.caseSensitive ? [] : .caseInsensitive, range: r)
      guard m.location != NSNotFound else { break }
      all.append(m.location)
      r = NSRange(location: NSMaxRange(m), length: ns.length - NSMaxRange(m))
    }
    let at = all.firstIndex(of: editor.selection.range.lowerBound)
    bar.count.stringValue = all.isEmpty ? "0" : at.map { "\($0 + 1)/\(all.count)" } ?? "\(all.count)"
  }

  /// Closes the find bar, the keys back to the editor
  public func closeFind() {
    findBar?.removeFromSuperview()
    findBar = nil
    window?.makeFirstResponder(self)
  }

  /// At the top right of the editor's part in view, at the screen's size whatever the view's zoom
  private func placeFindBar() {
    guard let bar = findBar, !bar.isHidden else { return }
    let z = bounds.width > 0 ? frame.width / bounds.width : 1
    let seen = window == nil ? bounds : visibleRect.intersection(bounds)
    let s = bar.size
    bar.frame = CGRect(
      x: max(0, (seen.isNull ? bounds : seen).maxX - (s.width + 6) / z), y: (seen.isNull ? bounds : seen).minY + 8 / z,
      width: s.width / z, height: s.height / z)
    bar.bounds.size = s
  }

  /// A key's command, over the rows as laid out; one that would change the text does nothing when it cannot change
  public func perform(_ c: CodeCommand) {
    guard isEditable || !c.changesText else { return }
    let before = editor.text
    let composed = editor.composition
    var rows = layout
    // a page: the rows in view less one (out of a window, everything is in view)
    let seen = window == nil ? bounds.height : visibleRect.height
    rows.pageRows = max(1, Int((seen / look.metrics.row).rounded(.down)) - 1)
    editor.perform(c, in: rows)
    changed(before, composed)
  }

  /// What reaches here: the input method's and AppKit's commands for keys CodeKeys has not
  public override func doCommand(by selector: Selector) {
    let commands: [Selector: CodeCommand] = [
      #selector(insertNewline(_:)): .newline, #selector(insertTab(_:)): .indent, #selector(insertBacktab(_:)): .outdent,
      #selector(deleteBackward(_:)): .deleteBackward, #selector(deleteForward(_:)): .deleteForward,
      #selector(moveLeft(_:)): .move(.character, forward: false, extend: false),
      #selector(moveRight(_:)): .move(.character, forward: true, extend: false),
      #selector(moveUp(_:)): .move(.line, forward: false, extend: false),
      #selector(moveDown(_:)): .move(.line, forward: true, extend: false),
    ]
    if let c = commands[selector] { return perform(c) }
    if selector == #selector(cancelOperation(_:)) { onExit?() }
  }

  @objc public func copy(_ sender: Any?) {
    let r = editor.selection.range
    guard !r.isEmpty else { return }
    pasteboard.clearContents()
    pasteboard.setString((editor.text as NSString).substring(with: NSRange(r)), forType: .string)
  }

  @objc public func cut(_ sender: Any?) {
    guard isEditable, !editor.selection.isEmpty else { return }
    copy(sender)
    change { $0.deleteBackward() }
  }

  @objc public func paste(_ sender: Any?) {
    guard isEditable, let s = pasteboard.string(forType: .string) else { return }
    change { $0.insert(s) }
  }

  public override func selectAll(_ sender: Any?) { perform(.selectAll) }
  @objc public func undo(_ sender: Any?) { perform(.undo) }
  @objc public func redo(_ sender: Any?) { perform(.redo) }

  // MARK: The mouse

  private func hit(_ e: NSEvent) -> (offset: Int, assoc: Int) {
    let (q, assoc) = layout.offset(at: convert(e.locationInWindow, from: nil))
    // in the composition: its start
    guard let c = editor.composition, q > c.at else { return (q, assoc) }
    return (max(c.at, q - (c.text as NSString).length), assoc)
  }

  public override func mouseDown(with e: NSEvent) {
    window?.makeFirstResponder(self)
    if editor.composition != nil, inputContext?.handleEvent(e) == true { return }
    let (q, assoc) = hit(e)
    if e.clickCount <= 1 { continuing = 0 }
    let clicks = max(1, e.clickCount - continuing)
    change { $0.press(at: q, clicks: clicks, extend: e.modifierFlags.contains(.shift), assoc: assoc) }
  }

  public override func mouseDragged(with e: NSEvent) {
    let (q, assoc) = hit(e)
    change { $0.drag(to: q, assoc: assoc) }
  }

  public override func mouseUp(with e: NSEvent) { editor.release() }
}

extension CodeEditorView: NSUserInterfaceValidations {
  /// Cut, paste, undo and redo only while the text can change (undo and redo with a step to take); copy and cut with a
  /// selection
  public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    guard let action = item.action else { return true }
    return switch action {
    case #selector(cut(_:)): isEditable && !editor.selection.isEmpty
    case #selector(copy(_:)): !editor.selection.isEmpty
    case #selector(paste(_:)): isEditable
    case #selector(undo(_:)): isEditable && editor.canUndo
    case #selector(redo(_:)): isEditable && editor.canRedo
    default: true
    }
  }
}

extension CodeEditorView: @preconcurrency NSTextInputClient {
  /// Ranges are of the text as drawn: while an input method composes, with its text in it. Nothing is written while the
  /// text cannot change
  public func insertText(_ string: Any, replacementRange: NSRange) {
    guard isEditable else { return }
    let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    change { e in
      if e.composition == nil, replacementRange.location != NSNotFound {
        e.select(CodeSelection(anchor: replacementRange.location, head: NSMaxRange(replacementRange)))
      }
      e.insert(s)
    }
  }

  public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard isEditable else { return }
    let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    change { e in
      if e.composition == nil, replacementRange.location != NSNotFound {
        e.select(CodeSelection(anchor: replacementRange.location, head: NSMaxRange(replacementRange)))
      }
      e.setMarked(s, selected: selectedRange.location..<NSMaxRange(selectedRange))
    }
  }

  public func unmarkText() {
    guard let c = editor.composition else { return }
    change { $0.insert(c.text) }
  }

  public func selectedRange() -> NSRange {
    if let c = editor.composition { return NSRange(location: c.at + c.selected.lowerBound, length: c.selected.count) }
    return NSRange(editor.selection.range)
  }

  public func markedRange() -> NSRange {
    guard let c = editor.composition else { return NSRange(location: NSNotFound, length: 0) }
    return NSRange(location: c.at, length: (c.text as NSString).length)
  }

  public func hasMarkedText() -> Bool { editor.composition != nil }

  public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString?
  {
    let ns = shown.text as NSString
    let r = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
    actualRange?.pointee = r
    return NSAttributedString(string: ns.substring(with: r))
  }

  public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }

  /// Where the candidate window goes: the range's first row, on screen
  public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = range
    let r = firstBox(range.location..<NSMaxRange(range)) ?? layout.caret(range.location, assoc: 1)
    guard let w = window else { return r }
    return w.convertToScreen(convert(r, to: nil))
  }

  public func characterIndex(for point: NSPoint) -> Int {
    guard let w = window else { return NSNotFound }
    return layout.offset(at: convert(w.convertPoint(fromScreen: point), from: nil)).offset
  }
}
