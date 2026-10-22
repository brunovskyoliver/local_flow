import SwiftUI
import UIKit

/// UI-03: the complete text of one dictation. It scrolls, any range of it can be
/// selected, it follows Dynamic Type up to the largest accessibility sizes, and the
/// toolbar copies or shares the whole text.
struct DictationReaderView: View {
  let text: String
  /// One muted line above the text: when and how the dictation was made.
  var caption: String? = nil
  @State private var copied = false

  var body: some View {
    SelectableText(text: text, caption: caption)
      .background(SottoPalette.canvas)
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            UIPasteboard.general.string = text
            copied = true
          }
          .accessibilityIdentifier("reader.copy")
          ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
            .accessibilityIdentifier("reader.share")
        }
      }
      .onChange(of: text) { copied = false }
  }
}

/// A read-only `UITextView`: it scrolls itself, so long text is laid out lazily, and
/// it allows selecting part of the text, which SwiftUI `Text` does not on iOS.
struct SelectableText: UIViewRepresentable {
  let text: String
  var caption: String? = nil

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    Self.configure(view)
    view.attributedText = Self.content(text: text, caption: caption)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    let content = Self.content(text: text, caption: caption)
    if view.attributedText.string != content.string { view.attributedText = content }
  }

  static func configure(_ view: UITextView) {
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = true
    view.alwaysBounceVertical = true
    view.adjustsFontForContentSizeCategory = true
    view.backgroundColor = .clear
    view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 32, right: 16)
    view.dataDetectorTypes = []
    view.accessibilityIdentifier = "reader.text"
  }

  /// The caption (muted, small) and the text (Figtree body), both scaled with the
  /// reader's content size category.
  static func content(text: String, caption: String?) -> NSAttributedString {
    let result = NSMutableAttributedString()
    if let caption, !caption.isEmpty {
      result.append(
        NSAttributedString(
          string: caption + "\n\n",
          attributes: [
            .font: font(size: 13, style: .footnote),
            .foregroundColor: UIColor(SottoPalette.muted),
          ]))
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    result.append(
      NSAttributedString(
        string: text,
        attributes: [
          .font: font(size: 17, style: .body),
          .foregroundColor: UIColor(SottoPalette.ink),
          .paragraphStyle: paragraph,
        ]))
    return result
  }

  /// Figtree at `size`, scaled like `style`.
  static func font(size: CGFloat, style: UIFont.TextStyle) -> UIFont {
    UIFontMetrics(forTextStyle: style).scaledFont(for: baseFont(size: size))
  }

  /// Unscaled Figtree; the system font when Figtree is not registered.
  static func baseFont(size: CGFloat) -> UIFont {
    let figtree = UIFont(
      descriptor: UIFontDescriptor(fontAttributes: [.family: "Figtree"]), size: size)
    return figtree.familyName == "Figtree" ? figtree : .systemFont(ofSize: size)
  }
}
