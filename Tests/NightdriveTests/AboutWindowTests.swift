import Testing

@testable import Nightdrive

@MainActor
struct AboutWindowTests {
  @Test
  func testMissingVersionIsDevelopmentBuild() {
    #expect(AboutWindow.versionText(info: nil) == "Development build")
  }

  @Test
  func testPlaceholderVersionIsDevelopmentBuild() {
    #expect(
      AboutWindow.versionText(info: [
        "CFBundleShortVersionString": "0.0.0",
        "CFBundleVersion": "0",
      ]) == "Development build")
  }

  @Test
  func testReleaseVersionIncludesBuildNumber() {
    #expect(
      AboutWindow.versionText(info: [
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "42",
      ]) == "Version 1.2.3 (42)")
  }

  @Test
  func testMarketingVersionCanStandAlone() {
    #expect(
      AboutWindow.versionText(info: ["CFBundleShortVersionString": "1.2.3"])
        == "Version 1.2.3")
  }

  @Test
  func testCopyrightUsesBundleMetadata() {
    #expect(
      AboutWindow.copyrightText(info: [
        "NSHumanReadableCopyright": "Copyright © 2026 Felix Rieseberg"
      ]) == "Copyright © 2026 Felix Rieseberg")
  }

  @Test
  func testCopyrightHasDevelopmentFallback() {
    #expect(AboutWindow.copyrightText(info: nil) == "© Felix Rieseberg")
  }

  @Test
  func testSparkleLicenseIsBundledInFull() {
    let license = ThirdPartyNotices.sparkleLicense
    #expect(license.contains("Copyright (c) 2006-2013 Andy Matuschak."))
    #expect(license.contains("EXTERNAL LICENSES"))
    #expect(license.contains("Copyright 2003-2005 Colin Percival"))
    #expect(license.contains("Copyright (c) 2008-2010 Yuta Mori"))
    #expect(license.contains("Copyright (c) 2015 Orson Peters"))
    #expect(license.contains("Copyright (c) 2011 Mark Hamlin."))
  }
}
