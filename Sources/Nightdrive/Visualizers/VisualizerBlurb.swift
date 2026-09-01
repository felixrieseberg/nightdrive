import Foundation

enum VisualizerBlurb {
  static func text(for descriptor: VisualizerDescriptor) -> String {
    if let written = written[descriptor.id] { return written }
    if descriptor.isPlugin {
      return String(localized: "A display mode loaded from the visualizers folder.")
    }
    return descriptor.wantsContinuousRedraw
      ? String(localized: "Runs on its own clock, with the audio pushing it along.")
      : String(localized: "Drawn straight from the audio as it plays.")
  }

  static func displayName(_ name: String) -> String {
    name.split(separator: " ")
      .map { word -> String in
        let text = String(word)
        if acronyms.contains(text.uppercased()) { return text.uppercased() }
        return text.prefix(1).uppercased() + text.dropFirst().lowercased()
      }
      .joined(separator: " ")
  }

  private static let acronyms: Set<String> = [
    "EQ", "VU", "VFD", "LCD", "LED", "FM", "AM", "2D", "3D", "XY",
  ]

  static func drive(for descriptor: VisualizerDescriptor) -> String {
    descriptor.wantsContinuousRedraw
      ? String(localized: "Always moving") : String(localized: "Follows the audio")
  }

  private static let written: [String: String] = [
    "spectrum": String(
      localized: "A fine-pitch spectrum with slow peak caps and an amber overload row."),
    "scope": String(
      localized: "An oscilloscope trace with a few frames of phosphor still fading behind it."),
    "waterfall": String(
      localized: "The spectrum scrolling away from you, so you can see what just happened."),
    "vu": String(
      localized: "A pair of moving-coil VU meters with the ballistics of the real thing."),
    "eq": String(
      localized: "The equalizer curve a thirteen-band deck drew while you nudged the sliders."),
    "ripple": String(localized: "A still surface that a bass hit throws rings across."),
    "marquee": String(
      localized: "The track name crawling by in a dot-matrix, the way a deck spelled it out."),
    "combo": String(
      localized: "Bars, a level ladder and a beat lamp on one panel — the busy setting."),
    "plasma": String(localized: "Interference patterns rolling through the tube's four inks."),
    "fire": String(localized: "A dot-matrix fire, fed by the bottom end."),
    "tunnel": String(localized: "A textured tunnel you fall down in time with the track."),
    "rotozoom": String(localized: "A checkerboard rotating and zooming under its own steam."),
    "vectors": String(localized: "Transparent glenz solids tumbling the way the demos did it."),
    "metaballs": String(localized: "Blobs that swell, meet and merge on the bass."),
    "radar": String(localized: "A sweeping radar line that leaves contacts glowing behind it."),
    "constellation": String(
      localized: "Points that find each other and draw the lines between them."),
    "eqladder": String(localized: "A ladder of level segments, climbing the way a deck's did."),
    "glyphrain": String(localized: "Characters falling in columns, thickening with the top end."),
    "hyperwarp": String(localized: "Streaks pulled to a vanishing point, stretched by the beat."),
    "vectorscope": String(localized: "Left against right, so you can see the stereo image."),
    "wireframe": String(localized: "A wireframe solid turning slowly on two axes."),
  ]
}
