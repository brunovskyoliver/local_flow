# Production integration

Date: 2026-09-17. Scope: connect ordinary dictation to bounded assembly, conservative normalization and saved processing detail following the owner's revised priorities.

## Implemented

T024 and T029 are complete. [ADR 0012](../../../docs/adr/0012-production-contiguous-dictation.md) records the fixed contiguous assembly choice, evidence limitations and constitution check.

Ordinary dictation now uses the pinned Parakeet runtime with contiguous 239,360-sample windows and unchanged minimum padding. It saves exact admitted raw windows, original timing evidence, assembled text, normalized parent text, independent stage hashes/versions, model/build/settings identity, actual stage durations, empty vocabulary revision/hash, seam audits and bounded completion reasons. History's existing Details action reads these actual saved envelopes. Existing legacy rows remain unchanged.

Recognition admission leaves 24,576 bytes for fixed processing identity/seam metadata in addition to the existing 4,096 terminal reserve, and accounts for assembled as well as raw escaping overhead. Each candidate full detail validates before replacing the retained envelope. Metadata overflow rejects that window whole, retains the earlier envelope and marks the result incomplete. Normalization metadata failure similarly retains the original envelope for review. Save retries reuse the exact envelope and hash.

Downloaded-corpus historical evaluation explicitly selects the historical profile. Its results are not silently relabeled as output from the production pipeline. No new corpus comparison or alternative-engine experiment was run.

## Checks

The initial three production regressions failed against the old path: missing detail, no normalization and the old overlapping sample counts. The targeted implementation run then passed 70 tests and exposed one silence-status regression. Distinguishing wholly silent output from an empty chunk amid recognized text corrected that regression.

`make check` passes with **280 XCTest passed, 10 skipped, 0 failed**, plus Swift formatting, shell syntax, JSON/artifact/document-link checks, 7 historical scorer tests, 25 quality scorer tests, 12 acquisition tests, plist validation and Go tests/vet. Private logs: `build/pipeline-red.log`, `build/pipeline-targeted.log`, `build/pipeline-check.log`.

New tests verify raw decomposed-Unicode bytes and original spacing, normalized text/hashes/rule IDs, durable save before delivery, unexpected-control insertion suppression, exact 180-second coverage with 13 windows and 12 zero-discard seams, metadata overflow retaining the prior full detail, last-window failure, bounded bundled model identity and explicit unknown build dirty state. Existing cancellation, duration limit, storage failure and retry tests also pass; retry now explicitly checks the immutable detail hash through the default production path.

## Practical owner check

Once the signed build is open, dictate a few ordinary Slovak and English sentences. Include one recording around 20–30 seconds to cross a chunk boundary. Check whether the wording is right, then open History → Details to compare Raw recognition, Assembled and Normalized. Copy or insert the saved text normally. Within-sentence language switching is optional, not the focus.

Report the phrase you expected, what appeared and whether it was a short or longer recording. No benchmark corpus or formal review file is required for this practical check. Do not infer speech-quality acceptance from the automated tests. T032 remains open for actual owner meaning feedback and signed keyboard/accessibility interaction; broader offline and resource acceptance remains separate.

## Signed development launch

`make run` built and installed `/Applications/LocalFlow.app` with the existing development signing identity, and the app is running. `codesign --verify --deep --strict` passed. Installed and build-product executables both hash to `c718d5defa16d98fedab67c806534d84ff1610473f5abb05375a923e93b6b53b`. Private launch log: `build/pipeline-signed-launch.log`.

The menu-bar **Open LocalFlow** command opened the main window; closing and reopening through that command also worked. AeroSpace 0.19.2 reported `TilingContainer` for the window using the existing main-window rule. Reopening moved the window to another display, so these observations do not establish a before/after neighboring-frame comparison on one workspace. No app window policy or AeroSpace configuration was changed. No dictation was initiated on the owner's behalf and no microphone, speech-quality or full accessibility acceptance is claimed.

## Row-action discoverability correction

The owner's first app screenshot showed the new Slovak recording in Transcriptions but no visible Details action. The screen was incorrectly called "History" in the testing instructions, and the row hid all actions at zero opacity until hover or focus. Row actions now stay visible; native keyboard and accessibility interaction remain available without custom focus-based visibility state. Use the actual screen name, **Transcriptions**, in owner instructions.

`make check` passed after this presentation correction. The screenshot confirms that the displayed recording reached history; it does not establish a formal meaning verdict or close T032's remaining interaction checks.
