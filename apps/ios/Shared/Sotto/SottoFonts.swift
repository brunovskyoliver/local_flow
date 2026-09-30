import CoreText
import Foundation

enum SottoFonts {
  /// Registers the bundled Figtree and EB Garamond for this process only. The files are
  /// memory-mapped, so the keyboard pays no copy for them.
  static func register(bundle: Bundle = .main) {
    guard let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil), !urls.isEmpty
    else { return }
    CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
  }
}
