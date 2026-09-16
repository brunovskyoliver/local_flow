# LocalFlow development

Read `.specify/memory/constitution.md` before changing architecture or code.
Use the repository's `.agents/skills/speckit-*` workflow for substantial features.
The active feature is recorded in `.specify/feature.json`.

Apply the global unslop skill to assistant-authored prose. Use plain, specific language; preserve code, commands, URLs and quoted text.

Keep this one native macOS app with source boundaries, a separate Go server, and shared wire schemas. Do not implement later roadmap features as part of Feature 001.
Run `make check` after changes. Hardware acceptance and resource measurements are separate from scaffolding validation; never claim measurements that were not collected.
Architecture exceptions require an ADR and an explicit constitution check. No VoiceInk application code may be copied.
