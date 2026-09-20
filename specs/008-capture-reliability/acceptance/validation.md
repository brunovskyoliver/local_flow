# Validation evidence

## Red reproductions

- Production ring: 19,200 offered frames, 15,360 emitted, 3,840 dropped; timeline assertion exited 1.
- Real worker/real AAC encoder: stalled progress recipient with 40 callbacks overflowed 32 slots, losing exactly 32,768 frames. Two runs failed the same three assertions in 0.60 and 0.47 seconds.
- Equal-duration saved track with one dropped frame: warning regression failed before the store fix.
- Device change: replacement segment duration remained zero after further supplied PCM. The old implementation reused a closed ring.

## Targeted green checks

- Original stalled-progress reproduction and bounded delivery/coalescing/late-completion checks pass; nine targeted worker tests passed before gap integration.
- Full MeetingSampleRingTests plus AAC finalization across multiple drain rounds pass. Gaps are checked in 1, 2 and 8 channels, including 44.1 kHz source positions, consecutive terminal drops, exact silence and retained sample order. Existing ordinary pop/dictation tests remain included.
- All 19 MeetingStoreTests pass, including nonzero loss with matching duration and late progress protecting finalized fields/totals.
- Coordinator loss-accounting and device-roll tests pass: counters remain cumulative, reset for new meetings, new segment writes continue, restart failure preserves the other track and original media.
- A concurrent production-C-ring harness ran 20 producer/consumer/close rounds under AddressSanitizer and UndefinedBehaviorSanitizer. Each round checked 1,920,000 offered frames, exact absolute positions of every retained stereo sample, and silence count equal to dropped frames. All passed. Local source: `build/capture-repair/concurrent-ring.c`.
- Independent review covered SPSC ordering and closure races, callback lifetime/cancellation, finalization, store guards, warnings and source replacement. No actionable introduced defects found.

## Full suite

`make check` passed on 2026-09-19. XCTest: 862 passed, 0 failed, 16 skipped (878 total). The run completed; the skipped opt-in tests are not counted as hardware acceptance. Formatting, shell/static, Python and Go checks also passed. Result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.19_15-57-54-+0200.xcresult`; extracted summary: `build/capture-repair/test-summary.json`. Hardware acceptance remains pending in [hardware.md](hardware.md).

## Reproduction commands

```sh
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:LocalFlowTests/MeetingSampleRingTests -only-testing:LocalFlowTests/MeetingTrackWorkerTests -only-testing:LocalFlowTests/MeetingCoordinatorTests -only-testing:LocalFlowTests/MeetingStoreTests test
make check
```

Local logs: `build/capture-repair/gap-tests.log`, `build/capture-heartbeat-green.log`, `build/warning-probe-green.log`, `build/capture-coordinator-green.log`, `build/capture-coordinator-source-failure.log`, and `build/capture-repair/make-check.log`. No private audio or transcript was added to tracked artifacts.
