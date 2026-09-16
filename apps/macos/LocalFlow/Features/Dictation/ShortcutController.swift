import AppKit
import Carbon
import CoreGraphics
import OSLog

struct ShortcutHoldState {
  enum Event: Equatable { case pressed, released, cancelled }
  private var held = false
  private var releaseRequired = false
  var isHeld: Bool { held }
  mutating func setHeld(_ value: Bool) -> Event? {
    guard value != held else { return nil }
    held = value
    if !value {
      if releaseRequired {
        releaseRequired = false
        return nil
      }
      return .released
    }
    return releaseRequired ? nil : .pressed
  }
  mutating func cancel() -> Event? {
    guard held, !releaseRequired else { return nil }
    releaseRequired = true
    return .cancelled
  }
}

// Bounded state only: key contents are neither retained nor logged. A release ends
// capture, but Escape remains armed until the coordinator ends the session.
struct ShortcutCancellationState {
  private var active = false
  private var cancelled = false

  mutating func pressed() {
    guard !active else { return }
    active = true
    cancelled = false
  }
  mutating func setSessionActive(_ value: Bool) {
    active = value
    if !value { cancelled = false }
  }
  mutating func cancel() -> Bool {
    guard active, !cancelled else { return false }
    cancelled = true
    return true
  }
}

@MainActor
final class ShortcutController {
  enum Failure: Error {
    case permissionDenied, accessibilityRequired, unavailable, conflict, invalidBinding
  }
  var onEvent: ((ShortcutHoldState.Event) -> Void)?
  var onCancel: (() -> Void)?
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "shortcut")
  private var cancellation = ShortcutCancellationState()
  private var hold = ShortcutHoldState()
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var monitor: Timer?
  private var sleepObserver: NSObjectProtocol?
  private var preference = ShortcutPreference()
  private var priorityActive = false
  private var consumedKey = false

  private let flagsState: (CGEventSourceStateID) -> CGEventFlags
  private let keyState: (CGEventSourceStateID, CGKeyCode) -> Bool

  init(
    preference: ShortcutPreference = .init(),
    flagsState: @escaping (CGEventSourceStateID) -> CGEventFlags = { CGEventSource.flagsState($0) },
    keyState: @escaping (CGEventSourceStateID, CGKeyCode) -> Bool = {
      CGEventSource.keyState($0, key: $1)
    }
  ) {
    self.preference = preference
    self.flagsState = flagsState
    self.keyState = keyState
  }

  var isAvailable: Bool {
    preference.enabled && CGPreflightListenEventAccess()
      && (!priorityActive || AXIsProcessTrusted())
      && tap.map { CGEvent.tapIsEnabled(tap: $0) } == true
  }

  func install(_ preference: ShortcutPreference) throws {
    guard preference.isValid else { throw Failure.invalidBinding }
    if !preference.enabled {
      remove()
      self.preference = preference
      return
    }
    guard CGPreflightListenEventAccess() else { throw Failure.permissionDenied }
    let priority = AXIsProcessTrusted()
    guard priority || preference.kind == .fnGlobe else { throw Failure.accessibilityRequired }
    let mask =
      (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.keyUp.rawValue)
    guard
      let newTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: priority ? .defaultTap : .listenOnly,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, context in
          guard let context else { return Unmanaged.passUnretained(event) }
          let consume = MainActor.assumeIsolated {
            if ShortcutRecorder.isRecording && NSApp.isActive { return false }
            let controller = Unmanaged<ShortcutController>.fromOpaque(context).takeUnretainedValue()
            let consume = controller.receive(type, event)
            return consume && controller.priorityActive
          }
          return consume ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { throw Failure.unavailable }
    guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
      CFMachPortInvalidate(newTap)
      throw Failure.unavailable
    }
    // Nothing replaces the working binding until every new resource exists.
    var installed = false
    defer { if !installed { CFMachPortInvalidate(newTap) } }
    remove()
    priorityActive = priority
    consumedKey = false
    tap = newTap
    source = newSource
    CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
    CGEvent.tapEnable(tap: newTap, enable: true)
    installed = true
    self.preference = preference
    hold = ShortcutHoldState()
    cancellation = ShortcutCancellationState()
    sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.cancelHeldSession(reason: "system sleep") }
    }
    // The timer detects lost key-up events without installing another event tap.
    monitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if !CGPreflightListenEventAccess() {
          self.cancelHeldSession(reason: "Input Monitoring permission lost")
        } else if self.priorityActive && !AXIsProcessTrusted() {
          self.cancelHeldSession(reason: "Accessibility permission lost")
        } else if IsSecureEventInputEnabled() {
          self.cancelHeldSession(reason: "secure input enabled")
        } else if self.tap.map({ !CGEvent.tapIsEnabled(tap: $0) }) == true {
          self.cancelHeldSession(reason: "event tap disabled during polling")
        } else {
          self.pollHeldShortcut()
        }
      }
    }
  }

  /// Returns true only for events belonging to this binding. No key text is read.
  @discardableResult
  func receive(_ type: CGEventType, _ event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      cancelHeldSession(
        reason: type == .tapDisabledByTimeout ? "event tap timeout" : "event tap disabled")
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return false
    }
    let key = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = ShortcutPreference.modifiers(
      from: event.flags, keyCode: type == .flagsChanged ? nil : key)
    if type == .keyDown && key == UInt32(kVK_Escape) {
      cancelHeldSession(reason: "Escape")
      return false
    }
    if preference.kind == .keyCombination {
      if key == preference.keyCode && type == .keyUp && consumedKey {
        consumedKey = false
        emit(hold.setHeld(false))
        return true
      }
      if key == preference.keyCode && type == .keyDown {
        if consumedKey { return true }
        guard modifiers == preference.modifiers, preference.matchesSides(event.flags),
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        else { return false }
        consumedKey = true
        emit(hold.setHeld(true))
        return true
      }
      if type == .flagsChanged && hold.isHeld
        && (modifiers != preference.modifiers || !preference.matchesSides(event.flags))
      {
        emit(hold.setHeld(false))
      }
      return false
    }
    let required =
      preference.kind == .fnGlobe ? ShortcutPreference.fnModifier : preference.modifiers
    if type == .flagsChanged {
      let wasHeld = hold.isHeld
      if modifiers == required && preference.matchesSides(event.flags) {
        emit(hold.setHeld(true))
        return true
      }
      if modifiers & required == required
        && preference.matchesSides(event.flags, allowingExtra: true)
      {
        _ = hold.setHeld(true)
        emit(hold.cancel())
        return false
      }
      emit(hold.setHeld(false))
      return wasHeld
    }
    if type == .keyDown { emit(hold.cancel()) }
    return false
  }
  private func emit(_ event: ShortcutHoldState.Event?) {
    guard let event else { return }
    logger.notice("Shortcut event: \(String(describing: event), privacy: .public)")
    if event == .pressed { cancellation.pressed() }
    if event == .cancelled { _ = cancellation.cancel() }
    onEvent?(event)
  }

  func setSessionActive(_ active: Bool) { cancellation.setSessionActive(active) }
  /// Polling is a cancellation backstop for a missed physical key release.
  func pollHeldShortcut() {
    guard hold.isHeld else { return }
    // The session tap consumes our binding, so combined session state can say
    // "released" while the physical key is still held. Query before filtering.
    let flags = flagsState(.hidSystemState)
    let down: Bool
    if preference.kind == .fnGlobe {
      down = flags.contains(.maskSecondaryFn)
    } else {
      down =
        ShortcutPreference.modifiers(
          from: flags, keyCode: preference.kind == .keyCombination ? preference.keyCode : nil)
        == preference.modifiers && preference.matchesSides(flags)
        && (preference.kind == .modifierOnly
          || keyState(.hidSystemState, CGKeyCode(preference.keyCode)))
    }
    guard !down else { return }
    logger.notice("Shortcut cancelled: physical shortcut released without matching event")
    emit(hold.cancel())
    _ = hold.setHeld(false)
  }
  func cancelHeldSession(reason: String = "controller reset") {
    _ = hold.cancel()
    if cancellation.cancel() {
      logger.notice("Shortcut cancelled: \(reason, privacy: .public)")
      onCancel?()
    }
  }
  func remove() {
    monitor?.invalidate()
    monitor = nil
    if let sleepObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
      self.sleepObserver = nil
    }
    if let tap { CFMachPortInvalidate(tap) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    tap = nil
    source = nil
    cancelHeldSession()
  }
}
