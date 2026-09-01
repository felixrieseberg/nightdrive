import AVFoundation

/// Metadata tags are read opportunistically: a value that fails to load is
/// treated the same as an absent tag. These accessors centralize that policy
/// so scanners don't repeat `try?` at every tag.
extension AVMetadataItem {
  var loadedStringValue: String? {
    get async { try? await load(.stringValue) }
  }

  var loadedNumberValue: NSNumber? {
    get async { try? await load(.numberValue) }
  }

  var loadedDataValue: Data? {
    get async { try? await load(.dataValue) }
  }
}
