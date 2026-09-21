import SwiftUI

struct DictationIndicator: View {
  let state: DictationSession.State
  let level: Float
  let cancel: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  @AccessibilityFocusState private var accessibilityFocused: Bool

  var body: some View {
    Group {
      if state == .rewriting {
        Text("Rewriting…").font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255))
          .lineLimit(1)
      } else {
        HStack(spacing: 3) {
          ForEach(0..<15, id: \.self) { bar in
            Capsule().fill(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255)).frame(
              width: 3,
              height: Self.barHeight(bar, state: state, level: level, reduceMotion: reduceMotion))
          }
        }
      }
    }
    .frame(width: 118, height: 38)
    .background(Color(red: 36 / 255, green: 37 / 255, blue: 34 / 255), in: Capsule())
    .overlay { Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1) }
    .overlay(alignment: .trailing) {
      Button(action: cancel) {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.plain).frame(width: 24, height: 24)
      .background(SottoPalette.canvas, in: Circle())
      .offset(x: 35)
      .accessibilityLabel(state == .rewriting ? "Cancel rewrite" : "Cancel dictation")
      .accessibilityFocused($accessibilityFocused)
      .opacity(hovering || accessibilityFocused ? 1 : 0)
    }
    .frame(width: 153, height: 38, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
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

/// "Added to dictionary" in the indicator's capsule, with Undo ringed by a draining countdown.
struct LearnedNoticeView: View {
  let notice: LearnedNotice
  let undo: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var remaining: Double = 1

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255).opacity(0.9))
      Text("Added to dictionary").font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255))
        .lineLimit(1)
      Spacer(minLength: 4)
      Button(action: undo) {
        Text("Undo").font(.system(size: 11, weight: .semibold))
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
      Image(systemName: "text.badge.xmark").font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255).opacity(0.9))
      Text(message).font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255))
        .lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: Self.maximumTextWidth)
      if let actionTitle {
        Button(action: action) {
          Text(actionTitle).font(.system(size: 11, weight: .semibold))
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

/// The background-work pill: one line and a symbol, the whole capsule is the button.
struct BackgroundNoticeView: View {
  let notice: BackgroundNotice
  let open: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        Image(systemName: notice.symbol).font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255).opacity(0.9))
        Text(notice.text).font(.system(size: 12, weight: .medium)).monospacedDigit()
          .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255))
          .lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: ActionNoticeView.maximumTextWidth)
          .contentTransition(.numericText())
      }
      .padding(.horizontal, 16)
      .frame(height: 38)
      .fixedSize()
      .background(
        Color(red: 36 / 255, green: 37 / 255, blue: 34 / 255).opacity(hovering ? 0.92 : 1),
        in: Capsule()
      )
      .overlay { Capsule().strokeBorder(.white.opacity(hovering ? 0.22 : 0.13), lineWidth: 1) }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.15), value: hovering)
    .accessibilityLabel(notice.text)
    .accessibilityHint("Opens LocalFlow")
    .accessibilityIdentifier("background.notice")
  }
}
