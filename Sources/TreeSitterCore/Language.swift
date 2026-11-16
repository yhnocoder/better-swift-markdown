import TreeSitter
import TreeSitterCUDA
import TreeSitterPython
import TreeSitterRust

/// A tree-sitter grammar's language. Python, Rust and CUDA come built in; any other grammar is one from its
/// `tree_sitter_<name>()`.
public struct Language: @unchecked Sendable {
  /// The grammar's TSLanguage, which tree-sitter never changes
  public let raw: OpaquePointer

  /// `raw`: the grammar's `tree_sitter_<name>()`
  public init(_ raw: OpaquePointer) { self.raw = raw }

  /// Python, with its external scanner (indents, strings), which the grammar's own package leaves out
  public static let python = Language(tree_sitter_python())
  public static let rust = Language(tree_sitter_rust())
  /// C, C++ and CUDA: tree-sitter-cuda is a superset of C++ (`<<<>>>`, `__global__`) with C++'s node names
  public static let cuda = Language(tree_sitter_cuda())

  /// `units` parsed with a parser of its own, reusing what of `old` did not change (see `Parser.parse`); nil when the
  /// grammar does not fit this tree-sitter (a pin mistake)
  public func parse(_ units: [UInt16], old: SyntaxTree? = nil) -> SyntaxTree? {
    Parser(self)?.parse(units, old: old)
  }
}

/// A parser of one language. Not for two threads at once; making one costs little next to a parse.
public final class Parser {
  public let language: Language
  private let raw: OpaquePointer = ts_parser_new()

  /// nil when the grammar does not fit this tree-sitter (a pin mistake)
  public init?(_ language: Language) {
    self.language = language
    guard ts_parser_set_language(raw, language.raw) else { return nil }
  }

  deinit { ts_parser_delete(raw) }

  /// `units` parsed as UTF-16. With `old`, which must already be edited to match `units` (`SyntaxTree.edit`), what of
  /// it did not change is reused.
  public func parse(_ units: [UInt16], old: SyntaxTree? = nil) -> SyntaxTree {
    // Never a null text, whatever address an empty array gives
    let empty: [UInt16] = [0]
    let tree = (units.isEmpty ? empty : units).withUnsafeBytes { bytes in
      ts_parser_parse_string_encoding(
        raw, old?.raw, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(units.count * 2),
        TSInputEncodingUTF16LE)
    }
    // tree-sitter gives none only without a language, or when a parse is cancelled or times out, which none is
    guard let tree else { preconditionFailure("tree-sitter gave no tree") }
    return SyntaxTree(tree, units)
  }
}
