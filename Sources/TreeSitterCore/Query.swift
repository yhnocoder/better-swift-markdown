import Foundation
import TreeSitter

/// A compiled tree-sitter query, its captures named and its predicates resolved: `#match?` (an NSRegularExpression
/// pattern found anywhere in the capture's text) and `#any-of?` (the capture's text is one of the words).
///
/// Never changed after it is made, and tree-sitter lets threads share a TSQuery: what a search changes lives in the
/// TSQueryCursor each search makes for itself.
public final class Query: @unchecked Sendable {
  private enum Predicate {
    case anyOf(capture: UInt32, Set<String>)
    case match(capture: UInt32, NSRegularExpression)
  }

  let raw: OpaquePointer
  /// By capture index
  public let names: [String]
  /// By pattern index
  private let predicates: [[Predicate]]

  public init(_ language: Language, _ source: String) throws(QueryError) {
    var offset: UInt32 = 0
    var error = TSQueryErrorNone
    guard let raw = ts_query_new(language.raw, source, UInt32(source.utf8.count), &offset, &error) else {
      throw .invalid(kind: error.rawValue, offset: Int(offset))
    }
    self.raw = raw
    func string(_ id: UInt32, _ get: (OpaquePointer, UInt32, UnsafeMutablePointer<UInt32>) -> UnsafePointer<CChar>?)
      -> String
    {
      var length: UInt32 = 0
      return get(raw, id, &length).map { String(cString: $0) } ?? ""
    }
    names = (0..<ts_query_capture_count(raw)).map { string($0, ts_query_capture_name_for_id) }
    var predicates: [[Predicate]] = []
    for pattern in 0..<ts_query_pattern_count(raw) {
      var count: UInt32 = 0
      let steps = UnsafeBufferPointer(start: ts_query_predicates_for_pattern(raw, pattern, &count), count: Int(count))
      var resolved: [Predicate] = []
      for p in steps.split(whereSeparator: { $0.type == TSQueryPredicateStepTypeDone }) {
        let name = string(p[p.startIndex].value_id, ts_query_string_value_for_id)
        let args = p.dropFirst()
        guard let capture = args.first, capture.type == TSQueryPredicateStepTypeCapture,
          args.dropFirst().allSatisfy({ $0.type == TSQueryPredicateStepTypeString })
        else { throw .predicate("#\(name) takes a capture and then strings") }
        let words = args.dropFirst().map { string($0.value_id, ts_query_string_value_for_id) }
        switch name {
        case "any-of?": resolved.append(.anyOf(capture: capture.value_id, Set(words)))
        case "match?":
          guard words.count == 1, let re = try? NSRegularExpression(pattern: words[0]) else {
            throw .predicate("#match? takes one valid pattern: \(words)")
          }
          resolved.append(.match(capture: capture.value_id, re))
        default: throw .predicate("#\(name) is not supported")
        }
      }
      predicates.append(resolved)
    }
    self.predicates = predicates
  }

  deinit { ts_query_delete(raw) }

  /// Each match under `node` that meets its predicates, in the order tree-sitter finds them. `units` limits the search
  /// to the nodes that meet that span of code units, `rows` to those that meet those rows (start inclusive, end
  /// exclusive). The match's captures are valid only inside `body`.
  public func forEachMatch(
    under node: Node, units: Range<Int>? = nil, rows: Range<Int>? = nil, _ body: (QueryMatch) -> Void
  ) {
    search(node, units, rows) { cursor in
      var match = TSQueryMatch()
      while ts_query_cursor_next_match(cursor, &match) {
        let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
        let pattern = Int(match.pattern_index)
        guard holds(pattern, captures, node.units) else { continue }
        let taken = QueryMatch.Captures(buffer: captures, names: names, units: node.units)
        body(QueryMatch(pattern: pattern, captures: taken))
      }
    }
  }

  /// The captures under `node` in the order tree-sitter gives them, of the matches that meet their predicates; `units`
  /// and `rows` limit them as in `forEachMatch`
  public func captures(under node: Node, units: Range<Int>? = nil, rows: Range<Int>? = nil) -> [QueryCapture] {
    var out: [QueryCapture] = []
    search(node, units, rows) { cursor in
      var match = TSQueryMatch()
      var index: UInt32 = 0
      while ts_query_cursor_next_capture(cursor, &match, &index) {
        let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
        guard holds(Int(match.pattern_index), captures, node.units) else { continue }
        let c = captures[Int(index)]
        out.append(QueryCapture(index: Int(c.index), name: names[Int(c.index)], node: Node(c.node, node.units)))
      }
    }
    return out
  }

  private func search(_ node: Node, _ units: Range<Int>?, _ rows: Range<Int>?, _ run: (OpaquePointer) -> Void) {
    let cursor = ts_query_cursor_new()!
    defer { ts_query_cursor_delete(cursor) }
    if let units {
      ts_query_cursor_set_byte_range(cursor, UInt32(units.lowerBound * 2), UInt32(units.upperBound * 2))
    }
    if let rows {
      // Rows out of range wrap as a 32-bit integer does, as JavaScript's tree-sitter binding wraps them, instead of
      // trapping
      ts_query_cursor_set_point_range(
        cursor, TSPoint(row: UInt32(truncatingIfNeeded: rows.lowerBound), column: 0),
        TSPoint(row: UInt32(truncatingIfNeeded: rows.upperBound), column: 0))
    }
    ts_query_cursor_exec(cursor, raw, node.raw)
    run(cursor)
  }

  /// Whether a match of `pattern` meets its predicates
  private func holds(_ pattern: Int, _ captures: UnsafeBufferPointer<TSQueryCapture>, _ units: [UInt16]) -> Bool {
    predicates[pattern].allSatisfy { predicate in
      switch predicate {
      case .anyOf(let id, let words):
        captures.allSatisfy { $0.index != id || words.contains(Node($0.node, units).text) }
      case .match(let id, let re):
        captures.allSatisfy { c in
          guard c.index == id else { return true }
          let s = Node(c.node, units).text
          return re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
        }
      }
    }
  }
}

/// Why a query could not be made
public enum QueryError: Error, Hashable {
  /// tree-sitter's TSQueryError (1 syntax, 2 node type, 3 field, 4 capture, 5 structure, 6 language) and the UTF-8
  /// offset in the source where it found it
  case invalid(kind: UInt32, offset: Int)
  /// A predicate other than `#match?` and `#any-of?`, or one written wrong
  case predicate(String)
}

/// A capture: its index among the query's captures, its name, and the node it took
public struct QueryCapture {
  public let index: Int
  public let name: String
  public let node: Node
}

/// A match of one of the query's patterns, with the captures it took
public struct QueryMatch {
  /// The pattern's index, in the order the query's source has them
  public let pattern: Int
  public let captures: Captures

  public struct Captures: RandomAccessCollection {
    let buffer: UnsafeBufferPointer<TSQueryCapture>
    let names: [String]
    let units: [UInt16]

    public var startIndex: Int { 0 }
    public var endIndex: Int { buffer.count }

    public subscript(i: Int) -> QueryCapture {
      let c = buffer[i]
      return QueryCapture(index: Int(c.index), name: names[Int(c.index)], node: Node(c.node, units))
    }
  }
}
