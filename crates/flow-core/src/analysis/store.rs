//! `AnalysisStore`: the run rows, their state machine, adoption and pruning. Same SQL, so Swift reads
//! what this writes. Logs nothing; a run's text never leaves the database here.
use super::validate::{self, Action, Counts, Item, NewItem, OverlayRow, Owner, Validated};
use super::{Policy, PIPELINE_VERSION, RUN_ROWS_PER_MEETING, prefix_bytes};
use crate::db::Db;
use crate::meetings::{SourceRef, new_id};
use rusqlite::{Connection, OptionalExtension, params};

#[derive(Debug)]
pub enum StoreError {
    /// The run left `running`, or a newer run became current. The result is discarded, not failed.
    Late,
    ActiveRun,
    Missing,
    InvalidTransition,
    Sql(rusqlite::Error),
}
impl From<rusqlite::Error> for StoreError {
    fn from(e: rusqlite::Error) -> Self {
        StoreError::Sql(e)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunRow {
    pub id: String,
    pub meeting: String,
    pub state: String,
    pub trigger: String,
    pub evidence_version: String,
    pub pass: Option<String>,
    pub failure_category: Option<String>,
    pub failure_detail: Option<String>,
}
/// `RunIdentity`, bounded on write to the columns' checks.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Identity {
    pub server_version: String,
    pub backend_kind: String,
    pub backend_model: String,
    pub prompt_versions: String,
    pub pipeline_version: String,
}
const RUN_COLUMNS: &str = "id, meeting_id, state, \"trigger\", evidence_version, transcript_pass_id, failure_category, failure_detail";
fn row(r: &rusqlite::Row) -> rusqlite::Result<RunRow> {
    Ok(RunRow { id: r.get(0)?, meeting: r.get(1)?, state: r.get(2)?, trigger: r.get(3)?, evidence_version: r.get(4)?, pass: r.get(5)?, failure_category: r.get(6)?, failure_detail: r.get(7)? })
}
pub fn run(db: &Db, id: &str) -> Result<Option<RunRow>, StoreError> {
    Ok(db.conn.query_row(&format!("SELECT {RUN_COLUMNS} FROM analysis_runs WHERE id=?1"), [id], row).optional()?)
}
pub fn latest_run(db: &Db, meeting: &str) -> Result<Option<RunRow>, StoreError> {
    Ok(db.conn.query_row(&format!("SELECT {RUN_COLUMNS} FROM analysis_runs WHERE meeting_id=?1 ORDER BY created_at DESC, rowid DESC LIMIT 1"), [meeting], row).optional()?)
}
pub fn accepted_run(db: &Db, meeting: &str) -> Result<Option<RunRow>, StoreError> {
    Ok(db.conn.query_row(&format!("SELECT {RUN_COLUMNS} FROM analysis_runs WHERE id=(SELECT accepted_run_id FROM meeting_analysis WHERE meeting_id=?1)"), [meeting], row).optional()?)
}
fn touch(c: &Connection, meeting: &str, now: i64) -> rusqlite::Result<()> {
    c.execute("INSERT INTO meeting_analysis (meeting_id, updated_at, revision) VALUES (?1,?2,0) ON CONFLICT(meeting_id) DO UPDATE SET updated_at=excluded.updated_at, revision=revision+1", params![meeting, now])?;
    Ok(())
}
/// The `pending` row and `current_run_id`, in one transaction. One active run per meeting.
pub fn admit(db: &Db, meeting: &str, trigger: &str, version: &str, pass: &str, policy: &Policy, now: i64) -> Result<String, StoreError> {
    let tx = db.conn.unchecked_transaction()?;
    let id = new_id();
    let inserted = tx.execute(
        "INSERT INTO analysis_runs (id, meeting_id, state, \"trigger\", evidence_version, transcript_pass_id, protocol_version, schema_version, pipeline_version, request_config_json, created_at) VALUES (?1,?2,'pending',?3,?4,?5,1,1,?6,?7,?8)",
        params![id, meeting, trigger, version, pass, PIPELINE_VERSION, policy.config_json(), now],
    );
    if let Err(rusqlite::Error::SqliteFailure(e, _)) = &inserted
        && e.code == rusqlite::ErrorCode::ConstraintViolation
    {
        return Err(StoreError::ActiveRun);
    }
    inserted?;
    touch(&tx, meeting, now)?;
    tx.execute("UPDATE meeting_analysis SET current_run_id=?1 WHERE meeting_id=?2", params![id, meeting])?;
    tx.commit()?;
    Ok(id)
}
fn state(db: &Db, id: &str) -> Result<String, StoreError> {
    db.conn.query_row("SELECT state FROM analysis_runs WHERE id=?1", [id], |r| r.get(0)).optional()?.ok_or(StoreError::Missing)
}
fn can_transition(from: &str, to: &str) -> bool {
    match from {
        "pending" => matches!(to, "running" | "cancelled" | "interrupted"),
        "running" => matches!(to, "succeeded" | "failed" | "timed_out" | "cancelled" | "interrupted" | "superseded"),
        "succeeded" => to == "superseded",
        _ => false,
    }
}
pub fn start(db: &Db, id: &str, now: i64) -> Result<(), StoreError> {
    let from = state(db, id)?;
    // A cancelled or deleted run mustn't resume: the result would be discarded anyway.
    if !can_transition(&from, "running") {
        return Err(StoreError::Late);
    }
    db.conn.execute("UPDATE analysis_runs SET state='running', started_at=COALESCE(started_at,?1) WHERE id=?2", params![now, id])?;
    Ok(())
}
pub fn record_path(db: &Db, id: &str, path: &str) -> Result<(), StoreError> {
    let failure = (path == "local_after_server_failure").then_some("user_ran_locally");
    db.conn.execute("UPDATE analysis_runs SET inference_path=?1, server_failure=?2 WHERE id=?3", params![path, failure, id])?;
    Ok(())
}
fn require_running(db: &Db, id: &str) -> Result<(), StoreError> {
    if state(db, id)? == "running" { Ok(()) } else { Err(StoreError::Late) }
}
pub fn record_plan(db: &Db, id: &str, chunks: usize) -> Result<(), StoreError> {
    require_running(db, id)?;
    db.conn.execute("UPDATE analysis_runs SET chunk_count=?1 WHERE id=?2", params![chunks as i64, id])?;
    Ok(())
}
pub fn record_request(db: &Db, id: &str, input: usize, output: usize, retried: bool, preempted: bool) -> Result<(), StoreError> {
    require_running(db, id)?;
    db.conn.execute(
        "UPDATE analysis_runs SET request_count=request_count+1, input_bytes=input_bytes+?1, output_bytes=output_bytes+?2, retry_count=retry_count+?3, preemption_count=preemption_count+?4 WHERE id=?5",
        params![input as i64, output as i64, i64::from(retried), i64::from(preempted), id],
    )?;
    Ok(())
}
fn finish(db: &Db, id: &str, to: &str, category: Option<&str>, detail: Option<&str>, now: i64) -> Result<(), StoreError> {
    if !can_transition(&state(db, id)?, to) {
        return Err(StoreError::InvalidTransition);
    }
    db.conn.execute(
        "UPDATE analysis_runs SET state=?1, completed_at=?2, failure_category=?3, failure_detail=?4, duration_ms=MAX(0, ?2 - COALESCE(started_at, created_at)) WHERE id=?5",
        params![to, now, category, detail.map(|d| prefix_bytes(d, 512)), id],
    )?;
    Ok(())
}
pub fn fail(db: &Db, id: &str, category: &str, detail: Option<&str>, now: i64) -> Result<(), StoreError> {
    finish(db, id, "failed", Some(category), detail, now)
}
pub fn time_out(db: &Db, id: &str, now: i64) -> Result<(), StoreError> {
    finish(db, id, "timed_out", Some("timeout"), None, now)
}
pub fn cancel(db: &Db, id: &str, now: i64) -> Result<(), StoreError> {
    finish(db, id, "cancelled", None, None, now)
}
pub fn interrupt(db: &Db, id: &str, now: i64) -> Result<(), StoreError> {
    finish(db, id, "interrupted", Some("interrupted"), None, now)
}
pub fn supersede(db: &Db, id: &str, now: i64) -> Result<(), StoreError> {
    if state(db, id)? == "superseded" {
        return Ok(());
    }
    finish(db, id, "superseded", None, None, now)
}
fn insert_sources(c: &Connection, run: &str, meeting: &str, kind: &str, target: &str, sources: &[SourceRef]) -> rusqlite::Result<()> {
    for (ordinal, source) in sources.iter().take(10).enumerate() {
        let (source_kind, segment, note, hash) = match source {
            SourceRef::Segment(id) => ("segment", Some(id.as_str()), None, None),
            SourceRef::Note(o, h) => ("note", None, Some(*o), Some(h.as_str())),
        };
        c.execute(
            "INSERT INTO analysis_sources (run_id, meeting_id, target_kind, target_id, ordinal, source_kind, segment_id, note_ordinal, note_hash) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            params![run, meeting, kind, target, ordinal as i64, source_kind, segment, note, hash],
        )?;
    }
    Ok(())
}
fn new_item(id: &str, kind: &str, text: &str, sources: &[SourceRef]) -> NewItem {
    NewItem { id: id.to_string(), kind: kind.to_string(), text: text.to_string(), source_keys: sources.iter().map(SourceRef::sort_key).collect() }
}
fn insert_plain(c: &Connection, run: &str, meeting: &str, kind: &str, items: &[Item], out: &mut Vec<NewItem>) -> rusqlite::Result<()> {
    for (ordinal, item) in items.iter().enumerate() {
        let id = new_id();
        c.execute("INSERT INTO analysis_items (id, run_id, meeting_id, kind, ordinal, text, evidence_class) VALUES (?1,?2,?3,?4,?5,?6,?7)", params![id, run, meeting, kind, ordinal as i64, item.text, item.evidence_class])?;
        insert_sources(c, run, meeting, "item", &id, &item.sources)?;
        out.push(new_item(&id, kind, &item.text, &item.sources));
    }
    Ok(())
}
fn insert_actions(c: &Connection, run: &str, meeting: &str, items: &[Action], out: &mut Vec<NewItem>) -> rusqlite::Result<()> {
    for (ordinal, a) in items.iter().enumerate() {
        let id = new_id();
        let (kind, speaker, known, name, certainty) = match &a.owner {
            Owner::Participant { speaker, known, certainty } => ("participant", Some(speaker.as_str()), known.as_deref(), None, Some(*certainty)),
            Owner::Mentioned(name) => ("mentioned", None, None, Some(name.as_str()), None),
            Owner::None => ("none", None, None, None, None),
        };
        let (segment, note) = match &a.due.source {
            Some(SourceRef::Segment(id)) => (Some(id.as_str()), None),
            Some(SourceRef::Note(o, _)) => (None, Some(*o)),
            None => (None, None),
        };
        c.execute(
            "INSERT INTO analysis_items (id, run_id, meeting_id, kind, ordinal, text, owner_kind, owner_speaker_id, owner_known_speaker_id, owner_name, owner_certainty, ownership_state, due_state, due_date, due_original, due_source_segment_id, due_source_note_ordinal) VALUES (?1,?2,?3,'action_item',?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
            params![id, run, meeting, ordinal as i64, a.text, kind, speaker, known, name, certainty, a.ownership_state, a.due.state, a.due.date, a.due.original, segment, note],
        )?;
        insert_sources(c, run, meeting, "item", &id, &a.sources)?;
        out.push(new_item(&id, "action_item", &a.text, &a.sources));
    }
    Ok(())
}
/// One transaction: a run that left `running` or lost `current_run_id` writes nothing.
pub fn adopt(db: &Db, id: &str, result: &Validated, counts: &Counts, identity: &Identity, now: i64) -> Result<(), StoreError> {
    let tx = db.conn.unchecked_transaction()?;
    let c: &Connection = &tx;
    let (meeting, from, version): (String, String, String) = c.query_row("SELECT meeting_id, state, evidence_version FROM analysis_runs WHERE id=?1", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).optional()?.ok_or(StoreError::Missing)?;
    if from != "running" {
        return Err(StoreError::Late);
    }
    let pointer: Option<(Option<String>, Option<String>)> = c.query_row("SELECT current_run_id, accepted_run_id FROM meeting_analysis WHERE meeting_id=?1", [&meeting], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
    let Some((Some(current), previous)) = pointer else { return Err(StoreError::Late) };
    if current != id {
        return Err(StoreError::Late);
    }
    let mut s = c.prepare("SELECT id, item_kind, field, target_kind, orphaned_at, item_text_snapshot, source_key FROM analysis_overlays WHERE meeting_id=?1 ORDER BY created_at, id")?;
    let overlays: Vec<OverlayRow> = s
        .query_map([&meeting], |r| Ok(OverlayRow { id: r.get(0)?, item_kind: r.get(1)?, field: r.get(2)?, is_summary: r.get::<_, String>(3)? == "summary", orphaned: r.get::<_, Option<i64>>(4)?.is_some(), item_text: r.get(5)?, source_key: r.get(6)? }))?
        .collect::<Result<_, _>>()?;
    drop(s);
    if let Some(previous) = previous {
        c.execute("UPDATE analysis_runs SET state='superseded' WHERE id=?1 AND state='succeeded'", [&previous])?;
        for table in ["analysis_summaries", "analysis_topics", "analysis_items", "analysis_sources"] {
            c.execute(&format!("DELETE FROM {table} WHERE run_id=?1"), [&previous])?;
        }
    }
    c.execute("INSERT INTO analysis_summaries (run_id, meeting_id, text, language, whole_meeting) VALUES (?1,?2,?3,?4,?5)", params![id, meeting, result.summary, result.language, result.whole_meeting])?;
    insert_sources(c, id, &meeting, "summary", id, &result.summary_sources)?;
    for (ordinal, topic) in result.topics.iter().enumerate() {
        let topic_id = new_id();
        let bullets = serde_json::to_string(&topic.bullets).unwrap_or_else(|_| "[]".into());
        c.execute("INSERT INTO analysis_topics (id, run_id, meeting_id, ordinal, title, summary, bullets_json) VALUES (?1,?2,?3,?4,?5,?6,?7)", params![topic_id, id, meeting, ordinal as i64, topic.title, topic.summary, bullets])?;
        insert_sources(c, id, &meeting, "topic", &topic_id, &topic.sources)?;
    }
    let mut items = vec![];
    insert_plain(c, id, &meeting, "decision", &result.decisions, &mut items)?;
    insert_actions(c, id, &meeting, &result.action_items, &mut items)?;
    insert_plain(c, id, &meeting, "next_step", &result.next_steps, &mut items)?;
    insert_plain(c, id, &meeting, "open_question", &result.open_questions, &mut items)?;
    insert_plain(c, id, &meeting, "risk", &result.risks, &mut items)?;
    let (matched, orphaned) = validate::match_overlays(&overlays, &items);
    for (overlay, item) in matched {
        c.execute("UPDATE analysis_overlays SET item_id=?1, orphaned_at=NULL, updated_at=?2 WHERE id=?3", params![item, now, overlay])?;
    }
    for overlay in orphaned {
        c.execute("UPDATE analysis_overlays SET item_id=NULL, orphaned_at=COALESCE(orphaned_at, ?1), updated_at=?1 WHERE id=?2", params![now, overlay])?;
    }
    c.execute(
        "UPDATE analysis_runs SET state='succeeded', completed_at=?1, server_version=?2, protocol_version=1, schema_version=1, backend_kind=?3, backend_model=?4, prompt_versions=?5, pipeline_version=?6, language_policy=?7, item_count=?8, dropped_literal_count=?9, dropped_unsupported_count=?10, identity_downgrade_count=?11, unresolved_owner_count=?12, duration_ms=MAX(0, ?1 - COALESCE(started_at, created_at)) WHERE id=?13",
        params![now, prefix_bytes(&identity.server_version, 64), prefix_bytes(&identity.backend_kind, 128), prefix_bytes(&identity.backend_model, 128), prefix_bytes(&identity.prompt_versions, 128), prefix_bytes(&identity.pipeline_version, 64), result.language, counts.items, counts.dropped_literal, counts.dropped_unsupported, counts.identity_downgrades, counts.unresolved_owners, id],
    )?;
    c.execute("UPDATE meeting_analysis SET accepted_run_id=?1, accepted_evidence_version=?2, updated_at=?3, revision=revision+1 WHERE meeting_id=?4", params![id, version, now, meeting])?;
    let count: i64 = c.query_row("SELECT count(*) FROM analysis_runs WHERE meeting_id=?1", [&meeting], |r| r.get(0))?;
    if count > RUN_ROWS_PER_MEETING {
        c.execute("DELETE FROM analysis_runs WHERE id IN (SELECT r.id FROM analysis_runs r WHERE r.meeting_id=?1 AND r.state<>'succeeded' ORDER BY r.created_at ASC, r.id ASC LIMIT ?2)", params![meeting, count - RUN_ROWS_PER_MEETING])?;
    }
    tx.commit()?;
    Ok(())
}
