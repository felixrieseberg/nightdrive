import Foundation
import SwiftParser
import SwiftSyntax

struct AllowlistEntry: Codable, Equatable, Hashable {
  let file: String
  let type: String
  let rawLiteralFingerprint: String
  let literalCount: Int
}

struct RawLiteral: Equatable {
  let file: String
  let type: String
  let literal: String
  let line: Int
}

private struct Configuration {
  let root: URL
  let allowlist: URL
  let printAllowlist: Bool

  init(arguments: [String]) throws {
    var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var allowlist: URL?
    var printAllowlist = false
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--root":
        index += 1
        guard index < arguments.count else { throw UsageError() }
        root = URL(fileURLWithPath: arguments[index])
      case "--allowlist":
        index += 1
        guard index < arguments.count else { throw UsageError() }
        allowlist = URL(fileURLWithPath: arguments[index])
      case "--print-allowlist":
        printAllowlist = true
      default:
        throw UsageError()
      }
      index += 1
    }

    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.allowlist =
      allowlist?.standardizedFileURL
      ?? self.root.appending(path: "scripts/localized-error-allowlist.json")
    self.printAllowlist = printAllowlist
  }
}

private struct UsageError: Error {}

private final class ErrorLiteralVisitor: SyntaxVisitor {
  private(set) var literals: [StringLiteralExprSyntax] = []

  override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
    if !isInsideLocalizedString(node) {
      literals.append(node)
    }
    return .skipChildren
  }

  private func isInsideLocalizedString(_ literal: StringLiteralExprSyntax) -> Bool {
    var ancestor = Syntax(literal).parent
    while let current = ancestor {
      if let call = current.as(FunctionCallExprSyntax.self), isLocalizedStringCall(call) {
        return true
      }
      if current.is(VariableDeclSyntax.self) {
        return false
      }
      ancestor = current.parent
    }
    return false
  }

  private func isLocalizedStringCall(_ call: FunctionCallExprSyntax) -> Bool {
    guard
      let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
      reference.baseName.text == "String",
      call.arguments.first?.label?.text == "localized"
    else {
      return false
    }
    return true
  }
}

private final class LocalizedErrorVisitor: SyntaxVisitor {
  let file: String
  let converter: SourceLocationConverter
  let conformingTypes: Set<String>
  private(set) var rawLiterals: [RawLiteral] = []

  init(file: String, tree: SourceFileSyntax, conformingTypes: Set<String>) {
    self.file = file
    converter = SourceLocationConverter(fileName: file, tree: tree)
    self.conformingTypes = conformingTypes
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    inspect(
      type: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock.members)
    return .visitChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    inspect(
      type: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock.members)
    return .visitChildren
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    inspect(
      type: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock.members)
    return .visitChildren
  }

  override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
    inspect(
      type: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock.members)
    return .visitChildren
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    inspect(
      type: node.extendedType.trimmedDescription, inheritance: node.inheritanceClause,
      members: node.memberBlock.members)
    return .visitChildren
  }

  private func inspect(
    type: String, inheritance: InheritanceClauseSyntax?,
    members: MemberBlockItemListSyntax
  ) {
    guard conformingTypes.contains(type) || inheritsLocalizedError(inheritance) else {
      return
    }

    for member in members {
      guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
      for binding in variable.bindings where isErrorDescription(binding.pattern) {
        let literalVisitor = ErrorLiteralVisitor(viewMode: .sourceAccurate)
        literalVisitor.walk(Syntax(binding))
        for literal in literalVisitor.literals {
          let location = converter.location(for: literal.positionAfterSkippingLeadingTrivia)
          rawLiterals.append(
            RawLiteral(
              file: file, type: type, literal: literal.trimmedDescription,
              line: location.line
            ))
        }
      }
    }
  }

  private func isErrorDescription(_ pattern: PatternSyntax) -> Bool {
    pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "errorDescription"
  }
}

private final class LocalizedErrorConformanceVisitor: SyntaxVisitor {
  private(set) var types: Set<String> = []

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    collect(type: node.name.text, inheritance: node.inheritanceClause)
    return .visitChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    collect(type: node.name.text, inheritance: node.inheritanceClause)
    return .visitChildren
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    collect(type: node.name.text, inheritance: node.inheritanceClause)
    return .visitChildren
  }

  override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
    collect(type: node.name.text, inheritance: node.inheritanceClause)
    return .visitChildren
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    collect(type: node.extendedType.trimmedDescription, inheritance: node.inheritanceClause)
    return .visitChildren
  }

  private func collect(type: String, inheritance: InheritanceClauseSyntax?) {
    if inheritsLocalizedError(inheritance) {
      types.insert(type)
    }
  }
}

private func inheritsLocalizedError(_ inheritance: InheritanceClauseSyntax?) -> Bool {
  inheritance?.inheritedTypes.contains(where: { inherited in
    let name = inherited.type.trimmedDescription
    return name == "LocalizedError" || name.hasSuffix(".LocalizedError")
  }) == true
}

private func swiftFiles(root: URL) throws -> [URL] {
  let sourceRoot = root.appending(path: "Sources/Nightdrive")
  guard
    let enumerator = FileManager.default.enumerator(
      at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
  else {
    throw CocoaError(.fileReadNoSuchFile)
  }

  return try enumerator.compactMap { item in
    guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
    let relative = relativePath(url, root: root)
    guard
      !relative.hasPrefix("Sources/Nightdrive/Development/"),
      !relative.hasPrefix("Sources/Nightdrive/Demo/")
    else {
      return nil
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    return values.isRegularFile == true ? url : nil
  }.sorted { $0.path < $1.path }
}

private func loadAllowlist(_ url: URL) throws -> [AllowlistEntry] {
  let data = try Data(contentsOf: url)
  return try JSONDecoder().decode([AllowlistEntry].self, from: data)
}

private func fingerprint(_ literals: [String]) -> String {
  // FNV-1a is sufficient here: this is a change detector, not a security boundary.
  var hash: UInt64 = 0xcbf2_9ce4_8422_2325
  for byte in literals.joined(separator: "\u{0}").utf8 {
    hash ^= UInt64(byte)
    hash &*= 0x0000_0100_0000_01B3
  }
  return String(format: "%016llx", hash)
}

private func entries(for rawLiterals: [RawLiteral]) -> [AllowlistEntry] {
  Dictionary(grouping: rawLiterals) { "\($0.file)\u{0}\($0.type)" }
    .values.map { group in
      AllowlistEntry(
        file: group[0].file,
        type: group[0].type,
        rawLiteralFingerprint: fingerprint(group.map(\.literal)),
        literalCount: group.count
      )
    }
    .sorted { ($0.file, $0.type) < ($1.file, $1.type) }
}

private func relativePath(_ url: URL, root: URL) -> String {
  let path = url.standardizedFileURL.resolvingSymlinksInPath().path
  guard path.hasPrefix(root.path + "/") else { return path }
  return String(path.dropFirst(root.path.count + 1))
}

private func run() throws -> Int32 {
  let configuration: Configuration
  do {
    configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
  } catch {
    let usage =
      "usage: localized-error-policy.swift [--root PATH] [--allowlist PATH] "
      + "[--print-allowlist]\n"
    FileHandle.standardError.write(Data(usage.utf8))
    return 2
  }

  let files = try swiftFiles(root: configuration.root)
  let trees = try files.map { url in
    let source = try String(contentsOf: url, encoding: .utf8)
    return (url, Parser.parse(source: source))
  }

  var conformingTypes: Set<String> = []
  for (_, tree) in trees {
    let visitor = LocalizedErrorConformanceVisitor(viewMode: .sourceAccurate)
    visitor.walk(tree)
    conformingTypes.formUnion(visitor.types)
  }

  var rawLiterals: [RawLiteral] = []
  for (url, tree) in trees {
    let visitor = LocalizedErrorVisitor(
      file: relativePath(url, root: configuration.root), tree: tree,
      conformingTypes: conformingTypes)
    visitor.walk(tree)
    rawLiterals.append(contentsOf: visitor.rawLiterals)
  }

  let actualEntries = entries(for: rawLiterals)
  if configuration.printAllowlist {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(actualEntries))
    print()
    return 0
  }

  let expected = Set(try loadAllowlist(configuration.allowlist))
  let actual = Set(actualEntries)
  let unexpectedEntries = actual.subtracting(expected)
  let staleEntries = expected.subtracting(actual)

  if unexpectedEntries.isEmpty, staleEntries.isEmpty {
    print("LocalizedError descriptions use the String Catalog.")
    return 0
  }

  for violation in rawLiterals
  where unexpectedEntries.contains(where: {
    $0.file == violation.file && $0.type == violation.type
  }) {
    print(
      "\(violation.file):\(violation.line): error: raw string literal in "
        + "\(violation.type).errorDescription; wrap user-facing copy in "
        + "String(localized:)")
    print("  \(violation.literal)")
  }
  for entry in staleEntries.sorted(by: { ($0.file, $0.type) < ($1.file, $1.type) }) {
    print(
      "\(entry.file): error: stale localized-error allowlist entry for "
        + "\(entry.type) (\(entry.literalCount) raw literals, fingerprint "
        + "\(entry.rawLiteralFingerprint))")
  }
  print(
    "After intentionally localizing existing debt, regenerate the snapshot with "
      + "./scripts/verify-localized-errors.sh --print-allowlist and review its diff; "
      + "do not allowlist new raw copy.")
  return 1
}

do {
  exit(try run())
} catch {
  FileHandle.standardError.write(Data("localized-error-policy: \(error)\n".utf8))
  exit(1)
}
