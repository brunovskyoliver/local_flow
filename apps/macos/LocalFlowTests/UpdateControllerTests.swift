import XCTest

@testable import LocalFlow

@MainActor
final class UpdateControllerTests: XCTestCase {
  private final class Driver: UpdateDriving {
    var canCheck = true
    var installationRequested = false
    var changed: (() -> Void)?
    var automaticallyChecks = false
    var checks = 0
    func check() {
      checks += 1
      canCheck = false
    }
  }
  func testRepeatedChecksAreCoalescedUntilDriverFinishes() {
    let driver = Driver()
    let controller = UpdateController(driver: driver)
    controller.check()
    controller.check()
    XCTAssertEqual(driver.checks, 1)
    driver.canCheck = true
    controller.check()
    XCTAssertEqual(driver.checks, 2)
  }
  func testUnavailableBuildNeverChecksAndPreferenceCannotEnableIt() {
    let controller = UpdateController(driver: nil, unavailableReason: "Unsigned build")
    controller.automaticallyChecks = true
    controller.check()
    XCTAssertFalse(controller.canCheck)
    XCTAssertFalse(controller.canCheck)
  }
  func testInstallationWaitsAndResumesOnce() {
    var busy = true
    var installs = 0
    let gate = UpdateInstallationGate { busy }
    XCTAssertTrue(gate.postpone { installs += 1 })
    XCTAssertFalse(gate.resumeIfIdle())
    XCTAssertEqual(installs, 0)
    busy = false
    XCTAssertTrue(gate.resumeIfIdle())
    XCTAssertTrue(gate.resumeIfIdle())
    XCTAssertEqual(installs, 1)
  }
  func testCancelledInstallationCannotResume() {
    var busy = true
    var installs = 0
    let gate = UpdateInstallationGate { busy }
    XCTAssertTrue(gate.postpone { installs += 1 })
    gate.cancel()
    busy = false
    XCTAssertTrue(gate.resumeIfIdle())
    XCTAssertEqual(installs, 0)
  }
  func testAutomaticCheckingDoesNotInstall() {
    let driver = Driver()
    let controller = UpdateController(driver: driver)
    controller.automaticallyChecks = true
    XCTAssertTrue(driver.automaticallyChecks)
    XCTAssertEqual(driver.checks, 0)
  }
}

final class HelperReconcilerTests: XCTestCase {
  private actor Host {
    var hash: String? = "old"
    var restarts = 0
    var succeeds = true
    func restart() {
      restarts += 1
      if succeeds { hash = "new" }
    }
    func read() -> String? { hash }
    func count() -> Int { restarts }
    func failRestart() { succeeds = false }
  }
  func testOldHelperIsRestartedAndNewIdentityVerified() async throws {
    let host = Host()
    let reconcile = HelperReconciler(
      expected: "new", running: { await host.read() },
      restart: { await host.restart() }, sleep: {})
    try await reconcile.reconcile()
    let count = await host.count()
    XCTAssertEqual(count, 1)
    try await reconcile.reconcile()
    let unchanged = await host.count()
    XCTAssertEqual(unchanged, 1)
  }
  func testFailedRestartDoesNotAcceptOldIdentity() async throws {
    let host = Host()
    await host.failRestart()
    let reconcile = HelperReconciler(
      expected: "new", running: { await host.read() },
      restart: { await host.restart() }, sleep: {})
    do {
      try await reconcile.reconcile()
      XCTFail("Accepted old helper")
    } catch HelperReconciler.Failure.unverified {}
  }
  func testScriptChangeForcesReconciliation() async throws {
    let host = Host()
    await host.restart()
    let reconcile = HelperReconciler(
      expected: "new", running: { await host.read() },
      restart: { await host.restart() }, sleep: {})
    try await reconcile.reconcile(force: true)
    let count = await host.count()
    XCTAssertEqual(count, 2)
  }
}
