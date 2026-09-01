import Foundation
import Testing

@testable import Nightdrive

final class VisualizerSeedingTests {
  private var folder: URL!

  init() {
    folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nightdrive-seeding-\(UUID().uuidString)", isDirectory: true)
  }

  deinit {
    guard let folder, FileManager.default.fileExists(atPath: folder.path) else { return }
    try? FileManager.default.removeItem(at: folder)
  }

  private func plugins(_ examples: [VisualizerExamples.Example] = VisualizerExamples.all)
    -> VisualizerPluginFolder
  {
    VisualizerPluginFolder(url: folder, examples: examples)
  }

  private func read(_ name: String) -> String? {
    try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
  }

  @Test
  func testMissingFolderIsCreatedWithEveryExample() {
    plugins().createIfNeeded()

    #expect(FileManager.default.fileExists(atPath: folder.path))
    #expect(
      ((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted())
        == (VisualizerExamples.all.map(\.name).sorted()))
    for example in VisualizerExamples.all {
      #expect((read(example.name)) == (example.contents), Comment(rawValue: "\(example.name) was not installed"))
    }
  }

  @Test
  func testExistingEmptyFolderIsNotFilled() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    plugins().createIfNeeded()

    #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ([]))
  }

  @Test
  func testExistingFolderIsNeverChanged() throws {
    let original = "// mine\n"
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try original.write(
      to: folder.appendingPathComponent("radar.js"), atomically: true, encoding: .utf8)

    let revised = VisualizerExamples.Example(name: "radar.js", source: "// shipped later")
    let added = VisualizerExamples.Example(name: "new.js", source: "// new")
    plugins([revised, added]).createIfNeeded()

    #expect((read("radar.js")) == (original))
    #expect(read("new.js") == nil)
  }

  @Test
  func testPathThatIsAFileIsLeftAlone() throws {
    try "not a folder".write(to: folder, atomically: true, encoding: .utf8)

    plugins().createIfNeeded()

    #expect((try String(contentsOf: folder, encoding: .utf8)) == ("not a folder"))
  }
}
