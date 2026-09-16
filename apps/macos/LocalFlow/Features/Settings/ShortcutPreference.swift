import AppKit
import Carbon
import CoreGraphics
import Foundation
import IOKit.hidsystem

struct ShortcutPreference: Codable, Equatable {
  enum Kind: String, Codable {
    case fnGlobe = "fn_globe"
    case keyCombination = "key_combination"
    case modifierOnly = "modifier_only"
  }
  var version = 1
  var kind: Kind = .fnGlobe
  var enabled = true
  var keyCode: UInt32 = 49
  var modifiers: UInt32 = UInt32(controlKey | optionKey)

  // Optional for compatibility with saved shortcuts that accept either side.
  var deviceModifiers: UInt64?

  static let sides: [(mask: UInt64, modifier: UInt32, title: String)] = [
    (UInt64(NX_DEVICELCTLKEYMASK), UInt32(controlKey), "Left Control"),
    (UInt64(NX_DEVICERCTLKEYMASK), UInt32(controlKey), "Right Control"),
    (UInt64(NX_DEVICELALTKEYMASK), UInt32(optionKey), "Left Option"),
    (UInt64(NX_DEVICERALTKEYMASK), UInt32(optionKey), "Right Option"),
    (UInt64(NX_DEVICELSHIFTKEYMASK), UInt32(shiftKey), "Left Shift"),
    (UInt64(NX_DEVICERSHIFTKEYMASK), UInt32(shiftKey), "Right Shift"),
    (UInt64(NX_DEVICELCMDKEYMASK), UInt32(cmdKey), "Left Command"),
    (UInt64(NX_DEVICERCMDKEYMASK), UInt32(cmdKey), "Right Command"),
  ]
  static let deviceMask = sides.reduce(UInt64(0)) { $0 | $1.mask }

  static func physicalModifiers(from flags: CGEventFlags) -> UInt64? {
    let value = flags.rawValue & deviceMask
    return value == 0 ? nil : value
  }

  func matchesSides(_ flags: CGEventFlags, allowingExtra: Bool = false) -> Bool {
    guard let deviceModifiers else { return true }
    let actual = flags.rawValue & Self.deviceMask
    return allowingExtra ? actual & deviceModifiers == deviceModifiers : actual == deviceModifiers
  }

  var isValid: Bool {
    if let deviceModifiers {
      guard deviceModifiers != 0, deviceModifiers & ~Self.deviceMask == 0,
        kind != .fnGlobe,
        Self.sides.allSatisfy({ deviceModifiers & $0.mask == 0 || modifiers & $0.modifier != 0 })
      else { return false }
    }
    guard version == 1, modifiers & ~Self.allowedModifiers == 0 else { return false }
    switch kind {
    case .fnGlobe: return true
    case .modifierOnly: return modifiers != 0
    case .keyCombination:
      return keyCode < 128 && !Self.modifierKeyCodes.contains(keyCode)
        && !(keyCode == 53 && modifiers == 0)
    }
  }

  static let fnModifier: UInt32 = 1 << 23
  static let allowedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey) | fnModifier
  static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
  // macOS also marks navigation/function key events with secondaryFn even when
  // the physical Fn key is up. Do not turn an ordinary F-key into an Fn chord.
  static let functionKeyCodes: [UInt32] = [
    122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
  ]
  static func modifiers(from flags: CGEventFlags, keyCode: UInt32? = nil) -> UInt32 {
    var value: UInt32 = 0
    if flags.contains(.maskCommand) { value |= UInt32(cmdKey) }
    if flags.contains(.maskControl) { value |= UInt32(controlKey) }
    if flags.contains(.maskAlternate) { value |= UInt32(optionKey) }
    if flags.contains(.maskShift) { value |= UInt32(shiftKey) }
    let implicitFn =
      keyCode.map {
        functionKeyCodes.contains($0)
          || [114, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains($0)
      } ?? false
    if flags.contains(.maskSecondaryFn) && !implicitFn { value |= fnModifier }
    return value
  }

  var title: String {
    guard enabled else { return "Disabled" }
    guard kind != .fnGlobe else { return "fn / Globe" }
    var parts: [String] = []
    for (modifier, symbol) in [
      (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
      (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘"),
    ] where modifiers & modifier != 0 {
      let names = Self.sides.filter {
        $0.modifier == modifier && (deviceModifiers ?? 0) & $0.mask != 0
      }.map(\.title)
      parts.append(contentsOf: names.isEmpty ? [symbol] : names)
    }
    if modifiers & Self.fnModifier != 0 { parts.append("fn") }
    if kind == .keyCombination { parts.append(Self.keyTitle(keyCode)) }
    return parts.joined(separator: " ")
  }

  private static func keyTitle(_ code: UInt32) -> String {
    let special: [UInt32: String] = [
      36: "Return", 48: "Tab", 49: "Space", 51: "⌫", 53: "Esc",
      65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter", 78: "−", 81: "=",
      82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
      114: "Help", 115: "Home", 116: "Page Up", 117: "⌦", 119: "End", 121: "Page Down",
      123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    if let title = special[code] { return title }
    let functions: [UInt32] = [
      122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
    if let index = functions.firstIndex(of: code) { return "F\(index + 1)" }
    let input = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
    if let raw = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) {
      let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
      let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(
        to: UCKeyboardLayout.self)
      var dead: UInt32 = 0
      var count = 0
      var chars = [UniChar](repeating: 0, count: 8)
      if UCKeyTranslate(
        layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &count, &chars) == noErr,
        count > 0
      {
        return String(utf16CodeUnits: chars, count: count).uppercased()
      }
    }
    return "Key \(code)"
  }

  static func load() -> Self {
    guard let data = UserDefaults.standard.data(forKey: "shortcut"),
      let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid
    else { return Self() }
    return value
  }
  func save() {
    guard isValid, let data = try? JSONEncoder().encode(self) else { return }
    UserDefaults.standard.set(data, forKey: "shortcut")
  }
}

/// One chord only; never accumulates typed text. Commit after key and modifiers release.
struct ShortcutCaptureState {
  enum Result: Equatable {
    case pending, cancelled
    case captured(ShortcutPreference)
  }
  private var candidate: ShortcutPreference?
  private var keyReleased = false
  private var finished = false

  mutating func receive(_ type: CGEventType, keyCode: UInt32, flags: CGEventFlags) -> Result {
    guard !finished else { return .pending }
    let modifiers = ShortcutPreference.modifiers(
      from: flags, keyCode: type == .flagsChanged ? nil : keyCode)
    if type == .keyDown && keyCode == 53 {
      finished = true
      return .cancelled
    }
    if type == .keyDown && candidate?.kind != .keyCombination {
      candidate = ShortcutPreference(
        kind: .keyCombination, keyCode: keyCode, modifiers: modifiers,
        deviceModifiers: ShortcutPreference.physicalModifiers(from: flags))
    } else if type == .flagsChanged && candidate?.kind != .keyCombination && modifiers != 0 {
      var value = candidate ?? ShortcutPreference(kind: .modifierOnly, modifiers: 0)
      value.modifiers |= modifiers
      if let physical = ShortcutPreference.physicalModifiers(from: flags) {
        value.deviceModifiers = (value.deviceModifiers ?? 0) | physical
      }
      candidate = value
    } else if type == .keyUp && candidate?.keyCode == keyCode {
      keyReleased = true
    }
    guard var value = candidate, modifiers == 0,
      value.kind == .modifierOnly || keyReleased
    else { return .pending }
    if value.kind == .modifierOnly && value.modifiers == ShortcutPreference.fnModifier {
      value.kind = .fnGlobe
    }
    guard value.isValid else { return .pending }
    finished = true
    return .captured(value)
  }
}

/// Temporary head-insert filter owns at most one chord, one timer and one observer.
@MainActor
final class ShortcutRecorder {
  static private(set) var isRecording = false
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var timer: Timer?
  private var observer: NSObjectProtocol?
  private var state = ShortcutCaptureState()
  private var finishing = false
  private let completion: (ShortcutPreference?) -> Void

  init(completion: @escaping (ShortcutPreference?) -> Void) { self.completion = completion }

  func start() throws {
    guard !Self.isRecording else { throw DictationFailure.busy }
    guard AXIsProcessTrusted() else { throw ShortcutController.Failure.accessibilityRequired }
    let mask =
      (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, context in
          guard let context else { return Unmanaged.passUnretained(event) }
          let consume = MainActor.assumeIsolated {
            let recorder = Unmanaged<ShortcutRecorder>.fromOpaque(context).takeUnretainedValue()
            guard NSApp.isActive else {
              recorder.finish(nil)
              return false
            }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
              recorder.finish(nil)
              return false
            }
            switch recorder.state.receive(
              type, keyCode: UInt32(event.getIntegerValueField(.keyboardEventKeycode)),
              flags: event.flags)
            {
            case .pending: break
            case .cancelled: recorder.finish(nil)
            case .captured(let value): recorder.finish(value)
            }
            return true
          }
          return consume ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else {
      throw ShortcutController.Failure.unavailable
    }
    Self.isRecording = true
    self.tap = tap
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.finish(nil) }
    }
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.finish(nil) }
    }
  }

  private func finish(_ value: ShortcutPreference?) {
    guard !finishing else { return }
    finishing = true
    Task { @MainActor [weak self] in
      guard let self, self.tap != nil else { return }
      self.stop()
      self.completion(value)
    }
  }

  func stop() {
    if tap != nil { Self.isRecording = false }
    if let tap { CFMachPortInvalidate(tap) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    tap = nil
    source = nil
    timer?.invalidate()
    timer = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }
}
