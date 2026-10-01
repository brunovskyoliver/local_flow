import SwiftUI
import UIKit

/// The LocalFlow keyboard. It links neither package target and makes no network call;
/// it only reads and writes the handoff files and rings the bells.
final class KeyboardViewController: UIInputViewController, KeyboardHost {
  private var model: KeyboardSessionModel!
  private var hosting: UIHostingController<KeyboardView>?
  private let store = HandoffStore.group()
  private var restReading: DispatchWorkItem?

  override func viewDidLoad() {
    super.viewDidLoad()
    SottoFonts.register(bundle: Bundle(for: Self.self))
    model = KeyboardSessionModel(hasFullAccess: hasFullAccess, store: store)
    model.host = self
    let doorbell = Doorbell.shared
    doorbell.observe(.pong) { [weak self] in self?.model.pong() }
    doorbell.observe(.session) { [weak self] in self?.model.refresh() }
    doorbell.observe(.result) { [weak self] in self?.model.checkResult() }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // One hosting controller while visible; released on disappear (research R11).
    let view = KeyboardView(
      model: model, levels: store.map(LevelsReader.init),
      needsGlobe: needsInputModeSwitchKey,
      actions: .init(
        tap: { [weak self] in self?.tap() },
        space: { [weak self] in self?.textDocumentProxy.insertText(" ") },
        delete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
        newline: { [weak self] in self?.textDocumentProxy.insertText("\n") },
        character: { [weak self] in self?.textDocumentProxy.insertText($0) },
        nextKeyboard: { [weak self] in self?.advanceToNextInputMode() }))
    let hosting = UIHostingController(rootView: view)
    hosting.view.backgroundColor = .clear
    hosting.sizingOptions = .intrinsicContentSize
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
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    restReading?.cancel()
    restReading = nil
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

  /// SC-004: the keyboard's own footprint and peak, for the app's diagnostics screen.
  private func writeStatus() {
    guard hasFullAccess, let store else { return }
    let footprint = Footprint.read()
    try? store.write(
      KeyboardStatusFile(
        hasFullAccess: true, lastSeen: Handoff.milliseconds(Date()),
        peakFootprintBytes: footprint.peak, footprintBytes: footprint.current), .keyboardStatus)
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
