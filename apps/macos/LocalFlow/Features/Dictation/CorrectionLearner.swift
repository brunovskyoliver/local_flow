import Foundation
import Observation

/// Turns one observed in-place edit of inserted text into a dictionary candidate.
/// Pure word diff: exactly one contiguous run of 1–3 inserted words replaced by 1–3 words,
/// everything else unchanged and in order.
enum CorrectionDetector {
  static let maximumWords = 3
  struct Candidate: Equatable, Sendable {
    let misspelling: String
    let correction: String
  }

  /// `before`/`after` are whole-word margins read around the insertion; `current` is the same
  /// window read later. `leadingCut` says the read started mid-word, so the first word of
  /// every read is dropped. The edit must sit inside the inserted passage, and the words after
  /// it must reappear unchanged.
  static func candidate(
    inserted: String, before: String, after: String, current: String, leadingCut: Bool = false,
    openEnded: Bool = false
  ) -> Candidate? {
    var beforeWords = words(before)
    let insertedWords = words(inserted)
    let afterWords = words(after)
    var now = words(current)
    if leadingCut {
      guard !beforeWords.isEmpty, !now.isEmpty else { return nil }
      beforeWords.removeFirst()
      now.removeFirst()
    }
    guard !insertedWords.isEmpty else { return nil }
    let base = beforeWords + insertedWords
    var prefix = 0
    while prefix < base.count, prefix < now.count, base[prefix] == now[prefix] { prefix += 1 }
    guard prefix >= beforeWords.count, prefix < base.count else { return nil }
    for replacedCount in 1...maximumWords {
      let replacedEnd = prefix + replacedCount
      guard replacedEnd <= base.count else { break }
      let tail = Array(base[replacedEnd...]) + afterWords
      for replacementCount in 1...maximumWords {
        let replacementEnd = prefix + replacementCount
        guard replacementEnd + tail.count <= now.count else { break }
        guard Array(now[replacementEnd..<(replacementEnd + tail.count)]) == tail else { continue }
        // With no trailing anchor, extra typed words would be mistaken for the correction:
        // the edit must end the read and must not grow the passage. Undo covers the rest.
        if afterWords.isEmpty, !openEnded {
          guard replacementEnd + tail.count == now.count else { continue }
          if tail.isEmpty, replacementCount > replacedCount { continue }
        }
        return make(
          replaced: base[prefix..<replacedEnd], replacement: now[prefix..<replacementEnd])
      }
    }
    return nil
  }

  private static func make(replaced: ArraySlice<String>, replacement: ArraySlice<String>)
    -> Candidate?
  {
    let misspelling = trimmed(replaced.joined(separator: " "))
    let correction = trimmed(replacement.joined(separator: " "))
    guard !misspelling.isEmpty, !correction.isEmpty, misspelling != correction,
      VocabularyValidation.termCode(misspelling) == nil,
      VocabularyValidation.termCode(correction) == nil,
      misspelling.unicodeScalars.contains(where: VocabularyValidation.isTermScalar),
      correction.unicodeScalars.contains(where: VocabularyValidation.isTermScalar)
    else { return nil }
    return Candidate(misspelling: misspelling, correction: correction)
  }

  private static func words(_ text: String) -> [String] {
    text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  /// Sentence punctuation around a term is not part of it.
  private static func trimmed(_ term: String) -> String {
    // Preserve literal markers for the assessment layer (for example /foo or ~/foo).
    let edges = CharacterSet.punctuationCharacters.union(.symbols)
      .subtracting(CharacterSet(charactersIn: "/\\:@~"))
    var scalars = Substring(term).unicodeScalars
    while let first = scalars.first, edges.contains(first) { scalars.removeFirst() }
    while let last = scalars.last, edges.contains(last) { scalars.removeLast() }
    return String(scalars)
  }
}

/// One "Added to dictionary" bubble with its undo deadline.
struct LearnedNotice: Equatable, Sendable {
  static let undoWindow: Duration = .seconds(6)
  let entryID: String
  let canonical: String
  let shownAt: ContinuousClock.Instant
}

/// Watches the field a confirmed insertion went into, for a bounded time, and learns one
/// in-place correction per insertion. Off unless the user enables it; reads only the
/// inserted passage plus small margins; never logs field text.
@MainActor @Observable
final class CorrectionLearner {
  static let observationWindow: Duration = .seconds(90)
  static let pollInterval: Duration = .seconds(1)
  static let marginUnits = 48
  static let growthUnits = 64
  static let maximumInsertedUnits = 4_096

  enum StopReason: String, Sendable {
    case learned
    case windowElapsed = "window_elapsed"
    case focusChanged = "focus_changed"
    case passageMoved = "passage_moved"
    case readFailed = "read_failed"
    case cancelled, disabled, rejected
  }

  private(set) var lastAssessment: CorrectionCandidateAssessment?
  private(set) var notice: LearnedNotice?
  private(set) var observing = false
  private(set) var lastStop: StopReason?
  var noticeChanged: ((LearnedNotice?) -> Void)?
  var stopped: ((StopReason) -> Void)?
  /// A correction worth suggesting: canonical spelling and the replaced text ("" if none).
  var suggested: ((_ canonical: String, _ alias: String) -> Void)?
  @ObservationIgnored private let scorer: any CorrectionCandidateScoring
  @ObservationIgnored private var candidateHistory = CorrectionCandidateHistory()
  @ObservationIgnored private let reader: any TextInserting
  @ObservationIgnored private let store: any VocabularyEditing
  @ObservationIgnored private let isEnabled: @MainActor () -> Bool
  @ObservationIgnored private let pollInterval: Duration
  @ObservationIgnored private let observationWindow: Duration
  @ObservationIgnored private let undoWindow: Duration
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var noticeTask: Task<Void, Never>?

  /// Durations are injectable so tests run in milliseconds; production uses the constants.
  init(
    reader: any TextInserting, store: any VocabularyEditing,
    isEnabled: @escaping @MainActor () -> Bool,
    pollInterval: Duration = pollInterval, observationWindow: Duration = observationWindow,
    undoWindow: Duration = LearnedNotice.undoWindow,
    scorer: any CorrectionCandidateScoring = CorrectionCandidateScorer()
  ) {
    self.scorer = scorer
    self.reader = reader
    self.store = store
    self.isEnabled = isEnabled
    self.pollInterval = pollInterval
    self.observationWindow = observationWindow
    self.undoWindow = undoWindow
  }

  /// Call after an insertion was confirmed at `target.selectedRange.location`.
  func observe(inserted text: String, target: CapturedTarget) {
    cancelObservation(.cancelled)
    lastAssessment = nil
    guard isEnabled() else {
      finish(.disabled)
      return
    }
    let length = text.utf16.count
    guard length > 0, length <= Self.maximumInsertedUnits, target.selectedRange.location >= 0 else {
      finish(.rejected)
      return
    }
    observing = true
    lastStop = nil
    task = Task { [weak self] in
      guard let self else { return }
      let reason = await self.run(text: text, target: target, length: length)
      guard !Task.isCancelled else { return }
      self.finish(reason)
    }
  }

  /// A new dictation or an explicit cancel ends observation and hides any bubble.
  func cancel() {
    cancelObservation(.cancelled)
    dismissNotice()
  }

  func undo() async {
    guard let notice else { return }
    dismissNotice()
    _ = try? await store.delete(id: notice.entryID, expectedRevision: nil)
  }

  private func cancelObservation(_ reason: StopReason) {
    guard let running = task else { return }
    running.cancel()
    task = nil
    if observing { finish(reason) }
  }

  private func finish(_ reason: StopReason) {
    observing = false
    lastStop = reason
    task = nil
    stopped?(reason)
  }

  private func run(text: String, target: CapturedTarget, length: Int) async -> StopReason {
    let start = max(0, target.selectedRange.location - Self.marginUnits)
    let leading = target.selectedRange.location - start
    let baselineLength = leading + length + Self.marginUnits
    let baseline: String
    do {
      baseline = try await reader.readText(on: target, location: start, length: baselineLength)
    } catch {
      return Self.stopReason(for: error)
    }
    let units = Array(baseline.utf16)
    guard units.count >= leading + length,
      String(utf16CodeUnits: Array(units[leading..<(leading + length)]), count: length) == text
    else { return .passageMoved }
    let before = String(utf16CodeUnits: Array(units[..<leading]), count: leading)
    var after = String(
      utf16CodeUnits: Array(units[(leading + length)...]), count: units.count - leading - length)
    // A full-length read may end mid-word; keep only whole words as the trailing anchor.
    var openEnded = false
    if units.count == baselineLength {
      if let cut = after.lastIndex(where: \.isWhitespace) {
        after = String(after[..<cut])
      } else {
        after = ""
        openEnded = true
      }
    }
    let leadingCut = start > 0
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: observationWindow)
    var pending: CorrectionDetector.Candidate?
    while clock.now < deadline {
      do {
        try await clock.sleep(for: pollInterval)
      } catch {
        return .cancelled
      }
      guard !Task.isCancelled else { return .cancelled }
      guard isEnabled() else { return .disabled }
      let current: String
      do {
        current = try await reader.readText(
          on: target, location: start, length: baselineLength + Self.growthUnits)
      } catch {
        let reason = Self.stopReason(for: error)
        // Fixing a word and pressing Return clears or leaves the field before a second read
        // can confirm the fix; the last read before that is the final text.
        if let pending, reason == .focusChanged || reason == .readFailed {
          guard !Task.isCancelled else { return .cancelled }
          return await learn(pending)
        }
        return reason
      }
      let candidate = CorrectionDetector.candidate(
        inserted: text, before: before, after: after, current: current, leadingCut: leadingCut,
        openEnded: openEnded)
      // Two identical reads a second apart mean the user finished typing the correction.
      guard let candidate, candidate == pending else {
        pending = candidate
        continue
      }
      guard !Task.isCancelled else { return .cancelled }
      return await learn(candidate)
    }
    return .windowElapsed
  }

  private static func stopReason(for error: Error) -> StopReason {
    switch error as? TargetIssue {
    case .focusChanged, .staleProcess, .accessibilityDenied: .focusChanged
    default: .readFailed
    }
  }

  private func learn(_ candidate: CorrectionDetector.Candidate) async -> StopReason {
    guard isEnabled() else { return .disabled }
    let key = VocabularyValidation.fold(candidate.misspelling)
    let target = VocabularyValidation.fold(candidate.correction)
    // A case- or accent-only fix is the canonical spelling itself; it needs no alias.
    let entry = VocabularyEntry(
      canonical: candidate.correction, aliases: key == target ? [] : [candidate.misspelling],
      enabled: true, learnedAt: Int64(Date().timeIntervalSince1970 * 1000))
    do {
      let contents = try await store.contents()
      guard !Task.isCancelled else { return .cancelled }
      guard isEnabled() else { return .disabled }
      let span = CorrectionCandidate(
        sourceText: candidate.misspelling, replacementText: candidate.correction)
      let assessment = scorer.assess(
        span,
        context: .init(
          canonicalTerms: contents.entries.filter(\.enabled).map(\.canonical),
          previousObservations: candidateHistory.observe(span)))
      lastAssessment = assessment
      // An entry that already maps this misspelling (or is this word) means nothing to learn.
      for existing in contents.entries {
        let keys = ([existing.canonical] + existing.aliases).map(VocabularyValidation.fold)
        if keys.contains(key) || keys.contains(target) { return .rejected }
      }
      guard assessment.disposition == .autoLearn else {
        // Feature 013: the Dictionary lists it for approval.
        if assessment.disposition == .suggest {
          suggested?(entry.canonical, entry.aliases.first ?? "")
        }
        return .rejected
      }
      _ = try await store.save(entry, expectedRevision: contents.state.revision)
    } catch {
      return .rejected
    }
    guard !Task.isCancelled else { return .cancelled }
    show(
      LearnedNotice(entryID: entry.id, canonical: entry.canonical, shownAt: ContinuousClock().now))
    return .learned
  }

  private func show(_ value: LearnedNotice) {
    noticeTask?.cancel()
    notice = value
    noticeChanged?(value)
    noticeTask = Task { [weak self] in
      guard let window = self?.undoWindow else { return }
      try? await ContinuousClock().sleep(for: window)
      guard !Task.isCancelled, let self, self.notice == value else { return }
      self.dismissNotice()
    }
  }

  private func dismissNotice() {
    noticeTask?.cancel()
    noticeTask = nil
    guard notice != nil else { return }
    notice = nil
    noticeChanged?(nil)
  }
}
