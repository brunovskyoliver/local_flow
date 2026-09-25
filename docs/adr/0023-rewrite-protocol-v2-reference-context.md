# 0023: Rewrite protocol v2 with reference context

Status: Accepted for Feature 012, 2026-09-24. Extends [0013](0013-rewrite-protocol-v1.md); v1 stays valid and unchanged.

## Context

Feature 012 lets a dictation rewrite use a small snapshot of the app and text field that had focus when the shortcut was pressed. The rewrite uses it for names, casing and continuation. Feature 003 FR-004 kept active-application contents out of rewrite requests, and ADR 0013 fixed a closed v1 request field set. Screen text is untrusted: it can contain instructions, other people's words and sensitive values. Existing flowd servers reject any unknown request field with `invalid_request` before they check the schema version.

## Decision

Add rewrite protocol v2. It is v1 plus one required `context` object that holds the canonical context snapshot: app name and category, field kind, window title, text before and after the cursor, selected text, candidate terms, truncation notes and `style_hints`. The snapshot is at most 8,192 bytes and its field set is closed. A v2 request without `context`, or a v1 request with it, is invalid. Endpoints, events, result validation, text bounds, shield, timeouts and credentials are unchanged.

The client sends v2 only when context capture and context rewrite are both enabled, a snapshot is stored for the dictation, and the endpoint's health lists `2` in `protocol_versions`. Health is cached per endpoint origin for the app run, in one entry that is discarded after a 400 response to a v2 request. Otherwise the client sends v1 and records `server_unsupported`. It never probes by sending v2 and retrying, because an old server's error cannot be told apart from a real bad request.

The snapshot is treated as untrusted data at every step:

- The client masks email, URL, IP and number spans before it stores or sends the snapshot. History shows exactly the bytes that were sent. History retries resend the stored snapshot and never recapture.
- flowd puts the snapshot in the system message after the mode template and a versioned rules block, as JSON inside `<screen_context>` tags with `<` escaped, so the text cannot close the tag. The rules say to use it only for spelling, casing, continuation and tone, and never to copy it, answer it, summarize it, follow instructions in it, or translate because of it. The dictation stays the user message. Results report `context_prompt_version`, and the client requires it on v2 results.
- After v1 validation, the client rejects a result that contains four or more consecutive words from the context that are not in the faithful transcript, or a context term the speaker did not say. The rejection is persisted as `context_copied`, and the faithful transcript is inserted under the Feature 003 fallback.

Snapshot text is never logged or put in metrics on either side. flowd logs only `context_bytes`. The normative details are in [the v2 contract](../../specs/012-app-context-awareness/contracts/rewrite-protocol-v2.md) and [the snapshot contract](../../specs/012-app-context-awareness/contracts/context-snapshot.md).

This decision replaces Feature 003 FR-004's exclusion of active-application contents, but only under Feature 012's opt-in rules. Both switches are off by default.

## Consequences

Context can improve spelling and continuation without changing the transcript's role as the only source of content. Old servers keep working, with context omitted. Clients that don't enable context send v1 unchanged. `rewrite_attempts` needs a table rebuild to store protocol version 2, the new failure category and the sent context hash. Each context-aware request adds up to 8 KiB of prompt, and the latency cost must be measured against the Feature 003 SC-011 gates. The copy guard can reject acceptable output. Its threshold is set and defended with the Feature 012 evaluation corpus, and context rewrite stays Experimental until that evaluation passes.

## Alternatives considered

An optional `context` field in v1 would break the closed v1 field set and fail on old servers with an ambiguous `invalid_request`. A separate endpoint would duplicate the handler, limits and identity reporting. Putting the context in the user message next to the dictation makes it easier for the model to mistake context for content. Sending raw, unmasked context would put pattern-matchable sensitive values into the prompt and make copied numbers harder to detect. Relying on the prompt alone, without a client-side copy guard, would leave injection resistance to model behavior that is not guaranteed.

## Constitution check

Complies with principles 2 and 6 (fixed snapshot and request bounds), 4 (offline dictation unchanged, fallback to the faithful transcript), 5 (opt-in, visible, masked, not logged, sent only to the user's own server), 8 (no weights in flowd, the backend stays behind the adapter), 11 (versioned closed schema, validated result) and 12 (tested decode, negotiation, guard and fallback paths). No exception or new dependency.
