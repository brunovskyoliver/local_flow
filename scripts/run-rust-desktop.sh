#!/usr/bin/env bash
# Builds and runs the Rust desktop client on this Mac, with the speech worker beside it so local
# dictation works. The first run copies the Swift app's data; its data stays untouched. Quit the
# Swift app first, or give the two different shortcuts.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --release -p localflow
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -target flowd-speech -configuration Release \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO SYMROOT="$PWD/build/SpeechWorker" build
install -m 755 build/SpeechWorker/Release/flowd-speech target/release/flowd-speech
rm -rf target/release/FluidAudio_FluidAudio.bundle
ditto build/SpeechWorker/Release/FluidAudio_FluidAudio.bundle target/release/FluidAudio_FluidAudio.bundle
exec target/release/localflow
