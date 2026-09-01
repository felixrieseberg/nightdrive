import OSLog

/// Shared `os.Logger` instances for recording failures that are deliberately
/// swallowed by control flow but still worth diagnosing, following the
/// subsystem already used by `ArtworkDBWriter` and `RecoveryMarkerReadSupport`.
enum NightdriveLog {
  static let subsystem = "dev.nightdrive.Nightdrive"

  static let sync = Logger(subsystem: subsystem, category: "sync")
  static let ipodFS = Logger(subsystem: subsystem, category: "ipod-fs")
  static let library = Logger(subsystem: subsystem, category: "library")
  static let transcode = Logger(subsystem: subsystem, category: "transcode")
  static let device = Logger(subsystem: subsystem, category: "device")
  static let app = Logger(subsystem: subsystem, category: "app")
}
