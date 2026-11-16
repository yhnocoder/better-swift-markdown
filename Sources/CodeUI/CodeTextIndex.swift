import Foundation

/// Where a text's lines and rows are, found in one pass over its UTF-8 bytes: each line's start (in UTF-16 units and in
/// bytes) and first row, each row's y, and where the room inserted after lines goes. Nothing of what a row holds
struct CodeTextIndex: Sendable {
  /// Rows cut at `width`, ASCII `charWidth` a character and a tab to its stop, `tabWidth` columns apart
  struct Wrap {
    var width: CGFloat
    var charWidth: CGFloat
    var tabWidth: Int
  }

  /// Each line's start in UTF-16 units, then one past the text's end (where a line after it would start)
  let starts16: [Int]
  /// Each line's start in bytes, then one past the text's end
  let starts8: [Int]
  /// Each line's first row, then the row count
  let firstRows: [Int]
  /// Each row's y without the room, then where a row after the last would be, added up row by row as CodeLines does
  let ys: [CGFloat]
  let rowHeight: CGFloat
  /// The room in the order it is laid out: the row each goes before
  let placeRows: [Int]
  /// The room's heights, by its index in the insertions given
  let heights: [CGFloat]
  /// Each insertion's place in the laid out order, by its index
  let slots: [Int]
  /// The room above each of the laid out order, then all of it
  let shifts: [CGFloat]

  /// `insertions` placed as CodeLines.insert places them; `rows`: how many rows a line takes when it may not fit `wrap`,
  /// given its bytes and, when they are all ASCII, its columns with tabs to their stops
  init(
    _ bytes: UnsafeBufferPointer<UInt8>, firstNumber: Int, insertions: [(afterLine: Int, height: CGFloat)],
    top: CGFloat, rowHeight: CGFloat, wrap: Wrap?, rows: (Slice<UnsafeBufferPointer<UInt8>>, Int?) -> Int
  ) {
    var starts16 = [0]
    var starts8 = [0]
    var firstRows = [0]
    let n = bytes.count
    let wrapping = wrap != nil
    let tabWidth = wrap?.tabWidth ?? 1
    var u16 = 0
    var columns = 0
    var ascii = true
    var start = 0
    var i = 0
    while true {
      let b: UInt8 = i < n ? bytes[i] : 0x0A
      if b == 0x0A {
        var count = 1
        if let wrap, !(ascii && CGFloat(columns) * wrap.charWidth <= wrap.width) {
          count = rows(bytes[start..<i], ascii ? columns : nil)
        }
        firstRows.append(firstRows[firstRows.count - 1] + count)
        u16 += 1
        starts16.append(u16)
        starts8.append(i + 1)
        if i >= n { break }
        (start, columns, ascii) = (i + 1, 0, true)
      } else if b < 0x80 {
        u16 += 1
        if wrapping { columns += b == 0x09 ? tabWidth - columns % tabWidth : 1 }
      } else {
        ascii = false
        // a lead byte: one UTF-16 unit, two for a four-byte sequence; continuation bytes none
        if b >= 0xC0 { u16 += b >= 0xF0 ? 2 : 1 }
      }
      i += 1
    }
    let rowCount = firstRows[firstRows.count - 1]
    var ys: [CGFloat] = []
    ys.reserveCapacity(rowCount + 1)
    var y = top
    for _ in 0..<rowCount {
      ys.append(y)
      y += rowHeight
    }
    ys.append(y)
    // the row each goes before: the first of the first line numbered past its line
    let lineCount = starts16.count - 1
    let at = insertions.map { item in
      firstRows[item.afterLine < firstNumber ? 0 : min(lineCount, item.afterLine - firstNumber + 1)]
    }
    let order = insertions.indices.sorted { (at[$0], $0) < (at[$1], $1) }
    var shifts: [CGFloat] = [0]
    var shift: CGFloat = 0
    var slots = [Int](repeating: 0, count: insertions.count)
    for (j, k) in order.enumerated() {
      shift += insertions[k].height
      shifts.append(shift)
      slots[k] = j
    }
    self.starts16 = starts16
    self.starts8 = starts8
    self.firstRows = firstRows
    self.ys = ys
    self.rowHeight = rowHeight
    placeRows = order.map { at[$0] }
    heights = insertions.map(\.height)
    self.slots = slots
    self.shifts = shifts
  }

  var lineCount: Int { starts16.count - 1 }
  var rowCount: Int { firstRows[firstRows.count - 1] }
  /// Under the last row and the room after it
  var bottom: CGFloat { ys[ys.count - 1] + shifts[shifts.count - 1] }

  /// The first of 0..<n for which `p` holds (n when none does), `p` false up to some point and true from it on
  static func first(_ n: Int, where p: (Int) -> Bool) -> Int {
    var lo = 0
    var hi = n
    while lo < hi {
      let mid = (lo + hi) / 2
      if p(mid) { hi = mid } else { lo = mid + 1 }
    }
    return lo
  }

  /// The line a row is of
  func line(ofRow r: Int) -> Int {
    rowCount == lineCount ? r : Self.first(lineCount) { firstRows[$0 + 1] > r }
  }

  /// The line a UTF-16 offset is in: the first for one before the text, the last for one past it
  func line(at q: Int) -> Int { max(0, Self.first(lineCount) { starts16[$0] > q } - 1) }

  /// The line a byte is in, as `line(at:)`
  func line(atByte b: Int) -> Int { max(0, Self.first(lineCount) { starts8[$0] > b } - 1) }

  /// A row's y, the room above it with it
  func y(_ r: Int) -> CGFloat { ys[r] + shifts[Self.first(placeRows.count) { placeRows[$0] > r }] }

  /// The last row whose top is at or above `y`; the first when all are under it
  func row(atY y: CGFloat) -> Int { max(0, Self.first(rowCount) { self.y($0) > y } - 1) }

  /// The rows with some of their height in `band` (one that only touches it is not)
  func rows(in band: ClosedRange<CGFloat>) -> Range<Int> {
    let lo = Self.first(rowCount) { y($0) + rowHeight > band.lowerBound }
    let hi = Self.first(rowCount) { y($0) >= band.upperBound }
    return lo..<max(lo, hi)
  }

  /// The bottom of room `k` (its index in the insertions given); nil when there is none
  func roomBottom(_ k: Int) -> CGFloat? {
    guard slots.indices.contains(k) else { return nil }
    let j = slots[k]
    return ys[placeRows[j]] + shifts[j] + heights[k]
  }

  /// What to draw again when `old`'s text (`was`) became this one's (`now`), all else alike: nil when the bytes are the
  /// same; else from the top of the first line that differs to the bottom of the last, in either, and on to the
  /// bottom when the rows under them moved (other rows, lines or places of the room)
  func changed(
    from old: CodeTextIndex, was: UnsafeBufferPointer<UInt8>, now: UnsafeBufferPointer<UInt8>
  ) -> ClosedRange<CGFloat>? {
    let p = Self.commonPrefix(was, now)
    let s = Self.commonSuffix(was, now, limit: min(was.count, now.count) - p)
    guard p < was.count - s || p < now.count - s else { return nil }
    // the lines before it are alike in both
    let first = self.line(atByte: p)
    let top = min(y(firstRows[first]), old.y(old.firstRows[first]))
    func end(_ x: CodeTextIndex, _ last: Int) -> CGFloat {
      x.y(x.firstRows[x.line(atByte: last) + 1] - 1) + x.rowHeight
    }
    var bottom = max(end(old, was.count - s), end(self, now.count - s))
    if rowCount != old.rowCount || lineCount != old.lineCount || placeRows != old.placeRows {
      bottom = max(bottom, self.bottom, old.bottom)
    }
    return top...bottom
  }

  /// How many bytes two texts begin with alike
  static func commonPrefix(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
    let n = min(a.count, b.count)
    let block = 4096
    var p = 0
    while p + block <= n, let x = a.baseAddress, let y = b.baseAddress, memcmp(x + p, y + p, block) == 0 { p += block }
    while p < n, a[p] == b[p] { p += 1 }
    return p
  }

  /// How many bytes two texts end with alike, at most `limit`
  static func commonSuffix(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, limit: Int) -> Int {
    let block = 4096
    var s = 0
    while s + block <= limit, let x = a.baseAddress, let y = b.baseAddress,
      memcmp(x + (a.count - s - block), y + (b.count - s - block), block) == 0
    {
      s += block
    }
    while s < limit, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
    return s
  }

  /// How many lines a text has: one more than its "\n"s
  static func count(linesOf text: String) -> Int {
    var text = text
    return text.withUTF8 { bytes in
      guard var p = bytes.baseAddress else { return 1 }
      let end = p + bytes.count
      var n = 1
      while p < end, let hit = memchr(p, 0x0A, end - p) {
        n += 1
        p = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) + 1
      }
      return n
    }
  }
}
