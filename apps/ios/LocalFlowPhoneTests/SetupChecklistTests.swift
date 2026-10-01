import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

@MainActor
final class SetupChecklistTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suite = "setup-tests-\(UUID().uuidString)"

  override func setUp() async throws { defaults = UserDefaults(suiteName: suite) }
  override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

  private func status(fullAccess: Bool) -> KeyboardStatusFile {
    KeyboardStatusFile(hasFullAccess: fullAccess, lastSeen: 0, peakFootprintBytes: 0)
  }

  func testStepsAreDerivedFromTheirSources() {
    let checklist = SetupChecklistModel(defaults: defaults)
    checklist.refresh(
      keyboardStatus: nil, microphone: .undetermined, modelReady: false, hasDictation: false)
    XCTAssertTrue(checklist.done.isEmpty, "a missing status file is 'not detected yet'")
    checklist.refresh(
      keyboardStatus: status(fullAccess: false), microphone: .denied, modelReady: false,
      hasDictation: false)
    XCTAssertEqual(checklist.done, [.keyboard], "Full Access is missing")
    checklist.refresh(
      keyboardStatus: status(fullAccess: true), microphone: .granted, modelReady: true,
      hasDictation: true)
    XCTAssertTrue(checklist.isComplete)
  }

  /// T079: a relaunch or reinstall keeps what was detected; the microphone and the model
  /// follow their live state, so a step iOS reset is asked for again.
  func testStepsSurviveARelaunchUnlessTheirLiveStateWasReset() {
    SetupChecklistModel(defaults: defaults).refresh(
      keyboardStatus: status(fullAccess: true), microphone: .granted, modelReady: true,
      hasDictation: true)
    let relaunched = SetupChecklistModel(defaults: defaults)
    XCTAssertTrue(relaunched.isComplete)
    relaunched.refresh(
      keyboardStatus: nil, microphone: .denied, modelReady: false, hasDictation: false)
    XCTAssertEqual(relaunched.done, [.keyboard, .fullAccess, .firstDictation])
    relaunched.refresh(
      keyboardStatus: status(fullAccess: false), microphone: .granted, modelReady: true,
      hasDictation: false)
    XCTAssertFalse(relaunched.done.contains(.fullAccess), "the status file re-checks it")
  }

  func testSpaceCheckRefusesBelowTheTotalPlusTenPercent() {
    XCTAssertNotNil(ModelSetupViewModel.spaceShortfall(available: 1_099, required: 1_100))
    XCTAssertNil(ModelSetupViewModel.spaceShortfall(available: 1_100, required: 1_100))
    XCTAssertNil(ModelSetupViewModel.spaceShortfall(available: nil, required: 1_100))
  }

  func testRequiredSpaceIsTheDescriptorsPlusTenPercent() throws {
    let json = """
      {"schemaVersion":1,"modelID":"example/model","sourceRevision":"\(String(repeating: "a", count: 40))",
       "sdkCompatibility":"test","automaticLanguage":true,"license":"test",
       "files":[{"path":"a.bin","size":600,"sha256":"\(String(repeating: "0", count: 64))"},
                {"path":"b.bin","size":400,"sha256":"\(String(repeating: "1", count: 64))"}],
       "complete":true}
      """
    let descriptor = try JSONDecoder().decode(ModelDescriptor.self, from: Data(json.utf8))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = PhoneModelState(
      speech: ModelProvisioner(descriptor: descriptor, rootURL: root), boost: nil,
      transport: HTTPModelDownloadTransport(), directories: [root], descriptors: [descriptor])
    let setup = ModelSetupViewModel(model: model, availableBytes: { 1_099 })
    XCTAssertEqual(setup.requiredBytes, 1_100)
    setup.download()
    XCTAssertNotNil(setup.spaceMessage)
    XCTAssertEqual(model.state, .absent, "no download starts without the space")
  }
}
