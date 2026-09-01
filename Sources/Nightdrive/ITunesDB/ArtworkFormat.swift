import Foundation

struct ArtworkImageSpec: Equatable, Sendable {
  var formatID: UInt32
  var width: Int
  var height: Int
  var bigEndian: Bool

  var bytesPerTile: Int { width * height * 2 }
  var ithmbName: String { "F\(formatID)_1.ithmb" }
}

enum ArtworkSpecResolution: Equatable, Sendable {
  case specs([ArtworkImageSpec])
  case unknown
}

enum ArtworkFormats {
  static func resolve(fileSystem: IpodFileSystem) -> ArtworkSpecResolution {
    if let data = try? Data(contentsOf: fileSystem.sysInfoExtendedURL),
      let specs = specsFromSysInfoExtended(data)
    {
      return .specs(specs)
    }
    guard let model = fileSystem.modelNumber() else { return .unknown }
    if let specs = staticSpecs(modelNumber: model) { return .specs(specs) }
    return .unknown
  }

  static func specsFromSysInfoExtended(_ data: Data) -> [ArtworkImageSpec]? {
    guard
      let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = object as? [String: Any],
      let albumArt = dictionary["AlbumArt"] as? [[String: Any]]
    else { return nil }
    var specs: [ArtworkImageSpec] = []
    var seenFormatIDs: Set<UInt32> = []
    for entry in albumArt {
      guard let formatID = entry["FormatId"] as? Int,
        let width = entry["RenderWidth"] as? Int,
        let height = entry["RenderHeight"] as? Int,
        let pixelFormat = entry["PixelFormat"] as? String
      else { continue }
      let bigEndian: Bool
      switch pixelFormat.uppercased() {
      case "4C353635": bigEndian = false
      case "42353635": bigEndian = true
      default: continue
      }
      guard formatID > 0, formatID <= 0xFFFF,
        (1...1024).contains(width), (1...1024).contains(height),
        seenFormatIDs.insert(UInt32(formatID)).inserted
      else { continue }
      specs.append(
        ArtworkImageSpec(
          formatID: UInt32(formatID), width: width, height: height, bigEndian: bigEndian))
    }
    return specs.isEmpty ? nil : specs
  }

  static func staticSpecs(modelNumber: String) -> [ArtworkImageSpec]? {
    let model = modelNumber.uppercased()
    if monochromeModels.contains(model) { return [] }
    if colorPhotoModels.contains(model) {
      return [
        ArtworkImageSpec(formatID: 1017, width: 56, height: 56, bigEndian: false),
        ArtworkImageSpec(formatID: 1016, width: 140, height: 140, bigEndian: false),
      ]
    }
    if nanoModels.contains(model) {
      return [
        ArtworkImageSpec(formatID: 1031, width: 42, height: 42, bigEndian: false),
        ArtworkImageSpec(formatID: 1027, width: 100, height: 100, bigEndian: false),
      ]
    }
    if videoModels.contains(model) {
      return [
        ArtworkImageSpec(formatID: 1028, width: 100, height: 100, bigEndian: false),
        ArtworkImageSpec(formatID: 1029, width: 200, height: 200, bigEndian: false),
      ]
    }
    if classicModels.contains(model) {
      return [
        ArtworkImageSpec(formatID: 1061, width: 56, height: 56, bigEndian: true),
        ArtworkImageSpec(formatID: 1055, width: 128, height: 128, bigEndian: true),
      ]
    }
    return nil
  }

  private static let monochromeModels: Set<String> = [
    "M8541", "M8697", "M8709", "M8737", "M8740", "M8946", "M8948", "M8976", "M9244",
    "M9160", "M9245", "M9268", "M9282",
    "M9435", "M9436", "M9437", "M9800", "M9801", "M9802", "M9803", "M9804",
    "M9805", "M9806", "M9807",
  ]

  private static let colorPhotoModels: Set<String> = [
    "M9585", "M9586", "M9829", "M9830", "MA079", "MA127",
  ]

  private static let nanoModels: Set<String> = [
    "MA004", "MA005", "MA099", "MA107", "MA350", "MA352",
    "MA426", "MA428", "MA477", "MA487", "MA489", "MA497",
  ]

  private static let videoModels: Set<String> = [
    "MA002", "MA003", "MA146", "MA147", "MA444", "MA446", "MA448", "MA450",
  ]

  private static let classicModels: Set<String> = [
    "MB029", "MB035", "MB145", "MB147", "MB150", "MB562", "MB565", "MC293", "MC297",
  ]
}
