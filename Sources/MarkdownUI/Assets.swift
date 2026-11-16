import CodeUI
import CoreGraphics
import CoreText
import Foundation
import MarkdownCore

/// What the component draws with besides its code: the formula and diagram engines (engines.js, in this package's
/// resource bundle) and the host's own fonts, when it has any.
public enum MarkdownAssets {
  /// The package's resource bundle, found by its name where a build puts it: an app's Contents/Resources, beside the
  /// binary (`swift run`) or beside the test bundle (`swift test`). Not Bundle.module, which stops the process when the
  /// bundle is not where the build left it; missing here, the engines report that (`MarkdownAssetError`)
  public static let resources: URL? = {
    let name = "better-swift-markdown_MarkdownUI.bundle"
    let places = [
      Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent(),
      Bundle(for: Marker.self).bundleURL.deletingLastPathComponent(),
    ]
    for case let place? in places {
      if let b = Bundle(url: place.appending(path: name)), let r = b.resourceURL,
        FileManager.default.fileExists(atPath: r.appending(path: "Assets/engines.js").path(percentEncoded: false))
      {
        return r.appending(path: "Assets")
      }
    }
    return nil
  }()
  private final class Marker {}

  /// The folder of the host's font files and which of them it draws with; set both before the first layout. Without a
  /// folder, the fonts a theme names come from the system
  nonisolated(unsafe) public static var fontFolder: URL?
  nonisolated(unsafe) public static var fontFiles = MarkdownFontFiles(needed: [], families: [])

  /// The host's fonts for this process (`fontFiles` in `fontFolder`), each family registered the first time a font of
  /// it is made (synchronously, so a layout made right after uses them): registering them all took 200 ms, and a page
  /// draws with two or three. A host whose files are not there gets an error, never text quietly drawn in fallback
  /// fonts
  public static let fonts: Result<Void, MarkdownAssetError> =
    fontFolder.map { register(fontFiles, in: $0) } ?? .success(())

  /// Registers the files of `files` found in `folder`
  static func register(_ files: MarkdownFontFiles, in folder: URL) -> Result<Void, MarkdownAssetError> {
    let all =
      ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "woff2" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    for needed in files.needed where !all.contains(where: { $0.lastPathComponent.hasPrefix(needed) }) {
      return .failure(.fontsMissing(folder))
    }
    var chunks: [String: [Double: [URL]]] = [:]
    for f in all {
      let name = f.lastPathComponent
      if let (prefix, family) = files.chunked.first(where: { name.hasPrefix($0.prefix) }) {
        // a chunk's file is named after its weight: <Family>-700-<chunk>-<hash>
        let weight = Double(name.dropFirst(prefix.count).prefix(3)) ?? 400
        chunks[family, default: [:]][weight, default: []].append(f)
      } else if let (prefix, family) = files.families.first(where: { name.hasPrefix($0.prefix) }) {
        MarkdownFonts.registerWhenUsed(family, [f])
        // a variable font's file is named after the weights its @font-face declares: <Family>-400-600-<hash>
        if let m = name.dropFirst(prefix.count).wholeMatch(of: /(\d{3})-(\d{3})-[0-9A-F]+\.woff2/),
          let lo = Double(m.1), let hi = Double(m.2)
        {
          MarkdownFonts.declareWeights(family, lo...hi)
        }
      }
    }
    for (family, weights) in chunks { MarkdownFonts.addChunkedFamily(family, weights: weights) }
    return .success(())
  }

  /// The formula and diagram engines (engines.js in JavaScriptCore), loaded on the first document that may need them. A
  /// build without them, or with ones that do not start, is an error, never formulas quietly shown as source
  public static func engines() throws(MarkdownAssetError) -> JSEngines {
    try loadedEngines.get()
  }
  private static let loadedEngines: Result<JSEngines, MarkdownAssetError> = {
    guard let file = enginesScript else {
      return .failure(.enginesMissing("better-swift-markdown_MarkdownUI.bundle"))
    }
    do {
      return .success(try JSEngines(script: file))
    } catch {
      return .failure(.engines("\(error)"))
    }
  }()
  /// engines.js in the resource bundle, for a host that runs its own JSEngines or keys a cache by its file
  public static var enginesScript: URL? { resources?.appending(path: "engines.js") }

}

/// The font files a host draws with, by the start of their names: those that must be there, each family's own files
/// (a variable font's file named <prefix><lowest weight>-<highest>-<hash>.woff2), and the families that come in chunks
/// of characters all carrying one name (<prefix><weight>-…), registered together, not one by one (CoreText would use
/// one chunk)
public struct MarkdownFontFiles: Sendable {
  public var needed: [String]
  public var families: [(prefix: String, family: String)]
  public var chunked: [(prefix: String, family: String)]
  public init(
    needed: [String], families: [(prefix: String, family: String)], chunked: [(prefix: String, family: String)] = []
  ) {
    self.needed = needed
    self.families = families
    self.chunked = chunked
  }
}

public enum MarkdownAssetError: Error, Equatable {
  /// A font file the host needs is not in its folder
  case fontsMissing(URL)
  /// The package's resource bundle, by this name, is in none of the places a build puts it
  case enginesMissing(String)
  /// engines.js is there but does not start
  case engines(String)
}

extension MarkdownAssets {
  /// Lays out and draws a sample with every kind of block once in each of the host's themes, so the first document a
  /// host shows does not pay for CoreText's, the fonts' and the formula engine's first use (the web page warms its
  /// editor up the same way while it loads). For a host's launch, off the main thread; `math` the engines when the host
  /// has them
  public static func warmUp(
    math: MathTypesetter?, themes: [MarkdownTheme] = [.sample(dark: false), .sample(dark: true)]
  ) {
    guard (try? fonts.get()) != nil else { return }
    // the hand font first, which the sample does not draw: an annotation's note waits 50 ms for its Chinese otherwise
    for hand in Set(themes.map(\.fonts.hand)) { _ = FontBook.font(hand, size: 16) }
    struct Sample: MarkdownResources {
      let math: MathTypesetter?
      var diagrams: DiagramRenderer? { math as? DiagramRenderer }
      func imageSize(_ src: String) -> CGSize? { CGSize(width: 800, height: 450) }
      func ref(label: String, target: String?) -> MarkdownRefHit? { nil }
      func highlight(lines: [String], language: String) -> [[CodeRun]]? { nil }
      var mathPreamble: String { "" }
    }
    let text = """
      # Title

      Text with **bold**, *italics*, `code`, ==marks==, [a link](https://example.com) and 中文混排，一段文字。

      - one
      - [x] two

      > a quote

      | a | b |
      |---|---|
      | 1 | 2 |

      ```py
      x = 1
      ```

      $$
      x^2 + \\frac{1}{2}
      $$

      Inline $E = mc^2$ and ![p](p.png "caption").
      """
    let resources = Sample(math: math)
    for (n, theme) in themes.enumerated() {
      let l = BlockLayout(MarkdownDocument(text), width: 330, theme: theme, layout: nil, resources: resources)
      guard
        let ctx = CGContext(
          data: nil, width: 660, height: max(1, Int(l.size.height * 2)), bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { continue }
      ctx.scaleBy(x: 2, y: 2)
      l.draw(in: ctx, scale: 2, clip: CGRect(origin: .zero, size: l.size)) { _ in nil }
      // the caret into a link, a mark, code and a formula once: what showing their source first costs (a link's
      // address chip in the code font, 83 ms the first time) is paid here, not on the first click
      guard n == 0 else { continue }
      let e = EditorCore(layout: l, caret: 0)
      let ns = text as NSString
      for needle in ["a link", "bold", "code`", "E = mc"] {
        let at = ns.range(of: needle).location
        guard at != NSNotFound else { continue }
        e.select(MDSelection(at + 1))
        l.draw(in: ctx, scale: 2, clip: CGRect(origin: .zero, size: l.size)) { _ in nil }
      }
    }
  }
}
