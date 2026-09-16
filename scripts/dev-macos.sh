#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep development launches on the identity and location authorized in System Settings.
identity="${LOCALFLOW_SIGNING_IDENTITY:-Apple Development: obrunovsky7@gmail.com (D63PW2838J)}"
app=/Applications/LocalFlow.app
security find-identity -v -p codesigning | grep -F -- "$identity" >/dev/null || {
  echo "Signing identity unavailable. Set LOCALFLOW_SIGNING_IDENTITY to your Apple Development identity." >&2
  exit 1
}
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/SignedDevelopment CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM=QUB47S3XTF build
source_app=build/SignedDevelopment/Build/Products/Debug/LocalFlow.app
codesign --verify --deep --strict "$source_app"
if [[ -d "$app" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == org.localflow.LocalFlow ]]
fi
if pgrep -x LocalFlow >/dev/null; then
  # The app cancels the initial Apple event while completing asynchronous shutdown.
  # Process exit below decides whether replacement is safe, including user cancellation.
  osascript -e 'tell application id "org.localflow.LocalFlow" to quit' 2>/dev/null || true
  for ((attempt=0; attempt<40; attempt++)); do
    if ! pgrep -x LocalFlow >/dev/null; then break; fi
    sleep 0.25
  done
  if pgrep -x LocalFlow >/dev/null; then
    echo 'LocalFlow is still open. Finish dictation or resolve its quit dialog, then run make run again.' >&2
    exit 1
  fi
fi
stage="$(mktemp -d /Applications/.LocalFlow-dev.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
ditto "$source_app" "$stage/LocalFlow.app"
codesign --verify --deep --strict "$stage/LocalFlow.app"
if [[ -d "$app" ]]; then mv "$app" "$stage/previous.app"; fi
if ! mv "$stage/LocalFlow.app" "$app"; then
  if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$app"; fi
  exit 1
fi
open "$app"
printf 'Opened signed development app: %s\n' "$app"
