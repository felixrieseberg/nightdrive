import Foundation

enum SortNames {
  private static let leadingArticles = ["the ", "an ", "a "]

  static func strippingLeadingArticle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    for article in leadingArticles where lowered.hasPrefix(article) {
      let stripped = String(trimmed.dropFirst(article.count))
        .trimmingCharacters(in: .whitespaces)
      if !stripped.isEmpty { return stripped }
    }
    return trimmed
  }

  static func sortValue(display: String?, explicit: String?) -> String? {
    let displayValue = (display ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines),
      !explicit.isEmpty
    {
      return explicit == displayValue ? nil : explicit
    }
    guard !displayValue.isEmpty else { return nil }
    let derived = strippingLeadingArticle(displayValue)
    return derived == displayValue ? nil : derived
  }
}
