import Carbon
import CoreGraphics
import XCTest

@testable import LocalFlow

final class ShortcutControllerTests: XCTestCase {
  func testReleaseDuringPreparationAndRepeatedFlags() {
    var hold = ShortcutHoldState()
    XCTAssertEqual(hold.setHeld(true), .pressed)
    XCTAssertNil(hold.setHeld(true))
    XCTAssertEqual(hold.setHeld(false), .released)
    XCTAssertNil(hold.setHeld(false))
  }
  func testCombinationCancelsAndRequiresRelease() {
    var hold = ShortcutHoldState()
    _ = hold.setHeld(true)
    XCTAssertEqual(hold.cancel(), .cancelled)
    XCTAssertNil(hold.setHeld(true))
    XCTAssertNil(hold.setHeld(false))
    XCTAssertEqual(hold.setHeld(true), .pressed)
  }

  @MainActor
  func testFnCombinationEventCancelsWithoutChangingEventOrRearming() throws {
    let controller = ShortcutController()
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    let flags = try XCTUnwrap(CGEvent(source: nil))
    flags.flags = .maskSecondaryFn
    controller.receive(.flagsChanged, flags)
    flags.flags = [.maskSecondaryFn, .maskCommand]
    controller.receive(.flagsChanged, flags)
    XCTAssertEqual(flags.flags, [.maskSecondaryFn, .maskCommand])
    controller.receive(.flagsChanged, flags)
    XCTAssertEqual(events, [.pressed, .cancelled])
    flags.flags = []
    controller.receive(.flagsChanged, flags)
    flags.flags = .maskSecondaryFn
    controller.receive(.flagsChanged, flags)
    XCTAssertEqual(events, [.pressed, .cancelled, .pressed])
  }

  func testSleepCancellationKeepsReleaseRequiredUntilPhysicalRelease() {
    var hold = ShortcutHoldState()
    XCTAssertEqual(hold.setHeld(true), .pressed)
    XCTAssertEqual(hold.cancel(), .cancelled)
    XCTAssertTrue(hold.isHeld)
    XCTAssertNil(hold.setHeld(true))
    XCTAssertNil(hold.setHeld(false))
    XCTAssertFalse(hold.isHeld)
    XCTAssertEqual(hold.setHeld(true), .pressed)
  }

  func testEscapeRemainsArmedAfterReleaseAndCoalescesRepeats() {
    var state = ShortcutCancellationState()
    XCTAssertFalse(state.cancel())
    state.pressed()
    state.setSessionActive(true)
    XCTAssertTrue(state.cancel())
    XCTAssertFalse(state.cancel())
    state.setSessionActive(true)
    XCTAssertFalse(state.cancel())
    state.setSessionActive(false)
    XCTAssertFalse(state.cancel())
    state.pressed()
    XCTAssertTrue(state.cancel())
  }

  @MainActor
  func testBriefEscapeDuringPreparationRequiresReleaseBeforeRearm() throws {
    let controller = ShortcutController()
    var events: [ShortcutHoldState.Event] = []
    var cancellations = 0
    controller.onEvent = { events.append($0) }
    controller.onCancel = { cancellations += 1 }
    let flags = try XCTUnwrap(CGEvent(source: nil))
    flags.flags = .maskSecondaryFn
    controller.receive(.flagsChanged, flags)
    let escape = try XCTUnwrap(
      CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: true))
    controller.receive(.keyDown, escape)
    controller.receive(.keyDown, escape)
    controller.receive(.flagsChanged, flags)
    XCTAssertEqual(events, [.pressed])
    XCTAssertEqual(cancellations, 1)
    flags.flags = []
    controller.receive(.flagsChanged, flags)
    controller.setSessionActive(false)
    flags.flags = .maskSecondaryFn
    controller.receive(.flagsChanged, flags)
    XCTAssertEqual(events, [.pressed, .pressed])
    controller.receive(.keyDown, escape)
    XCTAssertEqual(cancellations, 2)
  }

  @MainActor
  func testEscapeDuringDecodingAndObserverLossCancelAfterRelease() throws {
    let controller = ShortcutController()
    var cancellations = 0
    controller.onCancel = { cancellations += 1 }
    let flags = try XCTUnwrap(CGEvent(source: nil))
    flags.flags = .maskSecondaryFn
    controller.receive(.flagsChanged, flags)
    flags.flags = []
    controller.receive(.flagsChanged, flags)
    controller.setSessionActive(true)
    let escape = try XCTUnwrap(
      CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: true))
    controller.receive(.keyDown, escape)
    XCTAssertEqual(cancellations, 1)
    controller.setSessionActive(false)
    controller.setSessionActive(true)
    controller.receive(.tapDisabledByTimeout, flags)
    controller.receive(.tapDisabledByUserInput, flags)
    XCTAssertEqual(cancellations, 2)
    controller.setSessionActive(false)
    controller.receive(.keyDown, escape)
    XCTAssertEqual(cancellations, 2)
  }
}

extension ShortcutControllerTests {
  func testCaptureArbitraryChordCommitsOnlyAfterAllKeysRelease() {
    var state = ShortcutCaptureState()
    XCTAssertEqual(state.receive(.flagsChanged, keyCode: 58, flags: .maskAlternate), .pending)
    XCTAssertEqual(
      state.receive(.keyDown, keyCode: 18, flags: [.maskAlternate, .maskShift]), .pending)
    XCTAssertEqual(
      state.receive(.keyUp, keyCode: 18, flags: [.maskAlternate, .maskShift]), .pending)
    let value = ShortcutPreference(
      kind: .keyCombination, keyCode: 18, modifiers: UInt32(optionKey | shiftKey))
    XCTAssertEqual(state.receive(.flagsChanged, keyCode: 58, flags: []), .captured(value))
    XCTAssertEqual(state.receive(.flagsChanged, keyCode: 58, flags: []), .pending)
  }

  func testCapturePlainKeyFnModifierChordAndEscape() {
    var key = ShortcutCaptureState()
    XCTAssertEqual(key.receive(.keyDown, keyCode: 96, flags: []), .pending)
    XCTAssertEqual(
      key.receive(.keyUp, keyCode: 96, flags: []),
      .captured(ShortcutPreference(kind: .keyCombination, keyCode: 96, modifiers: 0)))
    var fn = ShortcutCaptureState()
    XCTAssertEqual(fn.receive(.flagsChanged, keyCode: 63, flags: .maskSecondaryFn), .pending)
    XCTAssertEqual(
      fn.receive(.flagsChanged, keyCode: 63, flags: []),
      .captured(ShortcutPreference(kind: .fnGlobe, modifiers: ShortcutPreference.fnModifier)))
    var modifiers = ShortcutCaptureState()
    _ = modifiers.receive(.flagsChanged, keyCode: 55, flags: .maskCommand)
    _ = modifiers.receive(.flagsChanged, keyCode: 58, flags: [.maskCommand, .maskAlternate])
    _ = modifiers.receive(.flagsChanged, keyCode: 55, flags: .maskAlternate)
    XCTAssertEqual(
      modifiers.receive(.flagsChanged, keyCode: 58, flags: []),
      .captured(ShortcutPreference(kind: .modifierOnly, modifiers: UInt32(cmdKey | optionKey))))
    var cancel = ShortcutCaptureState()
    _ = cancel.receive(.keyDown, keyCode: 18, flags: .maskCommand)
    XCTAssertEqual(cancel.receive(.keyDown, keyCode: 53, flags: .maskCommand), .cancelled)
    XCTAssertEqual(cancel.receive(.keyUp, keyCode: 18, flags: []), .pending)
  }

  @MainActor func testPriorityConsumesMatchingDownRepeatUpButPassesUnrelatedKeys() throws {
    let value = ShortcutPreference(kind: .keyCombination, keyCode: 18, modifiers: UInt32(optionKey))
    let controller = ShortcutController(preference: value)
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true))
    down.flags = .maskAlternate
    XCTAssertTrue(controller.receive(.keyDown, down))
    down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    XCTAssertTrue(controller.receive(.keyDown, down))
    let unrelated = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 19, keyDown: true))
    unrelated.flags = .maskAlternate
    XCTAssertFalse(controller.receive(.keyDown, unrelated))
    let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: false))
    XCTAssertTrue(controller.receive(.keyUp, up))
    XCTAssertFalse(controller.receive(.keyUp, up))
    XCTAssertEqual(events, [.pressed, .released])
    down.flags = [.maskAlternate, .maskCommand]
    down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    XCTAssertFalse(controller.receive(.keyDown, down))
  }

  @MainActor func testModifierReleasedBeforeKeyStillConsumesKeyUpExactlyOnce() throws {
    let controller = ShortcutController(
      preference: ShortcutPreference(kind: .keyCombination, keyCode: 18, modifiers: UInt32(cmdKey)))
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true))
    event.flags = .maskCommand
    XCTAssertTrue(controller.receive(.keyDown, event))
    event.flags = []
    XCTAssertFalse(controller.receive(.flagsChanged, event))
    XCTAssertTrue(controller.receive(.keyUp, event))
    XCTAssertEqual(events, [.pressed, .released])
  }

  // MARK: US6 (T052): Shift on release marks the dictation local-only.

  @MainActor func testShiftHeldAtReleaseReportsTheRewriteBypass() throws {
    let controller = ShortcutController(
      preference: ShortcutPreference(kind: .keyCombination, keyCode: 18, modifiers: UInt32(cmdKey)))
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    XCTAssertTrue(controller.bypassGestureAvailable)
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true))
    event.flags = .maskCommand
    XCTAssertTrue(controller.receive(.keyDown, event))
    XCTAssertFalse(controller.releaseBypassedRewrite)
    // Shift arrives mid-hold: it neither cancels the session nor ends the hold.
    event.flags = [.maskCommand, .maskShift]
    XCTAssertFalse(controller.receive(.flagsChanged, event))
    XCTAssertEqual(events, [.pressed])
    let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: false))
    up.flags = [.maskCommand, .maskShift]
    XCTAssertTrue(controller.receive(.keyUp, up))
    XCTAssertEqual(events, [.pressed, .released])
    XCTAssertTrue(controller.releaseBypassedRewrite)
  }

  @MainActor func testReleaseWithoutShiftDoesNotBypassAndThePressPathIsUnchanged() throws {
    let controller = ShortcutController(
      preference: ShortcutPreference(kind: .keyCombination, keyCode: 18, modifiers: UInt32(cmdKey)))
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true))
    event.flags = [.maskCommand, .maskShift]
    XCTAssertTrue(controller.receive(.keyDown, event), "Shift never blocks the press")
    let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: false))
    up.flags = .maskCommand
    XCTAssertTrue(controller.receive(.keyUp, up))
    XCTAssertEqual(events, [.pressed, .released])
    XCTAssertFalse(controller.releaseBypassedRewrite)
  }

  @MainActor func testShiftInTheBindingMakesTheGestureUnavailable() throws {
    let controller = ShortcutController(
      preference: ShortcutPreference(
        kind: .keyCombination, keyCode: 18, modifiers: UInt32(cmdKey | shiftKey)))
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    XCTAssertFalse(controller.bypassGestureAvailable)
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true))
    event.flags = [.maskCommand, .maskShift]
    XCTAssertTrue(controller.receive(.keyDown, event))
    let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: false))
    up.flags = [.maskCommand, .maskShift]
    XCTAssertTrue(controller.receive(.keyUp, up))
    XCTAssertEqual(events, [.pressed, .released])
    XCTAssertFalse(controller.releaseBypassedRewrite)
  }

  @MainActor func testModifierOnlyShortcutIsNotCancelledByShift() throws {
    let controller = ShortcutController(
      preference: ShortcutPreference(kind: .modifierOnly, modifiers: UInt32(controlKey | optionKey))
    )
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    let event = try XCTUnwrap(CGEvent(source: nil))
    event.flags = [.maskControl, .maskAlternate]
    XCTAssertTrue(controller.receive(.flagsChanged, event))
    event.flags = [.maskControl, .maskAlternate, .maskShift]
    XCTAssertTrue(controller.receive(.flagsChanged, event))
    XCTAssertEqual(events, [.pressed], "Shift is transparent, so nothing is cancelled")
    event.flags = .maskShift
    XCTAssertTrue(controller.receive(.flagsChanged, event))
    XCTAssertEqual(events, [.pressed, .released])
    XCTAssertTrue(controller.releaseBypassedRewrite)
  }

  func testShortcutValidationAndPersistenceCoverNewBindings() throws {
    for value in [
      ShortcutPreference(kind: .keyCombination, keyCode: 96, modifiers: 0),
      ShortcutPreference(kind: .keyCombination, keyCode: 18, modifiers: UInt32(optionKey)),
      ShortcutPreference(kind: .modifierOnly, modifiers: UInt32(shiftKey)),
    ] {
      XCTAssertTrue(value.isValid)
      XCTAssertEqual(
        try JSONDecoder().decode(ShortcutPreference.self, from: JSONEncoder().encode(value)), value)
    }
    XCTAssertFalse(ShortcutPreference(kind: .keyCombination, keyCode: 128, modifiers: 0).isValid)
    XCTAssertFalse(ShortcutPreference(kind: .keyCombination, keyCode: 53, modifiers: 0).isValid)
    XCTAssertFalse(ShortcutPreference(kind: .modifierOnly, modifiers: 0).isValid)
  }
}

extension ShortcutControllerTests {
  func testFunctionKeysDoNotRecordAnImplicitFnModifier() {
    var state = ShortcutCaptureState()
    XCTAssertEqual(state.receive(.keyDown, keyCode: 96, flags: .maskSecondaryFn), .pending)
    XCTAssertEqual(
      state.receive(.keyUp, keyCode: 96, flags: .maskSecondaryFn),
      .captured(ShortcutPreference(kind: .keyCombination, keyCode: 96, modifiers: 0)))
    XCTAssertEqual(
      ShortcutPreference.modifiers(from: .maskSecondaryFn, keyCode: 0),
      ShortcutPreference.fnModifier)
  }
}

extension ShortcutControllerTests {
  @MainActor func testEachPhysicalModifierRecordsAndRejectsOppositeSide() throws {
    let pairs: [(UInt32, UInt32, CGEventFlags, UInt64, UInt64, String)] = [
      (58, 61, .maskAlternate, 0x20, 0x40, "Option"),
      (55, 54, .maskCommand, 0x08, 0x10, "Command"),
      (59, 62, .maskControl, 0x01, 0x2000, "Control"),
      (56, 60, .maskShift, 0x02, 0x04, "Shift"),
    ]
    for (leftKey, rightKey, generic, leftMask, rightMask, name) in pairs {
      for (key, mask, otherKey, otherMask, side) in [
        (leftKey, leftMask, rightKey, rightMask, "Left"),
        (rightKey, rightMask, leftKey, leftMask, "Right"),
      ] {
        let flags = CGEventFlags(rawValue: generic.rawValue | mask)
        var capture = ShortcutCaptureState()
        XCTAssertEqual(capture.receive(.flagsChanged, keyCode: key, flags: flags), .pending)
        guard case .captured(let value) = capture.receive(.flagsChanged, keyCode: key, flags: [])
        else {
          return XCTFail("Modifier was not captured")
        }
        XCTAssertEqual(value.title, "\(side) \(name)")
        XCTAssertTrue(value.isValid)
        XCTAssertEqual(value.deviceModifiers, mask)
        XCTAssertEqual(
          try JSONDecoder().decode(ShortcutPreference.self, from: JSONEncoder().encode(value)),
          value)
        let controller = ShortcutController(preference: value)
        var events: [ShortcutHoldState.Event] = []
        controller.onEvent = { events.append($0) }
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(otherKey))
        event.flags = CGEventFlags(rawValue: generic.rawValue | otherMask)
        XCTAssertFalse(controller.receive(.flagsChanged, event))
        XCTAssertTrue(events.isEmpty)
        event.flags = []
        XCTAssertFalse(controller.receive(.flagsChanged, event))
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
        event.flags = flags
        XCTAssertTrue(controller.receive(.flagsChanged, event))
        event.flags = []
        XCTAssertTrue(controller.receive(.flagsChanged, event))
        XCTAssertEqual(events, [.pressed, .released])
      }
    }
  }

  @MainActor func testBothOptionsDoNotMasqueradeAsRightOption() throws {
    let value = ShortcutPreference(
      kind: .modifierOnly, modifiers: UInt32(optionKey), deviceModifiers: 0x40)
    let controller = ShortcutController(preference: value)
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    let event = try XCTUnwrap(CGEvent(source: nil))
    event.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x60)
    XCTAssertFalse(controller.receive(.flagsChanged, event))
    event.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    controller.receive(.flagsChanged, event)
    XCTAssertFalse(events.contains(.pressed))
    event.flags = []
    controller.receive(.flagsChanged, event)
    event.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    controller.receive(.flagsChanged, event)
    event.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
    controller.receive(.flagsChanged, event)
    XCTAssertEqual(events.suffix(2), [.pressed, .released])
    XCTAssertFalse(value.matchesSides(event.flags))
  }

  func testBothSidesAndPhysicalKeyChordsAreCaptured() {
    let both = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x60)
    var capture = ShortcutCaptureState()
    _ = capture.receive(.flagsChanged, keyCode: 58, flags: both)
    guard case .captured(let value) = capture.receive(.flagsChanged, keyCode: 61, flags: []) else {
      return XCTFail("Both sides were not captured")
    }
    XCTAssertEqual(value.deviceModifiers, 0x60)
    XCTAssertEqual(value.title, "Left Option Right Option")
    var chord = ShortcutCaptureState()
    let right = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    _ = chord.receive(.keyDown, keyCode: 49, flags: right)
    guard case .captured(let binding) = chord.receive(.keyUp, keyCode: 49, flags: []) else {
      return XCTFail("Chord was not captured")
    }
    XCTAssertEqual(binding.title, "Right Option Space")
    XCTAssertTrue(binding.matchesSides(right))
    XCTAssertFalse(
      binding.matchesSides(CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)))
  }

  func testLegacyShortcutDecodesWithoutSideRequirement() throws {
    let data = Data(
      #"{"version":1,"kind":"modifier_only","enabled":true,"keyCode":49,"modifiers":2048}"#.utf8)
    let value = try JSONDecoder().decode(ShortcutPreference.self, from: data)
    XCTAssertNil(value.deviceModifiers)
    XCTAssertTrue(value.isValid)
    XCTAssertTrue(
      value.matchesSides(CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)))
    XCTAssertTrue(
      value.matchesSides(CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)))
    XCTAssertFalse(
      ShortcutPreference(kind: .modifierOnly, modifiers: UInt32(optionKey), deviceModifiers: 0x08)
        .isValid)
    XCTAssertFalse(
      ShortcutPreference(kind: .modifierOnly, modifiers: UInt32(optionKey), deviceModifiers: 0x8000)
        .isValid)
  }
}

extension ShortcutControllerTests {
  @MainActor func testConsumedRightOptionStaysHeldUntilPhysicalRelease() throws {
    var hardwareFlags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    let controller = ShortcutController(
      preference: ShortcutPreference(
        kind: .modifierOnly, modifiers: UInt32(optionKey), deviceModifiers: 0x40),
      flagsState: { source in source == .hidSystemState ? hardwareFlags : [] })
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    let event = try XCTUnwrap(CGEvent(source: nil))
    event.setIntegerValueField(.keyboardEventKeycode, value: 61)
    event.flags = hardwareFlags
    XCTAssertTrue(controller.receive(.flagsChanged, event))
    // Consuming the event leaves session flags empty while the hardware key is held.
    for _ in 0..<10 { controller.pollHeldShortcut() }
    XCTAssertEqual(events, [.pressed])
    hardwareFlags = []
    controller.pollHeldShortcut()
    controller.pollHeldShortcut()
    XCTAssertEqual(events, [.pressed, .cancelled])
  }
}

extension ShortcutControllerTests {
  @MainActor func testConsumedKeyCombinationPollsPhysicalKeyState() throws {
    var physicalKeyDown = true
    let controller = ShortcutController(
      preference: ShortcutPreference(
        kind: .keyCombination, keyCode: 49, modifiers: UInt32(optionKey)),
      flagsState: { _ in .maskAlternate },
      keyState: { source, key in source == .hidSystemState && key == 49 && physicalKeyDown })
    var events: [ShortcutHoldState.Event] = []
    controller.onEvent = { events.append($0) }
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
    event.flags = .maskAlternate
    XCTAssertTrue(controller.receive(.keyDown, event))
    controller.pollHeldShortcut()
    XCTAssertEqual(events, [.pressed])
    physicalKeyDown = false
    controller.pollHeldShortcut()
    XCTAssertEqual(events, [.pressed, .cancelled])
  }
}
