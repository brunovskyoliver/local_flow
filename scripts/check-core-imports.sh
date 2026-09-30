#!/usr/bin/env bash
# Feature 016: packages/LocalFlowCore builds for macOS and iOS. It imports no UI or
# Mac-only framework, LocalFlowSpeech imports no GRDB, and platform services come in
# as parameters rather than through Mac APIs or `#if os(` branches.
set -euo pipefail
cd "$(dirname "$0")/.."
sources=packages/LocalFlowCore/Sources
import='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(class[[:space:]]+|struct[[:space:]]+|enum[[:space:]]+|func[[:space:]]+)?'
status=0
if grep -rnE "${import}(AppKit|UIKit|SwiftUI|Carbon|ApplicationServices|ScreenCaptureKit|ServiceManagement|Cocoa)\b" "$sources"; then
  echo "LocalFlowCore imports a UI or Mac-only framework" >&2
  status=1
fi
if grep -rnE "${import}GRDB\b" "$sources/LocalFlowSpeech"; then
  echo "LocalFlowSpeech imports GRDB" >&2
  status=1
fi
if grep -rnE '\bProcess\b|NSWorkspace|homeDirectoryForCurrentUser|CGPreflight|#if os\(' "$sources"; then
  echo "LocalFlowCore uses a Mac-only API or a platform branch" >&2
  status=1
fi
[[ $status -eq 0 ]] && echo "LocalFlowCore sources import no UI, Mac-only API or platform branch"
exit $status
