import Foundation

struct AssembledWindow: Sendable {
  let window: TranscriptAssembler.Window
  let text: String
  let seam: TranscriptAssembler.Seam?
  let sourceSpans: [TranscriptAssembler.SourceSpan]
}

struct MeetingWindowAssembler: Sendable {
  let geometry: String
  private let maximumWindowSamples: Int
  private var previous: TranscriptAssembler.Window?
  var retainedWindowCount: Int { previous == nil ? 0 : 1 }
  var assemblyVersion: String { "\(TranscriptAssembler.version)/\(geometry)" }

  init(geometry: String = LiveChunkPlanner.version, maximumWindowSamples: Int = 239_360) {
    self.geometry = geometry
    self.maximumWindowSamples = maximumWindowSamples
  }

  mutating func append(window: TranscriptAssembler.Window) -> AssembledWindow {
    var assembler = TranscriptAssembler(maximumWindowSamples: maximumWindowSamples)
    var offset = 0
    if let previous {
      offset = previous.sampleCount
      // Adjacent windows require geometry alone. If two maximum-sized results would
      // exceed the dictation assembler's combined text bound, retain only the previous
      // geometry for this seam; the current received bytes remain untouched.
      let fits = previous.text.utf8.count + window.text.utf8.count + 1 <= 65_536
      assembler.append(
        .init(
          sequence: 0, sampleStart: 0, sampleCount: previous.sampleCount,
          paddedSampleCount: max(4_800, previous.sampleCount), text: fits ? previous.text : "",
          tokens: fits ? previous.tokens : nil))
    }
    assembler.append(
      .init(
        sequence: previous == nil ? 0 : 1, sampleStart: offset,
        sampleCount: window.sampleCount, paddedSampleCount: max(4_800, window.sampleCount),
        text: window.text, tokens: window.tokens))
    let seam = assembler.seams.last
    let cut = seam?.discardedPrefixBytes ?? 0
    let text = String(decoding: window.text.utf8.dropFirst(cut), as: UTF8.self)
    let spans: [TranscriptAssembler.SourceSpan] =
      text.isEmpty
      ? []
      : [
        .init(
          rawWindowIndex: 0, utf8Start: cut, utf8End: window.text.utf8.count,
          outputUTF8Start: 0, separatorBytes: 0)
      ]
    previous = window
    return .init(window: window, text: text, seam: seam, sourceSpans: spans)
  }
}
