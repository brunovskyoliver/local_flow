# Shared protocol design

Feature 001 is offline and has no API dependency. `meeting.schema.json` and `summary.schema.json` are provisional future v1 shapes, not implemented service contracts or database schemas. Future feature specifications must confirm limits and compatibility before shipping.

`meeting.schema.json` describes a transcript-text envelope, not audio or a full archive manifest. Unknown speaker_id is null. `summary.schema.json` uses stable participant UUIDs for owner, with null for unknown. Display names are resolved locally; never guess an owner from text. Validate schema with format checking enabled and reject unknown fields. Additional semantic checks must enforce unique segment IDs, end_ms >= start_ms, valid referenced participants and ownership supported by source evidence. Enforce byte/request limits before parsing; array caps alone are not safe network admission control.

## Rewrite protocol v1 (Feature 003)

`openapi.yaml` declares `GET /v1/rewrite/health` and `POST /v1/rewrite`. The request body is `schemas/rewrite-request.schema.json` (six fields, `additionalProperties: false`); the response is `application/x-ndjson` where each line matches `schemas/rewrite-event.schema.json` (`accepted`, `progress`, `delta`, `result`, `error`). Every `result` carries the identity fields `server`, `backend`, `prompt_version`, `shield` and `timing` so stored attempts and corpus results are reproducible. Normative limits, status mapping and the client's nine validation rules are in `specs/003-server-rewriting/contracts/rewrite-protocol.md`; the Swift types live in `apps/macos/LocalFlow/Core/Rewrite/RewriteProtocol.swift` and the Go types in `server/internal/rewrite/protocol.go`, each with tests for every rejection.

Breaking wire changes require a new schema_version and explicit migration/compatibility design. Render Markdown/UI only after structural and semantic validation. No generated clients or schema framework yet.
