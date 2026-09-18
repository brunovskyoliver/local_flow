import SwiftUI

/// Shared, deliberately quiet controls for the reference Notetaker layout.
enum NotetakerStyle {
  static let readingWidth: CGFloat = 600
  static let libraryWidth: CGFloat = 760
  static let rule = SottoPalette.line
}

extension View {
  /// Keeps scrolling but drops the scroller from an AppKit-backed control such as `TextEditor`,
  /// which ignores `scrollIndicators(.hidden)` when the system shows scroll bars permanently.
  func hideScrollers() -> some View {
    background(ScrollerRemover())
  }
}

private struct ScrollerRemover: NSViewRepresentable {
  func makeNSView(context: Context) -> ScrollerRemoverView { ScrollerRemoverView() }
  func updateNSView(_ nsView: ScrollerRemoverView, context: Context) { nsView.strip() }

  final class ScrollerRemoverView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      strip()
    }

    override func layout() {
      super.layout()
      strip()
    }

    /// The `TextEditor`'s scroll view is a sibling in the same SwiftUI container.
    func strip() {
      guard let container = superview else { return }
      for scroll in Self.scrollViews(in: container) {
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
      }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
      view.subviews.flatMap { child -> [NSScrollView] in
        if let scroll = child as? NSScrollView { return [scroll] }
        return scrollViews(in: child)
      }
    }
  }
}

extension MeetingStatus {
  /// Recorded time as whole milliseconds, for the duration formatter.
  var recordedElapsedMs: Int64 {
    let components = recordedElapsed.components
    return Int64(components.seconds) * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
  }
}

/// The green waveform and live timer Wispr shows next to a note that is being recorded.
struct LiveRecordingBadge: View {
  let status: MeetingStatus
  var size: CGFloat = 13

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: status.state == .paused ? "pause.fill" : "waveform")
        .font(.system(size: size - 1))
        .symbolEffect(.variableColor.iterative, isActive: status.state == .recording)
      Text(meetingDurationText(status.recordedElapsedMs))
        .font(.system(size: size)).monospacedDigit()
    }
    .foregroundStyle(status.state == .paused ? SottoPalette.muted : Color.green)
    .accessibilityLabel(status.state.badgeText)
    .accessibilityValue(meetingDurationText(status.recordedElapsedMs))
    .accessibilityIdentifier("meeting.elapsed")
  }
}

struct NoteIconButton: View {
  let symbol: String
  let label: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 13))
        .frame(width: 28, height: 28).contentShape(.rect)
    }
    .buttonStyle(.plain).help(label).accessibilityLabel(label)
  }
}

struct NoteTab: View {
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? SottoPalette.ink : SottoPalette.muted)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
          Rectangle().fill(selected ? SottoPalette.ink : .clear).frame(height: 2)
        }
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct NoteOverflowMenu: View {
  var canDelete: Bool
  var delete: () -> Void
  @State private var presented = false
  @State private var unavailable: String?

  var body: some View {
    NoteIconButton(symbol: "ellipsis", label: "Note options") { presented.toggle() }
      .popover(isPresented: $presented, arrowEdge: .bottom) {
        VStack(alignment: .leading, spacing: 2) {
          menuItem("Copy link", symbol: "link") {
            explain("Links will be available when note sharing is added.")
          }
          menuItem("Share", symbol: "square.and.arrow.up") {
            explain("Note sharing is not available yet. Your recordings stay on this Mac.")
          }
          menuItem("Report", symbol: "flag") {
            explain("Reporting is not available for local notes. Nothing has been sent.")
          }
          menuItem("Delete", symbol: "trash", destructive: true) {
            presented = false
            delete()
          }.disabled(!canDelete)
        }
        .padding(8).frame(width: 190)
        .background(SottoPalette.surface)
      }
      .alert(
        "Not available yet",
        isPresented: Binding(get: { unavailable != nil }, set: { if !$0 { unavailable = nil } })
      ) {
        Button("OK") { unavailable = nil }
      } message: {
        Text(unavailable ?? "")
      }
  }

  private func explain(_ message: String) {
    presented = false
    unavailable = message
  }

  private func menuItem(
    _ title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .foregroundStyle(destructive ? Color.red : SottoPalette.ink)
        .contentShape(.rect)
    }.buttonStyle(.plain)
  }
}

struct NoteUnavailableBar: View {
  var prompt = "Ask anything"
  @State private var explaining = false

  var body: some View {
    Button {
      explaining = true
    } label: {
      HStack {
        Text(prompt).font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
        Spacer()
      }
      .padding(.horizontal, 16).frame(height: 40)
      .background(SottoPalette.surface, in: Capsule())
      .overlay { Capsule().strokeBorder(NotetakerStyle.rule, lineWidth: 1) }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .alert("Meeting chat is not available yet", isPresented: $explaining) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(
        "You can read your transcript and edit My thoughts. Asking questions about recordings will be added with meeting summaries."
      )
    }
  }
}

struct NotePreview: View {
  let row: MeetingSummary?
  let detail: MeetingDetail?
  var notice: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let row {
        VStack(alignment: .leading, spacing: 8) {
          Text(row.displayTitle).font(.system(size: 15, weight: .bold)).fixedSize(
            horizontal: false, vertical: true)
          Text(MeetingRowView.dateText(row.createdAt)).font(.system(size: 12)).foregroundStyle(
            SottoPalette.muted)
          Text(meetingDurationText(row.recordedMs)).font(.system(size: 12)).monospacedDigit()
            .foregroundStyle(SottoPalette.muted)
        }.padding(20)
        NotetakerStyle.rule.frame(height: 1)
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("OVERVIEW").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(
              SottoPalette.muted)
            Text("No summary yet.").foregroundStyle(SottoPalette.muted)
            if let detail, !detail.notes.text.isEmpty {
              Text("MY THOUGHTS").font(.system(size: 10, weight: .semibold)).tracking(1)
                .foregroundStyle(SottoPalette.muted)
              Text(String(detail.notes.text.prefix(1_200))).lineSpacing(6)
            }
            if let notice { Text(notice).foregroundStyle(.red) }
          }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .scrollIndicators(.hidden)
      } else {
        Text("Hover over a note to see its overview.")
          .font(.system(size: 12)).foregroundStyle(SottoPalette.muted).padding(20)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(SottoPalette.canvas.opacity(0.5))
    .accessibilityIdentifier("notetaker.preview")
  }
}
