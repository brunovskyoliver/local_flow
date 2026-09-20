# Contract: identification UI

SwiftUI additions to the Feature 007 transcript, Assign speakers sheet and Settings. Copy is final unless marked draft. No similarity value, percentage or probability appears anywhere (FR-014, FR-040). Accessibility identifiers are listed so native captures and UI tests can find them.

## Transcript rows (FR-040)

| Effective identity | Row label | Extra control |
| --- | --- | --- |
| `confirmed`, `recognized` | the known speaker's name, speaker color | none |
| `possible` | `Name?` in the speaker color, with a subtle checkmark button `speaker.confirm` | Confirm → `confirmed / user_confirmation` (no sample) |
| `unknown`, `rejected_unknown`, no row | `Speaker N` (007 label) | none |
| local "You" | unchanged (track origin) | none |

The header speaker count and the Speakers menu are unchanged except for one new item, **Rerun identification** (`speakers.rerunIdentification`), enabled when the meeting has an accepted diarization run. The status line shows, in this order of precedence: the 007 diarization status, then "Identifying speakers… n%", "Identification failed: <reason>" with Retry, or "Looking for <name> in past meetings (k left)" with Cancel.

## Assign speakers sheet (FR-041)

Each section keeps its 007 name field, quotes, color and merge controls, and gains an identity block under the name field:

- **Match state line**: "Recognized as Tomáš", "Possible match: Tomáš?", "Confirmed", "Unknown", or "Choose an identity" (after a merge conflict).
- **Suggestion actions** (state `possible`): `Confirm` (`identity.confirm`), `Choose another…` (`identity.chooseAnother`, opens the picker; the within-margin runner-up is listed first), `Keep Unknown` (`identity.keepUnknown`). Confirm and Choose another show the toggle **Also remember this voice sample** (`identity.alsoRemember`), off by default, hidden when the cluster has no eligible region.
- **Known speaker picker** (`identity.picker`): a menu of known speakers sorted by name with sample count and a "needs re-enrollment" tag; the local-user profile is not offered for remote speakers. Picking sets the name field and marks the section `manual_profile_selection`.
- **Remember control**: when the name field holds a new name (not picked from the menu) and the section has no identity, a row appears: **Remember this voice for future meetings?** with `Remember` (`identity.remember`) and `Not now` (`identity.notNow`), under the sentence: *"LocalFlow will store data that can recognize this voice in future meetings on this Mac. It stays on this Mac and you can delete it in Settings › Known speakers."* (FR-002.) Choosing neither is the same as Not now.
- **Duplicate name** (US4 scenario 3): when Remember is chosen and an existing known speaker has exactly this name, an inline choice replaces the row: "Is this Tomáš Novák you already remember?" with `Same person` and `Someone new`.
- **Local row ("You")**: a single `Remember my voice` link (`identity.rememberLocal`) shown when no local-user profile exists; otherwise "Your voice is remembered".
- **Global setting off**: none of the identity block is rendered; the sheet is the 007 sheet (SC-010).

Save semantics: the sheet's Save commits names as today; identity actions commit when Save is pressed, in one `IdentityStore` call per section, in section order; Cancel discards every draft including Remember. Sample extraction runs after Save through the coordinator; the section shows "Storing voice sample…" then "n samples stored" or "No usable voice sample was found in this meeting" (`identity.enrollmentResult`).

**Past-meeting prompt** (FR-023a): after an enrollment stores ≥ 1 sample, the sheet (or the meeting view, if the sheet was closed) shows once: **Look for this voice in past meetings?** with `Look` (`identity.pastSearch`) and `Not now`. The prompt names how many meetings would be checked.

## Settings › Known speakers (FR-042, FR-043)

Placed under the existing Speaker labels group:

- Toggle **Remember and recognize speakers across meetings** (`settings.speakerIdentificationEnabled`), on by default. Detail text: "Nothing is stored until you choose Remember for a voice."
- **Known speakers** list (`settings.knownSpeakers`): rows show name, "n voice samples", a recognition switch, and a "Needs re-enrollment" tag when no compatible active sample exists. Row actions: Rename (inline, `SpeakerNames` validation), Delete (confirmation sheet: "Delete Tomáš? Voice samples are removed and future meetings will no longer recognize this voice. Past meetings keep the name."), and disclosure to the sample list.
- **Sample list** per speaker (`settings.voiceSamples`): each row shows the source meeting title and date, speech duration ("12 s") and quality label ("Good"/"Fair"); provenance-unavailable rows show "Source meeting deleted" and the sample's creation date. Row action: Remove. No vector, score or audio control exists.
- Stale edits (revision mismatch) reload the list with a notice.

## Dark, compact and wide captures

`NativePresentationTests` renders the sheet with a Recognized, a Possible, an Unknown and a merged-conflict section, and Settings with three known speakers (one needing re-enrollment, one with a deleted-source sample) at the same three sizes 007 used.
