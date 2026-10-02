# Keyboard footprint (SC-003, T045)

Run 2026-10-02 by the owner on the iPhone 16 Pro, iOS 27.0.1 (24A446). Build `c838e72` (Debug, signed with team 944A459UC3), keyboard with the 016 key row and the ☰ drawer; the dictation-only layout (`5236f42`) was not measured separately.

Read from LocalFlow › Settings › Diagnostics › Keyboard memory at 14:37, after a few dictations in Notes with a `5m` session running:

| Reading | Value | Limit |
|---|---|---|
| Peak at rest (keys up, sampled each second) | 14.1 MB | under 40 MB |
| Peak while listening (listening view up, sampled each second) | 13.1 MB | under 40 MB |
| Process peak (`ledger_phys_footprint_peak`) | 15.6 MB | — |
| At last report | 14.0 MB | — |

Result: SC-003 passes on this run. Only a few dictations had run, so the listening peak covers a short time; the SC-004 50-dictation run was not done yet.

App footprint at the same time: 41.3 MB now, 600.2 MB peak (model loaded). Recorded here only; the app's figures belong to T075.
