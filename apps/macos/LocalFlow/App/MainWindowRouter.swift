import AppKit
import Observation
import SwiftUI

enum LocalFlowPage: String, CaseIterable, Identifiable {
  case history = "Transcriptions"
  case dictionary = "Dictionary"
  case settings = "Settings"

  var id: Self { self }
  var symbol: String {
    switch self {
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
  @ObservationIgnored private weak var window: NSWindow?
  @ObservationIgnored private let activate: () -> Void
  @ObservationIgnored private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
  @ObservationIgnored private var closeObserver: MainWindowCloseObserver?

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
    }
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
