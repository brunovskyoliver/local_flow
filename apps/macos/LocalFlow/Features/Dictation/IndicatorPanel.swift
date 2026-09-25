import AppKit
import Observation
import SwiftUI

@MainActor @Observable
private final class IndicatorPresentation {
  var state: DictationSession.State = .idle
  var level: Float = 0
  var notice: LearnedNotice?
  var actionNotice: RewriteActionNotice?
  var clipboard: ClipboardNotice?
  var background: BackgroundNotice?
  @ObservationIgnored var cancel: () -> Void = {}
  @ObservationIgnored var undo: () -> Void = {}
  @ObservationIgnored var action: () -> Void = {}
  @ObservationIgnored var open: () -> Void = {}
  @ObservationIgnored var hideBackground: () -> Void = {}
  @ObservationIgnored var dismissClipboard: () -> Void = {}

  /// What the pill shows, in the host's order of precedence. The key changes only
  /// when a different notice takes the pill, so progress updates animate in place.
  enum Content: Hashable {
    case dictation
    case learned(String)
    case clipboard(UUID)
    case action(UUID)
    case background(UUID)
    case none
  }
  var content: Content {
    if IndicatorPanel.showsPanel(state) { return .dictation }
    if let notice { return .learned(notice.entryID) }
    if let clipboard { return .clipboard(clipboard.id) }
    if let actionNotice { return .action(actionNotice.id) }
    if let background { return .background(background.id) }
    return .none
  }
}

/// Dictation states win, then the dictation notices, then background work. A new
/// notice scales up out of the old one's place; the panel follows its size.
private struct IndicatorHost: View {
  let presentation: IndicatorPresentation
  let sizeChanged: (CGSize) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      switch presentation.content {
      case .dictation:
        DictationIndicator(
          state: presentation.state, level: presentation.level, cancel: presentation.cancel
        ).transition(transition)
      case .learned:
        if let notice = presentation.notice {
          LearnedNoticeView(notice: notice, undo: presentation.undo).id(notice.entryID)
            .transition(transition)
        }
      case .clipboard:
        if let notice = presentation.clipboard {
          ClipboardNoticeView(notice: notice, dismiss: presentation.dismissClipboard)
            .id(notice.id).transition(transition)
        }
      case .action:
        if let notice = presentation.actionNotice {
          ActionNoticeView(
            message: notice.message, actionTitle: notice.canRetry ? "Retry" : nil,
            actionIdentifier: "rewrite.notice.retry", action: presentation.action
          ).id(notice.id).transition(transition)
        }
      case .background:
        if let notice = presentation.background {
          BackgroundNoticeView(
            notice: notice, open: presentation.open, hide: presentation.hideBackground
          ).id(notice.id).transition(transition)
        }
      case .none:
        EmptyView()
      }
    }
    .animation(reduceMotion ? nil : PillStyle.swap, value: presentation.content)
    .onGeometryChange(for: CGSize.self, of: \.size, action: sizeChanged)
  }

  private var transition: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(
        insertion: .scale(scale: 0.88).combined(with: .opacity),
        removal: .opacity.animation(.easeOut(duration: 0.1)))
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

/// The pill at the bottom of the screen. It hugs whatever it shows: the content view
/// reports its size and the panel resizes around it, staying centered.
@MainActor
final class IndicatorPanel: NSPanel {
  static let height: CGFloat = 38
  /// The waveform is 118 points wide with Cancel in the trailing 35; the waveform is
  /// what sits on the screen's center line.
  static let indicatorWidth: CGFloat = 153
  static let indicatorVisualCenter: CGFloat = 59
  private static let showDuration: TimeInterval = 0.3
  private static let hideDuration: TimeInterval = 0.18
  private static let resizeDuration: TimeInterval = 0.32
  private static let rise: CGFloat = 10
  /// Fast out, long settle: the window's stand-in for the pill's spring.
  private static let settle = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

  private let presentation = IndicatorPresentation()
  private let announce: @MainActor (String) -> Void
  private let animated: Bool
  private var targetPoint: NSPoint?
  private var geometryObservers: IndicatorGeometryObservers?
  private var contentSize = NSSize(
    width: IndicatorPanel.indicatorWidth, height: IndicatorPanel.height)
  private var hiding = false
  private static let hiddenBackgroundGrace: Duration = .seconds(10)
  private var hiddenBackgroundIDs: Set<UUID> = []
  private var hiddenBackgroundReset: Task<Void, Never>?
  private var clipboardDismissal: Task<Void, Never>?
  /// True while the main window is focused: background work is on screen there already.
  var suppressesBackgroundNotice = false {
    didSet { if oldValue != suppressesBackgroundNotice { refresh() } }
  }
  var observesGeometryChanges: Bool { geometryObservers != nil }
  /// Full layout passes, for tests of the level-only path.
  private(set) var presentCount = 0
  var showsBackgroundNotice: Bool { isVisible && !hiding && Self.showsBackground(presentation) }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(
    animated: Bool = true,
    announce: @escaping @MainActor (String) -> Void = { message in
      // The application remains an accessibility element after this panel hides.
      NSAccessibility.post(
        element: NSApp!, notification: .announcementRequested,
        userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
  ) {
    self.announce = announce
    self.animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: Self.indicatorWidth, height: Self.height),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    animationBehavior = .none
    let hosting = NSHostingView(
      rootView: IndicatorHost(presentation: presentation) { [weak self] size in
        self?.contentDidResize(to: size)
      })
    hosting.sizingOptions = []
    contentView = hosting
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
    if Self.showsPanel(state) {
      self.targetPoint = targetPoint
      presentation.level = level.isFinite ? min(1, max(0, level)) : 0
      presentation.cancel = cancel
    }
    refresh()
  }

  /// Per-frame meter update. When the pill is already on screen in the same state
  /// at the same target, only the level changes: no relayout, fitting-size pass or
  /// frame change. Anything else takes the full `update` path.
  func updateLevel(
    _ level: Float, state: DictationSession.State, targetPoint: NSPoint? = nil,
    cancel: @escaping () -> Void
  ) {
    guard isVisible, !hiding, presentation.state == state, Self.showsPanel(state),
      self.targetPoint == targetPoint
    else {
      update(state: state, level: level, targetPoint: targetPoint, cancel: cancel)
      return
    }
    let clamped = level.isFinite ? min(1, max(0, level)) : 0
    if presentation.level != clamped { presentation.level = clamped }
    presentation.cancel = cancel
  }

  /// The learned-correction bubble uses the same panel; dictation states take precedence.
  func showNotice(_ notice: LearnedNotice?, targetPoint: NSPoint? = nil, undo: @escaping () -> Void)
  {
    let previous = presentation.notice
    presentation.notice = notice
    presentation.undo = undo
    if let notice, previous?.entryID != notice.entryID {
      announce("Added \(notice.canonical) to dictionary.")
    }
    if let targetPoint, notice != nil { self.targetPoint = targetPoint }
    refresh()
  }

  /// A rewrite notice with one action (Retry). The learned-correction bubble
  /// and dictation states take precedence; the message is announced once.
  func showActionNotice(
    _ notice: RewriteActionNotice?, targetPoint: NSPoint? = nil, action: @escaping () -> Void
  ) {
    let previous = presentation.actionNotice
    presentation.actionNotice = notice
    presentation.action = action
    if let notice, previous?.id != notice.id { announce(notice.message) }
    if let targetPoint, notice != nil { self.targetPoint = targetPoint }
    refresh()
  }

  /// Clears the action notice only if it is still the one with `id`.
  func dismissActionNotice(id: UUID) {
    guard presentation.actionNotice?.id == id else { return }
    presentation.actionNotice = nil
    presentation.action = {}
    refresh()
  }

  /// Background work (finalizing, labeling). Lowest precedence; hidden while the main
  /// window is focused. Clicking the pill calls `open`.
  /// A hidden notice stays hidden while its work runs (a meeting's finalizing,
  /// labeling and summarizing share its id) and returns with the next piece of work.
  func showBackgroundNotice(_ notice: BackgroundNotice?, open: @escaping () -> Void) {
    let previous = presentation.background
    let visible = notice.flatMap { hiddenBackgroundIDs.contains($0.id) ? nil : $0 }
    presentation.background = visible
    presentation.open = open
    presentation.hideBackground = { [weak self] in self?.hideBackgroundNotice() }
    if let visible, previous?.id != visible.id { announce(visible.text) }
    forgetHiddenBackground(when: notice == nil)
    refresh()
  }

  /// Hides the current background notice until its work is done.
  func hideBackgroundNotice() {
    guard let notice = presentation.background else { return }
    hiddenBackgroundIDs.insert(notice.id)
    presentation.background = nil
    announce("Progress hidden. It stays in LocalFlow.")
    refresh()
  }

  /// Stages of one meeting's work can leave short gaps with nothing running; only a
  /// quiet spell means the work is done and hidden notices may return.
  private func forgetHiddenBackground(when idle: Bool) {
    hiddenBackgroundReset?.cancel()
    hiddenBackgroundReset = nil
    guard idle, !hiddenBackgroundIDs.isEmpty else { return }
    hiddenBackgroundReset = Task { [weak self] in
      do { try await Task.sleep(for: Self.hiddenBackgroundGrace) } catch { return }
      self?.hiddenBackgroundIDs.removeAll()
    }
  }

  /// Dictated text that did not land and is on the clipboard now. It clears itself
  /// after `ClipboardNotice.visibleFor`, or when its keycap is clicked.
  func showClipboardNotice(_ notice: ClipboardNotice?, targetPoint: NSPoint? = nil) {
    let previous = presentation.clipboard
    presentation.clipboard = notice
    clipboardDismissal?.cancel()
    clipboardDismissal = nil
    if let notice {
      if previous?.id != notice.id { announce("\(notice.message). Paste with Command-V.") }
      if let targetPoint { self.targetPoint = targetPoint }
      presentation.dismissClipboard = { [weak self] in self?.dismissClipboardNotice(id: notice.id) }
      clipboardDismissal = Task { [weak self] in
        do { try await Task.sleep(for: ClipboardNotice.visibleFor) } catch { return }
        self?.dismissClipboardNotice(id: notice.id)
      }
    }
    refresh()
  }

  /// Clears the clipboard notice only if it is still the one with `id`.
  func dismissClipboardNotice(id: UUID) {
    guard presentation.clipboard?.id == id else { return }
    clipboardDismissal?.cancel()
    clipboardDismissal = nil
    presentation.clipboard = nil
    presentation.dismissClipboard = {}
    refresh()
  }

  private static func showsBackground(_ presentation: IndicatorPresentation) -> Bool {
    !showsPanel(presentation.state) && presentation.notice == nil
      && presentation.clipboard == nil && presentation.actionNotice == nil
      && presentation.background != nil
  }

  /// One place decides what is on screen, in the host's order of precedence.
  private func refresh() {
    let showsWork =
      Self.showsPanel(presentation.state) || presentation.notice != nil
      || presentation.clipboard != nil || presentation.actionNotice != nil
    if showsWork || (Self.showsBackground(presentation) && !suppressesBackgroundNotice) {
      present()
    } else {
      hide()
    }
  }

  /// The content reported a new size: the panel wraps it and re-centers.
  private func contentDidResize(to size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    let rounded = NSSize(width: ceil(size.width), height: ceil(size.height))
    guard rounded != contentSize else { return }
    contentSize = rounded
    guard isVisible, !hiding else { return }
    layoutFrame(animated: animated)
  }

  private func present() {
    presentCount &+= 1
    observeGeometryChanges()
    if let hosting = contentView as? NSHostingView<IndicatorHost> {
      // The first layout after a content change; the geometry callback corrects later ones.
      hosting.layoutSubtreeIfNeeded()
      let fitting = hosting.fittingSize
      if fitting.width > 0, fitting.height > 0 {
        contentSize = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
      }
    }
    if isVisible && !hiding {
      layoutFrame(animated: animated)
      return
    }
    hiding = false
    let target = targetFrame()
    guard animated else {
      alphaValue = 1
      setFrame(target, display: true)
      orderFrontRegardless()
      return
    }
    alphaValue = 0
    setFrame(target.offsetBy(dx: 0, dy: -Self.rise), display: false)
    orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.showDuration
      context.timingFunction = Self.settle
      animator().alphaValue = 1
      animator().setFrame(target, display: true)
    }
  }

  private func hide() {
    guard isVisible, !hiding else { return }
    guard animated else {
      orderOut(nil)
      return
    }
    hiding = true
    let sunk = frame.offsetBy(dx: 0, dy: -Self.rise)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.hideDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animator().alphaValue = 0
      animator().setFrame(sunk, display: true)
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.hiding else { return }
        self.hiding = false
        self.orderOut(nil)
      }
    }
  }

  override func orderOut(_ sender: Any?) {
    geometryObservers = nil
    targetPoint = nil
    hiding = false
    presentation.cancel = {}
    presentation.undo = {}
    presentation.action = {}
    presentation.open = {}
    presentation.hideBackground = {}
    presentation.dismissClipboard = {}
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
    layoutFrame(animated: false)
  }

  private func layoutFrame(animated: Bool) {
    let target = targetFrame()
    guard target != frame else { return }
    guard animated else {
      setFrame(target, display: true)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.resizeDuration
      context.timingFunction = Self.settle
      animator().setFrame(target, display: true)
    }
  }

  private func targetFrame() -> NSRect {
    let point = targetPoint ?? NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
      ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: contentSize)
    let centered = Self.showsPanel(presentation.state) ? Self.indicatorVisualCenter : nil
    return NSRect(
      origin: Self.origin(in: visible, width: contentSize.width, visualCenter: centered),
      size: contentSize)
  }

  /// Bottom-centered on the visible frame. `visualCenter` is the point inside the
  /// content that should sit on the center line (the waveform's middle); nil centers
  /// the whole width.
  static func origin(
    in visibleFrame: NSRect, width: CGFloat = IndicatorPanel.indicatorWidth,
    visualCenter: CGFloat? = IndicatorPanel.indicatorVisualCenter
  ) -> NSPoint {
    let center = visualCenter ?? width / 2
    return NSPoint(x: (visibleFrame.midX - center).rounded(), y: visibleFrame.minY + 20)
  }

  static func showsPanel(_ state: DictationSession.State) -> Bool {
    [.preparing, .recording, .transcribing, .persisting, .rewriting, .inserting, .cancelling]
      .contains(state)
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
    case .rewriting: return "Rewriting text. Microphone off."
    case .inserting: return "Inserting saved text."
    case .cancelling: return "Cancelling dictation."
    case .recovery: return "Text saved for review."
    case .failed: return "Dictation failed. Open LocalFlow for details."
    case .idle: return previous == .cancelling ? "Dictation cancelled." : "Dictation stopped."
    }
  }
}
