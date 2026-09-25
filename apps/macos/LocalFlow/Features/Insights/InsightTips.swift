import AppKit
import SwiftUI

/// Hover details for the Insights page. Targets publish their bounds while hovered and
/// one layer draws the tip above everything, so neighbouring cards never cover it.
enum InsightTip: Equatable {
  /// Dark bubble with an arrow, for info marks and usage bars.
  case note(title: String, detail: String? = nil)
  /// Light card for a calendar day.
  case day(date: Date, words: Int, apps: Int, topApp: String?)
}

private struct TipAnchor {
  let tip: InsightTip
  let bounds: Anchor<CGRect>
}

private struct TipAnchorKey: PreferenceKey {
  static let defaultValue: [TipAnchor] = []
  static func reduce(value: inout [TipAnchor], nextValue: () -> [TipAnchor]) {
    value += nextValue()
  }
}

private struct TipTarget: ViewModifier {
  let tip: InsightTip?
  @State private var hovering = false

  func body(content: Content) -> some View {
    content
      .contentShape(.rect)
      .onHover { hovering = $0 }
      .anchorPreference(key: TipAnchorKey.self, value: .bounds) { bounds in
        guard hovering, let tip else { return [] }
        return [TipAnchor(tip: tip, bounds: bounds)]
      }
  }
}

extension View {
  func insightTip(_ tip: InsightTip?) -> some View { modifier(TipTarget(tip: tip)) }

  /// Draws the hovered tip. Apply once, around every card that has targets.
  func insightTipLayer() -> some View {
    overlayPreferenceValue(TipAnchorKey.self) { anchors in
      GeometryReader { proxy in
        if let anchor = anchors.last {
          TipPlacement(tip: anchor.tip, target: proxy[anchor.bounds], container: proxy.size)
        }
      }
      .allowsHitTesting(false)
    }
  }
}

private struct TipPlacement: View {
  let tip: InsightTip
  let target: CGRect
  let container: CGSize
  private let gap: CGFloat = 8

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.clear
      content.fixedSize()
        .alignmentGuide(.leading) { -clampedX(width: $0.width) }
        .alignmentGuide(.top) { -(target.minY - gap - $0.height) }
      if case .note = tip {
        TipArrow().fill(SottoPalette.ink).frame(width: 12, height: 6)
          .alignmentGuide(.leading) { -(target.midX - $0.width / 2) }
          .alignmentGuide(.top) { _ in -(target.minY - gap - 0.5) }
      }
    }
    .frame(width: container.width, height: container.height, alignment: .topLeading)
  }

  private func clampedX(width: CGFloat) -> CGFloat {
    min(max(target.midX - width / 2, 0), max(container.width - width, 0))
  }

  @ViewBuilder private var content: some View {
    switch tip {
    case .note(let title, let detail):
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.flow(size: 13, weight: .medium))
        if let detail {
          Text(detail).font(.flow(size: 11.5)).opacity(0.75)
        }
      }
      .foregroundStyle(SottoPalette.surface)
      .padding(.horizontal, 11).padding(.vertical, 8)
      .background(SottoPalette.ink, in: RoundedRectangle(cornerRadius: 7))
    case .day(let date, let words, let apps, let topApp):
      VStack(alignment: .leading, spacing: 0) {
        Text(date.formatted(date: .long, time: .omitted))
          .font(.flow(size: 13, weight: .medium)).padding(.bottom, 14)
        VStack(spacing: 10) {
          row("Total words", words.formatted())
          row("Total apps used", apps.formatted())
          if let topApp { row("Top app", AppName.display(topApp)) }
        }
      }
      .font(.flow(size: 12.5))
      .foregroundStyle(SottoPalette.ink)
      .padding(14).frame(width: 250)
      .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 10))
      .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(SottoPalette.cardLine) }
      .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer(minLength: 12)
      Text(value).fontWeight(.medium).lineLimit(1)
    }
  }
}

private struct TipArrow: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.closeSubpath()
    }
  }
}

/// Installed application names for bundle identifiers, resolved once per identifier.
@MainActor
enum AppName {
  private static var cache: [String: String] = [:]

  static func display(_ bundleID: String) -> String {
    if let name = cache[bundleID] { return name }
    let name =
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
      .map { FileManager.default.displayName(atPath: $0.path) }
      .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
      ?? bundleID.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() }
      ?? bundleID
    cache[bundleID] = name
    return name
  }
}
