import Testing
import TreeSitterCore

private func parse(_ language: Language, _ text: String) throws -> SyntaxTree {
  try #require(language.parse(Array(text.utf16)))
}

/// Every node of the tree, outer first: its type and span
private func nodes(_ tree: SyntaxTree) -> [String] {
  var out: [String] = []
  tree.root.walk { node in
    out.append("\(node.type)@\(node.startIndex)-\(node.endIndex)/\(node.startRow):\(node.startColumn)")
    return true
  }
  return out
}

@Suite struct Parsing {
  @Test func eachBuiltInLanguageParsesItsCodeWithoutErrors() throws {
    let samples: [(Language, String, String)] = [
      (.python, "def f(x):\n    return x\n", "module"),
      (.rust, "fn f(x: i32) -> i32 { x }\n", "source_file"),
      (.cuda, "__global__ void k(int* x) {}\nvoid g() { k<<<1, 32>>>(nullptr); }\n", "translation_unit"),
    ]
    for (language, text, root) in samples {
      let tree = try parse(language, text)
      #expect(tree.root.type == root)
      #expect(!tree.root.hasError, "\(text)")
      #expect(tree.units == Array(text.utf16))
    }
  }

  /// The grammar's package leaves its external scanner out; without it an indented block would not parse
  @Test func pythonsScannerIsLinked() throws {
    let tree = try parse(.python, "if x:\n    y = 1\n    if y:\n        z = '''a\nb'''\n")
    #expect(!tree.root.hasError)
    var blocks = 0
    tree.root.walk { node in
      if node.type == "block" { blocks += 1 }
      return true
    }
    #expect(blocks == 2)
  }

  @Test func indexesAndColumnsAreUTF16CodeUnits() throws {
    let tree = try parse(.python, "s = '😀'\nt = 中\n")
    let t = try #require(tree.root.namedChild(1)?.firstNamedChild?.field("left"))
    #expect(t.text == "t")
    #expect(t.startIndex == 9 && t.endIndex == 10)
    #expect(t.startRow == 1 && t.startColumn == 0)
    let string = try #require(tree.root.firstNamedChild?.firstNamedChild?.field("right"))
    #expect(string.range == 4..<8)
    #expect(string.endColumn == 8)
    #expect(string.text == "'😀'")
  }

  @Test func anEmptyTextGivesAnEmptyTree() throws {
    let tree = try parse(.python, "")
    #expect(tree.root.range == 0..<0)
    #expect(!tree.root.hasError)
  }

  @Test func errorsAreFoundWhereTheParseCouldNotPlaceText() throws {
    let tree = try parse(.cuda, "int f( { return 1; }\n")
    #expect(tree.root.hasError)
    var errors = 0
    tree.root.walk { node in
      if node.isError || node.isMissing { errors += 1 }
      return node.hasError
    }
    #expect(errors > 0)
  }

  @Test func anIncrementalParseAfterAnEditIsAFreshParse() throws {
    let steps = [
      "def f(x):\n    return x\n",
      "def f(x, y):\n    return x\n",
      "import json\ndef f(x, y):\n    return x\n",
      "import json\ndef f(x, y):\n    return '😀' + x\n",
      "import json\ndef f(x, y):\n    return '😃' + x\n",
      "import json\ndef f(x, y):\n    return x\n\nclass A:\n    pass\n",
      "def f(x, y:\n    return x\n",
    ]
    let parser = try #require(Parser(.python))
    var tree = parser.parse(Array(steps[0].utf16))
    for (a, b) in zip(steps, steps.dropFirst()) {
      tree.edit(diffEdit(a, b))
      tree = parser.parse(Array(b.utf16), old: tree)
      #expect(nodes(tree) == nodes(try parse(.python, b)), "\(b)")
    }
  }
}

@Suite struct Nodes {
  @Test func aNodeLeadsToItsParentChildrenSiblingsAndFields() throws {
    let tree = try parse(.python, "def f(a, b=1, *c):\n    pass\n")
    let def = try #require(tree.root.firstNamedChild)
    #expect(def.type == "function_definition")
    #expect(def.parent == tree.root)
    #expect(tree.root.parent == nil)
    #expect(def.field("name")?.text == "f")
    #expect(def.field("nothing") == nil)
    #expect(def.child(0)?.type == "def")
    #expect(def.child(0)?.isNamed == false)
    #expect(def.child(-1) == nil && def.child(99) == nil)
    let params = try #require(def.field("parameters"))
    #expect(params.namedChildCount == 3)
    #expect(params.namedChildren.map(\.type) == ["identifier", "default_parameter", "list_splat_pattern"])
    #expect(params.firstNamedChild?.text == "a")
    #expect(params.lastNamedChild?.text == "*c")
    #expect(params.firstNamedChild?.nextNamedSibling?.text == "b=1")
    #expect(params.lastNamedChild?.nextNamedSibling == nil)
    #expect(params.namedChild(1) == params.firstNamedChild?.nextNamedSibling)
    #expect(params.firstNamedChild != params.lastNamedChild)
    #expect(try #require(params.namedChild(2)).firstNamedChild?.namedChildCount == 0)
    #expect(try #require(params.namedChild(2)).firstNamedChild?.lastNamedChild == nil)
  }

  @Test func fieldsGivesEveryChildUnderAField() throws {
    let tree = try parse(.rust, "fn f() { let (a, b) = (1, 2); }\n")
    var tuple: Node?
    tree.root.walk { node in
      if node.type == "tuple_pattern" { tuple = node }
      return tuple == nil
    }
    let call = try parse(.cuda, "int x = f(1, 2);\n")
    let declaration = try #require(call.root.firstNamedChild)
    #expect(declaration.fields("declarator").map(\.text) == ["x = f(1, 2)"])
    #expect(declaration.fields("no_such_field").isEmpty)
    #expect(tuple?.namedChildren.map(\.text) == ["a", "b"])
  }

  @Test func aWalkGoesIntoTheChildrenItIsToldTo() throws {
    let tree = try parse(.python, "def f():\n    g(h(1))\n")
    var seen: [String] = []
    tree.root.walk { node in
      seen.append(node.type)
      return node.type != "call"
    }
    #expect(seen.filter { $0 == "call" }.count == 1, "the inner call is not visited")
    #expect(seen.first == "module")
  }
}

@Suite struct Queries {
  static let source = "class A:\n    def run(self, x):\n        return Y(x) + cls\n"

  @Test func capturesAreNamedAndMeetTheirPredicates() throws {
    let tree = try parse(.python, Queries.source)
    let query = try Query(
      .python,
      """
      ((identifier) @self (#any-of? @self "self" "cls"))
      ((identifier) @type (#match? @type "^[A-Z]"))
      (function_definition name: (identifier) @fn)
      """)
    #expect(query.names == ["self", "type", "fn"])
    let captures = query.captures(under: tree.root)
    #expect(captures.map { "\($0.name) \($0.node.text)" } == ["type A", "fn run", "self self", "type Y", "self cls"])
    #expect(captures.map(\.index) == [1, 2, 0, 1, 0])
  }

  @Test func matchesGiveTheirPatternAndCaptures() throws {
    let tree = try parse(.python, Queries.source)
    let query = try Query(
      .python,
      """
      (call function: (identifier) @callee arguments: (argument_list (identifier) @arg))
      ((identifier) @self (#any-of? @self "self"))
      """)
    var matches: [String] = []
    query.forEachMatch(under: tree.root) { match in
      matches.append("\(match.pattern): " + match.captures.map { "\($0.name)=\($0.node.text)" }.joined(separator: " "))
    }
    #expect(matches == ["1: self=self", "0: callee=Y arg=x"])
  }

  @Test func aSearchIsLimitedToRowsOrCodeUnits() throws {
    let tree = try parse(.python, Queries.source)
    let query = try Query(.python, "(identifier) @id")
    let all = query.captures(under: tree.root).map(\.node.text)
    #expect(all == ["A", "run", "self", "x", "Y", "x", "cls"])
    #expect(query.captures(under: tree.root, rows: 1..<2).map(\.node.text) == ["run", "self", "x"])
    #expect(query.captures(under: tree.root, rows: 2..<3).map(\.node.text) == ["Y", "x", "cls"])
    let wrapped = Int(UInt32.max) + 3
    #expect(
      query.captures(under: tree.root, rows: wrapped..<wrapped + 1).map(\.node.text) == ["Y", "x", "cls"],
      "rows wrap as 32-bit integers")
    #expect(query.captures(under: tree.root, units: 0..<8).map(\.node.text) == ["A"])
    var inLine = 0
    query.forEachMatch(under: tree.root, rows: 1..<2) { _ in inLine += 1 }
    #expect(inLine == 3)
    let def = try #require(tree.root.firstNamedChild?.field("body")?.firstNamedChild)
    #expect(query.captures(under: def).map(\.node.text) == ["run", "self", "x", "Y", "x", "cls"])
  }

  @Test func aWrongQuerySaysWhy() {
    #expect(throws: QueryError.invalid(kind: 2, offset: 1)) { try Query(.python, "(no_such_node) @x") }
    #expect(throws: QueryError.self) { try Query(.python, "(identifier) @x (") }
    #expect(throws: QueryError.predicate("#eq? is not supported")) {
      try Query(.python, "((identifier) @x (#eq? @x \"y\"))")
    }
    #expect(throws: QueryError.self) { try Query(.python, "((identifier) @x (#match? @x \"(\"))") }
  }
}

@Suite struct Edits {
  @Test func diffEditCoversTheChangedSpan() {
    #expect(
      diffEdit("ab\ncd\nef", "ab\ncXd\nef")
        == TreeEdit(
          startIndex: 4, oldEndIndex: 4, newEndIndex: 5, startPosition: .init(row: 1, column: 1),
          oldEndPosition: .init(row: 1, column: 1), newEndPosition: .init(row: 1, column: 2)))
    let same = diffEdit("aaa", "aaa")
    #expect(same.startIndex == 3 && same.oldEndIndex == 3 && same.newEndIndex == 3)
    #expect(diffEdit(Array("ab".utf16), Array("b".utf16)) == diffEdit("ab", "b"))
  }

  @Test func diffEditNeverSplitsASurrogatePair() {
    let pair = diffEdit("x😀y", "x😃y")
    #expect(pair.startIndex == 1 && pair.oldEndIndex == 3 && pair.newEndIndex == 3)
    #expect(pair.startPosition == .init(row: 0, column: 1) && pair.oldEndPosition == .init(row: 0, column: 3))
    // 😀 and 𐘀 share their trailing half
    let trail = diffEdit("x😀", "x𐘀")
    #expect(trail.startIndex == 1 && trail.oldEndIndex == 3 && trail.newEndIndex == 3)
    let below = diffEdit("a\n😀b", "a\n😃b")
    #expect(below.startIndex == 2 && below.oldEndIndex == 4 && below.newEndIndex == 4)
    #expect(below.startPosition == .init(row: 1, column: 0) && below.oldEndPosition == .init(row: 1, column: 2))
  }
}
