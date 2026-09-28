#!/usr/bin/env bash
# Feature 014 SC-009, research R15: logs never carry credentials or content. Scans the
# given log files (flowd logs, captured worker stderr, test output) and, with
# --unified-log MINUTES, the app's unified log for that many recent minutes, for:
#   access and refresh tokens (lfa_, lfr_), JWTs (eyJ…), the reference phrases of the
#   audio fixtures, and the Dictionary terms of the Feature 013 boost corpora.
# Reports file, line and the kind of match only, never the matched text.
#   scripts/check-remote-logs.sh [--unified-log MINUTES] [FILE...]
set -euo pipefail
cd "$(dirname "$0")/.."
minutes=""
if [[ "${1:-}" == --unified-log ]]; then
  minutes="${2:?minutes}"
  shift 2
fi
files=("$@")
work="$(mktemp -d "${TMPDIR:-/tmp}/localflow-log-scan.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [[ -n "$minutes" ]]; then
  /usr/bin/log show --last "${minutes}m" --style compact \
    --predicate 'subsystem BEGINSWITH "org.localflow.LocalFlow"' >"$work/unified.log" 2>/dev/null || true
  files+=("$work/unified.log")
fi
[[ ${#files[@]} -gt 0 ]] || { echo "usage: $0 [--unified-log MINUTES] [FILE...]" >&2; exit 64; }
python3 - "${files[@]}" <<'PY'
import json, re, sys
from pathlib import Path

patterns = [
    ("token", re.compile(r"\blf[ar]_[A-Za-z0-9_-]{8,}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}")),
]
phrases = []
for fixture in json.loads(Path("fixtures/audio/manifest.json").read_text())["fixtures"]:
    words = re.findall(r"\w+", fixture["reference"].lower())
    if len(words) >= 4:
        phrases.append(" ".join(words[:4]))
# Product names that also name components in operational log lines.
operational = {"MTPLX", "LocalFlow"}
terms = set()
for corpus in ("tuning", "heldout"):
    data = json.loads(Path(f"fixtures/vocabulary-boost/{corpus}.json").read_text())
    for entry in data.get("vocabulary", []):
        for term in [entry["canonical"], *entry.get("aliases", [])]:
            if len(term) >= 4 and term not in operational:
                terms.add(term)
term_pattern = re.compile(
    r"(?<![\w-])(" + "|".join(sorted(map(re.escape, terms), key=len, reverse=True)) + r")(?![\w-])")

hits = 0
for name in sys.argv[1:]:
    path = Path(name)
    if not path.exists():
        continue
    for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        kinds = [kind for kind, pattern in patterns if pattern.search(line)]
        folded = " ".join(re.findall(r"\w+", line.lower()))
        if any(phrase in folded for phrase in phrases):
            kinds.append("fixture phrase")
        if term_pattern.search(line):
            kinds.append("dictionary term")
        for kind in kinds:
            print(f"{path}:{number}: {kind}")
            hits += 1
if hits:
    print(f"log scan: {hits} finding(s)", file=sys.stderr)
    sys.exit(1)
print(f"log scan: no tokens, JWTs, fixture phrases or Dictionary terms in {len(sys.argv) - 1} file(s)")
PY
