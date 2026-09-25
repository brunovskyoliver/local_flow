import XCTest

@testable import LocalFlow

final class LocalAIRuntimeTests: XCTestCase {
  func testPullEventsReadProgressAndResultAndIgnoreNoise() {
    XCTAssertEqual(
      LocalAIInstaller.pullEvent(
        #"{"event": "progress", "size_bytes": 512, "total_bytes": 2048, "path": "/x"}"#),
      .progress(completed: 512, total: 2048))
    XCTAssertEqual(
      LocalAIInstaller.pullEvent(#"{"event": "progress", "size_bytes": 5, "total_bytes": 0}"#),
      .progress(completed: 5, total: nil))
    XCTAssertEqual(
      LocalAIInstaller.pullEvent(#"{"event": "result", "path": "/models/a"}"#),
      .result(path: "/models/a"))
    XCTAssertNil(LocalAIInstaller.pullEvent(#"{"event": "resolving", "repo_id": "a/b"}"#))
    XCTAssertNil(LocalAIInstaller.pullEvent("Downloading model files"))
    XCTAssertNil(LocalAIInstaller.pullEvent(String(repeating: " ", count: 70_000)))
  }

  func testCatalogIsPinnedAndGatedByMemory() {
    for model in LocalAIModel.catalog {
      XCTAssertEqual(model.revision.count, 40, model.id)
      XCTAssertTrue(model.revision.allSatisfy(\.isHexDigit), model.id)
      XCTAssertTrue(model.id.hasPrefix("Youssofal/"), model.id)
      XCTAssertGreaterThan(Double(model.minimumMemoryGB), model.peakMemoryGB, model.id)
    }
    XCTAssertTrue(LocalAIModel.recommended.fits(physicalMemory: 8 << 30))
    let large = LocalAIModel.catalog.last!
    XCTAssertFalse(large.fits(physicalMemory: 32 << 30))
    XCTAssertTrue(large.fits(physicalMemory: 64 << 30))
  }

  func testHashRefusesFilesOverTheCap() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertEqual(
      try LocalAIInstaller.sha256(of: file, maximumBytes: 3),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertThrowsError(try LocalAIInstaller.sha256(of: file, maximumBytes: 2))
  }

  @MainActor func testFinishedPullIsDetectedAndPreselected() throws {
    let models = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalFlow-models-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: models) }
    let model = LocalAIModel.catalog[3]
    let folder = models.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "--"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: folder.appendingPathComponent("mtplx_runtime.json"))
    XCTAssertFalse(model.isDownloaded(in: models), "No pull marker: an unfinished pull")
    try Data(#"{"repo_id": "\#(model.id)", "resolved_sha": "older"}"#.utf8)
      .write(to: folder.appendingPathComponent(".mtplx-source.json"))
    XCTAssertTrue(model.isDownloaded(in: models), "Any commit counts; the pull fetches the rest")
    XCTAssertFalse(LocalAIModel.catalog[0].isDownloaded(in: models))

    let setup = LocalAISetup(
      preferences: nil, installer: nil, physicalMemory: 32 << 30, downloaded: [model.id])
    XCTAssertEqual(setup.selection, model)
    let small = LocalAISetup(
      preferences: nil, installer: nil, physicalMemory: 16 << 30, downloaded: [model.id])
    XCTAssertEqual(
      small.selection, .recommended, "A downloaded model that doesn't fit is not picked")
  }

  @MainActor func testSetupWithoutInstallerChangesNothing() async {
    let suite = "LocalFlow-localai-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    let setup = LocalAISetup(preferences: preferences, installer: nil)
    setup.start()
    XCTAssertEqual(setup.phase, .idle, "No installer, nothing starts")
    XCTAssertFalse(preferences.rewriteEnabled)
  }
}

@MainActor
final class LocalModelResidencyTests: XCTestCase {
  private var commands: [Bool] = []
  private var probes: [Bool] = []
  private var busy = false
  private let local = RewriteEndpoint(
    url: URL(string: LocalAIInstaller.rewriteEndpoint)!, origin: LocalAIInstaller.rewriteEndpoint)

  private func residency(
    idle: LocalModelIdleUnload = .never, games: Bool = true, clock: any DictationClock
  ) -> LocalModelResidency {
    let preferences = AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    preferences.localModelIdleUnload = idle
    preferences.unloadLocalModelDuringGames = games
    let residency = LocalModelResidency(
      preferences: preferences, clock: clock,
      setRunning: { [unowned self] in commands.append($0) },
      backendReady: { [unowned self] in probes.isEmpty ? true : probes.removeFirst() },
      busy: { [unowned self] in busy })
    residency.managed = true
    return residency
  }

  func testIdleDelayUnloadsAndNeverKeepsTheModel() async {
    let kept = residency(clock: ImmediateClock())
    XCTAssertNil(kept.idleTimer)
    let idle = residency(idle: .fifteenMinutes, clock: ImmediateClock())
    await idle.idleTimer?.value
    XCTAssertFalse(idle.loaded)
    XCTAssertEqual(commands, [false])
  }

  func testGameInFrontUnloadsAndQuittingItReloads() async {
    let residency = residency(clock: ImmediateClock())
    residency.frontmostChanged(toGame: true)
    await residency.gameTimer?.value
    XCTAssertFalse(residency.loaded)
    residency.gameQuit()
    XCTAssertTrue(residency.loaded)
    XCTAssertEqual(commands, [false, true])
  }

  func testGamesSwitchOffOrLeavingTheGameKeepsTheModel() async {
    let off = residency(games: false, clock: ImmediateClock())
    off.frontmostChanged(toGame: true)
    XCTAssertNil(off.gameTimer)
    let switched = residency(clock: HourClock())
    switched.frontmostChanged(toGame: true)
    switched.frontmostChanged(toGame: false)
    XCTAssertNil(switched.gameTimer)
    XCTAssertTrue(switched.loaded)
    XCTAssertEqual(commands, [])
  }

  func testMemoryPressureWaitsForBusyWork() {
    let residency = residency(clock: HourClock())
    busy = true
    residency.memoryPressure()
    XCTAssertTrue(residency.loaded)
    busy = false
    residency.memoryPressure()
    XCTAssertFalse(residency.loaded)
    XCTAssertEqual(commands, [false])
  }

  func testRequestStartsAnUnloadedModelAndWaitsUntilItServes() async {
    let residency = residency(clock: ImmediateClock())
    residency.memoryPressure()
    probes = [false, false, true]
    await residency.ready(for: local)
    XCTAssertEqual(commands, [false, true])
    XCTAssertTrue(probes.isEmpty)
    XCTAssertFalse(residency.starting)
    // Once serving, later requests don't probe.
    probes = [false]
    await residency.ready(for: local)
    XCTAssertEqual(probes, [false])
  }

  func testRemoteEndpointNeverTouchesTheLocalModel() async {
    let residency = residency(clock: ImmediateClock())
    residency.memoryPressure()
    await residency.ready(
      for: RewriteEndpoint(url: URL(string: "https://example.com")!, origin: "https://example.com"))
    XCTAssertFalse(residency.loaded)
    XCTAssertEqual(commands, [false])
  }

  func testGameCategoryComesFromInfoPlist() throws {
    let plist = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: plist) }
    for (category, game) in [
      ("public.app-category.games", true), ("public.app-category.action-games", true),
      ("public.app-category.productivity", false),
    ] {
      try (["LSApplicationCategoryType": category] as NSDictionary).write(to: plist)
      XCTAssertEqual(LocalModelResidency.isGame(infoPlist: plist), game, category)
    }
    XCTAssertFalse(LocalModelResidency.isGame(infoPlist: plist.appendingPathExtension("missing")))
  }
}

private struct ImmediateClock: DictationClock {
  func sleep(for duration: Duration) async throws {}
}

private struct HourClock: DictationClock {
  func sleep(for duration: Duration) async throws { try await Task.sleep(for: .seconds(3600)) }
}
