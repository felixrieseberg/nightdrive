import Foundation

enum AppIdentity {
  static var appTitle: String {
    appTitle(infoDictionary: Bundle.main.infoDictionary)
  }

  static func appTitle(infoDictionary: [String: Any]?) -> String {
    let base = "Nightdrive"
    guard let suffix = developmentTitleSuffix(infoDictionary: infoDictionary) else { return base }
    return "\(base) (\(suffix))"
  }

  static var isDevelopmentBuild: Bool {
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      developmentTitleSuffix != nil
    #else
      false
    #endif
  }

  static var developmentTitleSuffix: String? {
    developmentTitleSuffix(infoDictionary: Bundle.main.infoDictionary)
  }

  static func developmentTitleSuffix(infoDictionary: [String: Any]?) -> String? {
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      guard
        let suffix = infoDictionary?["NightdriveDevelopmentTitleSuffix"] as? String
      else { return nil }
      let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    #else
      nil
    #endif
  }
}
