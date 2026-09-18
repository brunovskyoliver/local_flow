#!/usr/bin/env bash
# Replay frozen recognition evidence through the Swift assembler. No model is loaded.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 3 ]]; then
  printf 'Usage: %s CORPUS_ROOT BASELINE_RUN NEW_OUTPUT_ROOT\n' "$0" >&2
  exit 1
fi
corpus_root="$(cd "$1" && pwd)"
baseline_root="$(cd "$2" && pwd)"
python3 scripts/acquire-quality-corpus.py --validate-only --root "$corpus_root" \
  --lock fixtures/quality/public-selection-lock.json
umask 077
mkdir -m 700 "$3"
replay_root="$(cd "$3" && pwd)"
mkdir -m 700 "$replay_root/scores"
python3 - "$baseline_root" "$replay_root/source-hashes.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
paths=sorted(set(Path('apps/macos').rglob('*.swift')) | set(Path('scripts').glob('*.py')) |
             set(Path('scripts').glob('*.sh')) | {Path('apps/macos/LocalFlow.xcodeproj/project.pbxproj'),
             Path('fixtures/quality/assembly-cases.json')})
obj={'sources':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
     'baseline_files':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path(sys.argv[1]).rglob('*.json'))}}
Path(sys.argv[2]).write_text(json.dumps(obj,sort_keys=True,indent=2)+'\n')
PY
export TEST_RUNNER_LOCALFLOW_ASSEMBLY_MANIFEST="$corpus_root/manifest.json"
export TEST_RUNNER_LOCALFLOW_ASSEMBLY_BASELINE="$baseline_root"
for label in a b; do
  export TEST_RUNNER_LOCALFLOW_ASSEMBLY_OUTPUT="$replay_root/run-$label"
  xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
    -only-testing:LocalFlowTests/TranscriptAssemblerTests/testOptInFrozenCorpusReplay test \
    > "$replay_root/replay-$label.log" 2>&1
  for repetition in 1 2; do
    python3 scripts/transcription-quality.py score "$corpus_root/manifest.json" \
      "$replay_root/run-$label" "$replay_root/scores/$label-$repetition.json"
  done
  cmp "$replay_root/scores/$label-1.json" "$replay_root/scores/$label-2.json"
done
python3 scripts/transcription-quality.py score "$corpus_root/manifest.json" \
  "$baseline_root" "$replay_root/scores/baseline-rescore.json"
python3 scripts/transcription-quality.py compare "$corpus_root/manifest.json" \
  "$baseline_root" "$replay_root/run-a" "$replay_root/scores/compare.json"
python3 - "$baseline_root" "$replay_root" <<'PY'
import hashlib,json,sys
from pathlib import Path
baseline,root=map(Path,sys.argv[1:])
snapshot=json.loads((root/'source-hashes.json').read_bytes())
for p,h in snapshot['baseline_files'].items():
    assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h
run=json.loads((root/'run-a/run.json').read_bytes())
for row in run['ledger']:
    name=row['id']+'.json'
    old=json.loads((baseline/'results'/name).read_bytes())
    new=json.loads((root/'run-a/results'/name).read_bytes())
    assert old['windows']==new['windows'] and old['stages']['raw']==new['stages']['raw']
    assert old['stages']['normalized']==new['stages']['normalized']
    for directory in ('results','seams'):
        assert (root/'run-a'/directory/name).read_bytes()==(root/'run-b'/directory/name).read_bytes()
receipt=dict(fixtures=len(run['ledger']),raw_evidence_unchanged=True,
             exact_repeated_results=True,exact_repeated_seams=True,frozen_baseline_unchanged=True)
(root/'verification.json').write_text(json.dumps(receipt,sort_keys=True)+'\n')
print(json.dumps(receipt,sort_keys=True))
PY
