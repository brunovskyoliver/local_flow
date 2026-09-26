# Research: Dictionary term boosting and suggestions

## R1 — Approach

Options within "no bigger model": aliases only (today), prompting or fine-tuning Parakeet (not exposed by FluidAudio 0.15.7), and CTC keyword spotting with rescoring (FluidAudio's context biasing, a 110M CTC encoder next to the TDT decoder). Chosen: CTC spotting, using the public `CtcKeywordSpotter`, `VocabularyRescorer` and `ctcTokenRescore` APIs with an explicit model directory.

## R2 — Gating rules (policy `ctc110m-v1`, rule `V002`)

FluidAudio's rescorer alone made clips worse (it replaced real words such as "network" and Slovak inflections). Each rule below removed a regression seen on the tuning set:

1. TDT confidence of the covered tokens below 0.9; unmatched spans are left alone.
2. Not every word is a correct English word (system spell checker).
3. Not an inflection of the term (shared prefix of at least 3 and at least the term length minus one).
4. Folded similarity (letters and digits, no diacritics, Levenshtein) at least 0.6.
5. Slovak window: similarity at least 0.8 and no lowercase word of 3 letters or fewer.
6. The span is not already a canonical spelling or alias in the Dictionary (the user's own mapping wins; found on real speech: "Whisperflow" must stay with its "Wispr Flow" entry).

## R3 — Benchmark

Harness: `scripts/vocabulary-boost-benchmark.sh` runs the production runtime (`FluidAudioRuntime`, Release build) twice per clip, without and with the Dictionary; `scripts/vocabulary-boost-quality.py` scores WER, term recall, false insertions and clips better or worse, and fails when any clip is worse. Corpora: `fixtures/vocabulary-boost/tuning.json` (46 terms, rules were tuned on it) and `heldout.json` (45 terms, run once after tuning), spoken with macOS voices by `scripts/generate-vocabulary-boost-corpus.py`; the public English and Slovak quality corpus; and the owner's 369 minutes of meeting audio (1,585 windows). Audio and results stay in `build/`.

Measured on the M5, macOS 27, build `6a32362` plus the working tree:

| Set | WER before | WER after | Term recall before | Term recall after | Worse clips |
| --- | --- | --- | --- | --- | --- |
| Tuning, English | 11.40% | 9.55% | 60.7% | 75.3% | 0 |
| Tuning, Slovak | 26.97% | 24.21% | 47.4% | 57.9% | 0 |
| Tuning, negatives | unchanged | unchanged | – | – | 0 |
| Held-out, English | 10.47% | 7.92% | 64.3% | 79.1% | 0 |
| Held-out, Slovak | 36.58% | 34.74% | 33.3% | 41.7% | 0 |
| Public English and Slovak | unchanged | unchanged | – | – | 0 |
| Real meetings | 0 of 1,585 windows changed | | | | 0 |

No false term insertions in any set. Latency per window: about 65 ms before and 118 ms after on TTS clips; 91 ms before and 142 ms after on real audio (p95 163 ms). Memory: about 8 MB more process footprint after loading, 7–17 MB after a run.

Limits: TTS is a proxy; no recording of the owner's own English was available. The spotter is English-trained, so Slovak gains are modest, and rule 5 blocks some correct real-voice fixes ("sabkui" → "SAPGUI").

## R4 — Suggestion sources

Checked on the owner's history: 214 dictation contexts, 9 meetings with no notes or titles, 556 final meeting segments. Meeting segments recurring in at least two meetings gave only "OK" and two Slovak place names, so meeting transcripts are not a source: they come from the same recognizer and carry its misspellings. Sources kept: corrections the scorer rated `suggest` (one sighting is enough, it is the user's own spelling) and context terms seen in at least three dictations that have a capital or a digit, are not files, paths, snake_case, hashes or UUIDs, and are not all English words. On the owner's data this suggests one term; DHCP, SNMP and ChatGPT are known to the spell checker and are dropped. Computing suggestions took 13 ms.
