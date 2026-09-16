import AppKit
import Observation
import SwiftUI

@MainActor @Observable
private final class IndicatorPresentation {
  var state: DictationSession.State = .idle
  var level: Float = 0
  @ObservationIgnored var cancel: () -> Void = {}
}

private struct IndicatorHost: View {
  let presentation: IndicatorPresentation
  var body: some View {
    DictationIndicator(
      state: presentation.state, level: presentation.level, cancel: presentation.cancel)
  }
}

// Three notification registrations at most. Removing the holder unregisters all
// callbacks, including when a panel is released without another state update.
private final class IndicatorGeometryObservers {
  private var registrations: [(NotificationCenter, NSObjectProtocol)] = []
  func add(
    center: NotificationCenter, name: Notification.Name,
    action: @escaping @Sendable (Notification) -> Void
  ) {
    registrations.append(
      (
        center,
        center.addObserver(
          forName: name, object: nil,
          queue: .main, using: action)
      ))
  }
  deinit {
    for (center, token) in registrations { center.removeObserver(token) }
  }
}

@MainActor
final class IndicatorPanel: NSPanel {
  private let presentation = IndicatorPresentation()
  private let announce: @MainActor (String) -> Void
  private var targetPoint: NSPoint?
  private var geometryObservers: IndicatorGeometryObservers?
  var observesGeometryChanges: Bool { geometryObservers != nil }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(
    announce: @escaping @MainActor (String) -> Void = { message in
      // The application remains an accessibility element after this panel hides.
      NSAccessibility.post(
        element: NSApp!, notification: .announcementRequested,
        userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
  ) {
    self.announce = announce
    super.init(
      // The trailing 35 points hold Cancel without covering the centered 118-point waveform.
      contentRect: NSRect(x: 0, y: 0, width: 153, height: 38),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    contentView = NSHostingView(rootView: IndicatorHost(presentation: presentation))
  }

  static func displayPoint(for target: CapturedTarget?) -> NSPoint? {
    guard let window = target?.focusedWindow else { return nil }
    var positionRaw: CFTypeRef?
    var sizeRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRaw)
        == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRaw) == .success,
      let positionRaw, let sizeRaw,
      CFGetTypeID(positionRaw) == AXValueGetTypeID(), CFGetTypeID(sizeRaw) == AXValueGetTypeID()
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionRaw as! AXValue, .cgPoint, &position),
      AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size),
      position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0, let primary = NSScreen.screens.first
    else { return nil }
    return NSPoint(
      x: position.x + size.width / 2,
      y: primary.frame.maxY - position.y - size.height / 2)
  }

  func update(
    state: DictationSession.State, level: Float,
    targetPoint: NSPoint? = nil, cancel: @escaping () -> Void
  ) {
    let previous = presentation.state
    presentation.state = state
    if let message = Self.announcement(from: previous, to: state) { announce(message) }
    guard Self.showsPanel(state) else {
      orderOut(nil)
      return
    }
    self.targetPoint = targetPoint
    presentation.level = level.isFinite ? min(1, max(0, level)) : 0
    presentation.cancel = cancel
    observeGeometryChanges()
    reposition()
    if !isVisible { orderFrontRegardless() }
  }

  override func orderOut(_ sender: Any?) {
    geometryObservers = nil
    targetPoint = nil
    presentation.cancel = {}
    super.orderOut(sender)
  }

  private func observeGeometryChanges() {
    guard geometryObservers == nil else { return }
    let observers = IndicatorGeometryObservers()
    let reposition: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.reposition() }
    }
    observers.add(
      center: .default, name: NSApplication.didChangeScreenParametersNotification,
      action: reposition)
    observers.add(
      center: NSWorkspace.shared.notificationCenter,
      name: NSWorkspace.activeSpaceDidChangeNotification, action: reposition)
    observers.add(
      center: NSWorkspace.shared.notificationCenter,
      name: NSWorkspace.didWakeNotification, action: reposition)
    geometryObservers = observers
  }

  private func reposition() {
    guard geometryObservers != nil else { return }
    let point = targetPoint ?? NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
      ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
    if let screen { setFrameOrigin(Self.origin(in: screen.visibleFrame)) }
  }

  static func origin(in visibleFrame: NSRect) -> NSPoint {
    NSPoint(x: visibleFrame.midX - 59, y: visibleFrame.minY + 20)
  }

  static func showsPanel(_ state: DictationSession.State) -> Bool {
    [.preparing, .recording, .transcribing, .persisting, .inserting, .cancelling].contains(state)
  }

  static func announcement(
    from previous: DictationSession.State,
    to state: DictationSession.State
  ) -> String? {
    guard previous != state else { return nil }
    switch state {
    case .preparing: return "Preparing dictation. Microphone off."
    case .recording: return "Recording."
    case .transcribing: return "Transcribing. Microphone off."
    case .persisting: return "Saving dictation."
    case .inserting: return "Inserting saved text."
    case .cancelling: return "Cancelling dictation."
    case .recovery: return "Text saved for review."
    case .failed: return "Dictation failed. Open LocalFlow for details."
    case .idle: return previous == .cancelling ? "Dictation cancelled." : "Dictation stopped."
    }
  }
}
