#!/usr/bin/env bash
# Feature 010, FR-034/FR-036: the identification module has no networking path. The
# embedder loads from the verified local model directory only.
set -euo pipefail
cd "$(dirname "$0")/.."
if grep -rnE 'import Network|URLSession|URLRequest|NWConnection|CFNetwork' \
  apps/macos/LocalFlow/Core/Identification apps/macos/LocalFlow/Core/IdentificationBoundaries.swift \
  apps/macos/LocalFlow/Core/Storage/IdentityStore.swift apps/macos/LocalFlow/Features/Speakers \
  packages/LocalFlowCore/Sources/LocalFlowCore/Transcripts/SpeakerIdentityQuery.swift \
  packages/LocalFlowCore/Sources/LocalFlowCore/Transcripts/MergedIdentityRule.swift; then
  echo "identification module references networking" >&2
  exit 1
fi
echo "identification module has no networking entry point"
