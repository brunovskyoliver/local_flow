#!/usr/bin/env bash
# Explicit, sequential real-model run of the production pipeline stages (fixed contiguous
# 239,360-sample windows, TranscriptAssembler, empty-vocabulary TranscriptNormalizer) over the
# frozen short and long-form corpora. Never called by make check. Each corpus runs twice and
# every run is scored twice so determinism is checked on exact stage bytes.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 4 ]]; then
  printf 'Usage: %s SHORT_CORPUS_ROOT LONG_CORPUS_ROOT NEW_OUTPUT_ROOT PROVISIONED_MODEL_ROOT\n' "$0" >&2
  exit 1
fi
corpus_root="$(cd "$1" && pwd)"
long_corpus_root="$(cd "$2" && pwd)"
model_root="$(cd "$4" && pwd)"
python3 scripts/acquire-quality-corpus.py --validate-only --root "$corpus_root" \
  --lock fixtures/quality/public-selection-lock.json
python3 scripts/acquire-quality-corpus.py --validate-only --long-form --root "$long_corpus_root" \
  --lock fixtures/quality/public-long-form-selection-lock.json
umask 077
mkdir -m 700 "$3"
output_root="$(cd "$3" && pwd)"
mkdir -m 700 "$output_root/scores"
export TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT="$model_root"
export TEST_RUNNER_LOCALFLOW_QUALITY_HARDWARE="$(sysctl -n machdep.cpu.brand_string)"
export TEST_RUNNER_LOCALFLOW_QUALITY_POWER="$(pmset -g batt | head -1)"
export TEST_RUNNER_LOCALFLOW_QUALITY_BUILD="$(git rev-parse HEAD)"
export TEST_RUNNER_LOCALFLOW_QUALITY_DIRTY="working_tree_snapshot"
export TEST_RUNNER_LOCALFLOW_CHUNK_STRATEGY="production"
export TEST_RUNNER_LOCALFLOW_CHUNK_OVERLAP="0"
export TEST_RUNNER_LOCALFLOW_CHUNK_SEARCH_START="0"
export TEST_RUNNER_LOCALFLOW_CHUNK_NORMALIZE="1"
for corpus in short long; do
  if [[ "$corpus" == short ]]; then root="$corpus_root"; else root="$long_corpus_root"; fi
  export TEST_RUNNER_LOCALFLOW_SPEECH_FIXTURE_ROOT="$root"
  export TEST_RUNNER_LOCALFLOW_SPEECH_MANIFEST="$root/manifest.json"
  for label in a b; do
    run="production-$corpus-$label"
    export TEST_RUNNER_LOCALFLOW_CHUNK_OUTPUT="$output_root/$run"
    printf 'production %s pass %s started.\n' "$corpus" "$label"
    xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
      -scheme LocalFlow -configuration Debug -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
      -only-testing:LocalFlowTests/RuntimeCompatibilityTests/testOptInChunkGeometryExperiment test \
      > "$output_root/$run.log" 2>&1
    for pass in 1 2; do
      python3 scripts/transcription-quality.py score "$root/manifest.json" \
        "$output_root/$run" "$output_root/scores/$run-score$pass.json"
    done
    cmp "$output_root/scores/$run-score1.json" "$output_root/scores/$run-score2.json"
  done
  python3 - "$output_root" "production-$corpus" <<'PY'
import hashlib,json,sys
from pathlib import Path
root,name=Path(sys.argv[1]),sys.argv[2]
a=json.loads((root/f'{name}-a/run.json').read_bytes());b=json.loads((root/f'{name}-b/run.json').read_bytes())
assert a['status']==b['status']=='complete' and a['config']==b['config']
def stable(path):
    obj=json.loads(Path(path).read_bytes())
    for key in ('recognition_seconds','wall_seconds','rss','normalization_seconds'):
        obj.get('measurements',{}).pop(key,None)
    for key in ('recognition_seconds','wall_seconds','peak_rss_bytes'):
        obj.pop(key,None)
    return json.dumps(obj,sort_keys=True)
changed=[r['id'] for r in a['ledger']
         if stable(root/f'{name}-a/results/{r["id"]}.json')!=stable(root/f'{name}-b/results/{r["id"]}.json')]
chunks=[r['id'] for r in a['ledger']
        if stable(root/f'{name}-a/chunks/{r["id"]}.json')!=stable(root/f'{name}-b/chunks/{r["id"]}.json')]
print(json.dumps({'strategy_corpus':name,'fixtures':len(a['ledger']),
                  'nondeterministic_results':len(changed),'nondeterministic_chunk_plans':len(chunks),
                  'run_sha256_a':hashlib.sha256((root/f'{name}-a/run.json').read_bytes()).hexdigest(),
                  'run_sha256_b':hashlib.sha256((root/f'{name}-b/run.json').read_bytes()).hexdigest()},sort_keys=True))
PY
done
