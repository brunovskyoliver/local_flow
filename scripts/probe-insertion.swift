import AppKit
@preconcurrency import ApplicationServices
import Foundation

// Standalone signed probe, compiled with the production insertion source files.
// Usage: probe-insertion <bundle-id> <exact-window-title> <caret|selection>
// Open a dedicated fixture containing exactly the fixture text below first.
@main
struct InsertionProbe {
  static let fixture = "LocalFlow insertion probe fixture.\n"

  @MainActor
  static func main() async {
    let args = CommandLine.arguments
    guard args.count == 4, ["caret", "selection"].contains(args[3]) else {
      print("usage: probe-insertion bundle-id exact-window-title caret|selection")
      exit(2)
    }
    let clipboard = NSPasteboard.general.changeCount
    guard AXIsProcessTrusted() else {
      print("BLOCKED Accessibility unavailable; no permission prompt or dispatch")
      exit(3)
    }
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier == args[1]
    else {
      print("BLOCKED frontmost app does not match fixture app")
      exit(4)
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    var rawWindow: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
      let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
    else {
      print("BLOCKED no app-level focused window")
      exit(5)
    }
    let window = rawWindow as! AXUIElement
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
      title as? String == args[2], args[2].contains("LocalFlow-AX-Probe-")
    else {
      print("BLOCKED dedicated fixture title mismatch")
      exit(6)
    }
    let adapter = SystemTextAccessibilityAdapter()
    guard let original = try? await adapter.captureTarget(),
      original.bundleIdentifier == args[1], original.processIdentifier == app.processIdentifier,
      original.focusedWindow.map({ CFEqual($0, window) }) == true
    else {
      print("BLOCKED production adapter capture returned no fixture target")
      exit(7)
    }
    // Read only the known, bounded synthetic fixture before changing its selection.
    var range = CFRange(location: 0, length: fixture.utf16.count)
    let value = AXValueCreate(.cfRange, &range)!
    var text: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        original.element, kAXStringForRangeParameterizedAttribute as CFString, value, &text)
        == .success, text as? String == fixture,
      await adapter.validate(original) == .eligible
    else {
      print("BLOCKED synthetic fixture content or target identity mismatch")
      exit(8)
    }
    range = CFRange(location: 0, length: args[3] == "selection" ? 9 : 0)
    let selection = AXValueCreate(.cfRange, &range)!
    guard
      AXUIElementSetAttributeValue(
        original.element, kAXSelectedTextRangeAttribute as CFString, selection) == .success,
      let target = try? await adapter.captureTarget(),
      target.processIdentifier == original.processIdentifier,
      target.launchDate == original.launchDate, CFEqual(target.element, original.element),
      target.selectedRange.location == range.location, target.selectedRange.length == range.length
    else {
      print("BLOCKED could not establish fixture selection")
      exit(9)
    }
    let service = TextInsertionService(adapter: adapter)
    let outcome = await service.insertOnce(
      attemptID: UUID(), target: target, text: "LocalFlow verified probe")
    try? await Task.sleep(for: .milliseconds(250))
    // Diagnostic reads stay on the captured synthetic element and are bounded.
    var insertedRange = CFRange(
      location: range.location, length: "LocalFlow verified probe".utf16.count)
    let insertedValue = AXValueCreate(.cfRange, &insertedRange)!
    var readback: CFTypeRef?
    let readStatus = AXUIElementCopyParameterizedAttributeValue(
      target.element, kAXStringForRangeParameterizedAttribute as CFString, insertedValue, &readback)
    var selected: CFTypeRef?
    let selectionStatus = AXUIElementCopyAttributeValue(
      target.element, kAXSelectedTextRangeAttribute as CFString, &selected)
    var actualRange = CFRange(location: -1, length: -1)
    if let selected, CFGetTypeID(selected) == AXValueGetTypeID() {
      _ = AXValueGetValue(selected as! AXValue, .cfRange, &actualRange)
    }
    print(
      "readbackStatus=\(readStatus.rawValue) insertedTextMatches=\(readback as? String == "LocalFlow verified probe") selectionStatus=\(selectionStatus.rawValue) selection=\(actualRange.location),\(actualRange.length)"
    )
    let delta = NSPasteboard.general.changeCount - clipboard
    print("bundle=\(args[1]) mode=\(args[3]) outcome=\(outcome) clipboardChangeCountDelta=\(delta)")
    exit(outcome == .confirmed && delta == 0 ? 0 : 10)
  }
}
