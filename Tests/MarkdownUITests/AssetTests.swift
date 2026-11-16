import Foundation
import Testing

@testable import MarkdownUI

/// Where the engines and the host's fonts are found
@Suite struct AssetTests {
  /// The resource bundle beside the test bundle, as `swift test` leaves it, with engines that start
  @Test func theEnginesAreFoundInTheResourceBundle() throws {
    let script = try #require(MarkdownAssets.enginesScript)
    #expect(FileManager.default.fileExists(atPath: script.path(percentEncoded: false)))
    _ = try MarkdownAssets.engines()
  }

  /// The fonts are the host's: those it names must be there, whatever they are
  @Test func theFontsAreTheOnesTheHostNames() throws {
    let mono = MarkdownFontFiles(needed: ["JetBrainsMono-400-600"], families: [("JetBrainsMono-", "JetBrains Mono")])
    #expect((try? MarkdownAssets.register(mono, in: fontFolder).get()) != nil)
    let other = MarkdownFontFiles(needed: ["NotAFont-"], families: [])
    #expect(throws: MarkdownAssetError.fontsMissing(fontFolder)) {
      try MarkdownAssets.register(other, in: fontFolder).get()
    }
  }
}
