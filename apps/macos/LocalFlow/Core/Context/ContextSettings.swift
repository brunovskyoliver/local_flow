import Foundation
import LocalFlowCore

/// Immutable settings taken at the press, so a change applies to the next dictation.
struct ContextSettings: Sendable, Equatable {
  var enabled = false
  var rewriteEnabled = false
  var styleEnabled = false
  var excludedBundleIDs: Set<String> = AppCategory.defaultExclusions
  var categoryOverrides: [String: AppCategory] = [:]
  var ownBundleID = AppCategory.ownBundleID

  static let disabled = ContextSettings()

  func isExcluded(_ bundleID: String) -> Bool {
    bundleID == ownBundleID || excludedBundleIDs.contains(bundleID)
  }
}

extension AppCategory {
  static let ownBundleID = AppIdentity.current.bundleIdentifier
}
