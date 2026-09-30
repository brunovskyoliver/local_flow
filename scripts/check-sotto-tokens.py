#!/usr/bin/env python3
"""Feature 016 R13: the iOS Sotto tokens use exactly the Mac palette's hex values."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / "apps/macos/LocalFlow/UI/Appearance.swift"
IOS = ROOT / "apps/ios/Shared/Sotto/SottoTokens.swift"


def colours(path):
    return {value.upper() for value in re.findall(r"0x([0-9A-Fa-f]{6})\b", path.read_text())}


mac, ios = colours(MAC), colours(IOS)
if mac != ios:
    print(f"Sotto tokens differ. Mac only: {sorted(mac - ios)}; iOS only: {sorted(ios - mac)}",
          file=sys.stderr)
    sys.exit(1)
print(f"Sotto tokens match the Mac palette ({len(mac)} colours)")
