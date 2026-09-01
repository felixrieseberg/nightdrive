// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "Nightdrive",
  platforms: [.macOS(.v15)],
  dependencies: [
    // Sparkle powers in-app updates for the notarized direct download. It
    // stays inert unless the packaged bundle carries a signing key, so
    // from-source builds never check for updates. See DISTRIBUTION.md.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
  ],
  targets: [
    .target(
      name: "CJSCExecutionTimeLimit",
      path: "Sources/CJSCExecutionTimeLimit",
      linkerSettings: [.linkedFramework("JavaScriptCore")]
    ),
    .target(
      name: "CAudioTapRing",
      path: "Sources/CAudioTapRing"
    ),
    .executableTarget(
      name: "Nightdrive",
      dependencies: [
        "CAudioTapRing", "CJSCExecutionTimeLimit",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "Sources/Nightdrive",
      resources: [
        .copy("Resources/DockIconFrames"),
        .copy("Resources/ThirdPartyNotices"),
        .copy("Resources/VisualizerExamples"),
      ],
      swiftSettings: [
        .define("NIGHTDRIVE_DEVELOPMENT_TOOLS", .when(configuration: .debug))
      ]
    ),
    .testTarget(
      name: "NightdriveTests",
      dependencies: ["Nightdrive"],
      path: "Tests/NightdriveTests",
      swiftSettings: [
        .define("NIGHTDRIVE_DEVELOPMENT_TOOLS", .when(configuration: .debug))
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
