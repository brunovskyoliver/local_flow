#!/usr/bin/env bash
# Builds, signs, installs and opens the development app.
#   scripts/dev-macos.sh         replaces /Applications/LocalFlow.app (org.localflow.LocalFlow)
#   scripts/dev-macos.sh --dev   installs /Applications/LocalFlow Dev.app (org.localflow.LocalFlow.dev)
#                                beside it, with its own data, Keychain services, agents and ports
#                                (Feature 014, FR-033). It never reads, replaces or quits LocalFlow.app.
# Sign in with Apple needs LOCALFLOW_PROVISIONING_PROFILE: the name of a provisioning profile for
# the variant's App ID (team QUB47S3XTF). Without it the build signs without that entitlement.
# Google sign-in appears when LOCALFLOW_GOOGLE_CLIENT_ID names the variant's iOS OAuth client.
set -euo pipefail
cd "$(dirname "$0")/.."
variant=production
if [[ "${1:-}" == --dev ]]; then variant=dev; shift; fi
[[ $# -eq 0 ]] || { echo "usage: $0 [--dev]" >&2; exit 64; }
configuration="${LOCALFLOW_CONFIGURATION:-Debug}"
# Keep development launches on the identity and location authorized in System Settings.
identity="${LOCALFLOW_SIGNING_IDENTITY:-Apple Development: obrunovsky7@gmail.com (D63PW2838J)}"
production_id=org.localflow.LocalFlow
production_app=/Applications/LocalFlow.app
if [[ "$variant" == dev ]]; then
  bundle_id=org.localflow.LocalFlow.dev
  product="LocalFlow Dev"
  port_base=18000
  derived=build/SignedDevelopment-dev
else
  bundle_id=$production_id
  product=LocalFlow
  port_base=8000
  derived=build/SignedDevelopment
fi
app="/Applications/$product.app"
# The dev variant must never touch the installed app, whatever the settings above say.
if [[ "$variant" == dev ]]; then
  if [[ "$bundle_id" == "$production_id" || "$app" == "$production_app" || "$port_base" == 8000 ]]; then
    echo "Refusing: the dev variant would touch $production_app or $production_id." >&2
    exit 1
  fi
fi
security find-identity -v -p codesigning | grep -F -- "$identity" >/dev/null || {
  echo "Signing identity unavailable. Set LOCALFLOW_SIGNING_IDENTITY to your Apple Development identity." >&2
  exit 1
}
signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM=QUB47S3XTF)
if [[ -n "${LOCALFLOW_PROVISIONING_PROFILE:-}" ]]; then
  signing+=(PROVISIONING_PROFILE_SPECIFIER="$LOCALFLOW_PROVISIONING_PROFILE"
    CODE_SIGN_ENTITLEMENTS=LocalFlow/LocalFlowSignIn.entitlements)
else
  echo "Sign in with Apple is unavailable in this build: set LOCALFLOW_PROVISIONING_PROFILE to a profile for $bundle_id." >&2
fi
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow \
  -configuration "$configuration" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" "${signing[@]}" \
  LOCALFLOW_BUNDLE_IDENTIFIER="$bundle_id" LOCALFLOW_PRODUCT_NAME="$product" \
  LOCALFLOW_VARIANT="$variant" LOCALFLOW_PORT_BASE="$port_base" \
  LOCALFLOW_GOOGLE_CLIENT_ID="${LOCALFLOW_GOOGLE_CLIENT_ID:-}" build
source_app="$derived/Build/Products/$configuration/$product.app"
codesign --verify --deep --strict "$source_app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" == "$bundle_id" ]]
if [[ -d "$app" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]] || {
    echo "$app is not $bundle_id; not replacing it." >&2
    exit 1
  }
fi
if pgrep -x "$product" >/dev/null; then
  # The app cancels the initial Apple event while completing asynchronous shutdown.
  # Process exit below decides whether replacement is safe, including user cancellation.
  osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
  for ((attempt=0; attempt<40; attempt++)); do
    if ! pgrep -x "$product" >/dev/null; then break; fi
    sleep 0.25
  done
  if pgrep -x "$product" >/dev/null; then
    echo "$product is still open. Finish dictation or resolve its quit dialog, then run this again." >&2
    exit 1
  fi
fi
stage="$(mktemp -d /Applications/.LocalFlow-dev.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
ditto "$source_app" "$stage/$product.app"
codesign --verify --deep --strict "$stage/$product.app"
if [[ -d "$app" ]]; then mv "$app" "$stage/previous.app"; fi
if ! mv "$stage/$product.app" "$app"; then
  if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$app"; fi
  exit 1
fi
open "$app"
printf 'Opened signed development app: %s\n' "$app"
