import AppKit
import Observation
import SwiftUI

enum LocalFlowPage: String, CaseIterable, Identifiable {
  case meetings = "Notetaker"
  case history = "Transcriptions"
  case dictionary = "Dictionary"
  case settings = "Settings"

  var id: Self { self }
  var symbol: String {
    switch self {
    case .meetings: "record.circle"
    case .history: "list.bullet.rectangle"
    case .dictionary: "character.book.closed"
    case .settings: "gearshape"
    }
  }
}

/// Window visibility never owns capture or model lifetime.
@MainActor @Observable
final class MainWindowRouter {
  var selection: LocalFlowPage = .history
  /// True while the main window is key and the app is active: whatever the
  /// background pill would say is already on screen.
  private(set) var isMainWindowFocused = false
  /// Set by the scene so services can open the window without an environment.
  @ObservationIgnored var openMainWindow: () -> Void = {}
  @ObservationIgnored private weak var window: NSWindow?
  @ObservationIgnored private let activate: () -> Void
  @ObservationIgnored private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
  @ObservationIgnored private var closeObserver: MainWindowCloseObserver?
  @ObservationIgnored private var focusObservers: [NSObjectProtocol] = []

  init(
    setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = {
      NSApp.setActivationPolicy($0)
    },
    activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }
  ) {
    self.setActivationPolicy = setActivationPolicy
    self.activate = activate
  }

  func attach(_ window: NSWindow) {
    window.identifier = NSUserInterfaceItemIdentifier("localflow.main")
    guard self.window !== window else { return }
    self.window = window
    setActivationPolicy(.regular)
    closeObserver = MainWindowCloseObserver(window: window) { [weak self] in
      self?.setActivationPolicy(.accessory)
      self?.refreshFocus()
    }
    observeFocus(window)
    refreshFocus()
  }

  /// Opens the window from anywhere (the pill, the menu bar) using the scene's opener.
  func show(_ destination: LocalFlowPage? = nil) {
    open(destination, openWindow: openMainWindow)
  }

  private func observeFocus(_ window: NSWindow) {
    for token in focusObservers { NotificationCenter.default.removeObserver(token) }
    let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshFocus() }
    }
    focusObservers = [
      (NSWindow.didBecomeKeyNotification, window as AnyObject?),
      (NSWindow.didResignKeyNotification, window as AnyObject?),
      (NSWindow.didMiniaturizeNotification, window as AnyObject?),
      (NSWindow.didDeminiaturizeNotification, window as AnyObject?),
      (NSApplication.didBecomeActiveNotification, nil),
      (NSApplication.didResignActiveNotification, nil),
    ].map { name, object in
      NotificationCenter.default.addObserver(
        forName: name, object: object, queue: .main, using: refresh)
    }
  }

  private func refreshFocus() {
    let focused =
      window.map { $0.isVisible && $0.isKeyWindow && !$0.isMiniaturized } ?? false
      && NSApp?.isActive == true
    if focused != isMainWindowFocused { isMainWindowFocused = focused }
  }

  func open(_ destination: LocalFlowPage? = nil, openWindow: () -> Void) {
    if let destination { selection = destination }
    setActivationPolicy(.regular)
    openWindow()
    window?.deminiaturize(nil)
    window?.makeKeyAndOrderFront(nil)
    activate()
  }

  /// Dock clicks restore the existing main window, including a minimized window.
  func reopen() -> Bool {
    guard window != nil else { return false }
    open(openWindow: {})
    return true
  }
}

private final class MainWindowCloseObserver {
  private var token: NSObjectProtocol?

  @MainActor init(window: NSWindow, closed: @escaping @MainActor @Sendable () -> Void) {
    token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in
      MainActor.assumeIsolated { closed() }
    }
  }

  deinit {
    if let token { NotificationCenter.default.removeObserver(token) }
  }
}

struct MainWindowAttachment: NSViewRepresentable {
  let router: MainWindowRouter

  func makeNSView(context: Context) -> AttachmentView {
    AttachmentView(router: router)
  }
  func updateNSView(_ nsView: AttachmentView, context: Context) {}

  final class AttachmentView: NSView {
    let router: MainWindowRouter
    init(router: MainWindowRouter) {
      self.router = router
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { router.attach(window) }
    }
  }
}
