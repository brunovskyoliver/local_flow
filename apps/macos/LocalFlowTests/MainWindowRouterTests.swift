import AppKit
import XCTest

@testable import LocalFlow

final class MainWindowRouterTests: XCTestCase {
  @MainActor
  func testExplicitOpenPreservesDestinationAndSettingsSelectsSameRoute() {
    var activations = 0
    var opens = 0
    let router = MainWindowRouter(setActivationPolicy: { _ in }, activate: { activations += 1 })
    XCTAssertEqual(router.selection, .history)
    router.selection = .history
    router.open { opens += 1 }
    XCTAssertEqual(router.selection, .history)
    router.open(.settings) { opens += 1 }
    XCTAssertEqual(router.selection, .settings)
    XCTAssertEqual(opens, 2)
    XCTAssertEqual(activations, 2)
  }

  @MainActor
  func testAttachingAndChangingSelectionDoesNotActivateApplication() {
    var activations = 0
    let router = MainWindowRouter(setActivationPolicy: { _ in }, activate: { activations += 1 })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
    router.attach(window)
    router.selection = .settings
    XCTAssertEqual(activations, 0)
    XCTAssertEqual(window.identifier?.rawValue, "localflow.main")
    XCTAssertFalse(window.isVisible)
  }

  @MainActor
  func testOpeningPromotesApplicationBeforeOpeningOrFocusingWindow() {
    var events: [String] = []
    let router = MainWindowRouter(
      setActivationPolicy: { events.append($0 == .regular ? "regular" : "accessory") },
      activate: { events.append("activate") })
    router.open { events.append("open") }
    XCTAssertEqual(events, ["regular", "open", "activate"])
  }

  @MainActor
  func testOnlyMainWindowCloseRemovesDockPresence() {
    var policies: [NSApplication.ActivationPolicy] = []
    let router = MainWindowRouter(setActivationPolicy: { policies.append($0) }, activate: {})
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: true)
    router.attach(window)
    router.attach(window)
    XCTAssertEqual(policies, [.regular])
    NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
    let otherWindow = NSWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: otherWindow)
    XCTAssertEqual(policies, [.regular])
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    XCTAssertEqual(policies, [.regular, .accessory])
    router.open(openWindow: {})
    XCTAssertEqual(policies, [.regular, .accessory, .regular])
    window.orderOut(nil)
  }

  @MainActor
  func testReplacingWindowRemovesPreviousCloseObserver() {
    var policies: [NSApplication.ActivationPolicy] = []
    let router = MainWindowRouter(setActivationPolicy: { policies.append($0) }, activate: {})
    let first = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    let second = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    router.attach(first)
    router.attach(second)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: first)
    XCTAssertEqual(policies, [.regular, .regular])
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: second)
    XCTAssertEqual(policies, [.regular, .regular, .accessory])
  }

  @MainActor
  func testDockReopenPreservesSelectionAndRequiresAttachedWindow() {
    var activations = 0
    let router = MainWindowRouter(
      setActivationPolicy: { _ in }, activate: { activations += 1 })
    XCTAssertFalse(router.reopen())
    XCTAssertEqual(activations, 0)
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: true)
    defer { window.orderOut(nil) }
    router.attach(window)
    router.selection = .history
    XCTAssertTrue(router.reopen())
    XCTAssertEqual(router.selection, .history)
    XCTAssertEqual(activations, 1)
    XCTAssertTrue(window.isVisible)
  }

  /// A minimized window is restored in place rather than replaced by a second
  /// window, from both an explicit command and a Dock click.
  @MainActor
  func testMinimizedWindowIsRestoredInPlace() {
    var opens = 0
    let router = MainWindowRouter(setActivationPolicy: { _ in }, activate: {})
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
    defer { window.orderOut(nil) }
    router.attach(window)
    window.makeKeyAndOrderFront(nil)
    window.miniaturize(nil)
    router.open(.settings) { opens += 1 }
    XCTAssertFalse(window.isMiniaturized, "An explicit command must restore the window")
    XCTAssertEqual(router.selection, .settings)
    XCTAssertEqual(opens, 1, "Restoring must not open a second window")

    window.miniaturize(nil)
    XCTAssertTrue(router.reopen())
    XCTAssertFalse(window.isMiniaturized, "A Dock click must restore the same window")
    XCTAssertEqual(router.selection, .settings, "Restoring preserves the destination")
  }

  /// Closing the window is not quitting: the route survives and reopening uses
  /// the same window identity instead of creating another main window.
  @MainActor
  func testClosingKeepsTheRouteAndReopensTheSameWindow() {
    var policies: [NSApplication.ActivationPolicy] = []
    let router = MainWindowRouter(setActivationPolicy: { policies.append($0) }, activate: {})
    var closes = 0
    router.mainWindowDidClose = { closes += 1 }
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: true)
    defer { window.orderOut(nil) }
    router.attach(window)
    router.open(.settings) {}
    XCTAssertEqual(closes, 0)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    XCTAssertEqual(closes, 1, "window-only state is released on close")
    XCTAssertEqual(policies.last, .accessory)
    XCTAssertEqual(router.selection, .settings, "Closing must not reset the destination")

    XCTAssertTrue(router.reopen())
    XCTAssertEqual(policies.last, .regular)
    XCTAssertEqual(window.identifier?.rawValue, "localflow.main")
    XCTAssertEqual(router.selection, .settings)
  }

  /// Feature 004 adds the Meetings page before Transcriptions; the default
  /// route and the other pages are unchanged.
  @MainActor
  func testMeetingsPageIsListedFirstAndRoutable() {
    XCTAssertEqual(
      LocalFlowPage.allCases, [.meetings, .history, .dictionary, .settings])
    XCTAssertEqual(LocalFlowPage.meetings.rawValue, "Notetaker")
    XCTAssertEqual(LocalFlowPage.meetings.symbol, "record.circle")
    let router = MainWindowRouter(setActivationPolicy: { _ in }, activate: {})
    XCTAssertEqual(router.selection, .history, "the default route is unchanged")
    router.open(.meetings) {}
    XCTAssertEqual(router.selection, .meetings)
  }
}
