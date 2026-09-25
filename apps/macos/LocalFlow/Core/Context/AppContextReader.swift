import AppKit
import ApplicationServices
import Foundation

/// The Accessibility reads the snapshot builder needs. Production is
/// `AXContextSource`; tests script one without live AX.
protocol ContextAttributeSource: Sendable {
  func isTrusted() -> Bool
  /// Subrole of the frontmost focused element, used only when no target was captured.
  func focusedSubrole() -> String?
  func appName(_ target: CapturedTarget) -> String?
  /// Sets the per-call messaging timeout on the element and its window.
  func prepare(_ target: CapturedTarget)
  func windowTitle(_ target: CapturedTarget) -> String?
  func role(_ target: CapturedTarget) -> (role: String?, subrole: String?)
  func placeholder(_ target: CapturedTarget) -> String?
  func characterCount(_ target: CapturedTarget) -> Int?
  /// UTF-16 range read; nil when the attribute is unsupported or the call failed.
  func string(_ target: CapturedTarget, location: Int, length: Int) -> String?
  /// Roles of up to `levels` ancestors, nearest first.
  func ancestorRoles(_ target: CapturedTarget, levels: Int) -> [String]
}

/// Collects parts as they are read, so a deadline can finish from what exists.
final class ContextReadProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var parts = AppContextSnapshot.Parts()
  private var bundleID: String?

  func update(_ change: (inout AppContextSnapshot.Parts) -> Void) {
    lock.withLock { change(&parts) }
  }
  func setBundleID(_ value: String) { lock.withLock { bundleID = value } }
  var current: (AppContextSnapshot.Parts, String?) { lock.withLock { (parts, bundleID) } }
}

enum AppContextSnapshotBuilder {
  static let secureSubrole = "AXSecureTextField"
  static let toolbarWalkLevels = 3

  /// The decision order of `contracts/context-snapshot.md`. No text is read
  /// before the exclusion checks pass.
  static func build(
    target: CapturedTarget?, settings: ContextSettings, source: any ContextAttributeSource,
    progress: ContextReadProgress = ContextReadProgress(), deadlineReached: () -> Bool
  ) -> AppContextCapture {
    guard settings.enabled else { return .off }
    guard source.isTrusted() else { return AppContextCapture(outcome: .noPermission) }
    guard let target else {
      return AppContextCapture(
        outcome: source.focusedSubrole() == secureSubrole ? .secureField : .noTarget)
    }
    let bundleID = target.bundleIdentifier
    if bundleID == settings.ownBundleID {
      return AppContextCapture(outcome: .ownApp, bundleID: bundleID)
    }
    if settings.excludedBundleIDs.contains(bundleID) {
      return AppContextCapture(outcome: .excludedApp, bundleID: bundleID)
    }
    progress.setBundleID(bundleID)
    let category = AppCategory.category(for: bundleID, overrides: settings.categoryOverrides)
    progress.update { $0.appCategory = category }
    source.prepare(target)
    func timedOut() -> AppContextCapture {
      finish(progress: progress, settings: settings, outcome: .timedOut)
    }

    guard !deadlineReached() else { return timedOut() }
    let appName = source.appName(target)
    progress.update { $0.appName = appName }
    guard !deadlineReached() else { return timedOut() }
    let title = source.windowTitle(target)
    progress.update { $0.windowTitle = title }
    guard !deadlineReached() else { return timedOut() }
    let (role, subrole) = source.role(target)
    if subrole == secureSubrole {
      return AppContextCapture(outcome: .secureField, bundleID: bundleID)
    }
    let kind = fieldKind(role: role, subrole: subrole, category: category)
    progress.update { $0.fieldKind = kind }
    // A paste target has no cursor; reading from offset 0 would send scrollback.
    if target.delivery == .paste {
      return finish(progress: progress, settings: settings, outcome: .used)
    }
    // The address bar: a single-line field in a browser under a toolbar.
    if AppCategory.browsers.contains(bundleID), role == "AXTextField",
      source.ancestorRoles(target, levels: toolbarWalkLevels).prefix(toolbarWalkLevels)
        .contains("AXToolbar")
    {
      return finish(progress: progress, settings: settings, outcome: .used)
    }
    guard !deadlineReached() else { return timedOut() }
    let placeholder = source.placeholder(target)
    guard !deadlineReached() else { return timedOut() }
    let selection = target.selectedRange
    let cursor = max(0, selection.location)
    let selectedLength = max(0, selection.length)
    let count = source.characterCount(target) ?? (cursor + selectedLength)

    guard !deadlineReached() else { return timedOut() }
    let beforeLength = min(cursor, AppContextSnapshot.beforeCharacters)
    let before =
      beforeLength > 0
      ? source.string(target, location: cursor - beforeLength, length: beforeLength) : nil
    progress.update { $0.beforeCursor = before }

    guard !deadlineReached() else { return timedOut() }
    if selectedLength > AppContextSnapshot.selectedCharacters {
      progress.update { $0.selectedTooLarge = true }
    } else if selectedLength > 0 {
      let selected = source.string(target, location: cursor, length: selectedLength)
      progress.update { $0.selectedText = selected }
    }

    guard !deadlineReached() else { return timedOut() }
    let afterStart = cursor + selectedLength
    let afterLength = min(max(0, count - afterStart), AppContextSnapshot.afterCharacters)
    let after =
      afterLength > 0 ? source.string(target, location: afterStart, length: afterLength) : nil
    progress.update { $0.afterCursor = after }

    // A field showing its placeholder has no text of its own.
    if let placeholder, !placeholder.isEmpty {
      let (parts, _) = progress.current
      let field =
        (parts.beforeCursor ?? "") + (parts.selectedText ?? "") + (parts.afterCursor ?? "")
      if field == placeholder {
        progress.update {
          $0.beforeCursor = nil
          $0.selectedText = nil
          $0.afterCursor = nil
        }
      }
    }
    return finish(progress: progress, settings: settings, outcome: .used)
  }

  /// Builds the bounded snapshot from what was read. `used` becomes
  /// `nothing_readable` when no text and no title survived.
  static func finish(
    progress: ContextReadProgress, settings: ContextSettings, outcome: ContextOutcome
  ) -> AppContextCapture {
    let (parts, bundleID) = progress.current
    let snapshot = AppContextSnapshot.make(parts, styleHints: settings.styleEnabled)
    let final = outcome == .used && !snapshot.hasText ? .nothingReadable : outcome
    return AppContextCapture(outcome: final, snapshot: snapshot, bundleID: bundleID)
  }

  static func fieldKind(role: String?, subrole: String?, category: AppCategory) -> FieldKind {
    if category == .code { return .code }
    if category == .terminal { return .terminal }
    if subrole == "AXSearchField" || role == "AXComboBox" { return .search }
    switch role {
    case "AXTextField": return .singleLine
    case "AXTextArea": return .multiLine
    default: return .unknown
    }
  }
}

/// Reads the focused field once per dictation, off the main actor, within a hard deadline.
struct SystemAppContextReader: AppContextReading {
  var source: any ContextAttributeSource = AXContextSource()

  func read(target: CapturedTarget?, settings: ContextSettings, deadline: Duration) async
    -> AppContextCapture
  {
    guard settings.enabled else { return .off }
    let clock = ContinuousClock()
    let started = clock.now
    let end = started.advanced(by: deadline)
    let progress = ContextReadProgress()
    let source = source
    var capture = await withCheckedContinuation { continuation in
      let once = ResumeOnce(continuation)
      // A hung AX call cannot hold the dictation: the timer resumes with the parts read so far.
      Thread.detachNewThread {
        once.resume(
          AppContextSnapshotBuilder.build(
            target: target, settings: settings, source: source, progress: progress,
            deadlineReached: { clock.now >= end }))
      }
      Task.detached {
        try? await clock.sleep(until: end.advanced(by: .milliseconds(10)))
        once.resume(
          AppContextSnapshotBuilder.finish(
            progress: progress, settings: settings, outcome: .timedOut))
      }
    }
    capture.durationMs = Int((clock.now - started) / .milliseconds(1))
    return capture
  }
}

private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<AppContextCapture, Never>?
  init(_ continuation: CheckedContinuation<AppContextCapture, Never>) {
    self.continuation = continuation
  }
  func resume(_ value: AppContextCapture) {
    lock.withLock {
      continuation?.resume(returning: value)
      continuation = nil
    }
  }
}

/// Live Accessibility reads. Every call is bounded by the 100 ms messaging timeout.
struct AXContextSource: ContextAttributeSource {
  func isTrusted() -> Bool { AXIsProcessTrusted() }

  func focusedSubrole() -> String? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.1)
    guard let focused = element(system, kAXFocusedUIElementAttribute) else { return nil }
    return string(focused, kAXSubroleAttribute)
  }

  func appName(_ target: CapturedTarget) -> String? {
    NSRunningApplication(processIdentifier: target.processIdentifier)?.localizedName
  }

  func prepare(_ target: CapturedTarget) {
    AXUIElementSetMessagingTimeout(target.element, 0.1)
    if let window = target.focusedWindow { AXUIElementSetMessagingTimeout(window, 0.1) }
  }

  func windowTitle(_ target: CapturedTarget) -> String? {
    target.focusedWindow.flatMap { string($0, kAXTitleAttribute) }
  }

  func role(_ target: CapturedTarget) -> (role: String?, subrole: String?) {
    (string(target.element, kAXRoleAttribute), string(target.element, kAXSubroleAttribute))
  }

  func placeholder(_ target: CapturedTarget) -> String? {
    string(target.element, kAXPlaceholderValueAttribute)
  }

  func characterCount(_ target: CapturedTarget) -> Int? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        target.element, kAXNumberOfCharactersAttribute as CFString, &value) == .success
    else { return nil }
    return (value as? NSNumber)?.intValue
  }

  func string(_ target: CapturedTarget, location: Int, length: Int) -> String? {
    var range = CFRange(location: location, length: length)
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var value: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        target.element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        == .success
    else { return nil }
    return value as? String
  }

  func ancestorRoles(_ target: CapturedTarget, levels: Int) -> [String] {
    var roles: [String] = []
    var current = target.element
    for _ in 0..<levels {
      guard let parent = element(current, kAXParentAttribute) else { break }
      AXUIElementSetMessagingTimeout(parent, 0.1)
      roles.append(string(parent, kAXRoleAttribute) ?? "")
      current = parent
    }
    return roles
  }

  private func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }
}
