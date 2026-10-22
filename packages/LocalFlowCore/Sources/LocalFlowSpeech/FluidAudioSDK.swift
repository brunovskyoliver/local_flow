import FluidAudio

/// The FluidAudio release this package links (`Package.swift`, `exact:`). Provenance and
/// the speech worker's readiness record this value, the code that actually ran. A model
/// manifest's `sdkCompatibility` names the release its files were pinned against, which
/// can be older: the Parakeet v3 files were pinned against 0.15.7 and load unchanged.
public enum FluidAudioSDK {
  public static let version = "0.17.7"

  /// Manifest pins this build has checked to load with `version`. Keeping the v3 manifest
  /// byte-identical keeps installed models valid: the provisioner compares manifests exactly.
  static let compatibleManifestPins: Set<String> = ["0.15.7", "0.17.7"]

  private static let loggingConfigured: Void = {
    // FluidAudio's debug and info lines include recognized text and Dictionary terms.
    // Drop them, and never mirror to stderr: the unified log keeps interpolated text private.
    AppLogger.minimumLevel = .warning
    AppLogger.mirrorsToConsole = false
  }()

  /// Called by every factory that loads a FluidAudio model, before loading it.
  public static func configureLogging() { _ = loggingConfigured }
}
