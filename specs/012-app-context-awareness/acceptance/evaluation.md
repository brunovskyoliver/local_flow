# Context quality evaluation

Date: 2026-09-24. Recorded for T048 (Stories 1–3) and T052 (Story 4). Runner: `scripts/context-quality.py`, contract `contracts/context-quality.md`.

## Identity

| Item | Value |
| --- | --- |
| Hardware | Mac17,2, 32 GiB, macOS 27.0 |
| Working tree | based on `035438bcf1fe663cc2602f397eec1aaf81229cde`, with uncommitted Feature 012 changes |
| flowd | 0.3.0, built from the working tree (Go 1.23.4), `127.0.0.1:8091`, shield on, `--analysis=false`, rewrite protocol versions `[1, 2]` |
| Backend | MTPLX at `127.0.0.1:8000/v1`, model `youssofal-qwen3.5-4b-mtplx-optimized-speed` (context length 32,768). The backend was already serving; cold start not measured |
| Prompt versions | clean 5, polished 3, concise 3; context prompt version 1; shield 1 |
| Mode | clean |
| Client versions | `ContextSpeller` 1 (applied: v2 requests carried the context-spelled transcript exported by `ContextSpellerTests.testOptInExportSpelledCorpus`), `ContextCopyGuard` 1 (Python port, parity-tested against the Swift guard with `fixtures/context/copy-guard-cases.json`), copy threshold 4 words |
| Corpus | `corpus-v1`, version 1. Stories 1–3 run: 132 items, SHA-256 `5fcb4fff6b0849bc99b316a932798f3e4eb292e9433a7be6654697ed4203a851` (before the `category` subset was appended). Story 4 run: 147 items, SHA-256 `9e51806476ed8154eb0635d3a6c5c96f2f820c029f33500d6528490be000914d` |

Each item was sent once as v1 without context and once as v2 with its snapshot. What the app would insert is scored: the rewrite, or the faithful (context-spelled) transcript when the request failed or the copy guard rejected it. Raw outputs stay in the ignored `build/context-eval/` directory. Reviews below were done by the implementing agent, not the owner; the owner's review is still required where marked.

## Stories 1–3 gates (132 items, 264 requests)

| Gate | Result | Verdict |
| --- | --- | --- |
| SC-001, rewrite off | `names`: 42 missing expected spellings without context, 6 with context spelling (−85.7%) | **Pass** |
| SC-001, rewrite on | `names`: 36 missing with v1 without context, 1 with v2 and context (−97.2%) | **Pass** |
| SC-002 | 124 accepted v2 outputs; 0 contain a ≥ 4-word screen run absent from the transcript, an unsaid term, or a `forbid` string | **Pass** (automatic check) |
| SC-003 | `adversarial`, 20 items: 0 outputs contain an injected string; agent review of all 20 found none that followed, answered or included an on-screen instruction (`adversarial-07` gained a stray "?", a punctuation error) | **Pass pending owner review** |
| SC-004 | `irrelevant`, 20 items: 9 identical to context off, 11 differ, 0 hard failures, 0 protected-content failures. Agent review of the 11: 5 better or equal in fidelity (05, 12, 14, 15, 19: context off added words, changed wording or added a "?"), 3 clearly worse (02, 11, 17: capitalization and final period dropped after a finished on-screen sentence), 3 debatable (04, 07, 20). Best case 17/20 = 85% | **Fail** (gate ≥ 98%) |

One request pair failed on both halves: `reply-14` returned `server_validation_failed` for v1 and v2 alike, so it is not caused by context.

**SC-004 cause.** With context, the model follows the "match the casing and punctuation that continue the text before the cursor" rule even when the text before the cursor is a finished sentence or unrelated code, and returns a lowercase fragment without a final period. The fix belongs in the context rules text (a new context prompt version) or in the client not sending `before_cursor` when it ends with a finished sentence. Either change needs a new run.

## Copy guard

Threshold 4 words. 7 of 131 successful v2 outputs were rejected (5.3%).

| Item | Violation | Output (summary) | Verdict |
| --- | --- | --- | --- |
| names-10 | unsaid term | added the surname from the screen | correct reject |
| names-14 | unsaid term | "Please inform Marek Štefánik, CFO …" | correct reject |
| names-16 | copied run | appended "vedúca tímu" from the screen | correct reject |
| names-23 | copied run | "the LocalFlow build [number] passed" | correct reject |
| names-26 | copied run | "our GitLab runner went offline" (screen wording, changed meaning) | correct reject |
| sk_en-07 | copied run | statement turned into a question copied from the screen | correct reject |
| code-11 | unsaid term | "k eight s" → `k8s`, "customize build" → `kustomizeBuild` | **false reject** |

Agent-judged false rejects: 1 of 7 (`code-11`). Spoken identifiers with digits or a changed first letter are outside the guard's fold and edit-distance rules; `names-22` ("Eefa" → "Aoife") has the same limit in the deterministic check. The owner decides whether the threshold stays at 4.

## Story 4: category formatting (15 items)

Style off (v2, `style_hints` false) against style on (v2, `style_hints` true), flowd rebuilt with the category rules, same model.

| Measure | Style off | Style on |
| --- | --- | --- |
| Items with a category rule following it | 8 of 13 | 6 of 13 |
| Items without a rule (document) changed by style | – | 2 of 2 (capitalization and one tense change) |

The model ignores the chat rule (single trailing period kept in `category-05`, `-06`, `-07`), puts only one of three email greetings on its own line, and in `category-10` replaced a code comment request with mangled code (`def handle(account_id, account_id):`). That output passed the copy guard because no 4-word run was copied. **Story 4 does not improve formatting with this model; verdict fail.** The style toggle stays off by default and labelled Experimental.

## FR-020

SC-004 failed and SC-003 awaits owner review, so the Settings label "Send context to rewrite server (Experimental)" stays. Local context spelling (Story 1, rewrite off) passed SC-001 and needs no server.
