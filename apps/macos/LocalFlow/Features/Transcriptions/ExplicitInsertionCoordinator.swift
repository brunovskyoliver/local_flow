import AppKit
import Observation

/// Holds one reviewed entry and one target. No recording or history mutation may
/// overlap this operation; the durable attempt is written before AX dispatch.
@MainActor @Observable
final class ExplicitInsertionCoordinator {
  enum Phase: Equatable { case idle, reviewing, selecting, confirming, inserting }
  var phaseChanged: ((Phase) -> Void)?
  private(set) var phase: Phase = .idle { didSet { phaseChanged?(phase) } }
  private(set) var entry: TranscriptionEntry?
  private(set) var message = ""
  @ObservationIgnored private let store: any TranscriptionStoring
  @ObservationIgnored private let insertion: any TextInserting
  @ObservationIgnored private let dictation: DictationCoordinator
  @ObservationIgnored private let presentsPanel: Bool
  @ObservationIgnored private var panel: InsertionConfirmationPanel?
  @ObservationIgnored private var target: CapturedTarget?
  /// The chosen text and what it came from: the faithful transcript or one attempt.
  @ObservationIgnored private var chosen: (text: String, delivery: RewriteDelivery) = (
    "", .faithful
  )
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var selectionDeadline: Task<Void, Never>?
  @ObservationIgnored private var capturingTarget = false
  @ObservationIgnored private var selectionExpired = false
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var cancelled = false
  var warnings: [String] {
    guard let entry else { return [] }
    var values: [String] = []
    if entry.quality == .incomplete {
      values.append("This transcription is incomplete. Review the text before inserting.")
    }
    if entry.quality == .durationLimited {
      values.append("Recording stopped at 180 seconds. The ending may be missing.")
    }
    if entry.deliveryState == .uncertain || entry.deliveryState == .attempting {
      values.append(
        "This text may already be in the destination. Inserting again could duplicate it.")
    } else if entry.deliveryState == .confirmed {
      values.append("This text was already inserted. Inserting again creates another copy.")
    }
    return values
  }

  init(
    store: any TranscriptionStoring, insertion: any TextInserting,
    dictation: DictationCoordinator, presentsPanel: Bool = true
  ) {
    self.store = store
    self.insertion = insertion
    self.dictation = dictation
    self.presentsPanel = presentsPanel
  }

  /// Reviews a specific rewrite attempt's output instead of the saved text.
  /// The target selection and confirmation flow are the same.
  @discardableResult
  func beginReview(_ entry: TranscriptionEntry, attempt: RewriteAttempt) -> Bool {
    guard attempt.transcriptionID == entry.id, let text = attempt.deliverableText else {
      return false
    }
    return beginReview(
      entry, text: text,
      delivery: RewriteDelivery(
        source: .rewrite, attemptID: attempt.id, durationMilliseconds: nil))
  }

  @discardableResult
  func beginReview(_ entry: TranscriptionEntry) -> Bool {
    beginReview(entry, text: entry.text, delivery: .faithful)
  }

  @discardableResult
  private func beginReview(
    _ entry: TranscriptionEntry, text: String, delivery: RewriteDelivery
  ) -> Bool {
    guard phase == .idle,
      dictation.acquireExplicitInsertion(cancel: { [weak self] in self?.cancel() })
    else { return false }
    generation = UUID()
    cancelled = false
    selectionExpired = false
    self.entry = entry
    chosen = (text, delivery)
    message = "Review the text, then choose a destination."
    phase = .reviewing
    return true
  }

  /// The text this review will insert: the saved transcript or a chosen rewrite.
  var reviewText: String { chosen.text }

  func armSelection() {
    guard phase == .reviewing else { return }
    phase = .selecting
    message = "Focus the destination field, then click Use focused field here."
    showPanel()
    let token = generation
    selectionDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(60)) } catch { return }
      guard let self, self.generation == token, self.phase == .selecting else { return }
      self.selectionExpired = true
      self.cancel()
    }
  }

  func selectTarget() {
    guard phase == .selecting, !capturingTarget, !cancelled else { return }
    capturingTarget = true
    message = "Checking the focused field…"
    showPanel()
    let token = generation
    operation = Task { [weak self] in
      guard let self else { return }
      defer {
        self.capturingTarget = false
        if self.cancelled, self.generation == token, self.phase == .selecting {
          self.finish(
            self.selectionExpired
              ? "Selection expired. Your text remains saved."
              : "Insertion cancelled. The text remains saved.")
        } else if self.phase == .selecting {
          self.showPanel()
        }
      }
      let selected = await self.insertion.captureTarget()
      guard !Task.isCancelled, self.generation == token, self.phase == .selecting else { return }
      guard let selected, selected.processIdentifier != ProcessInfo.processInfo.processIdentifier
      else {
        self.message =
          "Choose a supported editable field in another app, then click Use focused field."
        return
      }
      self.selectionDeadline?.cancel()
      self.selectionDeadline = nil
      self.target = selected
      self.phase = .confirming
      self.message =
        "Insert into \(selected.bundleIdentifier), selected field at character \(selected.selectedRange.location + 1)?"
      self.showPanel()
    }
  }

  func confirm() {
    guard phase == .confirming, let entry, let target else { return }
    phase = .inserting
    message = "Inserting…"
    showPanel()
    operation = Task { [weak self] in
      guard let self else { return }
      do {
        let attempt = try await self.store.beginAttempt(id: entry.id, revision: entry.revision)
        let result: InsertionOutcome
        if self.cancelled || Task.isCancelled {
          result = .notInserted(.unsupported)
        } else {
          // insertOnce revalidates process, element, window, selection and context.
          result = await self.insertion.insertOnce(
            attemptID: attempt.id, target: target, text: self.chosen.text)
        }
        let outcome: TranscriptionStore.Outcome
        switch result {
        case .confirmed: outcome = .confirmed
        case .notInserted: outcome = .notInserted
        case .uncertain: outcome = .uncertain
        }
        do {
          _ = try await self.store.recordOutcome(
            id: entry.id, revision: attempt.entry.revision,
            attemptID: attempt.id, outcome: outcome, delivery: self.chosen.delivery)
        } catch {
          self.dictation.preserveExplicitOutcome(
            id: entry.id, revision: attempt.entry.revision,
            attempt: attempt.id, outcome: outcome, delivery: self.chosen.delivery)
          self.finish("Delivery status could not be saved. Retry storage before continuing.")
          return
        }
        await self.dictation.refreshHistory()
        switch result {
        case .confirmed: self.finish("Text inserted. The original remains in history.")
        case .notInserted:
          self.finish("Nothing was inserted. Review the saved text and choose the field again.")
        case .uncertain:
          self.finish("Delivery is uncertain. Check the destination before inserting again.")
        }
      } catch {
        self.finish(
          "Could not prepare insertion. The text remains saved; refresh history and try again.")
      }
    }
  }

  func cancel() {
    guard phase != .idle else { return }
    cancelled = true
    operation?.cancel()
    if phase == .selecting {
      if capturingTarget {
        message = "Cancelling selection…"
        showPanel()
      } else {
        finish(
          selectionExpired
            ? "Selection expired. Your text remains saved."
            : "Insertion cancelled. The text remains saved.")
      }
    } else if phase == .inserting {
      message = "Finishing delivery status…"
      showPanel()
    } else {
      finish("Insertion cancelled. The text remains saved.")
    }
  }

  private func finish(_ message: String) {
    generation = UUID()
    entry = nil
    chosen = ("", .faithful)
    target = nil
    operation = nil
    selectionDeadline?.cancel()
    selectionDeadline = nil
    self.message = message
    panel?.orderOut(nil)
    dictation.finishExplicitInsertion(message: message)
    phase = .idle
  }

  private func showPanel() {
    guard presentsPanel else { return }
    if panel == nil { panel = InsertionConfirmationPanel() }
    panel?.show(
      message: message, selecting: phase == .selecting,
      canSelect: phase == .selecting && !capturingTarget && !cancelled,
      canConfirm: phase == .confirming,
      select: { [weak self] in self?.selectTarget() },
      target: target, confirm: { [weak self] in self?.confirm() },
      cancel: { [weak self] in self?.cancel() })
  }
}
