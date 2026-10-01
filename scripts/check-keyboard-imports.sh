#!/usr/bin/env bash
# Features 016 and 017: the keyboard and widget extensions link no speech or storage
# code and make no network request. apps/ios/Shared is compiled into the keyboard, and
# apps/ios/Intents into the widget, so they are checked too. Missing folders are skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
import='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(class[[:space:]]+|struct[[:space:]]+|enum[[:space:]]+|func[[:space:]]+)?'
existing() { for d in "$@"; do [ -d "$d" ] && echo "$d"; done; return 0; }
fail=0
# check <message> <pattern> <dir>...
check() {
  local message=$1 pattern=$2; shift 2
  local dirs; dirs=$(existing "$@")
  [ -z "$dirs" ] && return 0
  # shellcheck disable=SC2086
  if grep -rnE "$pattern" $dirs; then
    echo "$message" >&2
    fail=1
  fi
}
check "keyboard sources import speech, storage or network code" \
  "${import}(Network|FluidAudio|GRDB|LocalFlowCore|LocalFlowSpeech)\b|URLSession" \
  apps/ios/Keyboard apps/ios/Shared
check "keyboard sources import audio code" \
  "${import}(AVFAudio|AVFoundation)\b" apps/ios/Keyboard
check "keyboard or shared sources import ActivityKit or AppIntents" \
  "${import}(ActivityKit|AppIntents)\b" apps/ios/Keyboard apps/ios/Shared
check "widget or intent sources import speech, storage, network or audio code" \
  "${import}(Network|FluidAudio|GRDB|LocalFlowCore|LocalFlowSpeech|AVFAudio|AVFoundation)\b|URLSession" \
  apps/ios/Widgets apps/ios/Intents
[ "$fail" -eq 0 ] || exit 1
echo "keyboard and widget sources import no speech, storage, network or audio code"
