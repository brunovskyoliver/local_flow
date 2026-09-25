import SwiftUI

/// The pill's colors, shared by every notice so they read as one object.
enum PillStyle {
  static let fill = Color(red: 36 / 255, green: 37 / 255, blue: 34 / 255)
  static let ink = Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255)
  static let stroke = Color.white.opacity(0.13)
  /// Size and position changes: settles quickly with no visible overshoot.
  static let morph = Animation.spring(response: 0.42, dampingFraction: 0.86)
  /// Notices entering and leaving the pill.
  static let swap = Animation.spring(response: 0.34, dampingFraction: 0.9)
}

extension View {
  /// The dark capsule every indicator notice sits in.
  func pillBackground(highlighted: Bool = false) -> some View {
    background(PillStyle.fill.opacity(highlighted ? 0.92 : 1), in: Capsule())
      .overlay {
        Capsule().strokeBorder(.white.opacity(highlighted ? 0.22 : 0.13), lineWidth: 1)
      }
  }
}

struct DictationIndicator: View {
  static let compactWidth: CGFloat = 46
  static let expandedWidth: CGFloat = 118
  static let barCount = 15
  let state: DictationSession.State
  let level: Float
  let cancel: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  /// Drives the recording reveal: the capsule opens out from its compact width and
  /// the bars come in from the right, where the recording enters.
  @State private var expanded = false
  /// What was said so far, one bar per slice, scrolling right to left.
  @State private var history = WaveformHistory()
  @AccessibilityFocusState private var accessibilityFocused: Bool

  var body: some View {
    ZStack {
      if state == .rewriting && !reduceMotion {
        // No label: a slow rolling wave with a light sweeping through it says the
        // text is being worked on.
        TimelineView(.animation) { timeline in
          rewritingWave(time: timeline.date.timeIntervalSinceReferenceDate)
        }
        .transition(.opacity)
      } else if state == .recording && !reduceMotion {
        TimelineView(.animation) { timeline in
          recordingStrip(time: timeline.date.timeIntervalSinceReferenceDate)
        }
      } else if Self.isProcessing(state) && !reduceMotion {
        // A soft pulse travels across low bars while the text is being made.
        TimelineView(.animation) { timeline in
          bars(time: timeline.date.timeIntervalSinceReferenceDate)
        }
        .transition(.opacity)
      } else {
        bars(time: nil)
      }
    }
    .frame(width: expanded ? Self.expandedWidth : Self.compactWidth, height: 38)
    .clipShape(Capsule())
    .pillBackground()
    .frame(width: Self.expandedWidth, height: 38)
    .overlay(alignment: .trailing) {
      Button(action: cancel) {
        Image(systemName: "xmark").font(.flow(size: 10, weight: .semibold))
      }
      .buttonStyle(.plain).frame(width: 24, height: 24)
      .background(SottoPalette.canvas, in: Circle())
      .offset(x: 35)
      .accessibilityLabel(state == .rewriting ? "Cancel rewrite" : "Cancel dictation")
      .accessibilityFocused($accessibilityFocused)
      .scaleEffect(hovering || accessibilityFocused ? 1 : 0.6)
      .opacity(hovering || accessibilityFocused ? 1 : 0)
      .animation(PillStyle.swap, value: hovering)
    }
    .frame(width: 153, height: 38, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .animation(PillStyle.morph, value: expanded)
    .animation(PillStyle.swap, value: state)
    .onAppear { setExpanded(for: state, animated: !reduceMotion) }
    .onChange(of: state) { previous, state in
      if state == .recording, previous != .recording { history = WaveformHistory() }
      setExpanded(for: state, animated: !reduceMotion)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      state == .recording
        ? "Recording"
        : state == .preparing
          ? "Preparing, microphone off"
          : state == .rewriting ? "Rewriting text, microphone off" : "Processing, microphone off"
    )
    .accessibilityAction(named: state == .rewriting ? "Cancel rewrite" : "Cancel dictation", cancel)
  }

  private func bars(time: TimeInterval?) -> some View {
    HStack(spacing: 3) {
      ForEach(0..<Self.barCount, id: \.self) { bar in
        let height =
          time.map { Self.processingBarHeight(bar, time: $0) }
          ?? Self.barHeight(bar, state: state, level: level, reduceMotion: reduceMotion)
        revealed(Capsule().fill(PillStyle.ink).frame(width: 3, height: height), slot: bar)
      }
    }
    .frame(width: Self.expandedWidth)
  }

  /// The live recording: the newest slice grows at the right edge while the strip
  /// slides left by one bar per slice, so speech moves across like a track playing.
  private func recordingStrip(time: TimeInterval) -> some View {
    history.advance(to: time, level: level)
    let heights = history.heights
    let step = WaveformHistory.barPitch * CGFloat(history.progress(at: time))
    return HStack(spacing: WaveformHistory.barPitch - 3) {
      ForEach(heights.indices, id: \.self) { slot in
        revealed(Capsule().fill(PillStyle.ink).frame(width: 3, height: heights[slot]), slot: slot)
      }
    }
    .offset(x: -step)
    .frame(width: WaveformHistory.windowWidth, alignment: .leading)
    .clipped()
    // Older speech fades as it leaves on the left.
    .mask {
      LinearGradient(
        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28)],
        startPoint: .leading, endPoint: .trailing)
    }
    .frame(width: Self.expandedWidth)
  }

  private func rewritingWave(time: TimeInterval) -> some View {
    HStack(spacing: 3) {
      ForEach(0..<Self.barCount, id: \.self) { bar in
        let wave = Self.rewritingWave(bar, time: time)
        Capsule().fill(PillStyle.ink)
          .frame(width: 3, height: wave.height)
          .opacity(wave.opacity)
      }
    }
    .frame(width: Self.expandedWidth)
  }

  /// A sine rolling right to left over the bars, with a brighter band sweeping
  /// across every 1.6 s. Heights stay between 5 and 17 pt.
  static func rewritingWave(_ bar: Int, time: TimeInterval) -> (height: CGFloat, opacity: Double) {
    let roll = sin(time * 5.5 + Double(bar) * 0.55)
    let sweep = (time / 1.6).truncatingRemainder(dividingBy: 1) * Double(barCount + 8) - 4
    let glow = exp(-pow(Double(barCount - 1 - bar) - sweep, 2) / 6)
    return (CGFloat(11 + 6 * roll), 0.45 + 0.55 * glow)
  }

  /// Bars come in from the right when the pill opens; collapsing runs back at once.
  private func revealed(_ bar: some View, slot: Int) -> some View {
    bar
      .opacity(expanded || state == .preparing ? 1 : 0)
      .scaleEffect(y: expanded || state == .preparing ? 1 : 0.2)
      .animation(
        reduceMotion || !expanded
          ? PillStyle.swap : PillStyle.morph.delay(Double(Self.barCount - slot) * 0.014),
        value: expanded)
  }

  /// Preparing sits compact; everything after the microphone opens is full width.
  private func setExpanded(for state: DictationSession.State, animated: Bool) {
    let target = state != .preparing
    guard target != expanded else { return }
    if animated {
      expanded = target
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { expanded = target }
    }
  }

  static func isProcessing(_ state: DictationSession.State) -> Bool {
    [.transcribing, .persisting, .inserting, .cancelling].contains(state)
  }

  /// A crest moving right to left over resting bars, one pass every 1.2 s.
  static func processingBarHeight(_ bar: Int, time: TimeInterval) -> CGFloat {
    let period = 1.2
    let phase = time.truncatingRemainder(dividingBy: period) / period
    // The crest travels a little past both ends so it enters and leaves smoothly.
    let crest = phase * Double(barCount + 6) - 3
    // Right to left, the same way the recording moved.
    let distance = abs(Double(barCount - 1 - bar) - crest)
    let lift = exp(-distance * distance / 4.5)
    return CGFloat(4 + 12 * lift)
  }

  static func barHeight(_ bar: Int, state: DictationSession.State, level: Float, reduceMotion: Bool)
    -> CGFloat
  {
    guard (0..<15).contains(bar) else { return 0 }
    switch state {
    case .preparing: return 4
    case .recording:
      let pattern = [7.0, 12, 19, 10, 23, 15, 27, 18, 11, 23, 15, 8, 18, 11, 6]
      return CGFloat(
        pattern[bar]
          * (reduceMotion
            ? 0.75 : 0.25 + 0.75 * Double(level.isFinite ? min(max(level * 5, 0), 1) : 0)))
    default: return bar.isMultiple(of: 3) ? 14 : 4
    }
  }
}

/// The recorded waveform as fixed-length slices. Each slice keeps the loudest level
/// heard during it, so syllables show as peaks and pauses as dots. It is a plain
/// reference: advancing it during a frame never invalidates the view.
@MainActor
final class WaveformHistory {
  /// One bar per slice; 15 bars hold about a second of speech.
  static let slice: TimeInterval = 0.07
  static let barPitch: CGFloat = 6
  /// Fifteen bars plus the gaps between them.
  static let windowWidth: CGFloat = barPitch * CGFloat(DictationIndicator.barCount) - 3
  /// Completed slices, oldest first; the slice being recorded is `current`.
  private(set) var slices: [Float] = Array(repeating: 0, count: DictationIndicator.barCount)
  private(set) var current: Float = 0
  private var sliceStart: TimeInterval?

  /// Takes the latest meter level and closes every slice that has ended by `time`.
  func advance(to time: TimeInterval, level: Float) {
    let level = level.isFinite ? min(max(level, 0), 1) : 0
    guard let start = sliceStart else {
      sliceStart = time
      current = level
      return
    }
    let ended = Int((time - start) / Self.slice)
    if ended > 0 {
      // A long frame gap closes several slices; the ones missed are silence.
      for index in 0..<min(ended, slices.count) {
        slices.removeFirst()
        slices.append(index == 0 ? current : 0)
      }
      sliceStart = start + Double(ended) * Self.slice
      current = level
    } else {
      current = max(current, level)
    }
  }

  /// How far the open slice has run, 0…1: the strip's sub-bar scroll.
  func progress(at time: TimeInterval) -> Double {
    guard let sliceStart else { return 0 }
    return min(max((time - sliceStart) / Self.slice, 0), 1)
  }

  /// Completed slices followed by the one still growing at the right edge.
  var heights: [CGFloat] { (slices + [current]).map(Self.height) }

  /// 3 pt at silence up to 28 pt; the curve lifts quiet speech so it reads.
  static func height(_ level: Float) -> CGFloat {
    let loudness = level.isFinite ? Double(min(max(level * 5, 0), 1)) : 0
    return CGFloat(3 + 25 * pow(loudness, 0.7))
  }
}

/// "Added to dictionary" in the indicator's capsule, with Undo ringed by a draining countdown.
struct LearnedNoticeView: View {
  let notice: LearnedNotice
  let undo: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var remaining: Double = 1

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "sparkles").font(.flow(size: 11, weight: .semibold))
        .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255).opacity(0.9))
      Text("Added to dictionary").font(.flow(size: 12, weight: .medium))
        .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255))
        .lineLimit(1)
      Spacer(minLength: 4)
      Button(action: undo) {
        Text("Undo").font(.flow(size: 11, weight: .semibold))
          .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255))
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(.white.opacity(0.1), in: Capsule())
          .overlay {
            // The ring drains from the trailing edge as the undo window closes.
            Capsule().trim(from: 0, to: remaining)
              .stroke(
                Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255).opacity(0.9),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
              )
          }
          .padding(1)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Undo adding \(notice.canonical) to dictionary")
      .accessibilityIdentifier("dictionary.notice.undo")
    }
    .padding(.leading, 14).padding(.trailing, 5)
    .frame(height: 38)
    .fixedSize()
    .background(Color(red: 36 / 255, green: 37 / 255, blue: 34 / 255), in: Capsule())
    .overlay { Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Added \(notice.canonical) to dictionary")
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.linear(duration: LearnedNotice.undoWindow.seconds)) { remaining = 0 }
    }
  }
}

extension Duration {
  /// Whole seconds plus attoseconds, for animation timing.
  var seconds: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}

/// One-line notice with a single action, in the indicator's capsule: used for
/// rewrite fallbacks, refusals and cancellations.
struct ActionNoticeView: View {
  /// The longest a one-line message grows before it truncates.
  static let maximumTextWidth: CGFloat = 420
  let message: String
  let actionTitle: String?
  let actionIdentifier: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "text.badge.xmark").font(.flow(size: 11, weight: .semibold))
        .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255).opacity(0.9))
      Text(message).font(.flow(size: 12, weight: .medium))
        .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255))
        .lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: Self.maximumTextWidth)
      if let actionTitle {
        Button(action: action) {
          Text(actionTitle).font(.flow(size: 11, weight: .semibold))
            .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(actionTitle) rewrite")
        .accessibilityIdentifier(actionIdentifier)
      }
    }
    .padding(.leading, 14).padding(.trailing, actionTitle == nil ? 16 : 5)
    .frame(height: 38)
    .fixedSize()
    .background(Color(red: 36 / 255, green: 37 / 255, blue: 34 / 255), in: Capsule())
    .overlay { Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(message)
  }
}

/// Work that keeps going while LocalFlow is in the background: a transcript being
/// finalized, speakers being labeled. Clicking the pill opens the app where the
/// work is. `id` is stable for one piece of work, so progress updates the text in
/// place instead of re-announcing it.
struct BackgroundNotice: Equatable, Identifiable {
  enum Destination: Equatable {
    case meetings
    case transcript(meetingID: UUID)
    case summary(meetingID: UUID)
  }
  let id: UUID
  var message: String
  var symbol: String
  /// 0…1; shown as a percentage after the message.
  var progress: Double?
  var destination: Destination

  var text: String {
    guard let progress else { return message }
    return "\(message) · \(Int((min(1, max(0, progress)) * 100).rounded())) %"
  }
}

/// Dictated text that did not land in the field. It is on the clipboard already;
/// the notice says so and how to paste it.
struct ClipboardNotice: Equatable, Identifiable {
  static let visibleFor: Duration = .seconds(6)
  enum Reason: Equatable {
    /// Nothing was inserted: no field, a refused target, or a failed attempt.
    case notInserted
    /// The attempt could not be confirmed; the text may or may not be there.
    case uncertain
  }
  let id = UUID()
  let dictationID: UUID
  let reason: Reason

  var message: String {
    switch reason {
    case .notInserted: return "Couldn't insert · copied to clipboard"
    case .uncertain: return "Copied to clipboard in case it's missing"
    }
  }
}

/// "Copied to clipboard" in the indicator's capsule, with a ⌘V keycap ringed by the
/// same draining countdown as the dictionary notice.
struct ClipboardNoticeView: View {
  let notice: ClipboardNotice
  let dismiss: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var remaining: Double = 1
  @State private var appeared = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "doc.on.clipboard").font(.flow(size: 11, weight: .semibold))
        .foregroundStyle(PillStyle.ink.opacity(0.9))
        .symbolEffect(.bounce, value: appeared)
      Text(notice.message).font(.flow(size: 12, weight: .medium))
        .foregroundStyle(PillStyle.ink)
        .lineLimit(1)
      Spacer(minLength: 4)
      Button(action: dismiss) {
        HStack(spacing: 1) {
          Image(systemName: "command").font(.flow(size: 9, weight: .semibold))
          Text("V").font(.flow(size: 11, weight: .semibold))
        }
        .foregroundStyle(PillStyle.ink)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.white.opacity(0.1), in: Capsule())
        .overlay {
          Capsule().trim(from: 0, to: remaining)
            .stroke(PillStyle.ink.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .padding(1)
      }
      .buttonStyle(.plain)
      .help("Paste with Command-V")
      .accessibilityLabel("Dismiss. Paste with Command-V")
      .accessibilityIdentifier("clipboard.notice.dismiss")
    }
    .padding(.leading, 14).padding(.trailing, 5)
    .frame(height: 38)
    .fixedSize()
    .pillBackground()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(notice.message)
    .onAppear {
      appeared = true
      guard !reduceMotion else { return }
      withAnimation(.linear(duration: ClipboardNotice.visibleFor.seconds)) { remaining = 0 }
    }
  }
}

/// The background-work pill: one line and a symbol, the whole capsule is the button.
/// Hide (on hover) puts it away until that meeting's work is done.
struct BackgroundNoticeView: View {
  let notice: BackgroundNotice
  let open: () -> Void
  let hide: () -> Void
  @State private var hovering = false
  @AccessibilityFocusState private var hideFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Button(action: open) {
        HStack(spacing: 10) {
          Image(systemName: notice.symbol).font(.flow(size: 11, weight: .semibold))
            .foregroundStyle(PillStyle.ink.opacity(0.9))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating)
          Text(notice.text).font(.flow(size: 12, weight: .medium)).monospacedDigit()
            .foregroundStyle(PillStyle.ink)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: ActionNoticeView.maximumTextWidth)
            .contentTransition(.numericText())
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .fixedSize()
        .pillBackground(highlighted: hovering)
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(notice.text)
      .accessibilityHint("Opens LocalFlow")
      .accessibilityIdentifier("background.notice")
      Button(action: hide) {
        Image(systemName: "xmark").font(.flow(size: 9, weight: .bold))
          .foregroundStyle(PillStyle.ink.opacity(0.85))
          .frame(width: 22, height: 22)
          .pillBackground()
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help("Hide until this meeting is done")
      .accessibilityLabel("Hide progress")
      .accessibilityIdentifier("background.notice.hide")
      .accessibilityFocused($hideFocused)
      .scaleEffect(hovering || hideFocused ? 1 : 0.5)
      .opacity(hovering || hideFocused ? 1 : 0)
    }
    // The hide button is laid out even while invisible, so the pill never jumps.
    .padding(.leading, 28)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .animation(PillStyle.swap, value: hovering)
    .animation(PillStyle.morph, value: notice.text)
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Hide progress", hide)
  }
}
