#!/usr/bin/env bash
# Production packaging fails closed; --ad-hoc is an explicit local test artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Usage: scripts/package-macos.sh VERSION BUILD_NUMBER [--ad-hoc|--signed-local]}"
build_number="${2:?Provide a positive numeric build number}"
mode="${3:---production}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z.' >&2; exit 64; }
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'Build number must be positive.' >&2; exit 64; }
[[ "$mode" == --production || "$mode" == --ad-hoc || "$mode" == --signed-local ]] || { echo 'Unknown packaging mode.' >&2; exit 64; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Build on an Apple Silicon Mac.' >&2; exit 1; }
if [[ "$mode" == --production ]]; then
  for name in LOCALFLOW_SIGNING_IDENTITY LOCALFLOW_NOTARY_PROFILE LOCALFLOW_UPDATE_PUBLIC_KEY LOCALFLOW_UPDATE_FEED_URL LOCALFLOW_UPDATE_KEY_FILE; do
    [[ -n "${!name:-}" ]] || { echo "Production packaging requires $name." >&2; exit 1; }
  done
  [[ "$LOCALFLOW_SIGNING_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'A Developer ID Application identity is required.' >&2; exit 1; }
  [[ -r "$LOCALFLOW_UPDATE_KEY_FILE" ]] || { echo 'Update signing key file is unavailable.' >&2; exit 1; }
  python3 - <<'PY'
import os,base64,urllib.parse
u=urllib.parse.urlsplit(os.environ['LOCALFLOW_UPDATE_FEED_URL'])
assert u.scheme=='https' and u.hostname and not u.username and not u.password and not u.query and not u.fragment, 'Invalid feed URL'
assert len(base64.b64decode(os.environ['LOCALFLOW_UPDATE_PUBLIC_KEY'],validate=True))==32, 'Invalid update public key'
PY
fi
if [[ "$mode" == --signed-local ]]; then
  [[ "${LOCALFLOW_SIGNING_IDENTITY:-}" == 'Developer ID Application:'* ]] || { echo 'Local signing requires a Developer ID Application identity.' >&2; exit 1; }
fi
output="$PWD/build/distribution/$version"
[[ ! -e "$output/LocalFlow-$version-arm64.zip" ]] || { echo 'Refusing to replace an existing release archive.' >&2; exit 1; }
mkdir -p "$output"
./scripts/prepare-sparkle.sh
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
cp packaging/sparkle/LICENSE "$app/Contents/Resources/Notices/Sparkle-LICENSE"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
signing=(--force --sign - --timestamp=none)
if [[ "$mode" == --signed-local ]]; then
  signing=(--force --sign "$LOCALFLOW_SIGNING_IDENTITY" --options runtime --timestamp=none)
fi
if [[ "$mode" == --production ]]; then
  signing=(--force --sign "$LOCALFLOW_SIGNING_IDENTITY" --options runtime --timestamp)
  APP_PLIST="$app/Contents/Info.plist" python3 - <<'PY'
import os,plistlib
p=os.environ['APP_PLIST']
with open(p,'rb') as f: info=plistlib.load(f)
info.update(LocalFlowSignedUpdates=True, SUFeedURL=os.environ['LOCALFLOW_UPDATE_FEED_URL'], SUPublicEDKey=os.environ['LOCALFLOW_UPDATE_PUBLIC_KEY'])
with open(p,'wb') as f: plistlib.dump(info,f)
PY
fi
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then codesign "${signing[@]}" "$binary"; fi
done < <(find "$app/Contents" -type f -print0)
while IFS= read -r -d '' bundle; do codesign "${signing[@]}" "$bundle"; done \
  < <(find "$app/Contents" -depth -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print0)
codesign "${signing[@]}" --entitlements apps/macos/LocalFlow/LocalFlow.entitlements "$app"
codesign --verify --deep --strict "$app"
archive="LocalFlow-$version-arm64.zip"
if [[ "$mode" == --production ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/notarize.zip"
  notary_keychain=()
  if [[ -n "${LOCALFLOW_NOTARY_KEYCHAIN:-}" ]]; then notary_keychain=(--keychain "$LOCALFLOW_NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$stage/notarize.zip" --keychain-profile "$LOCALFLOW_NOTARY_PROFILE" "${notary_keychain[@]}" --wait --timeout 30m
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute "$app"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
(cd "$output" && shasum -a 256 "$archive" > "$archive.sha256")
python3 scripts/render-homebrew-cask.py "$version" "$output/$archive" "$output/localflow.rb"
ruby -c "$output/localflow.rb"
if [[ "$mode" == --production ]]; then
  tools="$PWD/build/Sparkle/DerivedData/Build/Products/Release"
  "$tools/generate_appcast" --ed-key-file "$LOCALFLOW_UPDATE_KEY_FILE" \
    --download-url-prefix "https://github.com/brunovskyoliver/local_flow/releases/download/v$version/" \
    --maximum-deltas 0 "$output"
  python3 scripts/verify-update-artifacts.py "$output/appcast.xml" "$output/$archive" "$build_number"
  printf 'Packaged verified production release %s\n' "$output/$archive"
else
  printf 'Packaged local test artifact %s; not notarized, updates disabled.\n' "$output/$archive"
fi
