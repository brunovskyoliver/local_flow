#!/usr/bin/env bash
# Explicit, sequential real-model evaluation. Never called by make check.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 3 ]]; then
  printf 'Usage: %s CORPUS_ROOT NEW_OUTPUT_ROOT PROVISIONED_MODEL_ROOT\n' "$0" >&2
  exit 1
fi
corpus_root="$(cd "$1" && pwd)"
output_root="$2"
model_root="$(cd "$3" && pwd)"
python3 scripts/acquire-quality-corpus.py --validate-only --root "$corpus_root" \
  --lock fixtures/quality/public-selection-lock.json
umask 077
mkdir -m 700 "$output_root"
output_root="$(cd "$output_root" && pwd)"
mkdir -m 700 "$output_root/scores"
python3 - "$output_root/source-hashes.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
paths=sorted(set(Path('apps/macos').rglob('*.swift')) | set(Path('scripts').glob('*.py')) |
             set(Path('scripts').glob('*.sh')) | {Path('apps/macos/LocalFlow.xcodeproj/project.pbxproj'),
             Path('apps/macos/LocalFlow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')})
Path(sys.argv[1]).write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},sort_keys=True,indent=2)+'\n')
PY
export TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT="$model_root"
export TEST_RUNNER_LOCALFLOW_SPEECH_FIXTURE_ROOT="$corpus_root"
export TEST_RUNNER_LOCALFLOW_SPEECH_MANIFEST="$corpus_root/manifest.json"
export TEST_RUNNER_LOCALFLOW_QUALITY_HARDWARE="$(sysctl -n machdep.cpu.brand_string)"
export TEST_RUNNER_LOCALFLOW_QUALITY_POWER="$(pmset -g batt | head -1)"
export TEST_RUNNER_LOCALFLOW_QUALITY_BUILD="$(git rev-parse HEAD)"
source_hash="$(shasum -a 256 "$output_root/source-hashes.json" | cut -d ' ' -f 1)"
export TEST_RUNNER_LOCALFLOW_QUALITY_DIRTY="working_tree_snapshot_sha256=$source_hash"
for label in a b; do
  [[ "$(pmset -g batt | head -1)" == "$TEST_RUNNER_LOCALFLOW_QUALITY_POWER" ]]
  export TEST_RUNNER_LOCALFLOW_QUALITY_OUTPUT="$output_root/run-$label"
  printf 'Recognition pass %s started.\n' "$label"
  xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
    -scheme LocalFlow -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
    -only-testing:LocalFlowTests/RuntimeCompatibilityTests/testOptInQualityFixtures test \
    > "$output_root/run-$label.log" 2>&1
  for repetition in 1 2; do
    python3 scripts/transcription-quality.py score "$corpus_root/manifest.json" \
      "$output_root/run-$label" "$output_root/scores/$label-$repetition.json"
  done
  cmp "$output_root/scores/$label-1.json" "$output_root/scores/$label-2.json"
  printf 'Recognition pass %s finished; repeated scoring is byte-identical.\n' "$label"
done
python3 scripts/transcription-quality.py compare "$corpus_root/manifest.json" \
  "$output_root/run-a" "$output_root/run-b" "$output_root/scores/compare.json"
# Compare original received timing/window evidence too; score summaries alone do not cover it.
python3 - "$output_root" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);a=json.loads((root/'run-a/run.json').read_text());b=json.loads((root/'run-b/run.json').read_text())
assert a['status']==b['status']=='complete'
assert a['config']==b['config'] and a['manifest_sha256']==b['manifest_sha256']
assert [r['id'] for r in a['ledger']]==[r['id'] for r in b['ledger']]
changes=[]
for left,right in zip(a['ledger'],b['ledger']):
    ident=left['id'];x=(root/f'run-a/results/{ident}.json').read_bytes();y=(root/f'run-b/results/{ident}.json').read_bytes()
    assert hashlib.sha256(x).hexdigest()==left['result_sha256']
    assert hashlib.sha256(y).hexdigest()==right['result_sha256']
    if x!=y:changes.append(ident)
(root/'scores/exact-result-comparison.json').write_text(json.dumps({'fixtures':len(a['ledger']),'changed_result_ids':changes},sort_keys=True)+'\n')
print(json.dumps({'fixtures':len(a['ledger']),'changed_results':len(changes)}))
PY
