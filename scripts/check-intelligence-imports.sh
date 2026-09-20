#!/usr/bin/env bash
# Feature 011: the intelligence module is network-free except for the single
# URLSession transport, and it never touches a model runtime or the lifecycle
# owner. Evidence and the spec 010 identity tables are read-only for it.
set -euo pipefail
cd "$(dirname "$0")/.."
scope="apps/macos/LocalFlow/Core/Intelligence apps/macos/LocalFlow/Core/IntelligenceBoundaries.swift apps/macos/LocalFlow/Core/Storage/AnalysisStore.swift apps/macos/LocalFlow/Features/Intelligence"
if grep -rnE 'FluidAudio|whisper|WhisperKit|ModelLifecycleCoordinator|ModelFactory|makeRuntime' $scope 2>/dev/null; then
  echo "intelligence module references a model runtime or lifecycle owner" >&2
  exit 1
fi
network_hits=$(grep -rlnE 'URLSession|URLRequest|import Network|NWConnection' $scope 2>/dev/null || true)
for file in $network_hits; do
  if [[ "$file" != *"Core/Intelligence/AnalysisClient.swift" ]]; then
    echo "networking outside AnalysisClient: $file" >&2
    exit 1
  fi
done
echo "intelligence module boundaries hold"
