#!/usr/bin/env bash
# Feature 016: the keyboard extension links no speech or storage code and makes no
# network request. apps/ios/Shared is compiled into the keyboard, so it is checked too.
set -euo pipefail
cd "$(dirname "$0")/.."
import='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(class[[:space:]]+|struct[[:space:]]+|enum[[:space:]]+|func[[:space:]]+)?'
if grep -rnE "${import}(Network|FluidAudio|GRDB|LocalFlowCore|LocalFlowSpeech)\b|URLSession" \
  apps/ios/Keyboard apps/ios/Shared; then
  echo "keyboard sources import speech, storage or network code" >&2
  exit 1
fi
echo "keyboard sources import no speech, storage or network code"
