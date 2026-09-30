import Foundation

/// One immutable result travels through save/retry; summaries never contain the detail.
public struct TranscriptionEnvelope: Sendable {
  public let entry: TranscriptionEntry
  public let detail: TranscriptionQualityDetail?
  /// Feature 012: the context row, committed in the entry's transaction. Nil for
  /// legacy entries and for callers that predate the feature.
  public var context: DictationContextRecord? = nil

  public init(
    entry: TranscriptionEntry, detail: TranscriptionQualityDetail?,
    context: DictationContextRecord? = nil
  ) {
    self.entry = entry
    self.detail = detail
    self.context = context
  }

  func validate() throws {
    try context?.validate()
    guard let detail else { return }
    try detail.validate(normalizedText: entry.text)
    guard !detail.incomplete || entry.quality != .complete else {
      throw TranscriptionQualityDetail.Failure.invalidMetadata
    }
  }
}
