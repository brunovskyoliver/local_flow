#!/usr/bin/env bash
# Feature 016 SC-003, Mac side: fetch the fixtures in fixtures/audio/manifest.json and
# transcribe them through the Mac production dictation path (WindowedTranscriber production
# profile, TranscriptAssembler, TranscriptNormalizer with an empty Dictionary, so the
# term booster has nothing to spot). Writes OUTPUT_DIR/<id>.txt per fixture plus the raw
# results.json. Never called by make check.
# Usage: transcribe-dictation-fixtures.sh [OUTPUT_DIR]
# The model defaults to the installed app's; override with LOCALFLOW_MODEL_ROOT.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [OUTPUT_DIR]\n' "$0" >&2
  exit 2
fi
manifest=fixtures/audio/manifest.json
fixture_root=build/speech-fixtures
model_root="${LOCALFLOW_MODEL_ROOT:-$HOME/Library/Application Support/LocalFlow/Models/parakeet-v3}"
if [[ ! -d "$model_root" ]]; then
  printf 'No provisioned Parakeet v3 model at %s; set LOCALFLOW_MODEL_ROOT.\n' "$model_root" >&2
  exit 1
fi
# Hash-checks an existing corpus; downloads only what is missing.
python3 scripts/download-speech-fixtures.py --download --root "$fixture_root" --manifest "$manifest"
umask 077
output="${1:-$fixture_root/transcripts/mac}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
export TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT="$(cd "$model_root" && pwd)"
export TEST_RUNNER_LOCALFLOW_SPEECH_FIXTURE_ROOT="$(cd "$fixture_root" && pwd)"
export TEST_RUNNER_LOCALFLOW_SPEECH_MANIFEST="$PWD/$manifest"
export TEST_RUNNER_LOCALFLOW_ACCURACY_OUTPUT="$output/results.json"
export TEST_RUNNER_LOCALFLOW_SPEECH_PROFILE=production
rm -f "$output/results.json"
if ! xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalFlowTests/RuntimeCompatibilityTests/testOptInSpeechFixtures test \
  >"$output/test.log" 2>&1; then
  printf 'Transcription failed; see %s/test.log\n' "$output" >&2
  exit 1
fi
# A skipped test writes nothing; never report an empty run as complete.
[[ -s "$output/results.json" ]] || { printf 'No results written (test skipped?).\n' >&2; exit 1; }
python3 - "$output" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
results = json.loads((root / 'results.json').read_text())
for row in results:
    (root / f"{row['id']}.txt").write_text(row['text'] + '\n')
incomplete = [row['id'] for row in results if row['incomplete']]
print(f"{len(results)} transcripts in {root}; incomplete: {', '.join(incomplete) or 'none'}")
PY
printf 'hardware=%s os=%s build=%s\n' "$(sysctl -n machdep.cpu.brand_string)" \
  "$(sw_vers -productVersion)" "$(git rev-parse --short HEAD)"
