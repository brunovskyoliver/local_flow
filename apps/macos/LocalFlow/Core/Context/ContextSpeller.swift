import Foundation

/// Local context spelling, version 1 (research D5). A transcript span of 1–3 words
/// takes a candidate term's exact form when their fold keys match, or, for
/// capitalized names only, when they are within a small edit distance. Pure;
/// nothing is inserted or reordered.
enum ContextSpeller {
  static let version = 1
  static let maximumChanges = 64
  static let maximumOriginalBytes = 256
  private static let maximumDistanceBytes = 64

  struct Result: Equatable, Sendable {
    let text: String
    let changes: [ContextSpellingChange]
    /// More than `maximumChanges` matched; spelling stopped.
    let truncated: Bool
  }

  /// Letters with a stroke or bar have no canonical decomposition, so NFD alone
  /// would keep "Łukasz" apart from "Lukasz".
  private static let strokeLetters: [Unicode.Scalar: Unicode.Scalar] = [
    "ł": "l", "Ł": "L", "đ": "d", "Đ": "D", "ø": "o", "Ø": "O", "ħ": "h", "Ħ": "H", "ı": "i",
  ]

  /// NFD, combining marks removed, stroke letters mapped, lowercased, without
  /// spaces, `-` and `_`.
  static func fold(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars
    where scalar.properties.generalCategory != .nonspacingMark
      && !(scalar == " " || scalar == "-" || scalar == "_")
    {
      scalars.append(strokeLetters[scalar] ?? scalar)
    }
    return String(scalars).lowercased()
  }

  private struct Word {
    let range: NSRange
    let text: String
    /// Only spaces separate it from the previous word.
    let joinsPrevious: Bool
  }

  private struct Match {
    let range: NSRange
    let term: ContextTerm
    let kind: ContextSpellingChange.Match
  }

  /// `dictionaryTerms` are the enabled vocabulary canonicals and aliases; a span or
  /// candidate the dictionary governs is never changed here (FR-008).
  static func apply(to text: String, terms: [ContextTerm], dictionaryTerms: [String] = [])
    -> Result
  {
    let unchanged = Result(text: text, changes: [], truncated: false)
    guard !terms.isEmpty, !text.isEmpty else { return unchanged }
    let dictionary = Set(dictionaryTerms.map(fold))
    let candidates = terms.filter { !dictionary.contains(fold($0.text)) }
    var exact: [String: [ContextTerm]] = [:]
    for term in candidates { exact[fold(term.text), default: []].append(term) }
    let names = candidates.filter {
      $0.kind == .name && $0.text.first?.isUppercase == true
        && $0.text.utf8.count <= maximumDistanceBytes
    }
    let words = words(in: text)
    let source = text as NSString
    var matches: [Match] = []
    for start in words.indices {
      for count in 1...3 where start + count <= words.count {
        let span = words[start..<(start + count)]
        guard span.dropFirst().allSatisfy(\.joinsPrevious) else { break }
        guard
          !span.contains(where: { CorrectionStopwords.commonWords.contains($0.text.lowercased()) })
        else { continue }
        let range = NSRange(
          location: span.first!.range.location,
          length: NSMaxRange(span.last!.range) - span.first!.range.location)
        let original = source.substring(with: range)
        let key = fold(original)
        guard !dictionary.contains(key) else { continue }
        for term in exact[key] ?? [] where term.text != original {
          // One ordinary word capitalized by the screen ("legal" → "Legal") is not a
          // spelling; inner capitals ("NetBird") and multiword names are.
          if count == 1, original.lowercased() == term.text.lowercased(),
            !term.text.dropFirst().contains(where: \.isUppercase)
          {
            continue
          }
          matches.append(Match(range: range, term: term, kind: .exactFold))
        }
        guard exact[key] == nil, key.count >= 5, key.utf8.count <= maximumDistanceBytes,
          original.first?.isLetter == true
        else { continue }
        for term in names {
          let candidate = fold(term.text)
          guard candidate.count >= 5, candidate.first == key.first,
            levenshtein(key, candidate, limit: max(key.count, candidate.count) > 7 ? 2 : 1)
          else { continue }
          matches.append(Match(range: range, term: term, kind: .nearName))
        }
      }
    }
    return resolve(matches, in: source)
  }

  /// Overlapping matches that all produce the same text collapse to one change;
  /// any disagreement leaves the whole group unchanged, as V001 does.
  private static func resolve(_ matches: [Match], in source: NSString) -> Result {
    let sorted = matches.sorted {
      $0.range.location != $1.range.location
        ? $0.range.location < $1.range.location : NSMaxRange($0.range) < NSMaxRange($1.range)
    }
    var changes: [ContextSpellingChange] = []
    var truncated = false
    var index = 0
    while index < sorted.count {
      var end = index + 1
      var reach = NSMaxRange(sorted[index].range)
      while end < sorted.count, sorted[end].range.location < reach {
        reach = max(reach, NSMaxRange(sorted[end].range))
        end += 1
      }
      let group = sorted[index..<end]
      index = end
      let lower = group.first!.range.location
      let outputs = Set(
        group.map { match in
          source.substring(with: NSRange(location: lower, length: match.range.location - lower))
            + match.term.text
            + source.substring(
              with: NSRange(
                location: NSMaxRange(match.range), length: reach - NSMaxRange(match.range)))
        })
      guard outputs.count == 1, let replacement = outputs.first else { continue }
      let range = NSRange(location: lower, length: reach - lower)
      let original = source.substring(with: range)
      guard original.utf8.count <= maximumOriginalBytes,
        replacement.utf8.count <= ContextTerm.maximumBytes
      else { continue }
      guard changes.count < maximumChanges else {
        truncated = true
        break
      }
      // The longest match names the source and the kind.
      let widest = group.max { $0.range.length < $1.range.length }!
      changes.append(
        ContextSpellingChange(
          original: original, replacement: replacement, sourcePart: widest.term.source,
          start: range.location, length: range.length, match: widest.kind))
    }
    var output = source as String
    for change in changes.reversed() {
      output = (output as NSString).replacingCharacters(
        in: NSRange(location: change.start, length: change.length), with: change.replacement)
    }
    return Result(text: output, changes: changes, truncated: truncated)
  }

  /// Letter runs with inner `-`, `_` and `'`. Digits, punctuation and protected
  /// tokens end a span, so no span can cross them.
  private static func words(in text: String) -> [Word] {
    let source = text as NSString
    let protected = protectedIndexes(in: source)
    func isLetter(at index: Int) -> Bool {
      index < source.length && !protected.contains(index)
        && source.substring(with: source.rangeOfComposedCharacterSequence(at: index)).first?
          .isLetter == true
    }
    var words: [Word] = []
    var gap = ""
    var index = 0
    while index < source.length {
      let range = source.rangeOfComposedCharacterSequence(at: index)
      guard isLetter(at: index) else {
        gap += source.substring(with: range)
        index = NSMaxRange(range)
        continue
      }
      var end = NSMaxRange(range)
      while end < source.length {
        let next = source.rangeOfComposedCharacterSequence(at: end)
        if isLetter(at: end) {
          end = NSMaxRange(next)
        } else if "-_'’".contains(source.substring(with: next)), isLetter(at: NSMaxRange(next)) {
          end = NSMaxRange(next)
        } else {
          break
        }
      }
      let wordRange = NSRange(location: index, length: end - index)
      words.append(
        Word(
          range: wordRange, text: source.substring(with: wordRange),
          joinsPrevious: !words.isEmpty && !gap.isEmpty && gap.allSatisfy { $0 == " " }))
      gap = ""
      index = end
    }
    return words
  }

  /// UTF-16 offsets of whitespace-delimited tokens that are protected literals or carry digits.
  private static func protectedIndexes(in source: NSString) -> IndexSet {
    var result = IndexSet()
    var start: Int?
    func close(_ end: Int) {
      guard let from = start else { return }
      start = nil
      let token = source.substring(with: NSRange(location: from, length: end - from))
      let inner = token.trimmingCharacters(in: .punctuationCharacters)
      if token.contains(where: \.isNumber)
        || ProtectedLiteralDetector.protectedClass(of: inner) != nil
      {
        result.insert(integersIn: from..<end)
      }
    }
    for index in 0..<source.length {
      let isSpace = Character(UnicodeScalar(source.character(at: index)) ?? " ").isWhitespace
      if isSpace { close(index) } else if start == nil { start = index }
    }
    close(source.length)
    return result
  }

  /// True when the edit distance is at most `limit`.
  static func levenshtein(_ a: String, _ b: String, limit: Int) -> Bool {
    let a = Array(a)
    let b = Array(b)
    guard abs(a.count - b.count) <= limit else { return false }
    var previous = Array(0...b.count)
    for i in 1...max(a.count, 1) where !a.isEmpty {
      var current = [i] + Array(repeating: 0, count: b.count)
      for j in 1...max(b.count, 1) where !b.isEmpty {
        current[j] = min(
          previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
      }
      guard current.min()! <= limit else { return false }
      previous = current
    }
    return previous[b.count] <= limit
  }
}
