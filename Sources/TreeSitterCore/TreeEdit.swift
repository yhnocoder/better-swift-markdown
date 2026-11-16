/// A change to a text, as a tree is told of it (`SyntaxTree.edit`): the span that changed, in UTF-16 code units, rows
/// and columns 0-based
public struct TreeEdit: Hashable, Sendable {
  public struct Point: Hashable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
      self.row = row
      self.column = column
    }
  }

  public var startIndex: Int
  public var oldEndIndex: Int
  public var newEndIndex: Int
  public var startPosition: Point
  public var oldEndPosition: Point
  public var newEndPosition: Point

  public init(
    startIndex: Int, oldEndIndex: Int, newEndIndex: Int, startPosition: Point, oldEndPosition: Point,
    newEndPosition: Point
  ) {
    self.startIndex = startIndex
    self.oldEndIndex = oldEndIndex
    self.newEndIndex = newEndIndex
    self.startPosition = startPosition
    self.oldEndPosition = oldEndPosition
    self.newEndPosition = newEndPosition
  }
}

/// The difference of two texts as one edit: what lies between their common prefix and suffix
public func diffEdit(_ a: String, _ b: String) -> TreeEdit { diffEdit(Array(a.utf16), Array(b.utf16)) }

/// The difference of two UTF-16 texts as one edit: what lies between their common prefix and suffix
public func diffEdit(_ a: [UInt16], _ b: [UInt16]) -> TreeEdit {
  let n = min(a.count, b.count)
  var s = 0
  while s < n && a[s] == b[s] { s += 1 }
  var e = 0
  while e < n - s && a[a.count - 1 - e] == b[b.count - 1 - e] { e += 1 }
  // Never between the halves of a surrogate pair
  if s > 0 && UTF16.isLeadSurrogate(a[s - 1]) { s -= 1 }
  if e > 0 && UTF16.isTrailSurrogate(a[a.count - e]) { e -= 1 }
  return TreeEdit(
    startIndex: s, oldEndIndex: a.count - e, newEndIndex: b.count - e, startPosition: point(a, s),
    oldEndPosition: point(a, a.count - e), newEndPosition: point(b, b.count - e))
}

private func point(_ t: [UInt16], _ i: Int) -> TreeEdit.Point {
  var row = 0
  var lineStart = 0
  for k in 0..<i where t[k] == 0x0A {
    row += 1
    lineStart = k + 1
  }
  return TreeEdit.Point(row: row, column: i - lineStart)
}
