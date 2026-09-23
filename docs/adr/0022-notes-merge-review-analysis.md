# 0022: Meeting analysis as notes, merge and review

## Status

Accepted, 2026-09-23, including the exception to constitution principle 11 (see Constitution check).

## Context

Each analysis request asked the model for the whole result as one JSON object: summary, topics, decisions, action items with owner and due objects, and segment ids on every item, with the 5.3 KB result schema in the prompt. On real 1–3 hour Slovak meetings this failed:

- The chunk answer hit the 3,072-token output cap and was cut off mid-object (flowd log, 2026-09-23 13:46 and 19:08, remote `qwen3-8b`).
- One malformed field (`topics.bullets` of the wrong type, a due date missing a field) rejected the whole result; after three attempts the run failed.
- Constrained decoding was never used on vLLM, because flowd only enabled it for the MTPLX-specific `capabilities.json_schema` field. Where it was used, MTPLX ran to the token cap.
- The model also resolved dates and copied ids, work code does better.

A prototype (`/tmp/summary-proto`, not in the repo) ran four pipeline versions against two real meetings (56 min, 4 parts; 170 min, 12 parts) on the remote `qwen3-8b` (vLLM) and the local `qwen3.5-4b` (MTPLX):

- Markdown notes under fixed headings came back well-formed in every run on both models.
- JSON per section still broke on the 4B model (Slovak „…" quotes closed with an ASCII quote, invented key names).
- A model-written merge of all item lists dropped every decision and commitment of the 170-minute meeting.
- MTPLX refused prompts over its "memory-plan fit" with HTTP 507, at 4,096 tokens while the model list claimed 32,768; after a restart it accepted 5,400.
- The final version finished both meetings on both servers without failures: 98 s and 226 s on the remote, 89 s and 199 s locally (one run each).

Other open-source note takers take the same route. Meetily summarizes chunks as markdown and combines them. Hyprnote writes one markdown answer and checks only its first heading. "Let Me Speak Freely?" (EMNLP 2024) found strict JSON output lowers quality and a free-text answer converted afterwards recovers it.

## Decision

flowd keeps protocol v1 (stages, request, result object and events) and changes what happens inside a request:

1. **Notes.** For `chunk` (and first for `full`), the model writes markdown notes under Discussed, Decisions, Commitments ("who: what (due: …)"), Open questions and Risks. A part the backend refuses for size is split in half and asked again.
2. **Parse and ground, in code.**
   - Headings are matched by a fixed table.
   - Every item gets up to three segment sources by word overlap with the part. An item sharing fewer than two words with the part is dropped.
   - A due phrase is kept only when it was said in the part.
   - Owners map to participants by name or the "Speaker N" label the model saw.
3. **Merge.** The model writes an Overview and up to 8 Topics from the partials. If it fails, the partials' summaries stand in.
4. **Review.** Item lists from the partials are deduplicated in code. The model answers with the numbers of the entries to keep. If that fails, the list is kept.

The model never writes JSON or ids. Everything optional has a fallback and runs only while 45 s of the request's time budget remain. `--analysis-timeout` (270 s) bounds all calls of a request together, below the client's 300 s. No analysis call sends `response_format`. The backend adapter reports size refusals as `ErrTooLarge`; the primary/fallback router does not treat them as the primary being down.

## Constitution check

- **1–4, 6–10, 12–14.** Unaffected:
  - no client change;
  - no new runtime or dependency;
  - bounded memory: at most one part's notes per call, and the request body and output buffer bounds are unchanged;
  - flowd still owns no weights.
- **5. Privacy.** Unchanged. The log line gains `attempts`, the answering model's id and content-free reasons; it still carries no transcript, model text or credentials.
- **11. Structured LLM output. This is an exception.** "Behavior MUST NOT depend on parsing arbitrary prose or Markdown." flowd now parses the model's markdown notes and merge answer.
  - **Evidence** for the exception is in Context.
  - **Mitigation.** The markdown is an intermediate that never leaves flowd:
    - It is parsed against a fixed heading table, never free-form.
    - Every item must share words with the transcript part it came from.
    - Deadlines must have been said.
    - The resulting object conforms to the versioned result schema and passes the same structural and source validation before it is sent.
    - The client validates it again before persistence or rendering, unchanged.
    - The review step's answer only selects among existing entries; its text never becomes result content.
  - **Approval.** The owner approved this exception on 2026-09-23.

## Consequences

- Every request makes several short calls instead of one long one: notes per part, then one merge and up to four reviews. A dictation rewrite can take the model slot between calls.
- Deadlines now arrive as `unresolved` with the phrase as said. The client's resolver does not turn those into dates, so the Summary tab shows the phrase instead of a date.
- Segment sources are chosen by word overlap, not by the model. They point to where the words were said, not necessarily to the one sentence that decided something.
- Prompt version 9, pipeline version `analysis_v2`. Cached chunk results in the client are keyed by evidence, not prompt version, so a retry may still reuse partials built before the change.

## Alternatives considered

- **Constrained JSON everywhere** (`response_format` on every server). Rejected: it isn't supported consistently across OpenAI-compatible servers, and it ran to the cap on MTPLX.
- **Smaller JSON per section.** Broke on the 4B model in the prototype.
- **Letting the model merge the item lists.** It dropped decisions and commitments.
- **Sources written by the model.** The owner does not need links back to the transcript, and code picks them without the id-copying failures.
