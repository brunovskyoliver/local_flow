# Feature specification: Updates, usage reporting and dictation context

**Feature Branch**: `main` (design only; no branch created)
**Created**: 2026-10-23
**Status**: Clarified
**Input**: User requested easy GitHub redistribution to multiple users, an owner-only hosted usage dashboard with OpenTelemetry or similar, and current input-field context for successive dictations after manual edits. They prefer Parakeet Ultra based on their own use. Source thread: `6afdfca4-73fd-4ddb-9754-022c2f400e45`.

## Clarifications

### Session 2026-10-23

- Q: Should context change existing field text? A: Improve only newly dictated text using the current field.
- Q: Public or restricted downloads? A: Public app downloads; inference server access stays approval-only.
- Q: Anonymous or per-user reporting? A: Per-approved-user usage with device opt-in before local usage reporting.

## User Scenarios & Testing

### User story 1 - Continue an edited prompt (Priority: P1)

A Mac user dictates, manually edits the prompt, then dictates again. The next passage uses the current surrounding text when context is enabled, while preserving existing text outside the normal insertion or selected range.

**Why this priority**: Directly improves everyday dictation and builds on Feature 012.
**Independent test**: In a supported field, dictate, edit a nearby name, then dictate again; inspect the new snapshot and compare new text with context disabled.

**Acceptance scenarios**:
1. Given edits completed before the next recording, when capture succeeds, then the new snapshot contains those edits within the documented bounds.
2. Given no field access, an excluded app, or a secure field, when dictating, then dictation still completes and explains why context was unavailable without exposing content.
3. Given a changed target while processing, when insertion is attempted, then stale output is not inserted automatically and the completed transcript remains available.
4. Given a history retry, when rewriting again, then it uses the original snapshot and does not silently insert into the current field.

### User story 2 - Receive a Mac update (Priority: P2)

A user installs the public Mac app once and can check for, download and confirm a verified update from within it.

**Why this priority**: Avoids distributing replacement bundles by hand.
**Independent test**: Upgrade an older installed release while preserving its models, settings, history and helper compatibility.

**Acceptance scenarios**:
1. Given a valid newer release, when the user confirms installation while idle, then the app and bundled helpers run the new compatible build.
2. Given active recording, transcription or a transfer, when an update is available, then installation waits for work to finish or be explicitly cancelled.
3. Given a damaged or untrusted update or interrupted download, then the existing installation remains usable and the user can retry.
4. Given a public download, then it grants no access to an approval-only inference server.

### User story 3 - Review private usage (Priority: P3)

The owner signs into a separately hosted private dashboard and sees approved users' opted-in local and remote usage, daily totals, last report, and service reliability.

**Why this priority**: Helps support users and understand adoption without collecting their content.
**Independent test**: Two test users report known local and remote operations, resend reports, reconnect after offline use, and verify exact isolated totals and owner-only access.

**Acceptance scenarios**:
1. Given an enrolled device with sharing disabled, then no per-user usage report is exported from that device or its opted-out server operations.
2. Given consent and successful operations, then daily counts and audio duration appear once despite duplicate delivery.
3. Given an ordinary approved user or an unauthenticated visitor, then dashboard access is denied.
4. Given delayed or lost reports, then the dashboard shows coverage and freshness rather than implying complete totals.
5. Given consent withdrawal or account revocation, then future reporting stops, queued reports are discarded and retained reports can be deleted.

### Edge cases

Long fields and partial context; edits during capture; malicious instructions in a field; unsupported server context protocol; changed rewrite model; multiple devices and retry/fallback duplication; clock skew; revoked devices; storage full; dashboard outage; app/helper mismatch; current ad-hoc builds requiring a one-time signed installer; public archives without private repository credentials.

## Requirements

### Functional requirements

- **FR-001**: Reuse fresh bounded field capture per new Mac dictation; show capture availability and truncation without logging field text.
- **FR-002**: Context may affect only the new passage. Preserve normal explicit selection replacement, faithful transcript fallback, dictionary precedence, context-copy rejection, and language protection.
- **FR-003**: Detect changes to relevant captured field context and target before automatic insertion; preserve output for explicit recovery on conflict. Never follow instructions contained in field context.
- **FR-004**: Keep context capture and sending opt-in, honor exclusions, retain original snapshots for retries, and keep experimental labeling until the actual rewrite model meets Feature 012 quality gates.
- **FR-005**: Provide public verified Mac releases, manual update checking and configurable background checks with explicit installation confirmation.
- **FR-006**: Verify publisher authenticity and archive integrity before installation; reject incompatible or older builds; preserve settings, models, history and user data on update failure.
- **FR-007**: Defer installation during active work; refresh owned bundled helpers and verify compatible running versions after an update. Keep remote server deployment separately controlled.
- **FR-008**: Require explicit per-device usage consent for enrolled accounts, with a clear content-free field list, withdrawal and deletion controls. Unenrolled local-only users remain unreported.
- **FR-009**: Report daily dictation counts, audio duration, outcomes and last reporting time by approved user; distinguish local from server processing and logical operations from processing attempts.
- **FR-010**: Authenticate reporting identity, isolate users, deduplicate delivery and retries, retain reports across bounded outages, and mark gaps when reporting fails.
- **FR-011**: Restrict hosted reporting to the owner's verified identity. Keep existing administration interfaces private and never distribute administrative credentials with the app.
- **FR-012**: Exclude audio, transcripts, prompts, field text, titles, URLs and secrets from telemetry. Operational metrics use bounded labels without user or device identifiers.
- **FR-013**: Retain per-user daily usage for 90 days, support deletion, enforce bounded storage and retry limits, and keep dictation functional when reporting is unavailable.
- **FR-014**: Expose optional service-health measurements separately from durable usage accounting; report request latency, queue pressure and failures without claiming exact usage from sampled traces.

### Key entities

- Context snapshot: existing per-dictation reference and capture outcome, including fresh/truncated/unavailable status.
- Release: version, compatibility, publisher verification and public download location.
- Usage consent: account/device, revision, state and effective time.
- Usage aggregate: user/device/day and processing location, counts, duration, revision and completeness.
- Logical operation: bounded identifier shared across retry/fallback, distinct from processing attempts.
- Dashboard owner: exact allowed authenticated identity, separate from ordinary approved users.

## Success Criteria

- **SC-001**: All deterministic continuation tests preserve manual edits and only insert the new passage; unavailable context and stale targets never lose the completed transcript.
- **SC-002**: Context recommendation requires all Feature 012 quality gates on the recorded rewrite model, prompt version and hardware; failure keeps the option experimental.
- **SC-003**: Upgrade tests preserve user data, reject invalid archives, defer during active work, and confirm the new helper version in every tested case.
- **SC-004**: Known-count multi-device fixtures produce exact totals across duplicate delivery, retry, fallback and offline reconnection; missing reports are visibly identified.
- **SC-005**: Every unauthorized dashboard/reporting request in access tests is rejected and no prohibited content appears in captured telemetry.
- **SC-006**: Consent withdrawal, revocation, retention expiry and deletion tests prevent subsequent ingestion of removed or unauthorized reports.
- **SC-007**: Report measured capture overhead, unloaded memory, queue bounds and reporting overhead with hardware/build/conditions; retain existing constitution targets and record gaps rather than invent measurements.

## Assumptions

- First release covers the existing Mac client. iPhone distribution, iOS field context and iOS usage synchronization are separate follow-ups.
- One owner-operated LocalFlow server and one owner-operated reporting host; no federation, billing or public signup.
- Parakeet Ultra preference is user-reported; this feature neither changes the global recognition default nor assumes Ultra performs rewriting.
- Existing app boundaries remain intact. AGENTS wording and ADR 0032 differ on the client/server app count; no app is added or removed here.
- Deployment, public publication and credential provisioning occur only after concrete artifacts are prepared and the owner authorizes those external steps.

## LocalFlow resource and failure acceptance

Reuse Feature 012's context bounds and capture deadline. Updates stream to disk with one download at a time. Reporting uses bounded daily aggregates, bounded request bodies and a single export worker; exact capacities are defined in the plan. Reporting failure cannot block dictation or remove audio/transcripts. No additional model runtime or native app is introduced. Hosted reporting is optional and contains metadata only. Constitution compliance and dependency licenses must be checked before implementation; resource and live release acceptance remain distinct from unit tests.

## Approved revision: automatic reporting (2026-10-23)

The user requested removal of the Usage sharing section and all reporting alerts/status displays, with reporting built in. This supersedes the original per-device toggle requirement for new reporting enrollment. New approved identities automatically enroll through the existing authenticated usage endpoint. Local-only, signed-out and pending/revoked devices send nothing. Existing disabled bindings and pending deletion/withdrawal remain authoritative and are never automatically reopened. Switching identities discards unsent old-account aggregates before enrollment; it never forwards those totals to another account. No history backfill. Only daily counts/audio duration are allowed; all existing wire, retention, capacity and owner-access restrictions remain.

No reporting UI or dialogs remain in Settings. Reporting failures are silent and isolated from dictation. An immediate background attempt at startup and bounded retries enroll identities approved later without blocking app startup. Owner-side deletion and account revocation remain available. This behavior is documented in release notes even though the app has no reporting prompts.
