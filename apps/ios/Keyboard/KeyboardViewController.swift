import SwiftUI
import UIKit

/// The LocalFlow keyboard. It links neither package target and makes no network call;
/// it only reads and writes the handoff files and rings the bells.
final class KeyboardViewController: UIInputViewController, KeyboardHost {
  private var model: KeyboardSessionModel!
  private var hosting: UIHostingController<KeyboardView>?
  private let store = HandoffStore.group()
  private var restReading: DispatchWorkItem?
  private var sampler: Timer?
  /// SC-003: peak `phys_footprint` seen while each surface was up, for the life of the
  /// keyboard process. Sampled once a second, so a spike shorter than that can be missed.
  private static var restPeak: UInt64 = 0
  private static var listeningPeak: UInt64 = 0

  override func viewDidLoad() {
    super.viewDidLoad()
    SottoFonts.register(bundle: Bundle(for: Self.self))
    model = KeyboardSessionModel(hasFullAccess: hasFullAccess, store: store)
    model.host = self
    let doorbell = Doorbell.shared
    doorbell.observe(.pong) { [weak self] in self?.model.pong() }
    doorbell.observe(.session) { [weak self] in self?.model.refresh() }
    doorbell.observe(.result) { [weak self] in self?.model.checkResult() }
    // One height for the keys and the listening view; 999 so the system can still win
    // during rotation without a constraint conflict (research R10).
    let height = view.heightAnchor.constraint(equalToConstant: KeyboardView.height)
    height.priority = UILayoutPriority(999)
    height.isActive = true
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // One hosting controller while visible; released on disappear (research R11).
    let view = KeyboardView(
      model: model, levels: store.map(LevelsReader.init),
      needsGlobe: needsInputModeSwitchKey,
      actions: .init(
        tap: { [weak self] in self?.tap() },
        settings: { [weak self] in self?.openSettings() },
        space: { [weak self] in self?.textDocumentProxy.insertText(" ") },
        delete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
        newline: { [weak self] in self?.textDocumentProxy.insertText("\n") },
        character: { [weak self] in self?.textDocumentProxy.insertText($0) },
        nextKeyboard: { [weak self] in self?.advanceToNextInputMode() }))
    let hosting = UIHostingController(rootView: view)
    hosting.view.backgroundColor = .clear
    addChild(hosting)
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    self.view.addSubview(hosting.view)
    NSLayoutConstraint.activate([
      hosting.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
      hosting.view.topAnchor.constraint(equalTo: self.view.topAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
    ])
    hosting.didMove(toParent: self)
    self.hosting = hosting
    model.appear()
    writeStatus()
    // SC-004 "at rest": once the keyboard has settled, before the owner taps anything.
    let rest = DispatchWorkItem { [weak self] in self?.writeStatus() }
    restReading = rest
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: rest)
    sampler = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.sampleFootprint() }
    }
  }

  /// A dismissed keyboard never leaves a recording without a visible owner (FR-026).
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    model.stop()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    restReading?.cancel()
    restReading = nil
    sampler?.invalidate()
    sampler = nil
    model.disappear()
    hosting?.willMove(toParent: nil)
    hosting?.view.removeFromSuperview()
    hosting?.removeFromParent()
    hosting = nil
    writeStatus()
  }

  override func textDidChange(_ textInput: (any UITextInput)?) {
    super.textDidChange(textInput)
    model.textDidChange()
  }

  private func tap() {
    guard case .openApp(let url) = model.tap() else { return }
    open(url)
  }

  private func openSettings() {
    guard case .openApp(let url) = model.openSettings() else { return }
    open(url)
  }

  private func open(_ url: URL) {
    // Research R6: the public UIApplication.open(_:options:completionHandler:), reached
    // through the responder chain. Extensions must build extension-API-only, so the call
    // goes through the runtime instead of the compile-time declaration.
    typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = self
    while let current = responder {
      if current.isKind(of: UIApplication.self), current.responds(to: selector) {
        let open = unsafeBitCast(current.method(for: selector), to: Open.self)
        open(current, selector, url as NSURL, [:] as NSDictionary, nil)
        return
      }
      responder = current.next
    }
  }

  /// The listening view covers every surface but the keys (listening, transcribing, notices).
  private func sampleFootprint() {
    let current = Footprint.read().current
    if model.surface == .keys {
      guard current > Self.restPeak else { return }
      Self.restPeak = current
    } else {
      guard current > Self.listeningPeak else { return }
      Self.listeningPeak = current
    }
    writeStatus()
  }

  /// SC-003/SC-004: the keyboard's own footprint and peaks, for the app's diagnostics screen.
  private func writeStatus() {
    guard hasFullAccess, let store else { return }
    let footprint = Footprint.read()
    try? store.write(
      KeyboardStatusFile(
        hasFullAccess: true, lastSeen: Handoff.milliseconds(Date()),
        peakFootprintBytes: footprint.peak, footprintBytes: footprint.current,
        footprintRestBytes: Self.restPeak > 0 ? Self.restPeak : nil,
        footprintListeningBytes: Self.listeningPeak > 0 ? Self.listeningPeak : nil),
      .keyboardStatus)
  }

  // MARK: KeyboardHost

  var documentID: UUID? { textDocumentProxy.documentIdentifier }
  var contextBefore: String? { textDocumentProxy.documentContextBeforeInput }
  func insert(_ text: String) { textDocumentProxy.insertText(text) }
  func deleteBackward(_ count: Int) {
    for _ in 0..<count { textDocumentProxy.deleteBackward() }
  }
}

/// Reads `levels.bin` for the recording waveform.
struct LevelsReader {
  let store: HandoffStore

  func levels() -> [Float] {
    store.readData(.levels).flatMap(LevelsFile.init(data:))?.levels
      ?? Array(repeating: 0, count: LevelsFile.slotCount)
  }
}
