import Foundation
import UniformTypeIdentifiers

enum AudioFileOpening {
  static let contentTypeIdentifiers = [
    "public.mp3",
    "com.apple.m4a-audio",
    "com.apple.protected-mpeg-4-audio-b",
    "public.aac-audio",
    "com.microsoft.waveform-audio",
    "public.aiff-audio",
    "org.xiph.flac",
    "com.apple.coreaudio-format",
  ]

  static let contentTypes = contentTypeIdentifiers.compactMap(UTType.init)

  @MainActor
  static func resolveTracks(_ urls: [URL], library: LibraryStore) async -> [LibraryTrack] {
    let urls = eligibleURLs(urls)
    var resolved = urls.map { library.track(at: $0) }

    let missingIndices = urls.indices.filter { resolved[$0] == nil }
    let loaded = await LibraryStore.loadTracks(at: missingIndices.map { urls[$0] })
    guard !Task.isCancelled, loaded.count == missingIndices.count else { return [] }
    for (index, track) in zip(missingIndices, loaded) {
      resolved[index] = track
    }
    return resolved.compactMap(\.self)
  }

  @MainActor
  static func resolveDroppedTracks(_ urls: [URL], library: LibraryStore) async -> [LibraryTrack] {
    let discovery = Task.detached(priority: .userInitiated) {
      eligibleDropURLs(urls)
    }
    let eligible = await withTaskCancellationHandler {
      await discovery.value
    } onCancel: {
      discovery.cancel()
    }
    guard !Task.isCancelled else { return [] }
    return await resolveTracks(eligible, library: library)
  }

  /// Expands dropped folders without following their nested symlinks. The
  /// Finder-provided top-level order is retained, while every folder is
  /// traversed in stable path order by `LibraryStore.findAudioFiles`.
  nonisolated static func eligibleDropURLs(_ urls: [URL]) -> [URL] {
    let expanded = urls.flatMap { url -> [URL] in
      guard let (normalized, isDirectory) = dropItem(at: url) else { return [] }
      if isDirectory {
        return LibraryStore.findAudioFiles(in: normalized)
      }
      return [normalized]
    }
    return eligibleURLs(expanded)
  }

  /// Cheap validation for SwiftUI's synchronous drop acceptance callback.
  /// Directories are accepted because they may contain supported files; the
  /// recursive pass subsequently rejects empty or unreadable folders.
  nonisolated static func canAcceptDrop(_ urls: [URL]) -> Bool {
    urls.contains { url in
      guard let (normalized, isDirectory) = dropItem(at: url) else { return false }
      return isDirectory || LibraryAudioFormat(url: normalized) != nil
    }
  }

  nonisolated static func eligibleURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<URL>()
    return urls.compactMap { url in
      guard url.isFileURL, LibraryAudioFormat(url: url) != nil else { return nil }
      let normalized = url.standardizedFileURL
      return seen.insert(normalized).inserted ? normalized : nil
    }
  }

  nonisolated private static func dropItem(
    at url: URL
  ) -> (url: URL, isDirectory: Bool)? {
    guard url.isFileURL else { return nil }
    let normalized = url.resolvingSymlinksInPath().standardizedFileURL
    guard
      let values = try? normalized.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey]),
      values.isDirectory == true || values.isRegularFile == true
    else { return nil }
    return (normalized, values.isDirectory == true)
  }
}
