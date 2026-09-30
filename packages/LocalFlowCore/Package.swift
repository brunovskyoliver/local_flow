// swift-tools-version: 6.0
import PackageDescription

// Portable code shared by the Mac app, the flowd-speech worker and the iOS app (ADR 0029).
// LocalFlowSpeech has no GRDB so the worker can link it; LocalFlowCore adds storage.
let package = Package(
  name: "LocalFlowCore",
  platforms: [.macOS(.v14), .iOS("26.0")],
  products: [
    .library(name: "LocalFlowSpeech", targets: ["LocalFlowSpeech"])
  ],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7")
  ],
  targets: [
    .target(
      name: "LocalFlowSpeech",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    .testTarget(name: "LocalFlowCoreTests", dependencies: ["LocalFlowSpeech"]),
  ]
)
