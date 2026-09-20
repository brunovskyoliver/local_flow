# Meeting intelligence fixtures

Fixtures and scripted responses for Feature 011 (`specs/011-meeting-intelligence/`).
Everything here is synthetic: no captured speech, no real names, no credentials.

## Meeting fixture format

Each `*.json` file at the top level is one meeting:

```json
{
  "schema": "intelligence-fixture-v1",
  "id": "UUID",
  "title": "Deployment sync",
  "started_at": "2026-09-20T09:00:00+02:00",
  "duration_ms": 1830000,
  "time_zone": "Europe/Bratislava",
  "expected_language": "en",
  "expected_terms": ["deployment"],
  "participants": [
    {"speaker_id": "UUID", "certainty": "confirmed", "origin": "user_confirmation",
     "known_speaker_id": "UUID", "name": "Oliver Brunovský"}
  ],
  "segments": [
    {"id": "UUID", "ordinal": 0, "start_ms": 0, "end_ms": 4200,
     "speaker_id": "UUID-or-null", "normalized_text": "…"}
  ],
  "notes": "Free text, split into paragraphs at blank lines by the reader"
}
```

- `certainty` is one of `confirmed`, `recognized`, `possible`, `unknown`,
  `local_name`, `local_user` (the wire values of research R9).
- `origin` is the spec 010 `IdentityOrigin` raw value or `none`.
- `name` is present only where the R9 rule permits it. A Possible-match
  participant instead carries `candidate_name_kept_local`, which the fixture
  loader keeps for assertions but which must never reach the wire.
- `expected_language` and `expected_terms` are evaluation-set annotations used
  by `scripts/analysis-quality.py`; they are not part of the request.

## Scripted response format

`responses/<name>.json` is one scripted server answer:

```json
{
  "schema": "intelligence-response-v1",
  "streams": {
    "full": [ [ {"type": "accepted"}, {"type": "result", "analysis": {…}} ] ],
    "chunk": [ [ …stream for chunk 0… ], [ …chunk 1… ] ],
    "synthesis": [ [ … ] ]
  }
}
```

Each key is a request stage (`full`, `chunk`, `synthesis`). Each value is a list
of streams; a request consumes the stream at its index (chunk index for `chunk`,
synthesis round for `synthesis`), clamped to the last entry, so one stream can
answer every request of that stage. Each stream is a list of NDJSON lines as
objects; a line of the form `{"$raw": "…"}` emits the string verbatim, which is
how malformed responses are expressed. The literal `"*"` in `request_id`,
`run_id`, `meeting_id` and `language` fields is replaced by the value of the
request being answered (`language` takes `language_policy.output`). A source id
of the form `"$seg:<n>"` resolves to the fixture's segment at ordinal `n`, so one
scripted response can serve several fixtures.

## Evaluation-set manifest

Offline cases replayed by `scripts/analysis-quality.py` / `make check`:

| Fixture | Scripted response | Checks |
| --- | --- | --- |
| deployment.json | deployment-valid | SC-001/003/006: one decision, three owned action items |
| deployment.json | fabricated-segment | SC-003: run fails `source_validation` |
| deployment.json | cross-meeting-segment | SC-003: run fails `source_validation` |
| deployment.json | mutated-ip-item | SC-004: item dropped, `dropped_literal` counted |
| deployment.json | mutated-price-decision | SC-004: item dropped, counted |
| deployment.json | mutated-digit-summary | SC-004: run fails `protected_literal` |
| deployment.json | over-cap-decisions | SC-001: run fails `over_cap` |
| deployment.json | unsupported-version | SC-001: `unsupported_version` |
| deployment.json | wrong-meeting | SC-001: `meeting_mismatch` |
| deployment.json | malformed-json | SC-001: `malformed_response` |
| certainty-possible.json | named-possible-owner | SC-002: owner downgraded, candidate name never sent |
| deployment.json | mentioned-owner | mentioned owner stored verbatim |
| due-dates.json | due-dates-valid | SC-005: relative dates resolved, vague terms unresolved |
| slovak.json / english.json / mixed.json | language-valid | SC-014: policy value and term preservation |

## fourhour.json (generated)

`fourhour.json` is not committed. `IntelligenceFakes` synthesizes it
deterministically when asked: ~200 KB of `normalized_text` spread over numbered
segments of a four-hour meeting, with the unique decision
"Deployment moves to Monday" spoken in the last five minutes. Regenerate the
same bytes by seeding the loader with the fixture name; the generator note
exists so the deterministic synthesis is documented, not reproduced by hand.
