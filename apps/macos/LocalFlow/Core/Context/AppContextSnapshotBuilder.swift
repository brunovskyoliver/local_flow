import Foundation
import LocalFlowCore

extension AppContextSnapshot {
  /// Redacts, bounds each part, extracts terms and enforces the serialized limit.
  static func make(_ parts: Parts, styleHints: Bool = false) -> AppContextSnapshot {
    var truncated: [String] = []
    func note(_ part: ContextPart) {
      if !truncated.contains(part.rawValue) { truncated.append(part.rawValue) }
    }
    func clean(_ text: String?) -> String? {
      guard let text else { return nil }
      let redacted = ContextTermExtractor.redact(text.precomposedStringWithCanonicalMapping)
      return redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : redacted
    }
    var snapshot = AppContextSnapshot(
      appName: parts.appName.flatMap { $0.isEmpty ? nil : prefix($0, bytes: appNameBytes) },
      appCategory: parts.appCategory, fieldKind: parts.fieldKind, styleHints: styleHints)
    if let title = clean(parts.windowTitle) {
      if title.count > windowTitleCharacters { note(.windowTitle) }
      snapshot.windowTitle = String(title.prefix(windowTitleCharacters))
    }
    if let before = clean(parts.beforeCursor) {
      if before.count > beforeCharacters { note(.beforeCursor) }
      snapshot.beforeCursor = String(before.suffix(beforeCharacters))
    }
    if let after = clean(parts.afterCursor) {
      if after.count > afterCharacters { note(.afterCursor) }
      snapshot.afterCursor = String(after.prefix(afterCharacters))
    }
    if parts.selectedTooLarge {
      note(.selectedText)
    } else if let selected = clean(parts.selectedText) {
      if selected.count > selectedCharacters {
        note(.selectedText)
      } else {
        snapshot.selectedText = selected
      }
    }
    snapshot.terms = ContextTermExtractor.terms(
      windowTitle: snapshot.windowTitle, before: snapshot.beforeCursor,
      after: snapshot.afterCursor, selected: snapshot.selectedText)
    snapshot.truncated = truncated
    // Fixed drop order until the canonical bytes fit.
    for part in [ContextPart.afterCursor, .beforeCursor, .selectedText, .windowTitle] {
      guard snapshot.canonicalJSON().count > maximumBytes else { break }
      switch part {
      case .afterCursor: snapshot.afterCursor = nil
      case .beforeCursor: snapshot.beforeCursor = nil
      case .selectedText: snapshot.selectedText = nil
      case .windowTitle: snapshot.windowTitle = nil
      }
      if !snapshot.truncated.contains(part.rawValue) { snapshot.truncated.append(part.rawValue) }
    }
    return snapshot
  }
}
