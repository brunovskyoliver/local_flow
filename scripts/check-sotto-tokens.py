#!/usr/bin/env python3
"""Feature 016 R13 and Feature 024: the iOS and Rust Sotto tokens use exactly the Mac palette's hex values."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / "apps/macos/LocalFlow/UI/Appearance.swift"
IOS = ROOT / "apps/ios/Shared/Sotto/SottoTokens.swift"
RUST = ROOT / "crates/flow-ui/src/tokens.rs"
# systemGreen stands in for Swift's `.systemGreen`, which has no hex in Appearance.swift.
# The pill's fill and ink are in DictationIndicator.swift as RGB; the rest are AppKit's windowBackgroundColor.
# systemRed for destructive buttons; the blue is the tint SwiftUI draws link-style placeholders with, sampled from the reference.
RUST_ONLY = {"28CD41", "32D74B", "242522", "F5F5F1", "323232", "ECECEC", "FF3B30", "FF453A", "3A68D4", "659AF9"}


def colours(path):
    return {value.upper() for value in re.findall(r"0x([0-9A-Fa-f]{6})\b", path.read_text())}


mac, ios = colours(MAC), colours(IOS)
if mac != ios:
    print(f"Sotto tokens differ. Mac only: {sorted(mac - ios)}; iOS only: {sorted(ios - mac)}",
          file=sys.stderr)
    sys.exit(1)
rust_source = RUST.read_text().split("#[cfg(test)]")[0]
rust = {value.upper() for value in re.findall(r"0x([0-9A-Fa-f]{6})\b", rust_source)} - RUST_ONLY
if mac != rust:
    print(f"Rust tokens differ. Mac only: {sorted(mac - rust)}; Rust only: {sorted(rust - mac)}",
          file=sys.stderr)
    sys.exit(1)
print(f"Sotto tokens match the Mac palette on iOS and Rust ({len(mac)} colours)")
