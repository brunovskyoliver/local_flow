# Contract: Dictionary change classification

This is the internal contract between the dictation coordinator, the correction learner and `DictionaryUsageStore`. It is pure and deterministic, and it is tested without Accessibility.

## Inputs

- `DictionaryChange { entryID: String, keyID: String, canonical: String }`. There is one per distinct `(entryID, keyID)` changed in a dictation, produced by V001 (`keyID` = key digest) and V002 (`keyID = "boost"`).
- `inserted`: the exact text that was inserted.
- `before`: the whole-word margin read before the insertion at baseline, and `leadingCut`, both as in `CorrectionDetector`.
- `reads`: the successful reads of the same window made during observation, in order.

## Steps

1. **Words**: split on whitespace after NFC. A word's *core* is the word with edge punctuation trimmed, using the same edge set as `CorrectionDetector.trimmed`. With `leadingCut`, the first word of `before` and of every read is dropped.
2. **Spans**: for each change, every run of consecutive inserted words whose cores, joined by single spaces, equal `canonical` exactly. No run means the change is **unclassified**.
3. **Intact read**: the latest read in which the words of `before` are an exact prefix and an LCS of `insertedWords` against the rest of the read aligns at least ⌈n/2⌉ of the n inserted words. With no intact read, every change is **unclassified**.
4. **Alignment**: take one LCS of `insertedWords` against the words after the `before` prefix. When several are possible, the implementation picks the leftmost.
5. **Per change**:
   - **Kept**: every word of every span is aligned.
   - **Reverted**: some span has an unaligned word, and the closest aligned inserted word before the span and after it are both aligned (or the span touches the passage edge on that side).
   - **Unclassified**: otherwise.
6. **Learning off** (`learnCorrections == false`): no observation happens, so no classification either (FR-021).

## Outputs

`[(DictionaryChange, Outcome)]`, where `Outcome ∈ {kept, reverted, unclassified}`, is written through `DictionaryUsageStore.classify(dictationID:outcomes:)`. The store returns the keys whose state changed to `retired`, which the app turns into notices (R11).

## Required cases (tests)

| Inserted | Final read | Change | Outcome |
| --- | --- | --- | --- |
| "Ask John about it." | same | jon→John | kept |
| "Ask John about it." | "Ask jon about it." | jon→John | reverted |
| "Ask John about it." | "Ask Jonathan Smith about it." | jon→John | reverted |
| "Ask John about it." | "" (field cleared) | jon→John | unclassified |
| "Ask John and fix Zabbix." | "Ask John and fix Zabix." | jon→John; zabix→Zabbix | kept; reverted |
| "Ask him about it." (rewrite dropped the name) | same | jon→John | unclassified |
| "John met John." | "John met jon." | jon→John | reverted |
| "Deploy to Kubernetes now." | "Deploy to Kubernetes now. Thanks" | boost | kept |
