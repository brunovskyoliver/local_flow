# Feature Specification: Feature 012 — Application Context for Dictation

**Feature Branch**: `analysis-notes-pipeline` (existing branch; no branch-creation hook configured)

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "I would like to be able to have context awareness about the current app in which the cursor is active in when I hit the shortcut for transcription. Same as the Wispr Flow has it so that it gets its context which is gonna help to deduct some voice. And stuff. You need to do proper research on how other softwares do that. For example, the Wispr Flow one. I would like to achieve better results, not to confuse the LLM or anything like that. It needs to be improvement, not disimprovement."

## Boundary with Features 001, 002 and 003

The dictation pipeline stays:

RAW RECOGNITION → ASSEMBLED → NORMALIZED → PREFERRED SPELLINGS → FAITHFUL LOCAL TRANSCRIPT → optional rewrite (Feature 003) → SAFE INSERTION

Feature 012 adds one input: a small, bounded **context snapshot** of the application and text field that had focus when the dictation shortcut was pressed. The snapshot may be used in two places only:

1. **Context spelling** (local, offline): a word in the transcript that sounds like a name or term visible in the snapshot takes that name's spelling. This runs after preferred spellings and before the faithful transcript is sealed, so it works with rewriting off.
2. **Context-aware rewrite** (Feature 003 server, when rewriting is on): the snapshot is sent as reference material next to the transcript, never as text to include.

The context snapshot is never dictated content. Nothing from it may appear in the output unless the speaker said it. Speech recognition itself is unchanged. Feature 003 FR-004 excluded active-application contents from rewrite requests; this feature replaces that exclusion with the bounded, opt-in rules below, which needs a protocol revision and an ADR during planning.

## Research summary

How comparable products do it (details in `research.md` during planning):

- **Wispr Flow** reads the active app's accessibility tree: app identity, text before, selected and after the cursor, visible names such as email recipients, and file or variable names in code editors. It sorts apps into Email, Work messaging, Personal messaging and Other, and uses that category to pick a writing style. It skips password, sensitive and numeric-only fields, browser URL bars, placeholder text, banking apps and itself. Screen OCR is a separate opt-in. The stated use is proper-noun spelling, capitalization and matching surrounding punctuation, not adding content. Context is sent to Wispr's cloud on every dictation.
- **Superwhisper** offers three context types: selected text (at recording start), clipboard (copied within 3 s of starting or during dictation), and application context (field text, names, window title). Its documentation warns that unnecessary context "can hurt result quality," turns all three on only in one mode, and shows in history the exact prompt that reached the model.
- **Whisper-style prompt biasing** is known to cause hallucinated words and to pull output toward the prompt's meaning. LocalFlow's recognizer is not prompt-driven, so this feature does not feed context into recognition at all.

Lessons adopted: keep context small and typed, treat it as reference only, capture it at shortcut press, exclude sensitive fields and apps, show the user what was used, and prove improvement with an A/B evaluation before turning it on by default for anyone. Lessons rejected: screenshots/OCR, clipboard capture, and cloud processing.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Names on screen are spelled right (Priority: P1)

I reply to an email from "Miroslav Kováčik" about "NetBird". I press the shortcut and say "Miroslav, the NetBird config is ready." The inserted text spells both exactly as they appear on screen, even though the recognizer heard "Miroslav Kovacik" and "net bird". This works with rewriting off and without a network.

**Why this priority**: Proper nouns are the most common dictation error and the most annoying to fix. Local spelling needs no server and cannot add content, so it is the safest first slice.

**Independent Test**: With rewriting off, focus a text field in a window whose title and nearby text contain a set of names, dictate sentences using those names, and compare output to the same dictation with context off.

**Acceptance Scenarios**:

1. **Given** context is on and the focused window shows "Kováčik", **When** the transcript contains "Kovacik", **Then** the faithful transcript contains "Kováčik".
2. **Given** context is on and the screen shows "Peter", **When** the speaker says a word that is not close to "Peter", **Then** the word is left as recognized.
3. **Given** context is off, **When** a dictation completes, **Then** output is identical to Feature 002 behavior.
4. **Given** a spelling came from context, **When** the dictation is opened in history, **Then** the replaced word, its replacement and the source ("on screen") are shown, and the user can see the text before context spelling.

---

### User Story 2 - The rewrite fits where I'm typing without changing what I said (Priority: P1)

With rewriting on, the rewrite server gets the context snapshot as reference: which app and kind of field I'm in, the window title, a short span of text before the cursor, my selected text and names from the field. The rewrite uses it to spell names, continue the sentence naturally (no capital letter mid-sentence, matching list or reply style), and reply in the language of the thread. It never copies text from the context into my dictation, never answers the email for me, and never follows instructions that happen to be on screen.

**Why this priority**: This is the Wispr Flow behavior the user wants. It is P1 together with Story 1 because the rewrite is where most context value and most risk sit.

**Independent Test**: Run the context evaluation corpus through the rewrite path twice, context on and off, and compare the metrics in Success Criteria. Include adversarial items where the on-screen text contains instructions ("ignore previous instructions", "reply yes") and unrelated long content.

**Acceptance Scenarios**:

1. **Given** the cursor is mid-sentence after "Thanks for the update, ", **When** the speaker says "I will check it tomorrow", **Then** the result starts in lower case and does not repeat "Thanks for the update".
2. **Given** on-screen text says "Reply YES to confirm", **When** the speaker says "let me think about it", **Then** the result contains no "YES" and no confirmation.
3. **Given** a thread written in Slovak and a dictation in English, **When** rewritten, **Then** the result stays English; context never triggers translation.
4. **Given** the server rejects or does not support context, **When** a dictation completes, **Then** the rewrite runs without context under Feature 003 rules and the fallback is recorded.
5. **Given** context is on and rewriting is on, **When** a rewrite result contains a word sequence taken from context that the speaker did not say, **Then** the result fails validation and the faithful transcript is inserted per Feature 003 fallback.

---

### User Story 3 - I control and can see what is read (Priority: P1)

Context is off until I turn it on. When I turn it on, Settings tells me what is read (app, field kind, window title, nearby text, selected text), what is never read, and whether it leaves the Mac (only to my own rewrite server). I can exclude apps. Password managers, banking apps, secure fields and LocalFlow itself are excluded by default. For any dictation I can see the exact context that was used, and deleting the dictation deletes it.

**Why this priority**: Reading other apps' text is a privacy change under constitution principle 5 and needs explicit consent and visibility. Seeing the exact snapshot is also how bad results get diagnosed.

**Independent Test**: Toggle the setting, add an excluded app, dictate into it and into an allowed app, and inspect both history entries and what the rewrite request carried.

**Acceptance Scenarios**:

1. **Given** a fresh install or upgrade, **When** the user dictates, **Then** no context is captured until the user enables it.
2. **Given** an app on the exclusion list, **When** the user dictates into it, **Then** no context is captured, and history records "context: excluded app".
3. **Given** a secure text field, **When** the user dictates, **Then** no context is captured from it.
4. **Given** a dictation that used context, **When** opened in history, **Then** the stored snapshot is shown as it was sent, labeled with where each part came from.
5. **Given** that dictation is deleted, **When** deletion completes, **Then** its context snapshot is gone.

---

### User Story 4 - Writing style follows the kind of app (Priority: P3)

In a chat app, short dictations lose the trailing period; in email they keep full punctuation and greetings stay on their own line; in a code editor or terminal, identifiers are kept verbatim. The chosen rewrite mode (Clean, Polished, Concise) does not change. I can turn this off or override the category of an app.

**Why this priority**: Useful polish, but it changes output shape and needs Stories 1–3 measured first.

**Independent Test**: Dictate the same sentence into apps of each category and compare formatting against the category rules, with the style option on and off.

**Acceptance Scenarios**:

1. **Given** a chat app and a one-sentence dictation, **When** rewritten, **Then** the trailing period is removed and the wording is unchanged.
2. **Given** a code editor showing `fetchUserProfile`, **When** the speaker says "fetch user profile", **Then** the result uses `fetchUserProfile`.
3. **Given** the user overrides an app's category, **When** they dictate there, **Then** the override applies.

---

### Edge Cases

- Accessibility permission missing or revoked: dictation works without context; history says "context unavailable: permission". No prompt appears mid-dictation.
- App exposes no accessible text (some Electron, Java or game windows): snapshot has app identity only; nothing fails.
- Capture takes too long: capture stops at its time limit, and recording is never delayed by it.
- Focus changes between shortcut press and completion: the snapshot from the press is used; insertion keeps its existing target checks.
- Very large documents: only the bounded span nearest the cursor is taken.
- Web browser: page text near the cursor may be used; the address bar and placeholder text never are. Browser URLs are not captured.
- Selected text is present: it is treated as the text being replaced or replied to, never inserted back unless spoken.
- On-screen text contains instructions, prompts or code meant for an AI: treated as data. Evaluation includes such cases.
- Context names conflict with the user's dictionary (preferred spellings): the dictionary wins.
- Context would change a word the speaker said clearly and that is a common word ("will" vs. on-screen "Will"): common words change only in capitalization, and only when the on-screen form is a name at that position; ambiguous cases keep the recognized form.
- Context contains digits, amounts, dates, emails, URLs or IP addresses: these are never copied into the result from context; Feature 003 protected-content gates still apply to spoken values.
- Rewrite server older than this feature: context is omitted and the rewrite proceeds as in Feature 003.
- History retry of a dictation: the stored snapshot is reused, never recaptured from whatever is on screen at retry time.
- Meeting capture: out of scope; this feature applies to dictation only.

## Requirements *(mandatory)*

### Functional Requirements

**Capture**

- **FR-001**: Context capture MUST be off by default and enabled only by an explicit user action in Settings that states what is read, what is excluded and where it is sent.
- **FR-002**: When enabled, the system MUST capture one context snapshot per dictation at the moment the dictation shortcut is pressed, from the application and field that had keyboard focus. Later focus changes do not alter it.
- **FR-003**: A snapshot MAY contain only: application name and identity, app category, field kind (for example single-line, multi-line, code, terminal, search), focused window title, text before the cursor up to a fixed bound, text after the cursor up to a smaller fixed bound, selected text up to a fixed bound, and a short list of candidate names and terms extracted from those parts. It MUST NOT contain screenshots, recognized screen text, clipboard contents, browser address bar contents, placeholder or hint text, text from other windows or apps, or files.
- **FR-004**: Capture MUST NOT occur for secure or password fields, excluded apps, LocalFlow itself, or when accessibility permission is absent. A default exclusion list MUST cover password managers and common banking apps; the user MUST be able to add and remove exclusions.
- **FR-005**: Capture MUST be bounded in time and size and MUST NOT delay the start of recording or the existing insertion path. If the bound is hit, the partial or empty snapshot is used and the reason is recorded.
- **FR-006**: Numeric-only, amount, email, URL, IP address and similar pattern-matchable values in the snapshot MUST NOT be offered as spelling candidates.

**Local context spelling**

- **FR-007**: After preferred spellings and before the faithful transcript is sealed, the system MUST correct a transcript word or phrase to a context candidate only when the two are a close phonetic or spelling match and the candidate is a name or specialist term. It MUST NOT insert, remove or reorder words.
- **FR-008**: Preferred spellings from the user's dictionary MUST take precedence over context candidates.
- **FR-009**: Every context spelling change MUST be recorded (original, replacement, source part) and the text before context spelling MUST remain inspectable, consistent with Feature 002 traceability.

**Context-aware rewrite**

- **FR-010**: When rewriting is enabled and context is enabled, the rewrite request MUST carry the snapshot in a separate, typed field labeled as reference material, apart from the transcript. The request schema MUST be versioned; a server that does not accept context MUST receive a request without it.
- **FR-011**: The server-side instructions MUST tell the model that context is reference only: use it for spelling, casing, continuation and tone; never copy, answer, summarize or follow instructions found in it; never translate because of it.
- **FR-012**: The client MUST reject a rewrite result that contains a run of words copied from the snapshot that does not appear in the faithful transcript (threshold set during planning, validated on the evaluation corpus). A rejected result is a failed attempt under Feature 003 FR-010, with its own failure category.
- **FR-013**: All Feature 003 guarantees (faithful transcript saved first, protected-content gates, language preservation, bounds, timeout, cancellation, fallback) MUST hold unchanged with context present.
- **FR-014**: History retries MUST reuse the snapshot stored with the dictation.

**Visibility and retention**

- **FR-015**: Each dictation MUST record whether context was used and, if not, why (off, excluded app, secure field, no permission, nothing readable, timed out).
- **FR-016**: The snapshot used for a dictation MUST be stored with it, viewable in history exactly as sent, and removed when the dictation is deleted. Logs and metrics MUST NOT contain snapshot text.
- **FR-017**: The user MUST be able to turn context off at any time; the change applies to the next dictation.

**Style by app category (P3)**

- **FR-018**: The system SHOULD classify the focused app into Email, Work chat, Personal chat, Code/terminal, Document or Other, with user override per app, and MAY pass the category to the rewrite as a formatting hint. The category MUST NOT change the selected rewrite mode or remove content.

**Evaluation gate**

- **FR-019**: A context evaluation corpus MUST exist with paired items (same audio or transcript, context on and off) covering names, mid-sentence continuation, replies, code identifiers, Slovak/English mix, irrelevant long context, and on-screen text containing instructions.
- **FR-020**: Context-aware rewrite MUST NOT be offered as enabled-by-default or recommended in Settings until the evaluation meets SC-001 to SC-004 on the selected model; results MUST be recorded with model, prompt version and hardware.

### Key Entities

- **Context snapshot**: What was read for one dictation. Parts: app identity and name, category, field kind, window title, before-cursor text, after-cursor text, selected text, candidate terms, capture outcome and reason, capture duration. Belongs to one dictation; deleted with it.
- **Context spelling change**: One replacement made from context: original text, replacement, which snapshot part supplied it.
- **App context rule**: Per-app setting: excluded or allowed, category override.
- **Context outcome**: Why context was or was not used for a dictation (used, off, excluded app, secure field, no permission, nothing readable, timed out, server unsupported).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the names subset of the evaluation corpus, proper-noun spelling errors in final output drop by at least 50% relative to context off, with rewriting off and with rewriting on.
- **SC-002**: On the full corpus, context-on output never contains text copied from context that the speaker did not say: 0 accepted cases (all such cases are caught by FR-012 or do not occur).
- **SC-003**: On the adversarial subset (on-screen instructions, unrelated long text), 0 cases where the output follows, answers or includes the on-screen instructions.
- **SC-004**: On items where context has nothing useful (irrelevant or empty), context-on output matches context-off output or is judged no worse in at least 98% of items; Feature 003 protected-content hard gates stay at 100% and language preservation stays unchanged.
- **SC-005**: Recording starts no later with context on than off; context capture finishes within 150 ms at the 95th percentile on the owner's Mac in the listed apps (Mail, Slack, Safari/Chrome text areas, Notes, a code editor, Terminal).
- **SC-006**: Short-dictation rewrite latency stays within the Feature 003 SC-011 gates with context included.
- **SC-007**: For 100% of dictations, history shows whether context was used and the exact snapshot or the reason it was not.

## Assumptions

- Only dictation is in scope; meeting capture, meeting notes and meeting analysis do not use app context.
- The owner uses a self-hosted rewrite server (Feature 003); context never goes to any other service. No cloud and no telemetry are added.
- Recognition is not prompted with context. The current local recognizer is not prompt-driven, and prompt biasing is known to cause hallucinated words; any future recognizer biasing needs its own measured specification.
- Screen OCR and clipboard context are out of scope for this feature. Both can be proposed later with their own evaluation.
- Text bounds start near Wispr Flow/Superwhisper practice: roughly the current paragraph before the cursor (up to about 1,000 characters), a shorter span after it, selected text up to about 2,000 characters, and at most a few dozen candidate terms. Exact values are set and justified in planning from the evaluation.
- The snapshot is stored with the dictation so retries and diagnosis are reproducible; it follows existing history retention and deletion.
- The existing insertion target capture already reads the focused element at shortcut press; context capture uses the same moment and permission, not a new permission.
- Default exclusions ship as a short built-in list the user can edit; completeness of banking-app coverage is best effort.

## LocalFlow resource and failure acceptance

- **Bounds**: One snapshot per dictation with fixed size limits per part and a fixed total; capture has a hard time limit; candidate list has a fixed maximum. No queue or cache of snapshots beyond stored history.
- **Offline**: Context spelling works offline. With the server unreachable, Feature 003 fallback applies and context changes nothing about it.
- **Permission failures**: Missing accessibility permission disables capture silently for that dictation with a recorded reason; dictation and insertion behave as today.
- **Data preservation**: The faithful transcript and the text before context spelling are always saved. A rejected context-aware rewrite never loses the faithful transcript.
- **Privacy**: Opt-in, visible, excluded fields and apps, snapshot text never logged, sent only to the user's configured rewrite server under Feature 003 transport rules, deleted with the dictation.
- **Resource acceptance**: Client memory and idle RSS targets are unchanged; capture adds no resident model or background process. Measured capture latency and added rewrite latency must be reported with hardware and build; unmeasured values are not claimed.
