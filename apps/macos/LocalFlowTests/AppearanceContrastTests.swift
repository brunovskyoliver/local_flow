import AppKit
import SwiftUI
import XCTest

@testable import LocalFlow

/// UI-06: small text needs 4.5:1 (WCAG 1.4.3) against every fill it is drawn on.
final class AppearanceContrastTests: XCTestCase {
  private func hex(_ color: Color, _ name: NSAppearance.Name) -> UInt32 {
    var value: UInt32 = 0
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
      let resolved = NSColor(color).usingColorSpace(.sRGB)!
      func channel(_ component: CGFloat) -> UInt32 { UInt32((component * 255).rounded()) }
      value =
        channel(resolved.redComponent) << 16 | channel(resolved.greenComponent) << 8
        | channel(resolved.blueComponent)
    }
    return value
  }

  private func assertText(
    _ text: Color, on fills: [Color], _ label: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      for fill in fills {
        let ratio = SpeakerPalette.contrast(hex(text, appearance), hex(fill, appearance))
        XCTAssertGreaterThanOrEqual(
          ratio, 4.5, "\(label) in \(appearance.rawValue): \(ratio)", file: file, line: line)
      }
    }
  }

  private let fills = [
    SottoPalette.canvas, SottoPalette.surface, SottoPalette.card, SottoPalette.tint,
    SottoPalette.button,
  ]

  func testWarningAndMutedTextKeepContrastOnEveryPageFill() {
    assertText(SottoPalette.warning, on: fills, "warning")
    assertText(SottoPalette.muted, on: fills, "muted")
    assertText(SottoPalette.ink, on: fills, "ink")
  }

  func testDataBarLabelsKeepContrastOnTheirFill() {
    assertText(SottoPalette.onDataStrong, on: [SottoPalette.dataStrong], "strong bar")
    assertText(SottoPalette.onData, on: [SottoPalette.dataScale[1]], "bar")
    assertText(SottoPalette.onDataQuiet, on: [SottoPalette.dataQuiet], "quiet bar")
  }

  func testSpeakerTextColorsKeepTextContrast() {
    XCTAssertEqual(SpeakerPalette.textPairs.count, SpeakerPalette.pairs.count)
    let light = SpeakerPalette.lightSurfaces + [0xF7F6F3, 0xFCFCFB, 0xF5F4F1, 0xF1EEE9]
    for pair in SpeakerPalette.textPairs {
      for surface in light {
        XCTAssertGreaterThanOrEqual(SpeakerPalette.contrast(pair.light, surface), 4.5)
      }
      for surface in SpeakerPalette.darkSurfaces + [0x1F1F1E, 0x141414, 0x2A2A29] {
        XCTAssertGreaterThanOrEqual(SpeakerPalette.contrast(pair.dark, surface), 4.5)
      }
    }
  }
}
