# Pending manual acceptance

Prepared 2026-09-18 at the user's request. None of these checks has been performed
for phases 12–14. Use the signed app on the reference M5 with its provisioned model.
Keep audio and spoken/reference text in private local storage.

For each result, record the commit/build, hardware, macOS, model revision, planner
version, conditions, exact procedure and evidence location. A test-suite pass does
not complete any checkbox below.

- [ ] **T076:** Transcribe an existing pre-005 meeting. Check final coverage against
  recorded duration (within one second), and verify the descriptor for recovered
  stretches in an interrupted meeting. Record in [baseline.md](baseline.md).
- [ ] **T082:** Delete a transcribed meeting through the existing confirmation UI.
  Verify its transcript rows are gone, usage drops by its counters, and another
  meeting's rows/audio are unchanged. Force-quit during live capture, relaunch,
  verify preserved provisional text and Retry. Record in [baseline.md](baseline.md).
- [ ] **T087:** Record the 60-minute capture-only baseline, sampling RSS every ten
  seconds. Record in [long-run-memory.md](long-run-memory.md).
- [ ] **T088:** Record at least 60 minutes with transcription, fixture playback,
  speech, one pause/resume and notes edits. Report RSS levels/slope, queue depth,
  gaps, coverage, finalization duration/RTF and storage growth in
  [long-run-memory.md](long-run-memory.md).
- [ ] **T089:** During T088, speak twenty short phrases with five seconds of silence
  between them. Report latency median and p95 in [live-latency.md](live-latency.md).
- [ ] **T090:** Run twenty minutes with `--debug-slow-recognition 3`. Verify bounded
  queues, complete source recordings and final coverage of speech. Record in
  [long-run-memory.md](long-run-memory.md).
- [ ] **T091:** Force-quit during live capture and during finalization. Compare
  persisted rows before/after resume and record outcomes in [recovery.md](recovery.md).
- [ ] **T092:** Run the Feature 002 fixtures through finalization with the real
  model; compare WER per fixture set in [accuracy-parity.md](accuracy-parity.md).
- [ ] **T093:** Search recorder exports and system logs from the above runs for
  three spoken phrases and one note phrase. Record commands/results, without
  publishing private phrases, in [privacy.md](privacy.md).
- [ ] **T094:** Run a full meeting with transcription off. Verify zero model-loading
  phases and compare recording resource use with Feature 004 in
  [long-run-memory.md](long-run-memory.md).

The baseline, live and slow runs alone require at least 140 minutes. Latency
measurement shares the live run. Follow [quickstart.md](../quickstart.md) for the
full procedures and numeric gates. Earlier feature acceptance left pending in
[tasks.md](../tasks.md) remains pending too.
