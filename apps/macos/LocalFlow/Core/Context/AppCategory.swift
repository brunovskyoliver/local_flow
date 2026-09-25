import Foundation

/// App category sent in every snapshot (research D12). Style rules use it only
/// when the style toggle is on.
enum AppCategory: String, Codable, CaseIterable, Sendable {
  case email
  case workChat = "work_chat"
  case personalChat = "personal_chat"
  case code, terminal, document, other

  var title: String {
    switch self {
    case .email: "Email"
    case .workChat: "Work chat"
    case .personalChat: "Personal chat"
    case .code: "Code"
    case .terminal: "Terminal"
    case .document: "Document"
    case .other: "Other"
    }
  }

  static let ownBundleID = "org.localflow.LocalFlow"

  static let builtIn: [String: AppCategory] = [
    "com.apple.mail": .email,
    "com.microsoft.Outlook": .email,
    "com.readdle.SparkDesktop": .email,
    "com.readdle.smartemail-Mac": .email,
    "com.superhuman.electron": .email,
    "com.tinyspeck.slackmacgap": .workChat,
    "com.microsoft.teams": .workChat,
    "com.microsoft.teams2": .workChat,
    "com.apple.MobileSMS": .personalChat,
    "net.whatsapp.WhatsApp": .personalChat,
    "desktop.WhatsApp": .personalChat,
    "ru.keepcoder.Telegram": .personalChat,
    "org.telegram.desktop": .personalChat,
    "org.whispersystems.signal-desktop": .personalChat,
    "com.hnc.Discord": .personalChat,
    "com.apple.dt.Xcode": .code,
    "com.microsoft.VSCode": .code,
    "com.todesktop.230313mzl4w4u92": .code,
    "dev.zed.Zed": .code,
    "com.apple.Terminal": .terminal,
    "com.googlecode.iterm2": .terminal,
    "com.mitchellh.ghostty": .terminal,
    "com.cmuxterm.app": .terminal,
    "dev.warp.Warp-Stable": .terminal,
    "org.alacritty": .terminal,
    "net.kovidgoyal.kitty": .terminal,
    "com.github.wez.wezterm": .terminal,
    "com.apple.Notes": .document,
    "com.apple.iWork.Pages": .document,
    "com.microsoft.Word": .document,
    "md.obsidian": .document,
    "notion.id": .document,
  ]

  /// Browsers stay `other`; this list only drives the address-bar rule.
  static let browsers: Set<String> = [
    "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
    "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
  ]

  /// Password managers (research D11) plus a best-effort banking list; users add more.
  static let defaultExclusions: Set<String> = [
    "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password",
    "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
    "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal",
    // ponytail: banking apps have no registry; one known ID, extend when users report more.
    "com.moneymoney-app.retail",
  ]

  /// Overrides win, then the built-in map, then JetBrains IDEs by prefix, else `other`.
  static func category(for bundleID: String?, overrides: [String: AppCategory] = [:])
    -> AppCategory
  {
    guard let bundleID else { return .other }
    if let override = overrides[bundleID] { return override }
    if let known = builtIn[bundleID] { return known }
    return bundleID.hasPrefix("com.jetbrains.") ? .code : .other
  }
}
