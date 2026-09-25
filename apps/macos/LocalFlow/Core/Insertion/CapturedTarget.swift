import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog

public enum TargetIssue: Error, Equatable, Sendable {
  case accessibilityDenied
  case secureField
  case unsupported
  case staleProcess
  case focusChanged
  case selectionChanged
  case contextTooLarge
}

public struct CapturedTarget: @unchecked Sendable {
  /// How text reaches the target. Terminals expose no editable text element, so their
  /// focused window receives a clipboard paste that cannot be read back.
  public enum Delivery: Equatable, Sendable {
    case typing
    case paste
  }

  public let processIdentifier: pid_t
  public let launchDate: Date
  public let bundleIdentifier: String
  public let element: AXUIElement
  public let focusedWindow: AXUIElement?
  public let selectedRange: CFRange
  public let comparisonContext: String
  public let delivery: Delivery

  public init(
    processIdentifier: pid_t,
    launchDate: Date,
    bundleIdentifier: String,
    element: AXUIElement,
    focusedWindow: AXUIElement?,
    selectedRange: CFRange,
    comparisonContext: String,
    delivery: Delivery = .typing
  ) {
    self.processIdentifier = processIdentifier
    self.launchDate = launchDate
    self.bundleIdentifier = bundleIdentifier
    self.element = element
    self.focusedWindow = focusedWindow
    self.selectedRange = selectedRange
    self.comparisonContext = comparisonContext
    self.delivery = delivery
  }
}

public enum TargetValidation: Equatable, Sendable {
  case eligible
  case rejected(TargetIssue)
}

public enum AXDispatchResult: Equatable, Sendable {
  case noMutation
  case mutationMayHaveOccurred
  /// Handed to a paste target, which offers no readback.
  case pasted
}

public protocol TextAccessibilityAdapter: Sendable {
  func captureTarget() async throws -> CapturedTarget?
  func validate(_ target: CapturedTarget) async -> TargetValidation
  func setSelectedText(_ text: String, on target: CapturedTarget) async throws -> AXDispatchResult
  func readback(_ text: String, on target: CapturedTarget) async throws -> String
  /// Reads up to `length` UTF-16 units starting at `location` while the target stays focused.
  /// Used only by opt-in correction learning after a confirmed insertion.
  func readText(on target: CapturedTarget, location: Int, length: Int) async throws -> String
}

extension TextAccessibilityAdapter {
  public func readText(on target: CapturedTarget, location: Int, length: Int) async throws
    -> String
  {
    throw TargetIssue.unsupported
  }
}

public struct SystemTextAccessibilityAdapter: TextAccessibilityAdapter {
  /// Bounds every Accessibility message, so a hung app cannot stall a press or an
  /// insertion (the default is several seconds).
  static let messagingTimeout: Float = 0.25

  public init() {}

  private static func bounded(_ element: AXUIElement) -> AXUIElement {
    AXUIElementSetMessagingTimeout(element, messagingTimeout)
    return element
  }

  public func captureTarget() async throws -> CapturedTarget? {
    try captureSynchronously()
  }

  private func focusedElement() -> AXUIElement? {
    guard AXIsProcessTrusted(), let frontmost = NSWorkspace.shared.frontmostApplication else {
      return nil
    }
    let pid = frontmost.processIdentifier
    var raw: CFTypeRef?
    let system = Self.bounded(AXUIElementCreateSystemWide())
    let status = AXUIElementCopyAttributeValue(
      system, kAXFocusedUIElementAttribute as CFString, &raw)
    if status != .success || raw == nil {
      // Some apps expose focus only through their application AX object.
      let application = Self.bounded(AXUIElementCreateApplication(pid))
      guard
        AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &raw)
          == .success
      else { return nil }
    }
    guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    let element = Self.bounded(raw as! AXUIElement)
    var elementPID: pid_t = 0
    guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    else { return nil }
    return element
  }

  private func captureSynchronously() throws -> CapturedTarget? {
    if let target = pasteTarget() { return target }
    guard let element = focusedElement(), let target = try makeTarget(element),
      matchesFocusedIdentity(target)
    else { return nil }
    return target
  }

  private func matchesFocusedIdentity(_ target: CapturedTarget) -> Bool {
    guard let element = focusedElement(), CFEqual(element, target.element),
      let application = NSRunningApplication(processIdentifier: target.processIdentifier),
      application.launchDate == target.launchDate,
      application.bundleIdentifier == target.bundleIdentifier,
      let targetWindow = target.focusedWindow
    else { return false }
    var window: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
      let window, CFGetTypeID(window) == AXUIElementGetTypeID(), CFEqual(window, targetWindow)
    else { return false }
    var subrole: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
    return (subrole as? String) != (kAXSecureTextFieldSubrole as String)
  }

  public func validate(_ target: CapturedTarget) async -> TargetValidation {
    validateSynchronously(target)
  }

  private func validateSynchronously(_ target: CapturedTarget) -> TargetValidation {
    guard AXIsProcessTrusted() else { return .rejected(.accessibilityDenied) }
    if target.delivery == .paste { return validatePaste(target) }
    guard let current = try? captureSynchronously() else { return .rejected(.focusChanged) }
    guard current.processIdentifier == target.processIdentifier,
      current.launchDate == target.launchDate,
      current.bundleIdentifier == target.bundleIdentifier
    else { return .rejected(.staleProcess) }
    guard let currentWindow = current.focusedWindow, let targetWindow = target.focusedWindow,
      CFEqual(current.element, target.element), CFEqual(currentWindow, targetWindow),
      current.comparisonContext == target.comparisonContext
    else { return .rejected(.focusChanged) }
    guard current.selectedRange.location == target.selectedRange.location,
      current.selectedRange.length == target.selectedRange.length
    else { return .rejected(.selectionChanged) }
    return .eligible
  }

  public func setSelectedText(_ text: String, on target: CapturedTarget) async throws
    -> AXDispatchResult
  {
    guard !Task.isCancelled, !text.isEmpty, text.utf8.count <= 64 * 1024,
      validateSynchronously(target) == .eligible, !Task.isCancelled
    else { return .noMutation }
    if target.delivery == .paste {
      let result = await paste(text, on: target)
      Logger(subsystem: "org.localflow.LocalFlow", category: "insertion").notice(
        "Terminal paste: \(String(describing: result), privacy: .public)")
      return result
    }
    let result = await UnicodeTextDelivery.send(
      text,
      isCurrent: { submitted in
        submitted ? matchesFocusedIdentity(target) : validateSynchronously(target) == .eligible
      },
      post: { chunk in
        guard let source = CGEventSource(stateID: .privateState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        let units = Array(chunk.utf16)
        for event in [down, up] {
          event.flags = []
          event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        // No suspension between identity validation and process-targeted dispatch.
        down.postToPid(target.processIdentifier)
        up.postToPid(target.processIdentifier)
        return true
      },
      confirm: { prefix in try await readback(prefix, on: target) })
    Logger(subsystem: "org.localflow.LocalFlow", category: "insertion").notice(
      "Native text dispatch: \(String(describing: result), privacy: .public)")
    return result
  }

  public func readback(_ text: String, on target: CapturedTarget) async throws -> String {
    guard target.delivery == .typing else { throw TargetIssue.unsupported }
    // Web editors acknowledge input asynchronously. Poll confirmation, never delivery.
    for attempt in 0..<50 {
      try Task.checkCancellation()
      guard matchesFocusedIdentity(target) else { throw TargetIssue.focusChanged }
      do {
        let value = try readbackOnce(text, on: target)
        if value == text { return value }
      } catch TargetIssue.focusChanged {
        throw TargetIssue.focusChanged
      } catch {}
      if attempt < 49 { try await Task.sleep(for: .milliseconds(10)) }
    }
    throw TargetIssue.unsupported
  }

  public func readText(on target: CapturedTarget, location: Int, length: Int) async throws
    -> String
  {
    guard AXIsProcessTrusted() else { throw TargetIssue.accessibilityDenied }
    guard target.delivery == .typing else { throw TargetIssue.unsupported }
    // Selection changes recreate the focused element in web views; the field is the same
    // as long as its application is still frontmost and the element still answers.
    guard let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.processIdentifier == target.processIdentifier,
      frontmost.launchDate == target.launchDate
    else { throw TargetIssue.focusChanged }
    guard location >= 0, length > 0, length <= 8_192, location <= Int.max - length else {
      throw TargetIssue.unsupported
    }
    if let value = Self.string(in: target.element, location: location, length: length) {
      return value
    }
    guard let element = focusedElement(), !CFEqual(element, target.element),
      let value = Self.string(in: element, location: location, length: length)
    else { throw TargetIssue.unsupported }
    return value
  }

  /// Clamps to the field's length where the app reports it, then reads the range.
  private static func string(in element: AXUIElement, location: Int, length: Int) -> String? {
    var clamped = length
    var countRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      element, kAXNumberOfCharactersAttribute as CFString, &countRaw) == .success,
      let total = countRaw as? Int
    {
      guard total > location else { return nil }
      clamped = min(length, total - location)
    }
    var range = CFRange(location: location, length: clamped)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    var raw: CFTypeRef?
    let status = AXUIElementCopyParameterizedAttributeValue(
      element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &raw)
    guard status == .success, let value = raw as? String, value.utf8.count <= 64 * 1024 else {
      return nil
    }
    return value
  }

  /// Where the delivered text must be readable, given the target's current selection.
  /// Editors such as Slate hold a zero-width placeholder character in an empty field and
  /// drop it on the first keystroke, shifting every offset captured before typing. The
  /// caret reported after typing is the only stable anchor: the text must end at a
  /// collapsed caret, or remain selected in full where the editor selects what it received.
  static func confirmationRange(length: Int, selection: CFRange) -> CFRange? {
    guard length > 0, selection.location >= 0, selection.length >= 0 else { return nil }
    if selection.length == 0 {
      guard selection.location >= length else { return nil }
      return CFRange(location: selection.location - length, length: length)
    }
    guard selection.length == length else { return nil }
    return selection
  }

  private func readbackOnce(_ text: String, on target: CapturedTarget) throws -> String {
    let length = text.utf16.count
    guard length <= 65_536 else { throw TargetIssue.unsupported }
    guard matchesFocusedIdentity(target) else { throw TargetIssue.focusChanged }
    var selectedRangeValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        target.element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
      let selectedRangeValue,
      CFGetTypeID(selectedRangeValue) == AXValueGetTypeID()
    else { throw TargetIssue.unsupported }
    var selectedRange = CFRange()
    guard AXValueGetValue(selectedRangeValue as! AXValue, .cfRange, &selectedRange) else {
      throw TargetIssue.unsupported
    }
    guard var range = Self.confirmationRange(length: length, selection: selectedRange) else {
      throw TargetIssue.selectionChanged
    }
    guard let rangeValue = AXValueCreate(.cfRange, &range) else {
      throw TargetIssue.unsupported
    }
    var raw: CFTypeRef?
    let status = AXUIElementCopyParameterizedAttributeValue(
      target.element, kAXStringForRangeParameterizedAttribute as CFString,
      rangeValue, &raw)
    guard status == .success, let value = raw as? String, value.utf8.count <= 64 * 1024 else {
      throw TargetIssue.unsupported
    }
    guard matchesFocusedIdentity(target) else { throw TargetIssue.focusChanged }
    return value
  }

  static func comparisonRange(for selection: CFRange) -> CFRange? {
    guard selection.location >= 0, selection.length >= 0, selection.length <= 4_096,
      selection.location <= Int.max - selection.length
    else { return nil }
    let start = max(0, selection.location - (4_096 - selection.length))
    return CFRange(location: start, length: selection.location - start + selection.length)
  }

  /// The frontmost terminal's focused window. Its text is never read.
  private func pasteTarget() -> CapturedTarget? {
    guard AXIsProcessTrusted(), let application = NSWorkspace.shared.frontmostApplication,
      let bundleIdentifier = application.bundleIdentifier,
      AppCategory.builtIn[bundleIdentifier] == .terminal,
      let launchDate = application.launchDate,
      let window = Self.focusedWindow(of: application.processIdentifier)
    else { return nil }
    return CapturedTarget(
      processIdentifier: application.processIdentifier, launchDate: launchDate,
      bundleIdentifier: bundleIdentifier, element: focusedElement() ?? window,
      focusedWindow: window, selectedRange: CFRange(location: 0, length: 0),
      comparisonContext: "", delivery: .paste)
  }

  private static func focusedWindow(of pid: pid_t) -> AXUIElement? {
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        bounded(AXUIElementCreateApplication(pid)), kAXFocusedWindowAttribute as CFString, &raw)
        == .success,
      let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { return nil }
    return bounded(raw as! AXUIElement)
  }

  /// Same process and window still frontmost. Secure input means a password prompt.
  private func validatePaste(_ target: CapturedTarget) -> TargetValidation {
    guard let application = NSWorkspace.shared.frontmostApplication,
      application.bundleIdentifier == target.bundleIdentifier
    else { return .rejected(.focusChanged) }
    guard application.processIdentifier == target.processIdentifier,
      application.launchDate == target.launchDate
    else { return .rejected(.staleProcess) }
    guard let targetWindow = target.focusedWindow,
      let window = Self.focusedWindow(of: target.processIdentifier),
      CFEqual(window, targetWindow)
    else { return .rejected(.focusChanged) }
    guard !IsSecureEventInputEnabled() else { return .rejected(.secureField) }
    return .eligible
  }

  /// Puts the text on the clipboard, sends Command-V to the terminal and restores the
  /// previous clipboard once the terminal has read it, unless something else wrote since.
  @MainActor private func paste(_ text: String, on target: CapturedTarget) async
    -> AXDispatchResult
  {
    let pasteboard = NSPasteboard.general
    guard let saved = PasteboardSnapshot(pasteboard) else { return .noMutation }
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    // Clipboard managers skip transient items (nspasteboard.org).
    item.setData(Data(), forType: PasteboardSnapshot.transientType)
    guard pasteboard.writeObjects([item]) else {
      saved.restore(to: pasteboard)
      return .noMutation
    }
    let written = pasteboard.changeCount
    // No suspension between validation and process-targeted dispatch.
    guard !Task.isCancelled, validatePaste(target) == .eligible,
      let source = CGEventSource(stateID: .privateState),
      let down = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
      let up = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
    else {
      saved.restore(to: pasteboard)
      return .noMutation
    }
    // Only the flag: Terminal beeps at a Command-V that also carries a Unicode string.
    for event in [down, up] { event.flags = .maskCommand }
    down.postToPid(target.processIdentifier)
    up.postToPid(target.processIdentifier)
    Task { @MainActor in
      try? await Task.sleep(for: PasteboardSnapshot.restoreDelay)
      if pasteboard.changeCount == written { saved.restore(to: pasteboard) }
    }
    return .pasted
  }

  private func makeTarget(_ element: AXUIElement) throws -> CapturedTarget? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success,
      let application = NSRunningApplication(processIdentifier: pid),
      let bundleIdentifier = application.bundleIdentifier, bundleIdentifier.utf8.count <= 255,
      let launchDate = application.launchDate
    else { return nil }
    var rangeValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
      let rangeValue,
      CFGetTypeID(rangeValue) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0,
      range.length >= 0, range.length <= 4_096,
      range.location <= Int.max - range.length
    else { return nil }
    var subroleValue: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
    if (subroleValue as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
    var windowValue: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue)
    guard let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
    let window = Self.bounded(windowValue as! AXUIElement)
    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(
        element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue
    else { return nil }
    // Retain the entire selection, never a truncated prefix of text to replace.
    guard var contextRange = Self.comparisonRange(for: range) else { return nil }
    var context = ""
    guard let contextValue = AXValueCreate(.cfRange, &contextRange) else { return nil }
    do {
      var contextRaw: CFTypeRef?
      let contextStatus = AXUIElementCopyParameterizedAttributeValue(
        element, kAXStringForRangeParameterizedAttribute as CFString,
        contextValue, &contextRaw)
      guard contextStatus == .success, let value = contextRaw as? String,
        value.utf8.count <= 4 * 1024
      else { return nil }
      context = value
    }
    return CapturedTarget(
      processIdentifier: pid, launchDate: launchDate,
      bundleIdentifier: bundleIdentifier, element: element, focusedWindow: window,
      selectedRange: range, comparisonContext: context)
  }
}

/// Native keyboard events carrying Unicode strings. No clipboard or Return-key event.
struct UnicodeTextDelivery {
  /// Per-event bound: keyboard events carry at most 20 UTF-16 units; longer strings are
  /// truncated by the event system.
  static let maximumChunkUnits = 20
  /// Chunks posted between readbacks. Focus identity is still checked before every chunk;
  /// the readback re-reads the whole delivered prefix, so it runs every `confirmationInterval`
  /// chunks and after the last one, which keeps long text linear instead of quadratic.
  static let confirmationInterval = 16
  static let minimumDeadline = Duration.seconds(10)

  /// Splits on grapheme clusters; a single cluster longer than one event is split on
  /// scalars, so surrogate pairs are never divided.
  static func chunks(_ text: String) -> [String] {
    guard !text.isEmpty, text.utf8.count <= 65_536 else { return [] }
    var result: [String] = []
    var chunk = ""
    var units = 0
    func flush() {
      if !chunk.isEmpty { result.append(chunk) }
      chunk = ""
      units = 0
    }
    for character in text {
      let count = character.utf16.count
      if count > maximumChunkUnits {
        for scalar in character.unicodeScalars {
          if units + scalar.utf16.count > maximumChunkUnits { flush() }
          chunk.unicodeScalars.append(scalar)
          units += scalar.utf16.count
        }
        continue
      }
      if units + count > maximumChunkUnits { flush() }
      chunk.append(character)
      units += count
    }
    flush()
    return result
  }

  /// Admission window for dispatch: ten seconds, or 5 ms per UTF-16 unit for long text.
  static func dispatchWindow(forUnits units: Int) -> Duration {
    max(minimumDeadline, .milliseconds(5 * max(0, units)))
  }

  @MainActor static func send(
    _ text: String,
    isCurrent: @MainActor (Bool) -> Bool,
    post: @MainActor (String) -> Bool,
    confirm: @MainActor (String) async throws -> String
  ) async -> AXDispatchResult {
    let parts = chunks(text)
    guard !parts.isEmpty else { return .noMutation }
    let deadline = ContinuousClock.now.advanced(by: dispatchWindow(forUnits: text.utf16.count))
    var submitted = false
    var prefix = ""
    for (index, part) in parts.enumerated() {
      guard !Task.isCancelled, ContinuousClock.now < deadline, isCurrent(submitted) else {
        return submitted ? .mutationMayHaveOccurred : .noMutation
      }
      guard post(part) else { return submitted ? .mutationMayHaveOccurred : .noMutation }
      submitted = true
      prefix += part
      // Confirm the caret and text periodically and at the end before trusting delivery.
      let last = index == parts.count - 1
      guard last || (index + 1) % confirmationInterval == 0 else { continue }
      guard (try? await confirm(prefix)) == prefix else { return .mutationMayHaveOccurred }
    }
    return .mutationMayHaveOccurred
  }
}

/// A bounded copy of every clipboard item, so a terminal paste can put it back.
struct PasteboardSnapshot: Sendable {
  struct Entry: Sendable {
    let type: NSPasteboard.PasteboardType
    let data: Data
  }

  static let maximumBytes = 32 * 1024 * 1024
  static let restoreDelay = Duration.seconds(1)
  static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  let items: [[Entry]]

  /// Nil when the clipboard holds more than `maximumBytes`; the paste is then skipped.
  @MainActor init?(_ pasteboard: NSPasteboard) {
    var total = 0
    var items: [[Entry]] = []
    for item in pasteboard.pasteboardItems ?? [] {
      var entries: [Entry] = []
      for type in item.types {
        guard let data = item.data(forType: type) else { continue }
        total += data.count
        guard total <= Self.maximumBytes else { return nil }
        entries.append(Entry(type: type, data: data))
      }
      items.append(entries)
    }
    self.items = items
  }

  @MainActor func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    guard !items.isEmpty else { return }
    pasteboard.writeObjects(
      items.map { entries in
        let item = NSPasteboardItem()
        for entry in entries { item.setData(entry.data, forType: entry.type) }
        return item
      })
  }
}
