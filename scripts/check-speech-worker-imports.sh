#!/usr/bin/env bash
# Feature 014 R10: the flowd-speech worker compiles the app's recognition sources and
# nothing that brings in UI or the history database. Its source list is read from the
# target's sources phase in the Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
sources="$(python3 - <<'PY'
import re
text = open("apps/macos/LocalFlow.xcodeproj/project.pbxproj").read()
phase = re.search(r'"F0145000000000000000000B" = \{[^}]*?"files" = \(([^)]*)\)', text, re.S)
if not phase:
    raise SystemExit("flowd-speech sources phase not found")
for build in re.findall(r'"([0-9A-Z]{24})"', phase.group(1)):
    ref = re.search(r'"' + build + r'" = \{[^}]*"fileRef" = "([0-9A-Z]{24})"', text).group(1)
    path = re.search(r'"' + ref + r'" = \{[^}]*?"path" = "([^"]+)"', text, re.S)
    if not path:
        path = re.search(r'"' + ref + r'" = \{\s*"path" = "([^"]+)"', text)
    print("apps/macos/" + path.group(1))
PY
)"
[[ -n "$sources" ]] || { echo "flowd-speech has no sources" >&2; exit 1; }
status=0
while IFS= read -r file; do
  if grep -nE '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(class[[:space:]]+|struct[[:space:]]+|enum[[:space:]]+|func[[:space:]]+)?(SwiftUI|AppKit|GRDB)\b' "$file"; then
    echo "flowd-speech source imports UI or GRDB: $file" >&2
    status=1
  fi
done <<<"$sources"
[[ $status -eq 0 ]] && echo "flowd-speech sources import no SwiftUI, AppKit or GRDB ($(wc -l <<<"$sources" | tr -d ' ') files)"
exit $status
