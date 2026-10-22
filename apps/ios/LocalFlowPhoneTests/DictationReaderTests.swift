import UIKit
import XCTest

@testable import LocalFlow

/// UI-03: long dictations are readable in full, selectable and scaled with Dynamic Type.
@MainActor
final class DictationReaderTests: XCTestCase {
  /// About 6,000 characters of mixed English and Slovak, with diacritics and long words.
  private let longText =
    Array(
      repeating:
        "Stretnutie o rozpočte začne o deviatej; please send the slides beforehand. "
        + "Nezabudnite na prílohy a na aktualizované čísla z marketingu. ",
      count: 45
    ).joined() + "Koniec."

  func testContentKeepsTheWholeTextWithTheCaptionFirst() {
    let content = SelectableText.content(text: longText, caption: "Keyboard · Inserted")
    XCTAssertEqual(content.string, "Keyboard · Inserted\n\n" + longText)
    XCTAssertTrue(content.string.hasSuffix("Koniec."), "nothing is truncated")
    XCTAssertEqual(SelectableText.content(text: "Ahoj", caption: nil).string, "Ahoj")
  }

  func testTextViewIsReadOnlySelectableScrollableAndFollowsDynamicType() {
    let view = UITextView()
    SelectableText.configure(view)
    XCTAssertFalse(view.isEditable)
    XCTAssertTrue(view.isSelectable)
    XCTAssertTrue(view.isScrollEnabled)
    XCTAssertTrue(view.adjustsFontForContentSizeCategory)
  }

  func testLargestTextSizeScalesTheFontAndTheTextScrolls() throws {
    let largest = UITraitCollection(
      preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
    let body = SelectableText.baseFont(size: 17)
    let scaled = UIFontMetrics(forTextStyle: .body).scaledFont(for: body, compatibleWith: largest)
    XCTAssertGreaterThan(scaled.pointSize, 40)

    // An iPhone-sized reader at the largest size: the text is far taller than the
    // screen, so it must scroll rather than clip.
    let view = UITextView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    SelectableText.configure(view)
    view.attributedText = SelectableText.content(text: longText, caption: nil)
    view.font = scaled
    view.layoutIfNeeded()
    let needed = view.sizeThatFits(CGSize(width: 393, height: CGFloat.greatestFiniteMagnitude))
      .height
    XCTAssertGreaterThan(needed, view.bounds.height * 5)
    view.setContentOffset(CGPoint(x: 0, y: needed - view.bounds.height), animated: false)
    XCTAssertGreaterThan(view.contentOffset.y, 0, "the end of the text is reachable")
    view.selectedRange = NSRange(location: 10, length: 20)
    XCTAssertEqual(view.selectedRange.length, 20, "part of the text can be selected")
  }

  func testHistoryCaptionNamesSourceDeliveryAppAndReview() {
    let item = HistoryViewModel.Item(
      id: UUID(), text: longText, date: Date(), source: "Keyboard", delivery: "Inserted",
      targetApp: "com.apple.MobileSMS", needsReview: true)
    XCTAssertEqual(
      HistoryView.caption(item), "Keyboard · Inserted · com.apple.MobileSMS · Needs review")
  }
}
