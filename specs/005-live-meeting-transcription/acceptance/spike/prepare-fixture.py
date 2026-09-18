#!/usr/bin/env python3
"""Build a synthetic ten-minute throughput fixture from pinned online speech.

Run scripts/download-speech-fixtures.py --download first. Audio stays in build/.
This concatenates licensed utterances; it is not a conversation or accuracy set.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[4]
OUT = ROOT / "build/005-throughput-fixtures"
OUT.mkdir(parents=True, exist_ok=True)
manifest = json.loads((ROOT / "fixtures/audio/manifest.json").read_text())
rows = {row["id"]: row for row in manifest["fixtures"]}
order = [f"{language}-{index:02}" for index in range(1, 11) for language in ("en", "sk")]
limit = 600 * 16000
written = 0
turns = []
with wave.open(str(OUT / "synthetic-meeting-600s.wav"), "wb") as output:
    output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    turn = 0
    while written < limit:
        row = rows[order[turn % len(order)]]
        source = ROOT / manifest["fixture_root"] / row["path"]
        with source.open("rb") as handle:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
        assert digest == row["sha256"], source
        start = written
        with wave.open(str(source), "rb") as audio:
            assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 16000)
            while written < limit:
                block = audio.readframes(min(4096, limit - written))
                if not block:
                    break
                output.writeframesraw(block)
                written += len(block) // 2
        turns.append({"source_id": row["id"], "source_sha256": digest,
                      "start_sample": start, "end_sample": written})
        pause = min(8000 if turn % 5 else 32000, limit - written)
        while pause:
            count = min(pause, 4096)
            output.writeframesraw(bytes(count * 2))
            written += count
            pause -= count
        turn += 1
subprocess.run([
    "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(OUT / "synthetic-meeting-600s.wav"),
    "-ar", "48000", "-ac", "2", "-c:a", "aac", "-b:a", "128k", "-f", "adts",
    str(OUT / "synthetic-meeting-600s.aac"),
], check=True)
receipt = {
    "fixture": "synthetic-meeting-600s", "classification": "synthetic_concatenation",
    "audio_seconds_before_aac": 600, "sample_rate_before_aac": 16000,
    "source_manifest": "fixtures/audio/manifest.json", "dataset": manifest["dataset"],
    "attribution": "Alexis Conneau et al., FLEURS (2022), Google",
    "license": "CC-BY-4.0 https://creativecommons.org/licenses/by/4.0/",
    "changes": "Alternate en/sk clips in index order, repeat, insert 0.5s pauses (2s every fifth turn), trim at 600s; encode 48kHz dual-mono AAC-LC 128kbit/s ADTS.",
    "limitations": "Unrelated repeated utterances, no real turn-taking, overlap, echo or separate mic/system capture. Throughput only.",
    "turns": turns,
    "ffmpeg": subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0],
    "files": {p.name: hashlib.file_digest(p.open("rb"), "sha256").hexdigest()
              for p in sorted(OUT.glob("synthetic-meeting-600s.*")) if p.suffix in (".wav", ".aac")},
}
(OUT / "manifest.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
print(f"Prepared {written / 16000:.0f}s synthetic audio; {len(turns)} turns")
