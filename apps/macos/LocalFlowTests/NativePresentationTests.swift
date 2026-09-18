import AppKit
import SwiftUI
import XCTest

@testable import LocalFlow

/// Opt-in rendering of synthetic data only. This does not establish signed focus,
/// physical keyboard, VoiceOver, microphone or hardware resource acceptance.
final class NativePresentationTests: XCTestCase {
  @MainActor
  func testRenderLightAndDarkDestinations() async throws {
    guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_UI_CAPTURE_DIR"] else {
      throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_UI_CAPTURE_DIR for native render artifacts.")
    }
    let output = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "render-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let store = try TranscriptionStore(path: databaseURL.path)
    for index in 0..<4 {
      let entry = try TranscriptionEntry(
        id: UUID(),
        text: index == 0
          ? "Zajtra skontrolujeme návrh. Then we can send the final version to the team.\nTento text je syntetický príklad pre kontrolu rozloženia."
          : "A synthetic transcription for checking the native history layout and its actions.",
        createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000)
          - Int64(index * 86_400_000),
        quality: index == 1 ? .durationLimited : index == 2 ? .incomplete : .complete,
        stopReason: index == 1 ? .durationLimit : .keyRelease)
      _ = try await store.commit(reservation: try await store.reserve(), entry: entry)
    }
    let history = HistoryViewModel(store: store)
    history.refresh()
    for _ in 0..<200 {
      if !history.isLoading { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(history.isLoading)
    let suite = "LocalFlow-render-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    let settings = SettingsViewModel(
      observe: {
        var snapshot = SettingsViewModel.Snapshot()
        snapshot.modelIdentity = "Parakeet TDT v3"
        snapshot.modelVersion = "Pinned local revision"
        snapshot.modelInstalled = true
        snapshot.microphone = .granted
        snapshot.inputMonitoring = .granted
        snapshot.accessibility = .denied
        snapshot.shortcutReady = true
        snapshot.storageAvailable = true
        snapshot.status = "Copy-only dictation is available."
        return snapshot
      }, perform: { _ in })
    await settings.refresh()
    for (name, appearance, scheme) in [
      ("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark),
    ] {
      try await render(
        HistoryView(
          model: history, copy: { _ in }, insert: { _, _ in }, dismissRecovery: { _ in },
          delete: { _ in }),
        to: output.appendingPathComponent("history-\(name).png"), appearance: appearance,
        scheme: scheme)
      try await render(
        SettingsView(model: settings, preferences: preferences),
        to: output.appendingPathComponent("settings-\(name).png"), appearance: appearance,
        scheme: scheme)
      try await render(
        OnboardingView(
          settings: settings, coordinator: OnboardingCoordinator(preferences: preferences)),
        to: output.appendingPathComponent("setup-\(name).png"), appearance: appearance,
        scheme: scheme)
    }
  }

  @MainActor
  func testRenderRewriteSettings() async throws {
    guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_UI_CAPTURE_DIR"] else {
      throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_UI_CAPTURE_DIR for native render artifacts.")
    }
    let output = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let suite = "LocalFlow-rewrite-render-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    let transport = FakeRewriteTransport()
    transport.healthResult = .success(
      try HealthResponse.decode(
        Data(
          """
          {"schema_version":1,"service":"localflow-rewrite","protocol_versions":[1],
           "server":{"name":"flowd","version":"test-build"},
           "backend":{"state":"ready","kind":"openai-compatible","model":"synthetic-model"},
           "prompt_versions":{"clean":1,"polished":1,"concise":1},"shield_version":1}
          """.utf8)))
    let model = SettingsViewModel(
      observe: { .init() }, perform: { _ in }, preferences: preferences,
      rewriteCredentials: FakeRewriteCredentialStore(), rewriteTransport: transport)
    model.rewriteEndpoint = "http://rewrite.test:8080"
    model.rewriteInsecureOverride = true
    model.credentialDraft = "synthetic-credential"
    model.setRewriteCredential()
    model.rewriteEnabled = true
    await model.testConnection()
    for (name, appearance, scheme) in [
      ("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark),
    ] {
      try await render(
        SettingsView(model: model, preferences: preferences).rewriteSection.padding(20),
        to: output.appendingPathComponent("rewrite-settings-\(name).png"),
        appearance: appearance, scheme: scheme, height: 1000)
    }
  }

  @MainActor
  func testRenderNotetaker() async throws {
    guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_UI_CAPTURE_DIR"] else {
      throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_UI_CAPTURE_DIR for native render artifacts.")
    }
    let output = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    var ids: [UUID] = []
    for (index, title) in [
      "Product design review", "Hardware evaluation", "Release planning", "Team catch-up",
    ].enumerated() {
      let time = now - Int64(index + 1) * 86_400_000
      let meeting = try await fixture.store.create(now: time)
      ids.append(meeting.id)
      _ = try await fixture.store.setTitle(
        meetingID: meeting.id, title: title, revision: 0, now: time)
      try await fixture.store.transition(id: meeting.id, to: .preparing, now: time, effects: [])
      try await fixture.store.transition(
        id: meeting.id, to: .recording, now: time, effects: [.setStartedAt(time)])
      try await fixture.store.transition(
        id: meeting.id, to: .finalizing, now: time + 600_000,
        effects: [.setStoppedAt(time + 600_000)])
      try await fixture.store.transition(
        id: meeting.id, to: .completed, now: time + 600_001,
        effects: [.setCompletedAt(time + 600_001)])
    }
    let clock = FakeMeetingClock()
    let coordinator = MeetingCoordinator(
      dependencies: .init(
        store: fixture.store, writer: FakeSegmentWriter(root: fixture.root),
        permissions: MeetingCoordinatorTests.PermissionState().permissions,
        clock: clock, recorder: nil, storageRoot: fixture.root,
        sourceFactory: { kind in
          FakeMeetingAudioSource(
            kind: kind, format: .init(sampleRate: 48_000, channels: 1), clock: clock)
        }))
    coordinator.markReconciliationComplete()
    let suite = "Notetaker-render-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    let model = MeetingLibraryViewModel(store: fixture.store)
    await model.refresh()
    await model.preview(ids[0])
    let makeEditor: (MeetingDetail) -> MeetingNotesEditor = { detail in
      MeetingNotesEditor(
        meetingID: detail.meeting.id, store: fixture.store, clock: SystemMeetingClock(),
        text: detail.notes.text, revision: detail.notes.revision)
    }
    let transcripts = FakeTranscriptStore()
    await transcripts.seed(ids[0])
    let pass = UUID()
    _ = try await transcripts.transition(
      meetingID: ids[0], to: .finalizing, now: now, effects: [.setPass(id: pass, kind: .final)])
    let lines: [(AnalysisTracks, String)] = [
      (
        .system,
        "Let's walk through the new recording view and make sure the important details are easy to find."
      ),
      (
        .system,
        "The notes list should stay quiet. We can show more context when you hover over a recording."
      ),
      (
        .mic,
        "I agree. The transcript needs a clear reading column, with enough space between speaker changes."
      ),
      (
        .system,
        "We should also keep playback within reach without putting all of the technical information on the main screen."
      ),
      (
        .both,
        "This section contains mixed microphone and system audio. The speaker remains unassigned."
      ),
      (.mic, "Let's review the compact layout before we finish."),
    ]
    let drafts = lines.enumerated().map { index, line in
      TranscriptSegmentDraft(
        finality: .final, ordinal: index, stretchSequence: 1, startMs: Int64(index * 10_000),
        endMs: Int64(index * 10_000 + 9_000), coveredMs: 600_000, windowIndex: index,
        timingBasis: .window, rawText: line.1, assembledText: line.1, normalizedText: line.1,
        analysisTracks: line.0)
    }
    _ = try await transcripts.appendSegments(
      meetingID: ids[0], passID: pass, drafts: drafts, progress: nil, now: now)
    _ = try await transcripts.completeFinalPass(
      meetingID: ids[0], passID: pass, descriptor: .init(source: .decodedTracks),
      coveredMs: 600_000, now: now)
    for (name, appearance, scheme, width) in [
      ("wide-light", NSAppearance.Name.aqua, ColorScheme.light, CGFloat(1440)),
      ("compact-light", .aqua, .light, CGFloat(680)),
      ("wide-dark", .darkAqua, .dark, CGFloat(1440)),
    ] {
      model.closeDetail()
      try await render(
        MeetingLibraryView(
          coordinator: coordinator, model: model, storageRoot: fixture.root,
          preferences: preferences, transcriptStore: transcripts, notesEditorFactory: makeEditor),
        to: output.appendingPathComponent("notetaker-list-\(name).png"), appearance: appearance,
        scheme: scheme, height: 850, width: width)
      await model.open(ids[0])
      let detail = try XCTUnwrap(model.detail)
      for tab in NoteDetailTab.allCases {
        try await render(
          MeetingDetailView(
            detail: detail, model: model, storageRoot: fixture.root,
            notesEditor: makeEditor(detail), liveEditor: nil, transcriptStore: transcripts,
            initialTab: tab), to: output.appendingPathComponent("notetaker-\(tab.id)-\(name).png"),
          appearance: appearance, scheme: scheme, height: 850, width: width)
      }
    }
  }

  @MainActor
  private func render<V: View>(
    _ view: V, to url: URL, appearance: NSAppearance.Name, scheme: ColorScheme,
    height: CGFloat = 650, width: CGFloat = 670
  ) async throws {
    let host = NSHostingView(
      rootView: view.frame(width: width, height: height).background(SottoPalette.surface)
        .environment(
          \.colorScheme, scheme))
    let window = NSWindow(
      contentRect: NSRect(x: -2000, y: -2000, width: width, height: height),
      styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    defer { window.close() }
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: url)
    XCTAssertGreaterThan(data.count, 1_000)
  }
}

/// T030: the `rewriting` state and the rewrite action notice in the indicator.
@MainActor
final class RewriteIndicatorPresentationTests: XCTestCase {
  func testRewritingAnnouncesAndKeepsThePanelUp() {
    XCTAssertEqual(
      IndicatorPanel.announcement(from: .persisting, to: .rewriting),
      "Rewriting text. Microphone off.")
    XCTAssertNil(IndicatorPanel.announcement(from: .rewriting, to: .rewriting))
    XCTAssertTrue(IndicatorPanel.showsPanel(.rewriting))
    XCTAssertEqual(
      IndicatorPanel.announcement(from: .rewriting, to: .inserting), "Inserting saved text.")
  }

  func testActionNoticeCarriesItsMessageAndRetryAffordance() {
    let dictation = UUID()
    let notice = RewriteActionNotice(
      dictationID: dictation,
      message: RewriteNotice.text(for: .serverUnreachable, context: .live), canRetry: true)
    XCTAssertEqual(notice.message, "Rewrite server unreachable. Original text inserted.")
    XCTAssertTrue(notice.canRetry)
    XCTAssertEqual(notice.dictationID, dictation)
    // A notice that cannot be retried still shows its message.
    let limit = RewriteActionNotice(
      dictationID: dictation, message: RewriteNotice.text(for: .attemptLimit, context: .live),
      canRetry: false)
    XCTAssertEqual(limit.message, "This dictation already has ten rewrite attempts.")
    XCTAssertFalse(limit.canRetry)
    XCTAssertNotEqual(notice.id, limit.id, "a new notice re-announces")
  }

  /// Feature 004 (T036): the menu bar glyph and label per meeting state. The
  /// recording glyph wins over attention; without a meeting nothing changes.
  func testMenuBarGlyphReflectsMeetingState() {
    XCTAssertEqual(
      MenuBarGlyph.resolve(needsAttention: false, meetingState: nil).symbol, "waveform")
    XCTAssertEqual(
      MenuBarGlyph.resolve(needsAttention: false, meetingState: nil).label, "LocalFlow")
    XCTAssertEqual(
      MenuBarGlyph.resolve(needsAttention: true, meetingState: nil).symbol, "exclamationmark.circle"
    )
    XCTAssertEqual(
      MenuBarGlyph.resolve(needsAttention: true, meetingState: .recording).symbol,
      "record.circle.fill")
    XCTAssertEqual(
      MenuBarGlyph.resolve(needsAttention: false, meetingState: .recording).label,
      "LocalFlow: meeting recording")
    XCTAssertEqual(
      MenuBarGlyph.resolve(needsAttention: false, meetingState: .paused).symbol, "pause.circle.fill"
    )
    for state in [MeetingState.completed, .interrupted, .failed, .finalizing, .preparing] {
      XCTAssertEqual(
        MenuBarGlyph.resolve(needsAttention: false, meetingState: state).symbol, "waveform",
        "\(state)")
    }
  }
}
