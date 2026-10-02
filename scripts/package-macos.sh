#!/usr/bin/env bash
# Produce a self-contained release. Without LOCALFLOW_SIGNING_IDENTITY it is
# ad-hoc signed and needs no Apple account; with a Developer ID identity it is
# signed with the hardened runtime, and notarized and stapled when notary
# credentials are set: LOCALFLOW_NOTARY_PROFILE (a notarytool keychain profile)
# or LOCALFLOW_NOTARY_KEY, LOCALFLOW_NOTARY_KEY_ID and LOCALFLOW_NOTARY_ISSUER
# (an App Store Connect API key). Only a notarized build gets a Homebrew cask.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Usage: scripts/package-macos.sh VERSION BUILD_NUMBER}"
build_number="${2:?Provide a positive numeric build number}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z.' >&2; exit 64; }
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'Build number must be positive.' >&2; exit 64; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Build on an Apple Silicon Mac.' >&2; exit 1; }
output="$PWD/build/distribution/$version"
mkdir -p "$output"
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DistributionDerivedData CODE_SIGNING_ALLOWED=NO \
  LOCALFLOW_GOOGLE_CLIENT_ID="${LOCALFLOW_GOOGLE_CLIENT_ID:-}" build
stage="$(mktemp -d "$output/stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/LocalFlow.app"
ditto build/DistributionDerivedData/Build/Products/Release/LocalFlow.app "$app"
mkdir -p "$app/Contents/Resources/Notices/docs"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Notices/"
ditto docs/licenses "$app/Contents/Resources/Notices/docs/licenses"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
identity="${LOCALFLOW_SIGNING_IDENTITY:--}"
if [[ "$identity" == - ]]; then
  # Ad-hoc signing satisfies Apple Silicon's code-signing requirement, but establishes no identity.
  sign=(codesign --force --sign - --timestamp=none)
else
  sign=(codesign --force --sign "$identity" --options runtime --timestamp)
fi
# Sign nested Mach-O files before their enclosing bundles.
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    "${sign[@]}" "$binary"
  fi
done < <(find "$app/Contents" -type f -print0)
while IFS= read -r -d '' bundle; do
  "${sign[@]}" "$bundle"
done < <(find "$app/Contents" -depth -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print0)
"${sign[@]}" --entitlements apps/macos/LocalFlow/LocalFlow.entitlements "$app"
codesign --verify --deep --strict "$app"
notary=()
if [[ -n "${LOCALFLOW_NOTARY_PROFILE:-}" ]]; then
  notary=(--keychain-profile "$LOCALFLOW_NOTARY_PROFILE")
elif [[ -n "${LOCALFLOW_NOTARY_KEY:-}" ]]; then
  notary=(--key "$LOCALFLOW_NOTARY_KEY" --key-id "${LOCALFLOW_NOTARY_KEY_ID:?}"
    --issuer "${LOCALFLOW_NOTARY_ISSUER:?}")
fi
if [[ ${#notary[@]} -gt 0 ]]; then
  [[ "$identity" != - ]] || { echo 'Notarization needs a Developer ID identity.' >&2; exit 64; }
  ditto -c -k --keepParent "$app" "$stage/notarize.zip"
  xcrun notarytool submit "$stage/notarize.zip" "${notary[@]}" --wait --timeout 30m |
    tee "$stage/notary.log"
  grep -q 'status: Accepted' "$stage/notary.log" || { echo 'Notarization was not accepted.' >&2; exit 1; }
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi
archive="LocalFlow-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
(cd "$output" && shasum -a 256 "$archive" > "$archive.sha256")
if [[ ${#notary[@]} -gt 0 ]]; then
  python3 scripts/render-homebrew-cask.py "$version" "$output/$archive" "$output/localflow.rb"
  ruby -c "$output/localflow.rb"
  printf 'Packaged %s (signed by %s, notarized)\n' "$output/$archive" "$identity"
else
  rm -f "$output/localflow.rb"
  printf 'Packaged %s (signed by %s, not notarized; no cask)\n' "$output/$archive" "$identity"
fi
