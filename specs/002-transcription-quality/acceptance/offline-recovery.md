# Signed-app offline and recovery acceptance

Date: 2026-09-17. Scope: T045 and SC-008. Status: **not executed.** Nothing in this file is inferred from XCTest fakes; the deterministic coverage for the same behaviors is listed separately at the end so the two are never confused.

## Why it did not run

The run needs the owner's machine in a state this increment did not put it in on its own: network interfaces disabled, the Go server stopped, the signed app quit and relaunched, the microphone used for real speech, and a target application focused for insertion. Turning the network off, driving the microphone and inserting text into whatever is focused are owner actions. The run is prepared below so it can be done in one sitting.

## Preparation

1. `make run` installs and opens the signed development build at `/Applications/LocalFlow.app`. Record the executable hash: `shasum -a 256 /Applications/LocalFlow.app/Contents/MacOS/LocalFlow`.
2. Confirm the Parakeet model is verified in Settings (no download prompt).
3. Stop the server: `pgrep -fl flowd` must be empty.
4. Disable Wi-Fi and unplug Ethernet. Start an outbound observer before launching: `sudo tcpdump -i any -n 'not (src net 127.0.0.0/8 or dst net 127.0.0.0/8)' -w build/offline-acceptance/outbound.pcap` (or `nettop -p LocalFlow`). The check is that the capture contains no packets from the LocalFlow process for the whole session.
5. `export LOCALFLOW_RESOURCE_RECORDING=1` for the launch so lifecycle and stage figures land in the Measurements directory.

## Scenarios

Record for each: build hash, what was done, what appeared (status text, history row state, Details stage labels), and the outcome. Do not paste dictated text into this file; refer to history rows by time.

| # | Scenario | Expected observable | Result |
| --- | --- | --- | --- |
| 1 | Microphone permission denied (revoke in System Settings, press shortcut) | "Microphone access is not allowed…" status, no model load, no history row | not run |
| 2 | Permission granted, ordinary ~10 s Slovak dictation into TextEdit | Recording → Transcribing → text inserted, row `confirmed`, Details shows Raw/Assembled/Normalized | not run |
| 3 | ~25 s English dictation crossing one window boundary | two raw windows in Details, zero seam discards, text complete | not run |
| 4 | Hold past 180 s | capture stops at the cap, status says saved for review, row `needsReview`, no insertion | not run |
| 5 | Esc during transcription | "Cancelled"; if text existed it is saved incomplete and withheld from insertion | not run |
| 6 | Fill history with 20+ rows, search, copy, explicit Insert from Transcriptions | search on normalized text, copy exact saved text, explicit insertion asks for confirmation | not run |
| 7 | Vocabulary: add one entry with an alias, dictate the alias in the next session | canonical spelling in Normalized stage; entry ID count 1 in Details; the running session at edit time is unaffected | not run |
| 8 | Storage failure: `chmod 500` the Application Support directory before stop | "Text is unsaved. Retry save or Copy…"; Retry after `chmod 700` saves the same detail hash | not run |
| 9 | Quit during insertion (force quit after "Inserting…") and relaunch | row shows uncertain delivery, no automatic replay, recovery banner | not run |
| 10 | Restart after scenario 2 | same stage bytes/hashes in Details; legacy rows still read "Legacy: raw output and processing metadata unavailable" | not run |
| 11 | Confirmed Delete of a detail-bearing row | row and detail gone; `transcription_quality` count decreases by one | not run |
| 12 | Temporary audio | `~/Library/Application Support/LocalFlow/TemporaryAudio` holds only `.owner.lock` after every terminal state above | not run |
| 13 | Keyboard/accessibility: Tab through Transcriptions row actions, VoiceOver reads stage labels and completeness | all actions reachable without pointer; labels distinct | not run |
| 14 | Outbound requests | capture from step 4 shows none from LocalFlow across all scenarios | not run |

## Deterministic coverage that exists (not a substitute)

`DictationCoordinatorTests`, `UnsavedResultTests`, `StorageRecoveryTests`, `ResourceLifecycleTests` and `ExplicitInsertionTests` cover cancellation joining, the duration cap being review-only, storage failure retaining the exact envelope and hash, retry equality, cascading deletion, spool cleanup on every terminal path and insertion suppression for incomplete results. They run against fakes and prove control flow, not the signed app, TCC, the microphone or the network. SC-008 stays open until the table above is filled from an actual run.
