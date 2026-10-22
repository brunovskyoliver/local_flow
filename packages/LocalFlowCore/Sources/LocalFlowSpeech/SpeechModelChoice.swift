import Foundation

/// The pinned Parakeet TDT 0.6B checkpoints dictation and live previews can use. Both share
/// the v3 tokenizer (byte-identical `parakeet_vocab.json`), the 15 s window and the
/// JointDecisionv3 contract; only the weights differ. v3 is the default and the rollback.
public enum SpeechModelChoice: String, CaseIterable, Sendable, Identifiable {
  case parakeetV3 = "parakeet-v3"
  /// Moondream's post-trained v3, as FluidInference's Core ML build (int8 encoder).
  case parakeetUltra = "parakeet-ultra"

  public static let defaultChoice = SpeechModelChoice.parakeetV3

  public var id: String { rawValue }
  /// The bundled manifest's resource name and the install directory under Models.
  public var resourceName: String { rawValue }

  public var displayName: String {
    switch self {
    case .parakeetV3: "Parakeet v3"
    case .parakeetUltra: "Parakeet Ultra"
    }
  }

  /// Exact identity the factory accepts: model ID, immutable revision and manifest SDK pin.
  public var modelID: String {
    switch self {
    case .parakeetV3: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    case .parakeetUltra: "FluidInference/parakeet-ultra-coreml"
    }
  }

  public var sourceRevision: String {
    switch self {
    case .parakeetV3: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
    case .parakeetUltra: "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
    }
  }

  var manifestSDK: String {
    switch self {
    case .parakeetV3: "0.15.7"
    case .parakeetUltra: "0.17.7"
    }
  }

  /// Attribution shown before the download and in model details.
  public var attribution: String {
    switch self {
    case .parakeetV3:
      "NVIDIA parakeet-tdt-0.6b-v3, Core ML conversion by FluidInference. License: CC BY 4.0."
    case .parakeetUltra:
      "Moondream parakeet-ultra (post-trained from NVIDIA parakeet-tdt-0.6b-v3), Core ML conversion by FluidInference. License: CC BY 4.0."
    }
  }

  /// The choice whose pin `descriptor` matches exactly, or nil.
  public init?(pinned descriptor: ModelDescriptor) {
    guard
      let match = Self.allCases.first(where: {
        $0.modelID == descriptor.modelID && $0.sourceRevision == descriptor.sourceRevision
          && $0.manifestSDK == descriptor.sdkCompatibility
      }),
      FluidAudioSDK.compatibleManifestPins.contains(descriptor.sdkCompatibility),
      descriptor.automaticLanguage, descriptor.effectiveCapability == .speechRecognition
    else { return nil }
    self = match
  }

  /// A stored preference; anything unknown reads as the default.
  public init(storedValue: String?) {
    self = storedValue.flatMap(Self.init(rawValue:)) ?? .defaultChoice
  }
}
