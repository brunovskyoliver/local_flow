#!/usr/bin/env bash
# Explicit, sequential real-model chunk-geometry experiment. Never called by make check.
# One ASR model instance at a time; audio is read one bounded chunk at a time from the spool.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 5 ]]; then
  printf 'Usage: %s SHORT_CORPUS_ROOT LONG_CORPUS_ROOT NEW_OUTPUT_ROOT PROVISIONED_MODEL_ROOT VAD_MODEL_ROOT\n' "$0" >&2
  exit 1
fi
corpus_root="$(cd "$1" && pwd)"
long_corpus_root="$(cd "$2" && pwd)"
model_root="$(cd "$4" && pwd)"
vad_root="$(cd "$5" && pwd)"
python3 scripts/acquire-quality-corpus.py --validate-only --root "$corpus_root" \
  --lock fixtures/quality/public-selection-lock.json
python3 scripts/acquire-quality-corpus.py --validate-only --long-form --root "$long_corpus_root" \
  --lock fixtures/quality/public-long-form-selection-lock.json
umask 077
mkdir -m 700 "$3"
output_root="$(cd "$3" && pwd)"
mkdir -m 700 "$output_root/scores"
export TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT="$model_root"
export TEST_RUNNER_LOCALFLOW_VAD_MODEL_ROOT="$vad_root"
export TEST_RUNNER_LOCALFLOW_QUALITY_HARDWARE="$(sysctl -n machdep.cpu.brand_string)"
export TEST_RUNNER_LOCALFLOW_QUALITY_POWER="$(pmset -g batt | head -1)"
export TEST_RUNNER_LOCALFLOW_QUALITY_BUILD="$(git rev-parse HEAD)"
export TEST_RUNNER_LOCALFLOW_QUALITY_DIRTY="working_tree_snapshot"
# name:overlap_samples:silence_search_start:mode
for spec in contiguous-fixed:0:0:unused vad-min:0:205715:minimum vad-preferred:0:205715:threshold; do
  name="${spec%%:*}"; rest="${spec#*:}"
  overlap="${rest%%:*}"; rest="${rest#*:}"
  search="${rest%%:*}"; mode="${rest#*:}"
  export TEST_RUNNER_LOCALFLOW_CHUNK_STRATEGY="$name"
  export TEST_RUNNER_LOCALFLOW_CHUNK_OVERLAP="$overlap"
  export TEST_RUNNER_LOCALFLOW_CHUNK_SEARCH_START="$search"
  export TEST_RUNNER_LOCALFLOW_CHUNK_VAD_THRESHOLD="0.2"
  export TEST_RUNNER_LOCALFLOW_CHUNK_VAD_MODE="$mode"
  for corpus in short long; do
    if [[ "$corpus" == short ]]; then root="$corpus_root"; else root="$long_corpus_root"; fi
    export TEST_RUNNER_LOCALFLOW_SPEECH_FIXTURE_ROOT="$root"
    export TEST_RUNNER_LOCALFLOW_SPEECH_MANIFEST="$root/manifest.json"
    for label in a b; do
      run="$name-$corpus-$label"
      export TEST_RUNNER_LOCALFLOW_CHUNK_OUTPUT="$output_root/$run"
      printf '%s %s pass %s started.\n' "$name" "$corpus" "$label"
      xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
        -scheme LocalFlow -configuration Debug -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
        -only-testing:LocalFlowTests/RuntimeCompatibilityTests/testOptInChunkGeometryExperiment test \
        > "$output_root/$run.log" 2>&1
      python3 scripts/transcription-quality.py score "$root/manifest.json" \
        "$output_root/$run" "$output_root/scores/$run.json"
    done
    python3 - "$output_root" "$name-$corpus" <<'PY'
import hashlib,json,sys
from pathlib import Path
root,name=Path(sys.argv[1]),sys.argv[2]
a=json.loads((root/f'{name}-a/run.json').read_bytes());b=json.loads((root/f'{name}-b/run.json').read_bytes())
assert a['status']==b['status']=='complete' and a['config']==b['config']
def stable(path):
    obj=json.loads(Path(path).read_bytes())
    for key in ('recognition_seconds','wall_seconds','rss'):
        obj.get('measurements',{}).pop(key,None)
    for key in ('recognition_seconds','wall_seconds','peak_rss_bytes'):
        obj.pop(key,None)
    return json.dumps(obj,sort_keys=True)
changed=[r['id'] for r in a['ledger']
         if stable(root/f'{name}-a/results/{r["id"]}.json')!=stable(root/f'{name}-b/results/{r["id"]}.json')]
chunks=[r['id'] for r in a['ledger']
        if stable(root/f'{name}-a/chunks/{r["id"]}.json')!=stable(root/f'{name}-b/chunks/{r["id"]}.json')]
print(json.dumps({'strategy_corpus':name,'fixtures':len(a['ledger']),
                  'nondeterministic_results':len(changed),'nondeterministic_chunk_plans':len(chunks)},sort_keys=True))
PY
  done
done
