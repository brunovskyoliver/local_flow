#!/usr/bin/env bash
# Produce a self-contained, ad-hoc signed release without an Apple account.
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
  -derivedDataPath build/DistributionDerivedData CODE_SIGNING_ALLOWED=NO build
stage="$(mktemp -d "$output/stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/LocalFlow.app"
ditto build/DistributionDerivedData/Build/Products/Release/LocalFlow.app "$app"
mkdir -p "$app/Contents/Resources/Notices/docs"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Notices/"
ditto docs/licenses "$app/Contents/Resources/Notices/docs/licenses"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
# Sign nested Mach-O files before their enclosing bundles. Ad-hoc signing
# satisfies Apple Silicon's code-signing requirement, but establishes no identity.
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    codesign --force --sign - --timestamp=none "$binary"
  fi
done < <(find "$app/Contents" -type f -print0)
while IFS= read -r -d '' bundle; do
  codesign --force --sign - --timestamp=none "$bundle"
done < <(find "$app/Contents" -depth -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print0)
codesign --force --sign - --timestamp=none \
  --entitlements apps/macos/LocalFlow/LocalFlow.entitlements "$app"
codesign --verify --deep --strict "$app"
archive="LocalFlow-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
(cd "$output" && shasum -a 256 "$archive" > "$archive.sha256")
python3 scripts/render-homebrew-cask.py "$version" "$output/$archive" "$output/localflow.rb"
ruby -c "$output/localflow.rb"
printf 'Packaged %s (ad-hoc signed; not notarized)\n' "$output/$archive"
