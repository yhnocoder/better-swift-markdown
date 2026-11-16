import Foundation
import TreeSitterCore

/// A tree-sitter grammar and its highlight query, for the languages it is named by. The highlight query's captures are
/// the colour classes (`kw`, `op`, `fn`, `str`, `com`, `num`, `self`, `p`), `plain`, and the steps the highlighter does
/// in code (`callee`, `macro`, `prefix`, `fmt`, `doc`, `dec`; see `Action`); its predicates `#any-of?` and `#match?`.
/// Python, Rust and C, C++ and CUDA come built in; a host adds others with `Highlighter(grammars:)`.
public struct Grammar: Sendable {
  /// The language names it colours
  public let names: [String]
  let language: Language
  let query: Query
  /// By capture index
  let actions: [Action]
  /// What a piece cut from the middle of a file may start inside (a string or comment over several lines): parsed
  /// after each of these too when the plain parse has errors
  let openings: [String]
  /// The indent all lines share taken off before parsing (Python reads an indented first line as an error)
  let dedent: Bool

  /// `language`: the grammar's `tree_sitter_<name>()`; `highlights`: its highlight query, in the captures above
  public init(
    names: [String], language: OpaquePointer, highlights: String, openings: [String] = [], dedent: Bool = false
  ) {
    self.names = names
    self.language = Language(language)
    do {
      query = try Query(self.language, highlights)
    } catch {
      preconditionFailure("highlight query for \(names.first ?? "?"): \(error)")
    }
    actions = query.names.map { name in
      switch name {
      case "kw": .paint(.keyword)
      case "op": .paint(.operator)
      case "fn": .paint(.function)
      case "str": .paint(.string)
      case "com": .paint(.comment)
      case "num": .paint(.number)
      case "self": .paint(.receiver)
      case "p": .paint(.punctuation)
      case "plain": .paint(nil)
      case "callee": .callee
      case "macro": .macro
      case "prefix": .stringPrefix
      case "fmt": .placeholders
      case "doc": .docstring
      case "dec": .decorator
      case let name: preconditionFailure("unknown capture @\(name)")
      }
    }
    self.openings = openings
    self.dedent = dedent
  }

  /// Python, and Triton and TileLang, which are Python
  public static let python = Grammar(
    names: ["python", "triton", "tilelang"], language: Language.python.raw, highlights: pythonQuery,
    openings: ["\"\"\"", "'''"], dedent: true)
  public static let rust = Grammar(
    names: ["rust"], language: Language.rust.raw, highlights: rustQuery, openings: ["/*"])
  /// C, C++ and CUDA, all read with the CUDA grammar (a superset of C++ with the same node names)
  public static let cuda = Grammar(
    names: ["c", "cpp", "cuda-cpp"], language: Language.cuda.raw, highlights: cudaQuery, openings: ["/*"])
}

/// What a capture of the highlight query does
enum Action: Sendable {
  case paint(TokenClass?)
  /// The name a call or declaration is about (`f` of `a::b::f<T>`, `x.f`)
  case callee
  /// A C `#define` body: unparsed text, highlighted by parsing it again
  case macro
  /// A Python string's prefix letters (f, r, b) are keywords
  case stringPrefix
  /// %s and {} placeholders in a Python string
  case placeholders
  /// A Python docstring is a comment, whatever is inside
  case docstring
  /// A Python decorator is one colour up to its arguments
  case decorator
}

extension SyntaxTree {
  /// How much of the text the parse could not place: code units under ERROR nodes, plus one per node it had to invent.
  var errorCost: Int {
    var cost = 0
    root.walk { node in
      if node.isError {
        cost += node.range.count + 1
        return false
      }
      if node.isMissing {
        cost += 1
        return false
      }
      return node.hasError
    }
    return cost
  }
}

func regex(_ pattern: String) -> NSRegularExpression {
  guard let re = try? NSRegularExpression(pattern: pattern) else { preconditionFailure("bad pattern \(pattern)") }
  return re
}

/// The name node a call or declaration is about; nil for one with no name (`(*fp)(x)`, a lambda).
func calleeName(_ node: Node) -> Node? {
  var next: Node? = node
  while let node = next {
    switch node.type {
    case "identifier", "field_identifier", "destructor_name", "operator_name": return node
    case "qualified_identifier", "scoped_identifier", "template_function", "template_method": next = node.field("name")
    case "field_expression": next = node.field("field")
    default: return nil
    }
  }
  return nil
}
