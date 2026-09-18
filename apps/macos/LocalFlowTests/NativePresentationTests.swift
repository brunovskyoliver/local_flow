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
  private func render<V: View>(
    _ view: V, to url: URL, appearance: NSAppearance.Name, scheme: ColorScheme,
    height: CGFloat = 650
  ) async throws {
    let host = NSHostingView(
      rootView: view.frame(width: 670, height: height).background(SottoPalette.surface).environment(
        \.colorScheme, scheme))
    let window = NSWindow(
      contentRect: NSRect(x: -2000, y: -2000, width: 670, height: height), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    defer { window.close() }
    host.frame = NSRect(x: 0, y: 0, width: 670, height: height)
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
}
