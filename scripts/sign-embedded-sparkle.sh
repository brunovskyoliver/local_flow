#!/usr/bin/env bash
# Xcode's CodeSignOnCopy does not sign the nested bundles in our source-built framework.
set -euo pipefail
[[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]] || exit 0
identity="${EXPANDED_CODE_SIGN_IDENTITY:?Xcode signing identity is required}"
framework="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/Sparkle.framework"
[[ -d "$framework" ]] || { echo "Embedded Sparkle framework is missing." >&2; exit 1; }
# Work only on the embedded copy; the unsigned dependency cache is shared by builds.
signing=(--force --sign "$identity" --options runtime --timestamp=none --preserve-metadata=entitlements)
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    codesign "${signing[@]}" "$binary"
  fi
done < <(find "$framework" -type f -print0)
while IFS= read -r -d '' bundle; do
  codesign "${signing[@]}" "$bundle"
done < <(find "$framework" -depth -type d \( -name '*.xpc' -o -name '*.app' \) -print0)
codesign "${signing[@]}" "$framework"
codesign --verify --deep --strict "$framework"
