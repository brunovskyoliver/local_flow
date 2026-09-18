# Local user interface contract

Use the existing native settings and history windows. This contract defines behavior; it does not require new window presentation or change the tiling workflow.

## History

History list, search, Copy and guarded insertion use normalized text. Selecting a new record loads one detail envelope with clearly labeled Raw recognition, Assembled and Normalized views. Raw recognition shows windows in received order, including overlap, without pretending it is the assembled transcript. Show completeness/recovery status independently from delivery status.

Provide local processing details for model/build/settings, assembly/normalization versions, vocabulary revision and applied IDs, timings, missing evidence and failure reasons. Technical provenance belongs in details, not the ordinary dictation flow. Legacy records explicitly show unavailable raw/provenance. No invented metadata and no automatic reprocessing on settings changes.

Incomplete, duration-limited, cancelled and uncertain results retain the existing review and explicit insertion safeguards. Failed saves expose the existing retry/copy recovery with all bounded representations retained. Do not offer a new dictation that would displace an unsaved result. Confirmed Delete clears associated detail and cached UI copies along with the record.

## Vocabulary settings

Provide add, edit, enable/disable and delete, with canonical spelling and optional explicit aliases. Explain that entries standardize matched spellings and do not guarantee recognition of unheard words. Show validation next to the offending field, including ambiguous mapping and capacity. Disable duplicate saves during an active write. Preserve edits on a failed save.

Changes apply to the next dictation. The active dictation retains its original vocabulary revision. Empty vocabulary is a valid snapshot. Everything works with the network disabled and server stopped.

Validate keyboard navigation, accessible labels and state announcements for errors, restart persistence, revisions during an active session, limit rejection, raw/normalized distinction and legacy detail. The plan does not change app/window architecture.
