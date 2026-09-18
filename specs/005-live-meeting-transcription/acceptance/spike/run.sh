#!/usr/bin/env bash
# Six sequential real-model runs, each in a fresh test-host process. Never in make check.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
if [[ $# -ne 4 ]]; then
  printf 'Usage: %s LONG_WAV MEETING_AUDIO MODEL_ROOT NEW_OUTPUT_DIR\n' "$0" >&2
  exit 1
fi
long_audio="$1"
meeting_audio="$2"
model_root="$3"
output_root="$4"
for path in "$long_audio" "$meeting_audio" "$model_root" "$output_root"; do
  [[ "$path" == /* ]] || { printf 'All paths must be absolute.\n' >&2; exit 1; }
done
[[ -f "$long_audio" && -f "$meeting_audio" && -f "$model_root/manifest.json" ]]
umask 077
mkdir "$output_root"
export TEST_RUNNER_LOCALFLOW_MEETING_THROUGHPUT=1
export TEST_RUNNER_LOCALFLOW_THROUGHPUT_MODEL="$model_root"
export TEST_RUNNER_LOCALFLOW_THROUGHPUT_HARDWARE="$(sysctl -n hw.model) / $(sysctl -n machdep.cpu.brand_string) / $(sysctl -n hw.memsize) bytes"
export TEST_RUNNER_LOCALFLOW_THROUGHPUT_BUILD="$(git rev-parse HEAD) + Feature 005 working tree; Release -O, ENABLE_TESTABILITY=YES, Xcode $(xcodebuild -version | head -1)"
export TEST_RUNNER_LOCALFLOW_THROUGHPUT_POWER="$(pmset -g batt | head -1)"
# Capture source identity, including new untracked Swift files, without transcript content.
python3 - "$output_root" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
roots=[Path('apps/macos/LocalFlow'),Path('apps/macos/LocalFlowTests'),Path('specs/005-live-meeting-transcription/acceptance/spike')]
paths=sorted([p for root in roots for p in root.rglob('*') if p.is_file() and p.suffix in ('.swift','.py','.sh')]+[Path('apps/macos/LocalFlow.xcodeproj/project.pbxproj')])
result={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
Path(sys.argv[1],'source-hashes.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
PY
for fixture in long-continuous synthetic-meeting; do
  if [[ "$fixture" == long-continuous ]]; then audio="$long_audio"; else audio="$meeting_audio"; fi
  export TEST_RUNNER_LOCALFLOW_THROUGHPUT_AUDIO="$audio"
  export TEST_RUNNER_LOCALFLOW_THROUGHPUT_FIXTURE="$fixture"
  for run in 1 2 3; do
    export TEST_RUNNER_LOCALFLOW_THROUGHPUT_RUN="$run"
    export TEST_RUNNER_LOCALFLOW_THROUGHPUT_OUTPUT="$output_root/$fixture-$run.json"
    printf 'Measuring %s run %s\n' "$fixture" "$run"
    xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow \
      -configuration Release -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
      -only-testing:LocalFlowTests/MeetingThroughputTests/testOptInThroughput test \
      > "$output_root/$fixture-$run.log" 2>&1
    test -s "$output_root/$fixture-$run.json"
  done
done
