# Shared protocol design

Feature 001 is offline and has no API dependency. `openapi.yaml` intentionally has no paths. JSON schemas are provisional future v1 shapes, not implemented service contracts or database schemas. Future feature specifications must confirm limits and compatibility before shipping.

`meeting.schema.json` describes a transcript-text envelope, not audio or a full archive manifest. Unknown speaker_id is null. `summary.schema.json` uses stable participant UUIDs for owner, with null for unknown. Display names are resolved locally; never guess an owner from text. Validate schema with format checking enabled and reject unknown fields. Additional semantic checks must enforce unique segment IDs, end_ms >= start_ms, valid referenced participants and ownership supported by source evidence. Enforce byte/request limits before parsing; array caps alone are not safe network admission control.

Breaking wire changes require a new schema_version and explicit migration/compatibility design. Render Markdown/UI only after structural and semantic validation. No generated clients or schema framework yet.
