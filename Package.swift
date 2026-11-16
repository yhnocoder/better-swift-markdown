// swift-tools-version:6.4
import PackageDescription

let package = Package(
  name: "better-swift-markdown",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "CodeCore", targets: ["CodeCore"]),
    .library(name: "CodeUI", targets: ["CodeUI"]),
    .library(name: "TreeSitterHighlight", targets: ["TreeSitterHighlight"]),
    .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
    // untagged: v0.24.0 and six commits
    .package(
      url: "https://github.com/tree-sitter/tree-sitter-rust",
      revision: "261b20226c04ef601adbdf185a800512a5f66291"
    ),
    // a fork of tree-sitter-cuda
    .package(url: "https://github.com/yhnocoder/tree-sitter-cuda", exact: "0.21.2-cb.3"),
  ],
  targets: [
    // code edited as text alone, without a view
    .target(name: "CodeCore"),
    // code laid out, drawn and edited in a view
    .target(name: "CodeUI", dependencies: ["CodeCore"]),
    .testTarget(name: "CodeCoreTests", dependencies: ["CodeCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "CodeUITests", dependencies: ["CodeUI"]),
    // code coloured by tree-sitter
    .target(
      name: "TreeSitterHighlight",
      dependencies: [
        "CodeUI",
        .product(name: "TreeSitter", package: "tree-sitter"),
        .product(name: "TreeSitterPython", package: "tree-sitter-python"),
        .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
        .product(name: "TreeSitterCUDA", package: "tree-sitter-cuda"),
        "CTreeSitterScanners",
      ]
    ),
    // the Python grammar's external scanner, which its package leaves out (include/scanners.h says why)
    .target(
      name: "CTreeSitterScanners",
      exclude: ["python/LICENSE"],
      cSettings: [.headerSearchPath("."), .disableWarning("shorten-64-to-32")]
    ),
    .testTarget(name: "TreeSitterHighlightTests", dependencies: ["TreeSitterHighlight"]),
    // Markdown read with source ranges, and the editor's operations on the source
    .target(name: "MarkdownCore", dependencies: ["CodeCore"]),
    .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"], resources: [.copy("Fixtures")]),
  ]
)

// No warnings: a concurrency warning (Swift 6 downgrades some isolation errors from AppKit's overrides) is as
// much a crash as an error, and the rest stay at zero with it
for t in package.targets where t.name != "CTreeSitterScanners" {
  t.swiftSettings = (t.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
}
