#!/usr/bin/env bash
# Builds "LocalFlow Dev", the Rust desktop client as an app on this Mac, beside the Swift app. It has
# its own bundle ID, data folder and Keychain service. Ad-hoc signed, so macOS asks for permissions
# again after each rebuild. Quit the Swift app before dictating, or give the two different shortcuts.
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:-/Applications/LocalFlow Dev.app}"
staging="build/rust-dev/LocalFlow Dev.app"

cargo build --release -j 4 -p localflow
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -target flowd-speech -configuration Release \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO SYMROOT="$PWD/build/SpeechWorker" build

rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Helpers"
install -m 755 build/rust/release/localflow "$staging/Contents/MacOS/LocalFlow Dev"
install -m 755 build/SpeechWorker/Release/flowd-speech "$staging/Contents/Helpers/flowd-speech"
ditto build/SpeechWorker/Release/FluidAudio_FluidAudio.bundle "$staging/Contents/Helpers/FluidAudio_FluidAudio.bundle"
# The pinned descriptors the worker is pointed at. Code signing refuses them in Helpers.
mkdir -p "$staging/Contents/Resources/Models"
install -m 644 apps/macos/LocalFlow/Resources/Models/parakeet-v3.json apps/macos/LocalFlow/Resources/Models/parakeet-ctc-110m.json \
  apps/macos/LocalFlow/Resources/Models/whisper-large-v3-turbo.json apps/macos/LocalFlow/Resources/Models/speaker-diarization-offline.json "$staging/Contents/Resources/Models/"
sha="$(git rev-parse --short HEAD)"
cat > "$staging/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LocalFlow Dev</string>
<key>CFBundleDisplayName</key><string>LocalFlow Dev</string>
<key>CFBundleExecutable</key><string>LocalFlow Dev</string>
<key>CFBundleIdentifier</key><string>org.localflow.LocalFlow.rust-dev</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0-dev</string>
<key>CFBundleVersion</key><string>$sha</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>LocalFlow Dev uses the microphone for local dictation.</string>
</dict></plist>
PLIST
codesign --force --sign - "$staging/Contents/Helpers/flowd-speech" "$staging/Contents/Helpers/FluidAudio_FluidAudio.bundle"
codesign --force --sign - "$staging"
rm -rf "$target"
ditto "$staging" "$target"
echo "Installed $target ($sha)"
