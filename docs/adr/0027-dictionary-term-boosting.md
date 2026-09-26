# 0027: Dictionary term boosting in dictation

## Status

Proposed, 2026-09-26.

## Context

Parakeet TDT 0.6B v3 is accurate on everyday English and Slovak but misspells technical terms and names it has rarely heard ("Zabix", "Trifik", "postgre SQL"). The Dictionary (Feature 002) only rewrites exact spellings the user has listed as aliases, so every new misrecognition needs a new alias. Feature 012 said speech recognition stays unchanged. The owner wants better terms without a larger model, and accepts nothing that makes any dictation worse.

## Decision

Dictation checks the audio for the Dictionary's enabled canonical spellings with a second, small model and replaces a span only when strict rules agree.

- Model: FluidAudio's Parakeet CTC 110M CoreML keyword spotter (`FluidInference/parakeet-ctc-110m-coreml`, pinned revision `accdafd8…`, CC-BY-4.0, 103 MB), provisioned like the speech model through a pinned descriptor with the new `keyword_spotting` capability. It is optional: without it dictation works as before. Settings › Term booster downloads it; onboarding installs it after the speech model.
- It loads and unloads together with the Parakeet runtime through `ModelLifecycleCoordinator`, so it adds no separate residency. The dictionary for a dictation travels with its model lease.
- For each window the CTC encoder runs alongside the TDT decode. FluidAudio's `VocabularyRescorer.ctcTokenRescore` proposes replacements. A proposal becomes a hint only if the TDT tokens it covers had confidence below 0.9; its words are not all correct English words (system spell checker); it is not an inflected form of the term; its folded spelling similarity is at least 0.6; and the Dictionary does not already map that span. When the window is Slovak (Natural Language recognizer limited to English and Slovak) the similarity must be at least 0.8 and the span may not contain a lowercase word of three letters or fewer.
- Raw windows are never changed. Hints apply to the assembled text before normalization as rule `V002`, and the quality detail records the entry IDs, like `V001`.
- The Dictionary also lists suggestions: corrections the scorer only suggested (kept in a new `term_suggestions` table with dismissals) and term-shaped words that were in the app context of at least three dictations. Nothing is added without the user.

## Constitution check

- Principle 1: FluidAudio and CoreML are already dependencies (ADR 0002). No new package.
- Principle 4: dictation needs only the speech model; the booster is optional and its failure to load is logged and ignored.
- Principle 5: all local. Logs contain no terms or text.
- Principle 6: one extra encoder pass per window of at most 15 s; no whole-meeting audio.
- Principle 7: one migration, `term-suggestions-v14`, with bounded rows (500).
- Meetings are unchanged.

## Consequences

Measured on the M5 with the production runtime (details in [research](../../specs/013-dictionary-term-boost/research.md)): English term recall on held-out TTS clips rose from 64.3% to 79.1% and WER fell from 10.47% to 7.92%, with no clip worse in any set and no change on 369 minutes of real meeting audio. Each window costs about 50 ms more and the process about 8 MB more after load. The spotter is English-trained, so Slovak gains are smaller, and the strict Slovak rule blocks some real fixes. TTS is only a proxy for the owner's voice.

## Alternatives considered

A bigger recognizer (rejected by the owner); prompting or fine-tuning Parakeet (no supported path in FluidAudio 0.15.7); FluidAudio's `VocabularyBoostingSession` (it loads the tokenizer only from its default cache directory); a Czech spell checker as a Slovak proxy (the owner wants English and Slovak only).
