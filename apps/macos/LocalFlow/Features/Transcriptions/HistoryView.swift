// Presentation adapted from Sotto HistoryPage.swift; see Resources/Sotto-LICENSE.txt.
// Local history, search and recovery follow LocalFlow's Feature 001 contract.
import SwiftUI

struct HistoryView: View {
  @Environment(\.prototypeCompact) private var compact
  @Bindable var model: HistoryViewModel
  let copy: (String) -> Void
  /// A nil attempt inserts the saved transcript; an attempt inserts its output.
  let insert: (TranscriptionEntry, RewriteAttempt?) -> Void
  let delete: (TranscriptionEntry) async throws -> Void
  var globalBusy = false
  @State private var confirmingDelete = false
  @State private var actionBusy = false
  @State private var searching = false
  @FocusState private var searchFocused: Bool
  /// The row pinned at the top of the viewport, so the list stays put while pages
  /// join and leave above it.
  @State private var anchor: UUID?

  var body: some View {
    // PrototypePage's layout, with the scroll position this list needs.
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Transcriptions").font(.flow(size: 26, weight: .medium)).tracking(-0.4)
          Spacer(minLength: 12)
          if searching || !model.searchText.isEmpty {
            HStack(spacing: 6) {
              Image(systemName: "magnifyingglass").font(.flow(size: 14))
              TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain).font(.flow(size: 14)).frame(width: compact ? 90 : 160)
                .focused($searchFocused)
                .onAppear { searchFocused = searching }
                .onExitCommand {
                  model.searchText = ""
                  searching = false
                }
                .accessibilityLabel("Search transcriptions")
                .accessibilityIdentifier("history.search")
            }
            .foregroundStyle(SottoPalette.muted)
            .padding(.horizontal, 10).frame(height: 32)
            .background(SottoPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: searchFocused) { _, focused in
              if !focused && model.searchText.isEmpty { searching = false }
            }
          } else {
            Button {
              searching = true
            } label: {
              Image(systemName: "magnifyingglass").font(.flow(size: 15))
                .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(SottoPalette.muted)
            .keyboardShortcut("f")
            .help("Search").accessibilityLabel("Search transcriptions")
          }
        }
        .padding(.bottom, 12)
        if let error = model.errorMessage {
          HStack {
            Text(error).foregroundStyle(SottoPalette.warning)
            Button("Retry") { model.refresh() }.buttonStyle(PrototypeButtonStyle())
          }.padding(.top, 20)
        }
        if model.entries.isEmpty && !model.isLoading {
          Text(model.isNoMatches ? "No matches" : "No transcriptions yet")
            .foregroundStyle(SottoPalette.muted).frame(maxWidth: .infinity).padding(.vertical, 80)
        } else {
          LazyVStack(alignment: .leading, spacing: 0) {
            if model.hasNewer {
              pageSentinel(loading: model.isLoading) { model.loadNewer() }
                .id(model.entries.first?.id)
            }
            // One flat lazy list: only rows near the viewport are built, however long
            // the day. Each row draws its own slice of the day's card.
            ForEach(model.dateGroups) { group in
              Text(group.title.uppercased())
                .font(.flow(size: 12, weight: .medium)).tracking(1.2)
                .foregroundStyle(SottoPalette.muted)
                .padding(.top, 28).padding(.bottom, 12)
              ForEach(group.entries) { entry in
                let first = entry.id == group.entries.first?.id
                let last = entry.id == group.entries.last?.id
                HistoryRow(
                  entry: entry, busy: actionBusy || globalBusy,
                  copy: { copy(entry.text) }, insert: { insert(entry, nil) },
                  detail: { model.showDetail(entry) },
                  delete: {
                    model.selectedEntry = entry
                    confirmingDelete = true
                  }
                )
                .overlay(alignment: .bottom) {
                  if !last { SottoPalette.line.frame(height: 1).padding(.horizontal, 1) }
                }
                .clipShape(CardSegment(top: first, bottom: last))
                .overlay { CardSegmentEdge(top: first, bottom: last).stroke(SottoPalette.line) }
                .transition(.opacity)
              }
            }
            if model.hasOlder {
              pageSentinel(loading: model.isLoading) { model.loadOlder() }
                .id(model.entries.last?.id)
            }
          }
          .scrollTargetLayout()
          .animation(.easeOut(duration: 0.2), value: model.entries.first?.id)
          .accessibilityIdentifier("history.list")
        }
      }
      .font(.flow(size: 14))
      .foregroundStyle(SottoPalette.ink)
      .padding(.horizontal, compact ? 24 : 48)
      .padding(.top, compact ? 32 : 48)
      .padding(.bottom, 64)
      .frame(maxWidth: 960)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .scrollIndicators(.never)
    .scrollPosition(id: $anchor, anchor: .top)
    .task { model.refresh() }
    .onDisappear { model.clearDetail() }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      model.regroup()
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
      model.regroup()
    }
    .sheet(
      isPresented: Binding(
        get: { model.detailEntryID != nil }, set: { if !$0 { model.clearDetail() } })
    ) {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text("Details").font(.flow(size: 20, weight: .medium))
          Spacer()
          Button("Done") { model.clearDetail() }.buttonStyle(PrototypeButtonStyle())
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("history.detail.close")
        }
        ScrollView {
          Group {
            if model.isDetailLoading {
              ProgressView().frame(maxWidth: .infinity).padding(40)
            } else if let error = model.detailError {
              Text(error).foregroundStyle(SottoPalette.warning)
              Button("Retry") { model.retryDetail() }.buttonStyle(PrototypeButtonStyle())
            } else if let envelope = model.detailEnvelope {
              TranscriptionDetailView(
                envelope: envelope, model: model, copy: copy,
                insert: { insert(envelope.entry, $0) }
              ).id(envelope.entry.id)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
      }
      .padding(24).frame(width: 600, height: 560)
      .font(.flow(size: 14)).foregroundStyle(SottoPalette.ink)
      .background(SottoPalette.surface)
    }
    .confirmationDialog("Delete this transcription?", isPresented: deletionPresented) {
      if let entry = model.selectedEntry {
        Button("Delete", role: .destructive) {
          perform {
            try await delete(entry)
            model.didDelete(entry.id)
          }
        }
      }
      Button("Cancel", role: .cancel) { model.selectedEntry = nil }
    } message: {
      Text("This can't be undone.")
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
  let detail: () -> Void
  let delete: () -> Void
  @State private var hovering = false
  @State private var copied = false

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(
          Date(timeIntervalSince1970: Double(entry.createdAtMilliseconds) / 1000),
          format: .dateTime.hour().minute()
        )
        .font(.flow(size: 13)).monospacedDigit().foregroundStyle(SottoPalette.muted)
        // Only a cut-short or incomplete transcript gets a word; everything else is quiet.
        if let problem = entry.qualityLabel {
          Text(problem).font(.flow(size: 11, weight: .medium))
            .foregroundStyle(SottoPalette.warning)
        }
      }
      .padding(.top, 2)
      .frame(width: compact ? 72 : 104, alignment: .leading)
      Text(entry.text).textSelection(.enabled)
        .font(.flow(size: 15)).lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      actions.padding(.leading, 16).padding(.top, -4).opacity(hovering ? 1 : 0)
    }
    .padding(.vertical, 16).padding(.leading, 18).padding(.trailing, 12)
    .background(hovering ? SottoPalette.canvas : .clear)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .contextMenu { menuItems }
    .accessibilityElement(children: .contain)
  }

  private var actions: some View {
    HStack(spacing: 2) {
      rowButton(copied ? "checkmark" : "doc.on.doc", label: "Copy") {
        copy()
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.2))
          copied = false
        }
      }
      rowButton("text.insert", label: entry.deliveryState == .confirmed ? "Insert again" : "Insert")
      {
        insert()
      }
      .disabled(busy || entry.deliveryState == .attempting)
      Menu {
        menuItems
      } label: {
        Image(systemName: "ellipsis").font(.flow(size: 14))
          .frame(width: 28, height: 28).contentShape(Rectangle())
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .accessibilityLabel("More")
    }
    .foregroundStyle(SottoPalette.muted)
  }

  @ViewBuilder private var menuItems: some View {
    Button("Copy", systemImage: "doc.on.doc", action: copy)
    Button(
      entry.deliveryState == .confirmed ? "Insert again…" : "Insert…", systemImage: "text.insert",
      action: insert
    )
    .disabled(busy || entry.deliveryState == .attempting)
    Button("Details", systemImage: "info.circle", action: detail)
      .accessibilityIdentifier("history.row.details")
    Divider()
    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
      .disabled(busy || entry.deliveryState == .attempting)
  }

  private func rowButton(_ symbol: String, label: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).font(.flow(size: 14))
        .frame(width: 28, height: 28).contentShape(Rectangle())
    }
    .buttonStyle(.plain).help(label).accessibilityLabel(label)
  }
}

extension HistoryView {
  /// Sits at an open end of the loaded window; coming into view loads the next page.
  /// Its identity follows the end row, so it fires again if it is still visible
  /// after a page lands.
  fileprivate func pageSentinel(loading: Bool, load: @escaping () -> Void) -> some View {
    ProgressView().controlSize(.small)
      .opacity(loading ? 1 : 0)
      .frame(maxWidth: .infinity).frame(height: 44)
      .onAppear(perform: load)
  }
}

/// One row's slice of a day's rounded card: rounded only where the card begins or ends.
private struct CardSegment: Shape {
  let top: Bool
  let bottom: Bool
  var radius: CGFloat = 12

  func path(in rect: CGRect) -> Path {
    UnevenRoundedRectangle(
      topLeadingRadius: top ? radius : 0, bottomLeadingRadius: bottom ? radius : 0,
      bottomTrailingRadius: bottom ? radius : 0, topTrailingRadius: top ? radius : 0
    ).path(in: rect)
  }
}

/// The card's 1 pt border for one row: both sides always, the top and bottom edges
/// only on the day's first and last rows, so stacked rows draw one continuous card.
private struct CardSegmentEdge: Shape {
  let top: Bool
  let bottom: Bool
  var radius: CGFloat = 12

  func path(in rect: CGRect) -> Path {
    let minX = rect.minX + 0.5
    let maxX = rect.maxX - 0.5
    let minY = rect.minY + (top ? 0.5 : 0)
    let maxY = rect.maxY - (bottom ? 0.5 : 0)
    let r = radius - 0.5
    var path = Path()
    if bottom {
      path.move(to: CGPoint(x: minX + r, y: maxY))
      path.addArc(
        tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - r),
        radius: r)
    } else {
      path.move(to: CGPoint(x: minX, y: maxY))
    }
    if top {
      path.addArc(
        tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + r, y: minY),
        radius: r)
      path.addArc(
        tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + r),
        radius: r)
    } else {
      path.addLine(to: CGPoint(x: minX, y: minY))
      path.move(to: CGPoint(x: maxX, y: minY))
    }
    if bottom {
      path.addArc(
        tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - r, y: maxY),
        radius: r)
      // A line, not closeSubpath: a middle `move` makes the subpath start the top right.
      path.addLine(to: CGPoint(x: minX + r, y: maxY))
    } else {
      path.addLine(to: CGPoint(x: maxX, y: maxY))
    }
    return path
  }
}
