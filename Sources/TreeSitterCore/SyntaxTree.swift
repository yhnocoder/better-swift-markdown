import TreeSitter

/// A parsed text and the UTF-16 code units it was parsed from. Every index and column of its nodes is a UTF-16 code
/// unit, as JavaScript's strings and NSString count them.
public final class SyntaxTree {
  let raw: OpaquePointer
  /// The text the tree was parsed from
  public let units: [UInt16]

  init(_ raw: OpaquePointer, _ units: [UInt16]) {
    self.raw = raw
    self.units = units
  }

  deinit { ts_tree_delete(raw) }

  public var root: Node { Node(ts_tree_root_node(raw), units) }

  /// Tells the tree of a change to its text, before it is passed as `old` to a parse of the new text. Its nodes and
  /// `units` still speak of the old text: an edited tree is for that parse only.
  public func edit(_ e: TreeEdit) {
    func point(_ p: TreeEdit.Point) -> TSPoint { TSPoint(row: UInt32(p.row), column: UInt32(p.column * 2)) }
    var input = TSInputEdit(
      start_byte: UInt32(e.startIndex * 2), old_end_byte: UInt32(e.oldEndIndex * 2),
      new_end_byte: UInt32(e.newEndIndex * 2), start_point: point(e.startPosition),
      old_end_point: point(e.oldEndPosition), new_end_point: point(e.newEndPosition))
    ts_tree_edit(raw, &input)
  }
}

/// A syntax node, valid as long as its tree is; indexes and columns in UTF-16 code units, rows 0-based. Two nodes are
/// equal when they are the same node of the same tree.
public struct Node: Equatable {
  let raw: TSNode
  /// The whole text of the node's tree
  public let units: [UInt16]

  init(_ raw: TSNode, _ units: [UInt16]) {
    self.raw = raw
    self.units = units
  }

  private func wrap(_ n: TSNode) -> Node? { ts_node_is_null(n) ? nil : Node(n, units) }

  public static func == (a: Node, b: Node) -> Bool { ts_node_eq(a.raw, b.raw) }

  /// The grammar's name for the node, or the token itself for an anonymous one (`(`, `def`)
  public var type: String { String(cString: ts_node_type(raw)) }
  public var isNamed: Bool { ts_node_is_named(raw) }
  /// An ERROR node: text the parse could not place
  public var isError: Bool { ts_node_is_error(raw) }
  /// A node the parse invented to recover (a missing `)`), with no text
  public var isMissing: Bool { ts_node_is_missing(raw) }
  /// Whether the node is or holds an ERROR or missing node
  public var hasError: Bool { ts_node_has_error(raw) }

  public var startIndex: Int { Int(ts_node_start_byte(raw)) / 2 }
  public var endIndex: Int { Int(ts_node_end_byte(raw)) / 2 }
  public var range: Range<Int> { startIndex..<endIndex }
  public var startRow: Int { Int(ts_node_start_point(raw).row) }
  public var startColumn: Int { Int(ts_node_start_point(raw).column) / 2 }
  public var endRow: Int { Int(ts_node_end_point(raw).row) }
  public var endColumn: Int { Int(ts_node_end_point(raw).column) / 2 }
  public var text: String { String(decoding: units[startIndex..<endIndex], as: UTF16.self) }

  public var parent: Node? { wrap(ts_node_parent(raw)) }
  /// The child at `index`, named or not
  public func child(_ index: Int) -> Node? { index < 0 ? nil : wrap(ts_node_child(raw, UInt32(index))) }
  public var namedChildCount: Int { Int(ts_node_named_child_count(raw)) }
  public func namedChild(_ index: Int) -> Node? { index < 0 ? nil : wrap(ts_node_named_child(raw, UInt32(index))) }
  public var firstNamedChild: Node? { namedChild(0) }
  public var lastNamedChild: Node? { namedChild(namedChildCount - 1) }
  public var nextNamedSibling: Node? { wrap(ts_node_next_named_sibling(raw)) }

  /// The first child under the field
  public func field(_ name: String) -> Node? {
    wrap(ts_node_child_by_field_name(raw, name, UInt32(name.utf8.count)))
  }

  /// Every child under the field, named or not
  public func fields(_ name: String) -> [Node] {
    let id = ts_language_field_id_for_name(ts_node_language(raw), name, UInt32(name.utf8.count))
    guard id != 0 else { return [] }
    return children { ts_tree_cursor_current_field_id(&$0) == id }
  }

  public var namedChildren: [Node] { children { ts_node_is_named(ts_tree_cursor_current_node(&$0)) } }

  // By a cursor: ts_node_named_child(i) walks from the first child each time
  private func children(where keep: (inout TSTreeCursor) -> Bool) -> [Node] {
    var cursor = ts_tree_cursor_new(raw)
    defer { ts_tree_cursor_delete(&cursor) }
    var out: [Node] = []
    guard ts_tree_cursor_goto_first_child(&cursor) else { return out }
    repeat {
      if keep(&cursor) { out.append(Node(ts_tree_cursor_current_node(&cursor), units)) }
    } while ts_tree_cursor_goto_next_sibling(&cursor)
    return out
  }

  /// This node and those under it in source order, outer first; `visit` says whether to go into a node's children
  public func walk(_ visit: (Node) -> Bool) {
    var cursor = ts_tree_cursor_new(raw)
    defer { ts_tree_cursor_delete(&cursor) }
    while true {
      if visit(Node(ts_tree_cursor_current_node(&cursor), units)), ts_tree_cursor_goto_first_child(&cursor) {
        continue
      }
      while !ts_tree_cursor_goto_next_sibling(&cursor) {
        guard ts_tree_cursor_goto_parent(&cursor) else { return }
      }
    }
  }
}
