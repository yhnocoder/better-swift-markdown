import CodeUI
import CoreGraphics
import Foundation

@testable import MarkdownUI

/// The fonts the tests draw with (Fonts: Source Serif 4, JetBrains Mono, Shantell Sans), registered once
/// (registered through FontBook: a font another test looked up before is looked up again)
let testFonts: Void = {
  MarkdownFonts.register(
    ((try? FileManager.default.contentsOfDirectory(at: fontFolder, includingPropertiesForKeys: nil)) ?? []).filter {
      $0.pathExtension == "woff2"
    })
}()

let fontFolder = Bundle.module.resourceURL!.appending(path: "Fonts")

/// Resources with nothing but the formula engines, when given
struct NoResources: MarkdownResources {
  var math: MathTypesetter?
  var diagrams: DiagramRenderer? { math as? DiagramRenderer }
  func imageSize(_ src: String) -> CGSize? { nil }
  func ref(label: String, target: String?) -> MarkdownRefHit? { nil }
  func highlight(lines: [String], language: String) -> [[CodeRun]]? { nil }
  var mathPreamble: String { "" }
}
