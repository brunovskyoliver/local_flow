# Feature Specification: Adaptive Dictionary

**Feature Branch**: `015-adaptive-dictionary`

**Created**: 2026-09-30

**Status**: Implemented; acceptance on real dictations pending

**Input**: User description: "Feature 015: Adaptive Dictionary (Phase 1). The Dictionary learns from how its entries perform in real use. An alias the user keeps reverting is disabled automatically, with a notice and a one-click restore; nothing is deleted. First-sight auto-learn becomes a suggestion unless the replacement matches an existing Dictionary term; a second sighting auto-learns. Phase 1 only: no phonetic matching, no history mining."

## Summary

Today a Dictionary entry, once saved, applies forever. A wrong alias learned from one correction keeps rewriting an ordinary word, and the app never notices that the user undoes it, because the undo looks like an ordinary lowercase edit to the correction learner. This feature counts what each entry and alias does in real dictations, retires the ones the user keeps undoing, makes learning from a single correction more careful, and shows the numbers in the Dictionary.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A wrong alias stops applying on its own (Priority: P1)

The Dictionary maps "jon" to "John". The user is writing about a "jon boat", and twice in the next few dictations changes "John" back. From the next dictation on, "jon" is left alone, a short notice says the alias was turned off, and the Dictionary shows it as retired with a Restore button.

**Why this priority**: A bad alias damages every dictation that contains the word, and today the only fix is finding and deleting it by hand. This is the harm the feature exists to stop.

**Independent Test**: Seed an entry with one alias, run dictations that apply it, simulate readback edits that undo the replacement, and check that the alias is retired after the rule is met and is not applied to the next dictation.

**Acceptance Scenarios**:

1. **Given** an established alias applied in 4 dictations, **When** the user reverts it in 2 of them, **Then** the alias is retired, a notice is shown once, and the next dictation keeps the spoken word.
2. **Given** an established alias applied in 10 dictations, **When** the user reverts it in 2 of them (20%), **Then** it stays active.
3. **Given** a retired alias, **When** the user presses Restore, **Then** it applies again from the next dictation and its revert count starts over.
4. **Given** an alias is retired, **When** the user looks at the Dictionary, **Then** the entry, its canonical spelling and the alias are all still there.

---

### User Story 2 - Learned terms prove themselves before they are trusted (Priority: P1)

A correction learned automatically starts as provisional. If the user undoes it even once, it is retired. After it has been kept in 3 dictations without an edit, it becomes an ordinary established entry.

**Why this priority**: Auto-learned entries come from a single observed edit and are the most likely to be wrong. They need the strictest rule.

**Independent Test**: Learn an entry through the correction path, apply it, simulate one revert, and check that it is retired. Apply a second learned entry in 3 dictations with no edits and check that it becomes established.

**Acceptance Scenarios**:

1. **Given** a provisional learned alias, **When** it is reverted once, **Then** it is retired with the same notice and Restore as in Story 1.
2. **Given** a provisional learned alias, **When** it is kept in 3 dictations, **Then** it is shown as established and only the Story 1 rule applies from then on.
3. **Given** an entry the user typed in the Dictionary, **When** it is first used, **Then** it is established from the start.

---

### User Story 3 - One correction suggests; the second one learns (Priority: P1)

The user fixes "Zabix" to "Zabbix" once. The app adds a suggestion instead of saving a Dictionary entry. When the user makes the same fix again, even after restarting the Mac, the entry is learned automatically, with the existing undo bubble. When the replacement is already a Dictionary term, the first fix is enough.

**Why this priority**: Owner decision 2. It removes most wrong learned entries at the source, and it needs the repeat count to survive a restart to work at all.

**Independent Test**: Feed the same candidate correction twice with an app restart in between, and check that the first gives a suggestion and the second learns. Feed a correction whose replacement is an existing canonical and check that it learns on first sight.

**Acceptance Scenarios**:

1. **Given** a new correction that today scores for auto-learn, **When** it is seen the first time, **Then** it becomes a suggestion and no Dictionary entry is written.
2. **Given** the same correction was seen once before, including in an earlier app session, **When** it is seen again, **Then** it is learned as a provisional entry.
3. **Given** a correction whose replacement matches an existing canonical, **When** it is seen the first time, **Then** it is learned as today.
4. **Given** the repeat record is full, **When** a new correction arrives, **Then** the oldest record is dropped.

---

### User Story 4 - The Dictionary shows how each term is doing (Priority: P2)

Each entry in the Dictionary shows how often it changed a dictation, how often the change was kept or undone, and when it was last used. Provisional and retired aliases are marked, and retired ones have Restore.

**Why this priority**: It makes the automatic decisions visible and reversible, but the protection in Stories 1–3 works without it.

**Independent Test**: With stored counts for a few entries, open the Dictionary and check the figures, the markers and that Restore works.

**Acceptance Scenarios**:

1. **Given** an entry that was applied 12 times, kept 9 times and reverted once, last on 29 September, **When** the user opens the Dictionary, **Then** those figures are shown for that entry.
2. **Given** an entry that was never applied, **When** it is shown, **Then** it reads as unused rather than 0% kept.

---

### User Story 5 - The most-used terms get boosted first (Priority: P3)

When more entries are enabled than the speech-level boost can hold, it takes the ones used most and most recently, not the oldest ones.

**Why this priority**: The Dictionary has 22 entries and the boost holds 256, so this changes nothing today. It matters once the Dictionary grows.

**Independent Test**: With more than 256 enabled entries and stored usage, check which entries the boost receives.

**Acceptance Scenarios**:

1. **Given** 300 enabled entries, **When** a dictation starts, **Then** the boost receives the 256 with the highest recent use; entries never used are ordered by creation, as today.
2. **Given** an entry whose boost is retired, **When** the boost list is built, **Then** that entry is left out.

---

### Edge Cases

- **Terminal or unreadable target**: nothing can be read back, so no kept or reverted events are recorded, and nothing there retires an alias.
- **The rewrite changed the replaced word**: if the Dictionary's spelling is not present unchanged in the inserted text, that dictation is not attributed to the entry.
- **Edit covers more than the replaced word**: an edit that overlaps a Dictionary replacement counts as a revert of that replacement, even if it also changes other words.
- **Two replacements in one dictation**: each is judged separately; an edit counts against the replacement it overlaps.
- **The user edits the rest of the field, not the replaced word**: counts as kept for the replacement.
- **Focus leaves the field before the readback window ends**: the last reading decides, as correction learning does today.
- **Canonical-only entries**: they have no alias to retire, so a revert of a speech-level boost replacement retires that entry's boost. The entry stays enabled for exact matches and suggestions.
- **Alias edited or removed by the user**: its counts are dropped; a changed alias starts fresh.
- **Entry deleted**: all its counts and events are deleted with it.
- **Existing learned entries**: the 12 entries learned before this feature start as provisional with no counts.
- **Undo bubble used right after learning**: behaves as today; nothing is counted.
- **Clock changes**: "last used" is display-only and never drives a decision.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST record, for each dictation where a Dictionary entry changed the transcript, which entry and which alias (or the speech-level boost) made the change.
- **FR-002**: After a confirmed insertion into a readable field, the app MUST classify each such change as kept or reverted, using the existing post-insertion readback window.
- **FR-003**: An observed edit that overlaps the span a Dictionary change produced MUST count as a revert of that change, whether or not the correction learner would learn from it.
- **FR-004**: A change whose Dictionary spelling does not appear unchanged in the inserted text MUST NOT be classified.
- **FR-005**: An established alias MUST be retired when it has at least 2 reverts and its reverts are more than 30% of its classified uses.
- **FR-006**: A provisional alias MUST be retired on its first revert and MUST become established after 3 kept uses.
- **FR-007**: Entries learned automatically MUST start provisional. Entries the user created or edited in the Dictionary MUST start established. Entries learned before this feature MUST start provisional.
- **FR-008**: A revert of a speech-level boost change MUST count against that entry's boost with the same rules. A retired boost MUST stop the entry from being sent to the boost, without disabling the entry.
- **FR-009**: A retired alias MUST NOT be applied from the next dictation on. Retiring MUST NOT delete the entry, its canonical spelling or the alias text.
- **FR-010**: When an alias or boost is retired, the app MUST show a short notice naming the alias and canonical spelling, with a Restore button, in the same place as the existing "Added to dictionary" notice. It is shown once per retirement.
- **FR-011**: Restore MUST make a retired alias or boost active again from the next dictation, mark it established, and start its revert count over.
- **FR-012**: A correction that would be learned today MUST become a suggestion on its first sighting, unless its replacement matches an existing enabled canonical spelling.
- **FR-013**: A correction seen before MUST be learned on its next sighting, subject to the existing hard exclusions and score rules.
- **FR-014**: The record of seen corrections MUST survive app restarts, MUST hold only one-way digests of the correction, never its text, and MUST be bounded, dropping the oldest records first.
- **FR-015**: When more entries are enabled than the boost can hold, the boost MUST take the ones with the most recent use first. Unused entries keep today's order.
- **FR-016**: The Dictionary MUST show for each entry: times applied, kept, reverted, and last used; each alias's state (provisional, established, retired); and Restore for retired aliases and boosts.
- **FR-017**: Usage records MUST NOT contain transcript, alias or correction text. Logs about them MUST stay content-free.
- **FR-018**: Stored usage events MUST be bounded in count. Pruning old events MUST NOT change the totals used for retirement or display.
- **FR-019**: Deleting an entry MUST delete its usage records. Editing an alias MUST reset that alias's counts.
- **FR-020**: Nothing in this feature may slow down or block a dictation. If usage recording fails, the dictation MUST complete as it does today, and the failure MUST be logged without content.
- **FR-021**: Turning off correction learning MUST also stop the kept and reverted classification. Applied counts and existing retirements stay.

### Key Entities

- **Alias usage**: one per alias, and one per entry for the speech-level boost. It holds state (provisional, established, retired), totals for applied, kept and reverted, the time of last use, and when and why it was retired.
- **Usage event**: one Dictionary change in one dictation and what happened to it: applied, then kept, reverted or not classified. It holds identifiers and times only.
- **Seen correction**: a digest of a candidate correction, with how often it was seen and when last. Bounded, and it survives restarts.
- **Dictionary entry** (existing): gains nothing visible but its usage; the canonical spelling and aliases are unchanged.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In scripted tests, an established alias that meets the retirement rule is not applied in the very next dictation, in 100% of cases.
- **SC-002**: In scripted tests, a provisional learned alias reverted once is not applied in the next dictation, in 100% of cases.
- **SC-003**: A correction seen for the first time never creates a Dictionary entry unless its replacement is an existing canonical; the same correction seen again after an app restart is learned.
- **SC-004**: Inspecting all stored data after a test run with known transcripts finds none of the transcript, alias or correction text in any usage or seen-correction record.
- **SC-005**: Time from key release to inserted text does not measurably change: added work stays under 5 ms per dictation on the owner's Mac.
- **SC-006**: After two weeks of normal use, the owner can see in the Dictionary which entries are used, kept and undone, and can restore any retired alias in one click.
- **SC-007**: No existing entry or alias text is lost by the feature's migration or by any retirement.

## Assumptions

- The thresholds (2 reverts, over 30%, 1 revert while provisional, 3 kept) are starting values chosen by the owner's plan. They are named constants and will be revisited once real usage is recorded.
- Kept and reverted are only known where the app can read the field back after insertion, the same places correction learning works today. Elsewhere only "applied" is recorded.
- The existing 90-second readback and its single-contiguous-change detection are reused. No new permissions are needed.
- A change the rewrite moved or altered is left unclassified rather than guessed.
- English and Slovak only, as today.
- Out of scope: sound-based matching, mining history for suggestions, learning from History edits, syncing usage between devices, and meeting transcripts.

## LocalFlow resource and failure acceptance

- **Bounded work**: classification runs inside the existing post-insertion readback and adds no reads to the field. Event storage is bounded (FR-018); the seen-correction record is bounded (FR-014).
- **Offline**: everything is local; no network is involved.
- **Permission failures**: without Accessibility, nothing is classified and nothing is retired; dictation is unaffected.
- **Preservation of user data**: retiring never deletes Dictionary text (FR-009, SC-007). A failed usage write never affects the dictation (FR-020). The migration only adds data.
- **Resources**: no model, no extra process, and no measurable latency (SC-005).
