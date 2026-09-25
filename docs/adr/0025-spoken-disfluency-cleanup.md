# 0025: Spoken disfluency cleanup in the rewrite

Status: Accepted, 2026-09-25. Amends the shield guarantee of [0013](0013-rewrite-protocol-v1.md); the wire format is unchanged.

## Context

Rewrites should read as if the speaker had typed them: no "uh", no "the the", no "Tuesday, no, Wednesday". On 406 real dictations the clean v5 prompt on the reference 4B model (Qwen3.5 4B on MTPLX) kept hesitations in about half the affected outputs, sometimes wrapped them in commas ("Also, uh, redeploy"), and resolved almost no spoken self-corrections. On a 54-case evaluation set it failed 22 cases.

Two things blocked a prompt-only fix. Every prompt byte costs prefill time on every dictation, about 0.3 ms per character on the reference setup, and the backend does not reuse the system prompt between requests. Shield version 1 also replaced every number and date with an opaque placeholder that had to be restored exactly once, so a correction such as "30 seconds, wait, 60 seconds" could not be resolved: the model could not read the values, and dropping one failed the request.

## Decision

flowd cleans spoken disfluency in four bounded steps; the model does the part that needs judgement and deterministic code does the rest.

1. A pre-pass removes non-lexical hesitation sounds (uh, um, ehm, hmm, mm) and repairs commas, sentence punctuation and capitalization around them. Sounds that are also words, units or answers ("eh", "mhm", "5 mm", German "um") and quoted mentions stay.
2. A detector looks for signs of unedited speech: a hesitation, a filler or correction cue, a word repeated within three words, or a cut-off word. Only then is a versioned spoken-rules block with three short examples appended to the mode template. About half of real dictations trigger it; the rest keep the previous prompt length.
3. Shield version 2 still replaces URLs, emails, paths, IPs and versions with placeholders, but leaves numbers, dates, times and amounts readable. After generation every protected value must survive unless a later value of the same class, within 64 input bytes, replaced it. A changed, dropped or wrongly corrected value fails validation as before. The Slovak day and month detector now covers inflected forms.
4. Two guards reject a half-applied edit: a correction marker ("sorry", "I mean", "prepáč", ...) dropped while the word before it survives, which would state the abandoned value as fact, and, for clean-mode spoken-rules output, an input sentence of four or more words that has disappeared. On 413 historical rewrites the marker guard flagged none; the sentence guard flagged only polished rewordings and translations, which is why it is limited to clean. A spoken-rules output that fails any validation is regenerated once with the plain mode template; a plain-template output that fails is an error, and the client inserts the faithful transcript as before.

The templates move to clean v6, polished v4 and concise v4, with a shorter shared preamble. The spoken block's hash is registered against those versions, so changing it forces a template version bump.

## Consequences

On the 54-case set failures drop from 22 to 5, with no half-applied correction reaching the user. On 60 real dictations median latency moved from 682 to 695 ms and p90 from 1329 to 1311 ms; outputs got shorter and no hesitation survived. In the evaluation, 5 of 114 requests (fixture and real) took the retry path and paid a second generation. The 4B model still leaves some corrections as spoken, and occasionally rewrites a request's form ("Can you please" to "Please") or drops a hedge.

The shield no longer guarantees that every number survives: one may disappear when the speaker replaced it with a nearby later number of the same class. `shield.restored` can therefore be lower than `shield.placeholders`. The client already accepted this.

## Alternatives considered

Rules and examples in the prompt for every request added about 180 ms at the median. A separate cleanup model call would double the latency. Placeholders carrying their value (`⟦E0:30⟧`) confused the model, which unwrapped them and still kept the wrong value. Tuning the backend's prefix cache would depend on runtime settings flowd does not own. Deleting fillers in the client's transcript normalizer would change the faithful transcript, which Feature 002 keeps free of meaning edits.

## Constitution check

Complies with principles 2 (bounded work: one extra generation at most, linear-time checks), 4 (faithful transcript fallback unchanged), 5 (the retry log line carries a request id and error code, no text), 8 (no weights in flowd), 11 (versioned prompts, validated results) and 12 (unit tests for the pre-pass, detector, guards, shield and retry path; an opt-in live regression over fixtures/rewrite/disfluency-v1.json). No exception or new dependency.
