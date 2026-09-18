# Normalization and vocabulary contract v1

Input is assembled text plus an immutable vocabulary snapshot. Output is normalized text, applied IDs and an explicit failure reason if no safe result can be committed. Recognition and scoring normalization are separate algorithms.

## Formatting rules

Rules run in the table order. Protect whitespace-delimited spans containing URL/email/path syntax, digits, underscores, backticks, or identifier punctuation from punctuation edits. Preserve controls other than the explicitly handled whitespace; unexpected controls are reported for review rather than deleted. No rule deletes fillers or ordinary words.

| ID | Rule | Positive case | Counterexample kept intact |
| --- | --- | --- | --- |
| N001 | Canonical NFC composition, never compatibility folding | `c` + combining caron → `č` | `č` never becomes `c`; full-width symbols are not transliterated |
| N002 | CRLF and CR → LF | Windows line endings become LF | Line breaks remain line breaks |
| N003 | Collapse ASCII horizontal space/tab runs to one space; trim those at line edges | `hello  world` → `hello world` | Nonbreaking spaces and internal punctuation remain |
| N004 | Remove ASCII space before a comma only in `letter space comma space letter` context within one line, outside protected spans | `ahoj , svet` → `ahoj, svet` | `1 , 5`, `v1.2`, URLs, quoted/code spans and uncertain contexts remain |
| N005 | General capitalization is identity | Existing sentence/acronym casing retained | No automatic sentence-case, acronym expansion or grammar correction |
| N006 | Engine-artifact deletion is identity in v1 | Artifact-like literal words retained | No bracketed string removed merely because it resembles an SDK token |
| V001 | Explicit vocabulary spelling/case mapping under rules below | `local flow` → `LocalFlow` if configured | `local flower` stays unchanged |

A future nonidentity artifact rule requires engine metadata establishing that the item is not spoken text, enumerated examples/counterexamples, a new ruleset version and review. No such metadata-based deletion is assumed here.

## Term validation and matching

Store NFC canonical and alias strings. Require nonempty single-line values with no controls, no leading/trailing whitespace and single ASCII spaces between words. Canonical targets must already be stable under N001–N004. Strings are at most 64 Unicode scalars and 256 UTF-8 bytes. Keep diacritics and exact canonical casing.

Comparison keys use NFC plus locale-independent Unicode case folding with no diacritic or compatibility folding. Pin examples and record the runtime/OS version in provenance. Match literal canonical keys and explicit alias keys. No fuzzy, phonetic, stemming or semantic match is allowed.

A whole-term match cannot have a Unicode letter, mark, number or underscore immediately outside either end. A multiword alias must match its complete normalized spacing. Preserve identifiers/URLs/code-like protected spans unless the entire protected span is an explicitly configured term. Enclosing brackets and trailing sentence punctuation (`.,;:!?` and closing brackets) are not identifier syntax: the protected core of a span excludes them, so `(localflow)` or `term.` can match while `localflow.dev` cannot. Quoted and backtick runs stay protected whole. A canonical entry without aliases can correct casing of its whole-term match. Text already equal to the canonical bytes is not a candidate and never makes a neighbouring match ambiguous.

Reject edits if any folded source key maps to different canonical strings, including canonical spellings belonging to another entry. Reject a canonical target that itself maps to a different target. Validate disabled entries too so re-enabling cannot introduce a hidden conflict. Duplicate aliases within one entry may be deduplicated visibly before Save.

Find candidates against a stable pass input. Exact same-span/same-target matches collapse to one match. Any other overlapping candidate group is ambiguous: leave the entire group unchanged and report its entry IDs in detail, not logs, under the `ambiguous_vocabulary` reason, which marks the result incomplete like the other review reasons. Do not use longest-match precedence to silently select meaning. Disjoint matches apply left to right; replacement text comes only from the canonical spelling.

## Idempotence and bounded processing

Some replacements can create a new adjacent multiword match. Run the same full formatting/matching function to a fixed point, for at most 32 passes with two bounded text buffers. Commit only after a pass returns identical UTF-8 output. Reapplying the normalizer to a committed result is therefore identical. Do not recursively process replacement text inside a single pass.

If a pass exceeds output/match/span limits or 32 passes fail to stabilize, discard candidate changes, return the original assembled input and mark `normalization_capacity` or `normalization_nonconvergent`. Applied IDs then describe no committed changes; a separate reason records the failure. Tests must cover mappings that create adjacent terms, cycles, expansion and repeated invocation. These cases must never deliver a partially stabilized result as complete.

Record unique rule/entry IDs that changed committed text. Historical results keep their original normalized text after rules or vocabulary change. Never automatically reprocess history.

## Vocabulary actions

Add/edit/enable/disable/delete are transactional, local and available offline. Increment the revision only after a successful semantic change. Assign revision and content hash at dictation admission. Editing during a session affects the next session only. Reject conflicting or over-limit edits with a specific field error; no silent replacement/eviction.

Tests include Slovak combining accents, English case variants, acronyms, numbers, decimals, versions, URLs, code identifiers, aliases as substrings, overlapping multiword aliases, disabled entries, capacity, storage failures and revision races. Acceptance includes at least ten held-out explicit alias/case occurrences plus negative cases; this establishes spelling replacement, not better acoustic recognition.
