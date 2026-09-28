import Darwin
import Foundation

extension VocabularyBoostPolicy {
  /// Correctly spelled English words, per the system spell checker: the same answer the
  /// app gets, so V002 decisions match (SC-005). The worker must not import AppKit, so
  /// the checker is loaded at run time through the Objective-C runtime.
  @MainActor static func englishWords(in words: Set<String>) -> Set<String> {
    guard let checker = WorkerSpellChecker.shared else { return [] }
    return words.filter { checker.isCorrect($0) }
  }
}

@MainActor
private final class WorkerSpellChecker {
  static let shared = WorkerSpellChecker()

  private typealias Check =
    @convention(c) (
      AnyObject, Selector, NSString, Int, NSString?, Bool, Int, UnsafeMutablePointer<Int>?
    ) -> NSRange
  private let checker: AnyObject
  private let check: Check
  private let selector = NSSelectorFromString(
    "checkSpellingOfString:startingAt:language:wrap:inSpellDocumentWithTag:wordCount:")

  private init?() {
    guard dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW) != nil,
      let type = NSClassFromString("NSSpellChecker") as? NSObject.Type,
      let shared = type.perform(NSSelectorFromString("sharedSpellChecker"))?
        .takeUnretainedValue() as? NSObject,
      shared.responds(to: selector)
    else { return nil }
    checker = shared
    check = unsafeBitCast(shared.method(for: selector), to: Check.self)
  }

  func isCorrect(_ word: String) -> Bool {
    check(checker, selector, word as NSString, 0, "en", false, 0, nil).location == NSNotFound
  }
}
