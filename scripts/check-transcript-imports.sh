#!/usr/bin/env bash
# Feature 005, FR-027: the transcript module has no path into Feature 003 rewriting.
set -euo pipefail
cd "$(dirname "$0")/.."
if grep -rnE 'RewriteRequesting|RewriteCoordinator|RewriteClient' \
  apps/macos/LocalFlow/Core/Transcripts apps/macos/LocalFlow/Features/Transcripts \
  apps/macos/LocalFlow/Core/TranscriptBoundaries.swift packages/LocalFlowCore/Sources/LocalFlowCore/Transcripts \
  packages/LocalFlowCore/Sources/LocalFlowSpeech; then
  echo "transcript module references rewriting" >&2
  exit 1
fi
echo "transcript module has no rewrite entry point"
