import AppKit

/// Native buttons remain accessible without making the destination lose focus.
/// Signed mouse/VoiceOver focus acceptance remains a hardware check.
@MainActor
final class InsertionConfirmationPanel: NSPanel {
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let confirmButton = NSButton(title: "Confirm insertion", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private var confirmAction: () -> Void = {}
  private var cancelAction: () -> Void = {}
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 138),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    level = .floating
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    becomesKeyOnlyIfNeeded = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hasShadow = true
    backgroundColor = .windowBackgroundColor
    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.setAccessibilityLabel("Insertion destination")
    confirmButton.target = self
    confirmButton.action = #selector(confirmInsertion)
    cancelButton.target = self
    cancelButton.action = #selector(cancelInsertion)
    confirmButton.bezelStyle = .rounded
    cancelButton.bezelStyle = .rounded
    let buttons = NSStackView(views: [cancelButton, confirmButton])
    buttons.orientation = .horizontal
    buttons.spacing = 12
    let stack = NSStackView(views: [messageLabel, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView?.addSubview(stack)
    if let contentView {
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
        stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      ])
    }
  }

  func show(
    message: String, selecting: Bool, canSelect: Bool, canConfirm: Bool,
    select: @escaping () -> Void, target: CapturedTarget?,
    confirm: @escaping () -> Void, cancel: @escaping () -> Void
  ) {
    messageLabel.stringValue = message
    confirmButton.title = selecting ? "Use focused field" : "Confirm insertion"
    confirmButton.isEnabled = selecting ? canSelect : canConfirm
    confirmAction = selecting ? select : confirm
    cancelAction = cancel
    appearance = NSApp.appearance
    let point = IndicatorPanel.displayPoint(for: target) ?? NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    if let screen {
      setFrameOrigin(
        NSPoint(
          x: screen.visibleFrame.midX - frame.width / 2,
          y: screen.visibleFrame.minY + 70))
    }
    orderFrontRegardless()
  }

  @objc private func confirmInsertion() { confirmAction() }
  @objc private func cancelInsertion() { cancelAction() }
}
