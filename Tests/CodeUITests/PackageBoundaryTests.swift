import Foundation
import Testing

// Each target imports the system's frameworks and the package's own targets below it only, as the README's table says,
// and nothing in the package speaks of the app it was first written in.
private let allowed: [String: Set<String>] = [
  "CodeCore": ["Foundation"],
  "CodeUI": ["AppKit", "CodeCore", "CoreGraphics", "CoreText", "Foundation", "QuartzCore"],
  "TreeSitterHighlight": [
    "CodeUI", "Foundation", "TreeSitter", "TreeSitterCUDA", "TreeSitterPython", "TreeSitterRust",
  ],
  "TestGuard": ["AppKit"],
  "MarkdownCore": ["CodeCore", "Foundation"],
  "MarkdownUI": [
    "AppKit", "CodeUI", "CoreGraphics", "CoreText", "Foundation", "JavaScriptCore", "MarkdownCore", "Synchronization",
    "TestGuard",
  ],
  "MarkdownBench": [
    "AppKit", "CodeUI", "CoreGraphics", "Foundation", "ImageIO", "MarkdownCore", "MarkdownUI", "UniformTypeIdentifiers",
  ],
  "MarkdownEditorDemo": [
    "AppKit", "CodeUI", "Foundation", "ImageIO", "MarkdownCore", "MarkdownUI", "TreeSitterHighlight",
  ],
]

private let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized

/// The package's Swift targets as they are on disk: each must be in the table
@Test func everyTargetIsInTheTable() throws {
  let dirs = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Sources").path)
  let swift = dirs.filter { $0 != "CTreeSitterScanners" && !$0.hasPrefix(".") }
  #expect(Set(swift).isSubset(of: Set(allowed.keys)), "\(Set(swift).subtracting(allowed.keys).sorted())")
}

@Test(arguments: allowed.keys.sorted())
func aTargetImportsWhatItMay(_ target: String) throws {
  let sources = root.appending(path: "Sources/\(target)")
  // a target this checkout does not have yet
  guard FileManager.default.fileExists(atPath: sources.path) else { return }
  let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
  #expect(!files.isEmpty)
  let ok = allowed[target] ?? []
  let importLine = /^\s*(?:@\w+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)/
    .anchorsMatchLineEndings()
  for file in files {
    let text = try String(contentsOf: file, encoding: .utf8)
    for match in text.matches(of: importLine) where !ok.contains(String(match.1)) {
      Issue.record("\(target)/\(file.lastPathComponent) imports \(match.1)")
    }
  }
}

/// No file of the package names the app the components were written in
@Test func nothingNamesTheAppItCameFrom() throws {
  let app = /(?i)code\s*board/
  let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    .compactMap { $0 as? URL }.filter {
      let p = $0.path
      return !["/.build/", "/.git/", "/node_modules/", "/.swiftpm/"].contains { p.contains($0) }
        && ["swift", "md", "mjs", "ts", "json", "yml", "txt", "c", "h"].contains($0.pathExtension)
    }
  #expect(!files.isEmpty)
  for file in files {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
    if let m = text.firstMatch(of: app) {
      Issue.record("\(file.path.dropFirst(root.path.count)) says \"\(m.0)\"")
    }
  }
}
