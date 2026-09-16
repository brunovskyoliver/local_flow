// Presentation adapted from Sotto HistoryPage.swift; see Resources/Sotto-LICENSE.txt.
// Local history, search and recovery follow LocalFlow's Feature 001 contract.
import SwiftUI

struct HistoryView: View {
  @Environment(\.prototypeCompact) private var compact
  @Bindable var model: HistoryViewModel
  let copy: (TranscriptionEntry) -> Void
  let insert: (TranscriptionEntry) -> Void
  let dismissRecovery: (TranscriptionEntry) async throws -> Void
  let delete: (TranscriptionEntry) async throws -> Void
  var globalBusy = false
  @State private var confirmingDelete = false
  @State private var actionBusy = false

  var body: some View {
    PrototypePage {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Transcriptions").font(.system(size: 27, weight: .semibold)).tracking(-0.8)
          Spacer(minLength: 12)
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 17))
            TextField("Search", text: $model.searchText)
              .textFieldStyle(.plain).frame(width: compact ? 90 : 150).padding(.vertical, 7)
              .accessibilityLabel("Search transcriptions")
              .accessibilityIdentifier("history.search")
          }.foregroundStyle(SottoPalette.muted)
        }
        Text("Your words, saved on this Mac.")
          .font(.system(size: 13)).foregroundStyle(SottoPalette.muted)
          .padding(.top, 11).padding(.bottom, 9)
        if let error = model.errorMessage {
          HStack {
            Text(error).foregroundStyle(SottoPalette.warning)
            Button("Retry") { model.refresh() }
          }.padding(.top, 20)
        }
        if model.entries.isEmpty && !model.isLoading {
          VStack(spacing: 8) {
            Text(model.isNoMatches ? "No matching transcriptions." : "No transcriptions yet.")
            if !model.isNoMatches { Text("Hold your dictation shortcut to get started.") }
          }
          .foregroundStyle(SottoPalette.muted).frame(maxWidth: .infinity).padding(.vertical, 60)
        } else {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.dateGroups) { group in
              Text(group.title).font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
                .padding(.top, 30).padding(.bottom, 13)
              VStack(spacing: 0) {
                ForEach(group.entries) { entry in
                  HistoryRow(
                    entry: entry, busy: actionBusy || globalBusy,
                    copy: { copy(entry) }, insert: { insert(entry) },
                    dismissRecovery: { perform { try await dismissRecovery(entry) } },
                    delete: {
                      model.selectedEntry = entry
                      confirmingDelete = true
                    })
                  if entry.id != group.entries.last?.id {
                    SottoPalette.line.frame(height: 1)
                  }
                }
              }
              .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(SottoPalette.line, lineWidth: 1)
              }
            }
          }.accessibilityIdentifier("history.list")
        }
        if model.hasNewer || model.hasOlder || model.isLoading {
          HStack {
            if model.hasNewer { Button("Newest") { model.refresh() } }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button("Newer") { model.newer() }.disabled(!model.hasNewer || model.isLoading)
            Button("Older") { model.older() }.disabled(!model.hasOlder || model.isLoading)
          }.buttonStyle(PrototypeButtonStyle()).padding(.top, 24)
        }
      }
    }
    .task { model.refresh() }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      model.regroup()
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
      model.regroup()
    }
    .confirmationDialog("Delete this dictation?", isPresented: deletionPresented) {
      if let entry = model.selectedEntry {
        Button("Delete dictation", role: .destructive) {
          perform { try await delete(entry) }
        }
      }
      Button("Cancel", role: .cancel) { model.selectedEntry = nil }
    } message: {
      Text("This permanently deletes this saved text from this Mac. Other dictations are kept.")
    }
  }

  private var deletionPresented: Binding<Bool> {
    Binding(
      get: { confirmingDelete },
      set: { presented in
        confirmingDelete = presented
        guard !presented else { return }
        // SwiftUI may dismiss before invoking the button action. Let that action
        // take ownership first; an outside dismissal still releases the selection.
        Task { @MainActor in
          await Task.yield()
          if !confirmingDelete, !actionBusy { model.selectedEntry = nil }
        }
      })
  }

  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    guard !actionBusy, !globalBusy else { return }
    actionBusy = true
    Task {
      defer {
        actionBusy = false
        model.selectedEntry = nil
      }
      do {
        try await action()
        model.selectedEntry = nil
        model.refresh()
      } catch { model.reportActionError() }
    }
  }
}

private struct HistoryRow: View {
  @Environment(\.prototypeCompact) private var compact
  let entry: TranscriptionEntry
  let busy: Bool
  let copy: () -> Void
  let insert: () -> Void
  let dismissRecovery: () -> Void
  let delete: () -> Void

  @State private var hovering = false
  private enum Action: Hashable { case copy, insert, dismiss, delete }
  @FocusState private var keyboardFocused: Action?
  @AccessibilityFocusState private var accessibilityFocused: Action?

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text(
        Date(timeIntervalSince1970: Double(entry.createdAtMilliseconds) / 1000),
        format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
      )
      .font(.system(size: 12)).monospacedDigit().foregroundStyle(SottoPalette.muted)
      .frame(width: compact ? 55 : 76, alignment: .leading).padding(.top, 4)
      VStack(alignment: .leading, spacing: 0) {
        if entry.qualityLabel != nil || entry.recoveryLabel != nil {
          HStack(spacing: 5) {
            if let quality = entry.qualityLabel { badge(quality) }
            if let recovery = entry.recoveryLabel { badge(recovery) }
          }.padding(.bottom, 8)
        }
        Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true).lineSpacing(6)
        HStack(spacing: 5) {
          Button("Copy", action: copy)
            .focused($keyboardFocused, equals: .copy)
            .accessibilityFocused($accessibilityFocused, equals: .copy)
          Button(entry.deliveryState == .confirmed ? "Insert again…" : "Insert…", action: insert)
            .focused($keyboardFocused, equals: .insert)
            .accessibilityFocused($accessibilityFocused, equals: .insert)
            .disabled(busy || entry.deliveryState == .attempting)
          if entry.recoveryState == .needsReview {
            Button("Dismiss recovery", action: dismissRecovery)
              .focused($keyboardFocused, equals: .dismiss)
              .accessibilityFocused($accessibilityFocused, equals: .dismiss)
              .disabled(busy || entry.deliveryState == .attempting)
          }
          Spacer(minLength: 0)
          Button("Delete…", role: .destructive, action: delete)
            .focused($keyboardFocused, equals: .delete)
            .accessibilityFocused($accessibilityFocused, equals: .delete)
            .disabled(busy || entry.deliveryState == .attempting)
        }
        .buttonStyle(HistoryActionStyle())
        .opacity(
          hovering || keyboardFocused != nil || accessibilityFocused != nil
            || entry.recoveryState == .needsReview
            ? 1 : 0
        )
        .padding(.top, 9)
      }
    }
    .padding(.vertical, compact ? 16 : 21).padding(.horizontal, compact ? 12 : 20)
    .contentShape(Rectangle()).onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
  }

  private func badge(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(SottoPalette.muted)
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(SottoPalette.button, in: RoundedRectangle(cornerRadius: 4))
  }
}

private struct HistoryActionStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
      .padding(.horizontal, 7).padding(.vertical, 4)
      .background(
        configuration.isPressed ? SottoPalette.button : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .opacity(isEnabled ? 1 : 0.45)
  }
}
