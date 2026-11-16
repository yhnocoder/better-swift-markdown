// swift-tools-version:6.4
import PackageDescription

let package = Package(
  name: "better-swift-markdown",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "CodeCore", targets: ["CodeCore"]),
    .library(name: "CodeUI", targets: ["CodeUI"]),
  ],
  targets: [
    // code edited as text alone, without a view
    .target(name: "CodeCore"),
    // code laid out, drawn and edited in a view
    .target(name: "CodeUI", dependencies: ["CodeCore"]),
    .testTarget(name: "CodeCoreTests", dependencies: ["CodeCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "CodeUITests", dependencies: ["CodeUI"]),
  ]
)

// No warnings: a concurrency warning (Swift 6 downgrades some isolation errors from AppKit's overrides) is as
// much a crash as an error, and the rest stay at zero with it
for t in package.targets where t.name != "CTreeSitterScanners" {
  t.swiftSettings = (t.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
}
