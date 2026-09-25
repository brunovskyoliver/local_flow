import SwiftUI

/// Shared, deliberately quiet controls for the reference Notetaker layout.
enum NotetakerStyle {
  static let readingWidth: CGFloat = 600
  static let libraryWidth: CGFloat = 760
  static let rule = SottoPalette.line
}

extension View {
  /// Keeps scrolling but drops the scroller from an AppKit-backed control such as `TextEditor`,
  /// which ignores `scrollIndicators(.never)` when the system shows scroll bars permanently.
  func hideScrollers() -> some View {
    background(ScrollerRemover())
  }
}

private struct ScrollerRemover: NSViewRepresentable {
  func makeNSView(context: Context) -> ScrollerRemoverView { ScrollerRemoverView() }
  func updateNSView(_ nsView: ScrollerRemoverView, context: Context) { nsView.stripIfNeeded() }

  /// Strips once per window and enclosing scroll view instead of walking the sibling
  /// tree on every layout and update.
  final class ScrollerRemoverView: NSView {
    private weak var strippedWindow: NSWindow?
    private weak var strippedEnclosing: NSScrollView?
    private var stripped: [WeakScroll] = []

    private struct WeakScroll {
      weak var scroll: NSScrollView?
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      strippedWindow = nil
      stripIfNeeded()
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      strippedWindow = nil
      stripIfNeeded()
    }

    override func layout() {
      super.layout()
      stripIfNeeded()
    }

    func stripIfNeeded() {
      guard let window, superview != nil else { return }
      let enclosing = enclosingScrollView
      // Nothing found yet (the scroll view may not be installed), one went away, or
      // AppKit put a scroller back: walk again.
      let stale =
        stripped.isEmpty
        || stripped.contains { entry in
          guard let scroll = entry.scroll else { return true }
          return scroll.hasVerticalScroller || scroll.hasHorizontalScroller
        }
      guard strippedWindow !== window || strippedEnclosing !== enclosing || stale else { return }
      strippedWindow = window
      strippedEnclosing = enclosing
      strip()
    }

    /// The scroll view is a sibling in the same SwiftUI container, or encloses this view
    /// when SwiftUI hosts the background inside it.
    private func strip() {
      guard let container = superview else { return }
      let scrolls = Self.scrollViews(in: container) + [enclosingScrollView].compactMap({ $0 })
      for scroll in scrolls {
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
      }
      stripped = scrolls.map { WeakScroll(scroll: $0) }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
      view.subviews.flatMap { child -> [NSScrollView] in
        if let scroll = child as? NSScrollView { return [scroll] }
        return scrollViews(in: child)
      }
    }
  }
}

/// The green waveform and live timer Wispr shows next to a note that is being recorded.
/// Only this view reads the per-second elapsed value.
struct LiveRecordingBadge: View {
  let state: MeetingState
  let elapsed: MeetingElapsed
  var size: CGFloat = 13

  var body: some View {
    let duration = meetingDurationText(elapsed.milliseconds)
    HStack(spacing: 8) {
      Image(systemName: state == .paused ? "pause.fill" : "waveform")
        .font(.flow(size: size - 1))
        .symbolEffect(.variableColor.iterative, isActive: state == .recording)
      Text(duration)
        .font(.flow(size: size)).monospacedDigit()
    }
    .foregroundStyle(state == .paused ? SottoPalette.muted : Color.green)
    .accessibilityLabel(state.badgeText)
    .accessibilityValue(duration)
    .accessibilityIdentifier("meeting.elapsed")
  }
}

struct NoteIconButton: View {
  let symbol: String
  let label: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.flow(size: 13))
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
      Text(title).font(.flow(size: 15, weight: selected ? .medium : .regular))
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
  /// Transcribe / Retry / Re-transcribe, depending on the transcript's state.
  struct TranscriptionAction {
    let title: String
    let identifier: String
    let run: () -> Void
  }

  var canDelete: Bool
  var transcription: TranscriptionAction? = nil
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
          if let transcription {
            menuItem(transcription.title, symbol: "arrow.clockwise") {
              presented = false
              transcription.run()
            }
            .accessibilityIdentifier(transcription.identifier)
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
        .font(.flow(size: 14))
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
        Text(prompt).font(.flow(size: 15)).foregroundStyle(SottoPalette.muted)
        Spacer()
      }
      .padding(.horizontal, 18).frame(height: 48)
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
          Text(row.displayTitle).font(.flow(size: 18, weight: .medium)).fixedSize(
            horizontal: false, vertical: true)
          Text(
            "\(MeetingRowView.dateText(row.createdAt)) · \(meetingDurationText(row.recordedMs))"
          )
          .font(.flow(size: 14)).monospacedDigit().foregroundStyle(SottoPalette.muted)
        }.padding(20)
        NotetakerStyle.rule.frame(height: 1)
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if let detail, !detail.notes.text.isEmpty {
              Text("MY THOUGHTS").font(.flow(size: 12, weight: .medium)).tracking(1.2)
                .foregroundStyle(SottoPalette.muted)
              Text(
                String(
                  detail.notes.text.prefix(MeetingLibraryViewModel.previewNoteCharacters))
              ).lineSpacing(6)
            }
            if let notice { Text(notice).foregroundStyle(.red) }
          }.font(.flow(size: 14)).frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .scrollIndicators(.never)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(SottoPalette.surface)
    .accessibilityIdentifier("notetaker.preview")
  }
}
