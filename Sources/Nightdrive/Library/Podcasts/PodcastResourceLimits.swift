import Foundation

/// Hard resource ceilings for untrusted podcast network responses.
///
/// Feed and directory bodies are held in memory. Enclosures stream to disk,
/// where the free-space budget accounts for both the downloaded file and the
/// temporary full-file copy used while adding metadata.
struct PodcastResourceLimits: Equatable, Sendable {
  static let standard = PodcastResourceLimits()

  let maximumFeedBytes: Int64
  let maximumDirectoryResponseBytes: Int64
  let maximumEnclosureBytes: Int64
  let minimumFreeDiskBytes: Int64
  let maximumConcurrentFeedLoads: Int

  init(
    maximumFeedBytes: Int64 = 32 * 1_024 * 1_024,
    maximumDirectoryResponseBytes: Int64 = 5 * 1_024 * 1_024,
    maximumEnclosureBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
    minimumFreeDiskBytes: Int64 = 1 * 1_024 * 1_024 * 1_024,
    maximumConcurrentFeedLoads: Int = 3
  ) {
    precondition(maximumFeedBytes > 0)
    precondition(maximumDirectoryResponseBytes > 0)
    precondition(maximumEnclosureBytes > 0)
    precondition(minimumFreeDiskBytes >= 0)
    precondition(maximumConcurrentFeedLoads > 0)
    self.maximumFeedBytes = maximumFeedBytes
    self.maximumDirectoryResponseBytes = maximumDirectoryResponseBytes
    self.maximumEnclosureBytes = maximumEnclosureBytes
    self.minimumFreeDiskBytes = minimumFreeDiskBytes
    self.maximumConcurrentFeedLoads = maximumConcurrentFeedLoads
  }
}
