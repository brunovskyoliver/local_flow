import AppKit
import SwiftUI

@main
struct LocalFlowApp: App {
  @NSApplicationDelegateAdaptor(LocalFlowAppDelegate.self) private var appDelegate
  @State private var services: AppServices

  init() {
    let services = AppServices()
    _services = State(initialValue: services)
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
      Task { await services.start() }
    }
  }

  var body: some Scene {
    MenuBarExtra {
      LocalFlowMenu(services: services)
    } label: {
      let glyph = MenuBarGlyph.resolve(
        needsAttention: services.needsAttention,
        meetingState: services.meetingCoordinator?.status?.state)
      Image(systemName: glyph.symbol)
        .accessibilityLabel(glyph.label)
        .onAppear { appDelegate.services = services }
    }
    Window("LocalFlow", id: "main") {
      LocalFlowWindowView(services: services)
        .frame(minWidth: 720, minHeight: 560)
        .background(MainWindowAttachment(router: services.router))
    }
    .defaultSize(width: 1100, height: 760)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .appSettings) {
        MainWindowButton(services: services, destination: .settings)
      }
      CommandGroup(replacing: .appTermination) {
        Button("Quit LocalFlow") { services.quit() }.keyboardShortcut("q")
      }
    }
  }
}

/// Keep Dock actions on the same routes as the menu bar and application menu.
@MainActor
final class LocalFlowAppDelegate: NSObject, NSApplicationDelegate {
  weak var services: AppServices?

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    !(services?.router.reopen() ?? false)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let services else { return .terminateNow }
    if services.isReadyToTerminate { return .terminateNow }
    services.quit()
    return .terminateCancel
  }
}

private struct MainWindowButton: View {
  let services: AppServices
  var destination: LocalFlowPage?
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    if destination == .settings {
      Button("Settings…", action: show).keyboardShortcut(",")
    } else {
      Button("Open LocalFlow", action: show)
    }
  }
  private func show() {
    services.router.open(destination) { openWindow(id: "main") }
  }
}

private struct LocalFlowMenu: View {
  let services: AppServices
  var body: some View {
    Text(services.readinessStatus)
    if services.needsAttention { Label("Review needed", systemImage: "exclamationmark.circle") }
    Divider()
    MainWindowButton(services: services)
    MainWindowButton(services: services, destination: .settings)
    if services.coordinator?.busy == true {
      Button("Cancel") { services.coordinator?.cancel() }
    }
    if let meetings = services.meetingCoordinator {
      Divider()
      MeetingMenuItems(
        coordinator: meetings, router: services.router, preferences: services.preferences)
    }
    Divider()
    Button("Quit LocalFlow") { services.quit() }.keyboardShortcut("q")
  }
}

/// Menu bar glyph: the recording glyph while a meeting records, the pause glyph
/// while paused, attention or the waveform otherwise.
enum MenuBarGlyph {
  static func resolve(needsAttention: Bool, meetingState: MeetingState?) -> (
    symbol: String, label: String
  ) {
    switch meetingState {
    case .recording: return ("record.circle.fill", "LocalFlow: meeting recording")
    case .paused: return ("pause.circle.fill", "LocalFlow: meeting paused")
    default:
      return needsAttention
        ? ("exclamationmark.circle", "LocalFlow needs attention") : ("waveform", "LocalFlow")
    }
  }
}

/// Start / Pause / Resume / Stop for the menu bar. Start while a meeting is
/// active shows the active meeting instead of creating a second one.
struct MeetingMenuItems: View {
  let coordinator: MeetingCoordinator
  let router: MainWindowRouter
  let preferences: AppPreferences
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    switch coordinator.status?.state {
    case .recording:
      Button("Pause Meeting") { Task { await coordinator.pause(reason: .user) } }
      Button("Stop Meeting") { Task { await coordinator.stop() } }
    case .paused:
      Button("Resume Meeting") { Task { await coordinator.resume() } }
      Button("Stop Meeting") { Task { await coordinator.stop() } }
    case .preparing, .created, .finalizing:
      Text("Meeting \(coordinator.status?.state.badgeText.lowercased() ?? "")…")
    default:
      Button("Start Meeting") {
        router.open(.meetings) { openWindow(id: "main") }
        if coordinator.canStart {
          Task { await coordinator.start(options: .init(preferences: preferences)) }
        }
      }
      .disabled(!coordinator.canStart)
    }
  }
}

// Adapted from SottoWindowView.swift, copyright (c) 2026 Davis, MIT.
// Full notice: third_party/sotto/LICENSE and the bundled Sotto-LICENSE.txt.
private struct LocalFlowWindowView: View {
  let services: AppServices

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        sidebar(compact: geometry.size.width <= 800).frame(
          width: geometry.size.width <= 800 ? 165 : 208)
        VStack(spacing: 0) {
          if let coordinator = services.coordinator {
            RecoveryNotice(coordinator: coordinator)
          }
          if !services.preferences.onboardingComplete && services.router.selection == .history {
            OnboardingView(settings: services.settings, coordinator: services.onboarding)
          } else {
            destination
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SottoPalette.surface)
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
          RoundedRectangle(cornerRadius: 18).strokeBorder(SottoPalette.line, lineWidth: 1)
        }
        .padding(.top, 38).padding(.trailing, 8).padding(.bottom, 8)
      }
      .background(SottoPalette.canvas)
      .environment(\.prototypeCompact, geometry.size.width <= 800)
    }
    .ignoresSafeArea(.container, edges: .top)
    .foregroundStyle(SottoPalette.ink)
    .tint(SottoPalette.accent)
    .onExitCommand { services.coordinator?.cancel() }
    .onDisappear { services.flushMeetingNotes() }
    .task { await services.observeSettingsWhileVisible() }
    .onChange(of: services.preferences.appearance) { _, _ in services.applyAppearance() }
    .sheet(
      isPresented: Binding(
        get: { services.reviewingInsertion },
        set: { if !$0 { services.closeInsertionReview() } })
    ) {
      if let insertion = services.explicitInsertion, let entry = insertion.entry {
        InsertionReviewView(insertion: insertion, entry: entry)
      }
    }
  }

  private func sidebar(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7) {
        Image(systemName: "waveform").font(.system(size: 19))
        Text("LocalFlow").font(.system(size: compact ? 18 : 20, weight: .semibold)).tracking(-0.7)
      }
      .padding(.horizontal, 10).padding(.top, 77).padding(.bottom, 33)
      VStack(spacing: 6) {
        ForEach(LocalFlowPage.allCases) { destination in
          Button {
            services.router.selection = destination
          } label: {
            HStack(spacing: 10) {
              Image(systemName: destination.symbol).font(.system(size: 18)).frame(width: 19)
              Text(destination.rawValue)
                .lineLimit(1).minimumScaleFactor(0.85)
                .font(
                  .system(
                    size: 14, weight: services.router.selection == destination ? .medium : .regular)
                )
              Spacer(minLength: 0)
            }
            .padding(10)
            .background(
              services.router.selection == destination ? SottoPalette.tint : .clear,
              in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("navigation.\(destination.rawValue.lowercased())")
          .accessibilityAddTraits(services.router.selection == destination ? .isSelected : [])
        }
      }
      Spacer()
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Circle().fill(SottoPalette.muted).frame(width: 6, height: 6)
          Text("On this Mac")
        }
        if services.needsAttention {
          Label("Review needed", systemImage: "exclamationmark.circle")
        }
      }
      .font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
      .padding(.horizontal, 10).padding(.bottom, 23)
    }
    .padding(.horizontal, 12)
  }

  @ViewBuilder private var destination: some View {
    switch services.router.selection {
    case .meetings:
      if let meetings = services.meetingCoordinator, let library = services.meetingLibrary,
        let root = services.meetingStorageRoot
      {
        MeetingLibraryView(
          coordinator: meetings, model: library, storageRoot: root,
          preferences: services.preferences, transcriptStore: services.transcriptStore,
          notesEditorFactory: { services.makeNotesEditor(for: $0) })
      } else {
        ContentUnavailableView(
          "Meetings unavailable", systemImage: "externaldrive.badge.exclamationmark",
          description: Text(services.setupStatus))
      }
    case .history:
      if let history = services.historyModel, let coordinator = services.coordinator {
        HistoryView(
          model: history,
          copy: { coordinator.copy($0) },
          insert: { services.reviewInsertion($0, attempt: $1) },
          dismissRecovery: { try await coordinator.dismissOrThrow($0) },
          delete: { try await coordinator.deleteOrThrow($0) }, globalBusy: coordinator.busy)
      } else {
        ContentUnavailableView(
          "Transcriptions unavailable", systemImage: "externaldrive.badge.exclamationmark",
          description: Text(services.setupStatus))
      }
    case .dictionary:
      if let vocabulary = services.vocabularyModel {
        DictionaryView(model: vocabulary)
      } else {
        ContentUnavailableView(
          "Dictionary unavailable", systemImage: "externaldrive.badge.exclamationmark",
          description: Text(services.setupStatus))
      }
    case .settings:
      SettingsView(model: services.settings, preferences: services.preferences)
    }
  }
}

private struct InsertionReviewView: View {
  let insertion: ExplicitInsertionCoordinator
  let entry: TranscriptionEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Review before inserting").font(.system(size: 26, weight: .semibold))
      ForEach(insertion.warnings, id: \.self) { warning in
        Label(warning, systemImage: "exclamationmark.triangle")
      }
      ScrollView {
        // The reviewed text is the saved transcript or a chosen rewrite.
        Text(insertion.reviewText).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 300)
      Text(
        "Choose a destination, then switch to the app and click an editable field. LocalFlow will ask you to confirm before inserting."
      )
      .foregroundStyle(.secondary)
      HStack {
        Button("Cancel", role: .cancel) { insertion.cancel() }
        Spacer()
        Button("Choose destination") { insertion.armSelection() }.buttonStyle(.borderedProminent)
      }
    }
    .padding(26).frame(width: 520)
  }
}

private struct RecoveryNotice: View {
  let coordinator: DictationCoordinator
  @State private var discardWarning = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if coordinator.storageBlocked {
        HStack {
          Label(
            "Storage needs attention. Your saved text is retained.",
            systemImage: "externaldrive.badge.exclamationmark")
          Spacer()
          Button("Retry storage") { Task { await coordinator.retryStorage() } }
            .disabled(coordinator.busy)
        }
      }
      if coordinator.capacityBlocked {
        Label(
          "History is full. Open Transcriptions and delete saved text before recording again.",
          systemImage: "externaldrive.badge.exclamationmark")
      }
      if let unsaved = coordinator.unsaved {
        Label("Unsaved text", systemImage: "exclamationmark.triangle").font(.headline)
        Text("This text will be lost if you quit. Copy does not save it.")
        ScrollView {
          Text(unsaved.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150)
        HStack {
          Button("Retry save") { Task { await coordinator.retrySave() } }
          Button("Copy") { coordinator.copy(unsaved.text) }
          Button("Discard…", role: .destructive) { discardWarning = true }
        }.disabled(coordinator.busy)
      }
    }
    .padding(
      coordinator.unsaved != nil || coordinator.storageBlocked || coordinator.capacityBlocked
        ? 20 : 0
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SottoPalette.surface)
    .alert("Discard unsaved text?", isPresented: $discardWarning) {
      Button("Keep text", role: .cancel) {}
      Button("Discard", role: .destructive) { Task { await coordinator.discardUnsaved() } }
    } message: {
      Text("This text has not been saved. Discarding it cannot be undone.")
    }
  }
}
