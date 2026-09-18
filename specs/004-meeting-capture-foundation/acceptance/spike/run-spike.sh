#!/usr/bin/env bash
# Runs the codec recoverability spike: each writer is killed with SIGKILL at 5,
# 20 and 55 s of a 60 s recording, then the file is checked with AVAudioFile.
# Output: one line per run in $OUT (default: build/codec-spike/results.txt).
set -uo pipefail
cd "$(dirname "$0")"
OUT=${OUT:-$PWD/../../../../build/codec-spike}
mkdir -p "$OUT"
BIN="$OUT/codec-spike"
swiftc -O -o "$BIN" codec-spike.swift 2>"$OUT/compile.log" || { cat "$OUT/compile.log"; exit 1; }
: > "$OUT/results.txt"
for writer in adts fmp4 m4a; do
  for kill_at in 5 20 55; do
    ext=$writer; [[ $writer == fmp4 ]] && ext=mp4
    file="$OUT/$writer-kill$kill_at.$ext"
    rm -f "$file"
    "$BIN" record "$writer" "$file" 60 > "$OUT/$writer-kill$kill_at.log" 2>&1 &
    pid=$!
    sleep "$kill_at"
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    last=$(tail -n 1 "$OUT/$writer-kill$kill_at.log")
    result=$("$BIN" check "$writer" "$file" 2>&1)
    echo "killAt=$kill_at lastProgress=[$last] $result" | tee -a "$OUT/results.txt"
  done
done
echo "done" >> "$OUT/results.txt"
