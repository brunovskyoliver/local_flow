import AppKit
import SwiftUI

@main
struct LocalFlowApp: App {
  @NSApplicationDelegateAdaptor(LocalFlowAppDelegate.self) private var appDelegate
  @State private var services: AppServices

  init() {
    FlowFonts.register()
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
      MenuBarLabel(services: services) { appDelegate.services = services }
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

/// The menu bar glyph. It is the one view alive from launch, so it also hands the
/// scene's window opener to the router for the pill and the delegate.
private struct MenuBarLabel: View {
  let services: AppServices
  let installed: () -> Void
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let glyph = MenuBarGlyph.resolve(
      needsAttention: services.needsAttention,
      meetingState: services.meetingCoordinator?.status?.state)
    Image(systemName: glyph.symbol)
      .accessibilityLabel(glyph.label)
      .onAppear {
        services.router.openMainWindow = { openWindow(id: "main") }
        installed()
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
    Group {
      if services.preferences.onboardingComplete {
        library
      } else {
        // First run owns the whole window; the library appears once setup is done.
        OnboardingView(
          settings: services.settings, coordinator: services.onboarding,
          localAI: services.localAI, preferences: services.preferences
        )
        .background(SottoPalette.canvas)
        .ignoresSafeArea(.container, edges: .top)
      }
    }
    .foregroundStyle(SottoPalette.ink)
    .tint(SottoPalette.accent)
    .onExitCommand { services.coordinator?.cancel() }
    .onDisappear { services.flushMeetingNotes() }
    .task { await services.observeSettingsWhileVisible() }
    .onChange(of: services.router.selection) { _, _ in services.settingsPageChanged() }
    .onChange(of: services.preferences.onboardingComplete) { _, _ in
      services.settingsPageChanged()
    }
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

  private var library: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        sidebar(compact: geometry.size.width <= 800).frame(
          width: geometry.size.width <= 800 ? 180 : 216)
        VStack(spacing: 0) {
          if let coordinator = services.coordinator {
            RecoveryNotice(coordinator: coordinator)
          }
          destination
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SottoPalette.surface)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
          RoundedRectangle(cornerRadius: 16).strokeBorder(SottoPalette.line, lineWidth: 1)
        }
        .padding(.top, 44).padding(.trailing, 8).padding(.bottom, 8)
      }
      .background(SottoPalette.canvas)
      .font(.flow(size: 14))
      .scrollIndicators(.never)
      .environment(\.prototypeCompact, geometry.size.width <= 800)
    }
    .ignoresSafeArea(.container, edges: .top)
  }

  private func sidebar(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "chart.bar.xaxis").font(.flow(size: 19, weight: .semibold))
        Text("LocalFlow").font(.flow(size: 22, weight: .bold)).tracking(-0.6)
      }
      .padding(.horizontal, 8).padding(.top, 70).padding(.bottom, 36)
      VStack(spacing: 5) {
        ForEach(LocalFlowPage.allCases.filter { $0 != .settings }) { navigationItem($0) }
      }
      Spacer()
      if let meetings = services.meetingCoordinator, let status = meetings.status,
        meetings.isActive
      {
        Button {
          services.router.selection = .meetings
          if let library = services.meetingLibrary { Task { await library.open(status.id) } }
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            Text(status.title ?? "Untitled note").font(.flow(size: 13, weight: .medium))
              .lineLimit(1)
            LiveRecordingBadge(state: status.state, elapsed: meetings.elapsed, size: 12)
          }
          .padding(14).frame(maxWidth: .infinity, alignment: .leading)
          .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
          .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SottoPalette.line) }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("navigation.activeNote")
        .padding(.bottom, 12)
      }
      if services.needsAttention {
        Label("Review needed", systemImage: "exclamationmark.circle")
          .font(.flow(size: 13)).foregroundStyle(SottoPalette.warning)
          .padding(.horizontal, 10).padding(.bottom, 8)
      }
      SottoPalette.line.frame(height: 1).padding(.bottom, 8)
      navigationItem(.settings).padding(.bottom, 12)
    }
    .padding(.horizontal, 12)
  }

  private func navigationItem(_ destination: LocalFlowPage) -> some View {
    let selected = services.router.selection == destination
    return Button {
      services.router.selection = destination
    } label: {
      HStack(spacing: 10) {
        Image(systemName: destination.symbol).font(.flow(size: 16)).frame(width: 20)
        Text(destination.rawValue).font(.flow(size: 15)).lineLimit(1).minimumScaleFactor(0.85)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10).frame(height: 35)
      .background(selected ? SottoPalette.tint : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("navigation.\(destination.rawValue.lowercased())")
    .accessibilityAddTraits(selected ? .isSelected : [])
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
          diarization: services.speakerDiarization,
          identification: services.speakerIdentification,
          intelligence: services.meetingIntelligence,
          summaryModelFactory: { services.makeSummaryModel(meetingID: $0) },
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
          delete: { try await coordinator.deleteOrThrow($0) }, globalBusy: coordinator.busy)
      } else {
        ContentUnavailableView(
          "Transcriptions unavailable", systemImage: "externaldrive.badge.exclamationmark",
          description: Text(services.setupStatus))
      }
    case .insights:
      if let insights = services.insightsModel {
        InsightsView(model: insights)
      } else {
        ContentUnavailableView(
          "Insights unavailable", systemImage: "externaldrive.badge.exclamationmark",
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
      Text("Review before inserting").font(.flow(size: 26, weight: .semibold))
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
        Label("Unsaved text", systemImage: "exclamationmark.triangle").font(
          .flow(size: 14, weight: .semibold))
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
