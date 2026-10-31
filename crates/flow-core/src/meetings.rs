//! Store and logic behind the meetings views: the library, notes, transcript paging, speaker
//! assignment and the summary read model, on the Swift-migrated schema. Capture, ASR, diarization
//! and summary generation stay in Mac-only workers; here their stored results are read.
use crate::db::Db;
pub use crate::history::now_ms;
use rusqlite::{Connection, OptionalExtension, Row, params};
use std::collections::{HashMap, HashSet};
use std::path::Path;

pub const PAGE_SIZE: usize = 20;
pub const MAX_RESIDENT_ROWS: usize = 40;
pub const NOTES_MAX_BYTES: usize = 1_048_576;
pub const TITLE_MAX_BYTES: usize = 256;
pub const TRANSCRIPT_PAGE: usize = 200;
pub const SEARCH_LIMIT: usize = 1000;
pub const FULL_TEXT_LIMIT: usize = 20 * 1024 * 1024;
pub const CORRECTIONS_PER_MEETING: i64 = 10_000;
pub const OVERLAY_CAP: i64 = 500;
pub const REJECTED_PER_MEETING: i64 = 4096;
pub const NAME_MAX: usize = 80;

#[derive(Debug)]
pub enum MeetingError {
    Sql(rusqlite::Error),
    Missing,
    Stale,
    Active,
    TitleTooLarge,
    NotesTooLarge,
    CorrectionCapacity,
    RejectCapacity,
    OverlayCapacity,
    Invalid,
}
impl From<rusqlite::Error> for MeetingError {
    fn from(e: rusqlite::Error) -> Self {
        MeetingError::Sql(e)
    }
}
pub type Res<T> = Result<T, MeetingError>;

/// A random v4 UUID in Swift's `uuidString` form. `RandomState` is the standard library's OS seed.
pub fn new_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let word = || {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_i64(now_ms());
        h.finish()
    };
    let (a, b) = (word(), word());
    format!(
        "{:08X}-{:04X}-4{:03X}-{:04X}-{:012X}",
        (a >> 32) as u32,
        (a >> 16) as u16,
        a & 0xFFF,
        0x8000 | (b >> 48) as u16 & 0x3FFF,
        b & 0xFFFF_FFFF_FFFF
    )
}

// MARK: dates. `offset` is the local UTC offset in seconds at that instant.

/// SQLite reads the zone database, so this needs no OS call.
pub fn local_offset(db: &Db, ms: i64) -> i32 {
    db.conn.query_row("SELECT CAST(strftime('%s', ?1/1000, 'unixepoch', 'localtime') AS INTEGER) - ?1/1000", [ms], |r| r.get::<_, i64>(0)).unwrap_or(0) as i32
}

const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/// Days since 1970 to (year, month 1-12, day 1-31).
fn civil(days: i64) -> (i64, usize, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m as usize, d)
}

/// The local day number of an instant.
pub fn local_day(ms: i64, offset: i32) -> i64 {
    (ms.div_euclid(1000) + offset as i64).div_euclid(86_400)
}
fn clock(ms: i64, offset: i32) -> (i64, i64) {
    let s = (ms.div_euclid(1000) + offset as i64).rem_euclid(86_400);
    (s / 3600, s % 3600 / 60)
}
/// "24 Sep 2026, 14:05"
pub fn date_time_text(ms: i64, offset: i32) -> String {
    let (y, m, d) = civil(local_day(ms, offset));
    let (h, min) = clock(ms, offset);
    format!("{d} {} {y}, {h:02}:{min:02}", MONTHS[m - 1])
}
/// "14:05"
pub fn time_text(ms: i64, offset: i32) -> String {
    let (h, min) = clock(ms, offset);
    format!("{h:02}:{min:02}")
}
/// "24 Sep 2026", the copied report's date.
pub fn report_date(ms: i64, offset: i32) -> String {
    let (y, m, d) = civil(local_day(ms, offset));
    format!("{d} {} {y}", MONTHS[m - 1])
}
/// "20 Sep, 10:14", the summary menu's generated line.
pub fn generated_text(ms: i64, offset: i32) -> String {
    let (_, m, d) = civil(local_day(ms, offset));
    let (h, min) = clock(ms, offset);
    format!("Generated {d} {}, {h:02}:{min:02} · AI-generated", MONTHS[m - 1])
}
/// "TODAY, SEP 24", "YESTERDAY, SEP 23", "TUE, SEP 22".
pub fn day_heading(ms: i64, offset: i32, today: i64) -> String {
    let day = local_day(ms, offset);
    let (_, m, d) = civil(day);
    let month_day = format!("{} {d}", MONTHS[m - 1]).to_uppercase();
    if day == today {
        format!("TODAY, {month_day}")
    } else if day == today - 1 {
        format!("YESTERDAY, {month_day}")
    } else {
        format!("{}, {month_day}", WEEKDAYS[(day + 4).rem_euclid(7) as usize].to_uppercase())
    }
}
pub fn duration_text(ms: i64) -> String {
    let s = ms.max(0) / 1000;
    if s >= 3600 { format!("{}:{:02}:{:02}", s / 3600, s % 3600 / 60, s % 60) } else { format!("{}:{:02}", s / 60, s % 60) }
}
pub fn fallback_title(created_at: i64, offset: i32) -> String {
    format!("Meeting {}", date_time_text(created_at, offset))
}
/// `YYYY-MM-DD` to "21 Sep".
pub fn due_text(date: &str) -> String {
    let parts: Vec<&str> = date.split('-').collect();
    match (parts.len(), parts.get(1).and_then(|m| m.parse::<usize>().ok()), parts.get(2).and_then(|d| d.parse::<u32>().ok())) {
        (3, Some(m @ 1..=12), Some(d)) => format!("{d} {}", MONTHS[m - 1]),
        _ => date.to_string(),
    }
}
/// `localizedStandardContains` closely enough: case-insensitive substring.
// ponytail: no diacritic folding; add a table when a Slovak search misses a name.
pub fn contains(hay: &str, needle: &str) -> bool {
    hay.to_lowercase().contains(&needle.to_lowercase())
}

// MARK: messages shared by views

pub fn failure_reason_text(reason: &str, track: Option<&str>) -> String {
    match reason {
        "storage_write_failed" => "Recording stopped: audio could not be written to disk. What was recorded so far was kept.".into(),
        "storage_unavailable" => "Recording stopped: the meeting folder is unavailable.".into(),
        "encoder_failed" => "Recording stopped: the audio encoder failed. What was recorded so far was kept.".into(),
        "not_running_at_last_state" => "LocalFlow did not exit cleanly during this meeting. Recorded audio was recovered where possible.".into(),
        "device_lost" => "The microphone disconnected. The meeting continued with system audio.".into(),
        "stream_stopped" => "System audio stopped. The meeting continued with the microphone.".into(),
        "permission_revoked" => format!(
            "{} permission was revoked during the meeting.",
            match track {
                Some("microphone") => "Microphone",
                Some("system") => "System audio",
                _ => "Audio",
            }
        ),
        "both_sources_failed" => "Recording stopped because both audio sources failed.".into(),
        "record_missing" => "Files were found without a meeting record. They were kept and listed here.".into(),
        "file_missing" => "The audio file for this segment is missing.".into(),
        "segment_open_failed" => "The meeting could not start because an audio file could not be created.".into(),
        _ => "This track could not be made playable. The file was kept.".into(),
    }
}
pub fn transcript_failure_text(category: &str, kept: i64, resumes: bool, final_meeting: bool) -> String {
    match category {
        "model_unavailable" if final_meeting => "Whisper Turbo is not installed. Install the meeting model in Settings to transcribe.".into(),
        "model_unavailable" => "The speech model is not installed. Install it in Settings to transcribe.".into(),
        "model_provisioning" => "The speech model could not be verified. Reinstall it in Settings.".into(),
        "model_load_failure" => "The speech model failed to load. The recording was not affected.".into(),
        "audio_decode_failure" => "A recorded track could not be decoded. The recording was kept.".into(),
        "analysis_stream_failure" => "Audio could not be prepared for transcription. The recording was kept.".into(),
        "runtime_failure" if final_meeting => "Meeting transcription failed. The recording was kept; choose Retry to try again.".into(),
        "runtime_failure" => "Transcription stopped because the speech model failed. The recording continues.".into(),
        "finalization_interrupted" if resumes => "Finalization was interrupted. It will resume automatically.".into(),
        "finalization_interrupted" => "Finalization was interrupted. Choose Retry to finish it.".into(),
        "persistence_failure" => "Transcript could not be saved. The recording continues; retry later.".into(),
        _ => format!("Transcript storage limit reached ({kept} segments kept). Delete old meetings to free space."),
    }
}
pub fn badge_text(state: &str, progress: f64) -> String {
    match state {
        "not_requested" => "Not requested".into(),
        "pending" => "Pending".into(),
        "live" => "Live".into(),
        "finalizing" => format!("Finalizing {} %", (progress.clamp(0.0, 1.0) * 100.0).round() as i64),
        "final" => "Final".into(),
        "failed" => "Failed".into(),
        _ => "Interrupted".into(),
    }
}
/// `TranscriptSectionView.stateText`. `live` is the live preview's health while transcribing.
pub fn section_status_text(state: &str, live: &str, failure: Option<&str>, progress: f64) -> String {
    if let Some(f) = failure {
        return format!("Transcription failed: {f}");
    }
    if state == "finalizing" {
        return badge_text(state, progress);
    }
    match (state, live) {
        ("not_requested", _) => "Transcription off",
        ("pending", _) => "Pending",
        ("final", _) => "Final",
        ("failed", _) => "Transcription failed",
        ("interrupted", _) => "Interrupted",
        (_, "catching_up") => "Catching up",
        (_, "degraded") => "Degraded — some live text skipped; the full transcript is produced when the meeting stops",
        (_, "suspended") => "Live transcription suspended — catching up",
        (_, "stopped") => "Live preview stopped",
        _ => "Transcribing",
    }
    .into()
}
pub fn diarization_failure_text(c: &str) -> &'static str {
    match c {
        "model_unavailable" => "Speaker labeling model isn't installed. Install it in Settings → Models.",
        "os_unsupported" => "Speaker labeling needs macOS 15 or later.",
        "model_load_failure" => "The speaker labeling model couldn't be loaded.",
        "audio_missing" => "This meeting's audio isn't available, so speakers can't be labeled.",
        "audio_decode_failure" => "This meeting's audio couldn't be read.",
        "runtime_failure" => "Speaker labeling stopped unexpectedly.",
        "transcript_changed" => "The transcript changed while speakers were being labeled.",
        "persistence_failure" => "Speaker labels couldn't be saved.",
        "persistence_capacity" => "Speaker labels couldn't be saved. Meeting storage is full.",
        _ => "Speaker labeling was interrupted.",
    }
}
pub fn identification_failure_text(c: &str) -> &'static str {
    match c {
        "model_unavailable" => "Speaker labeling model isn't installed. Install it in Settings → Models.",
        "os_unsupported" => "Speaker identification needs macOS 15 or later.",
        "model_load_failure" => "The voice model couldn't be loaded.",
        "audio_missing" => "This meeting's audio isn't available, so speakers can't be identified.",
        "audio_decode_failure" => "This meeting's audio couldn't be read.",
        "runtime_failure" => "Speaker identification stopped unexpectedly.",
        "diarization_changed" => "Speaker labels changed while speakers were being identified.",
        "persistence_failure" => "Speaker identities couldn't be saved.",
        "persistence_capacity" => "Speaker identities couldn't be saved. Meeting storage is full.",
        _ => "Speaker identification was interrupted.",
    }
}
pub fn analysis_failure_text(c: &str) -> &'static str {
    match c {
        "not_eligible" => "The transcript is not finished yet.",
        "server_unreachable" => "Your server could not be reached.",
        "authentication_failed" => "The server rejected the credential.",
        "server_unavailable" | "backend_unavailable" => "The server's language model is not running.",
        "backend_busy" => "The server is busy with dictation. Try again in a moment.",
        "backend_timeout" | "timeout" => "The summary took too long and was stopped.",
        "unsupported_version" | "malformed_response" | "oversized_response" | "meeting_mismatch" => "The server sent a summary LocalFlow could not read.",
        "source_validation" | "protected_literal" | "unsupported_content" | "over_cap" => "The summary did not pass LocalFlow's checks and was not saved.",
        "too_long" => "This meeting is too long to summarize with the current limits.",
        "persistence_failure" => "The summary couldn't be saved.",
        "persistence_capacity" => "The summary couldn't be saved. Meeting storage is full.",
        _ => "The summary was interrupted.",
    }
}
pub fn today_summary(active_state: Option<&str>, today_count: usize) -> String {
    match active_state {
        Some("created" | "preparing" | "recording") => return "Recording now".into(),
        Some("paused") => return "Recording paused".into(),
        Some("finalizing") => return "Finishing the recording".into(),
        _ => {}
    }
    match today_count {
        0 => "No meetings today".into(),
        1 => "1 meeting today".into(),
        n => format!("{n} meetings today"),
    }
}
pub fn is_terminal(state: &str) -> bool {
    matches!(state, "completed" | "interrupted" | "failed")
}
pub fn state_badge(state: &str) -> String {
    let mut c = state.chars();
    c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
}

// MARK: meetings

#[derive(Clone, Debug, PartialEq)]
pub struct MeetingRow {
    pub id: String,
    pub state: String,
    pub title: Option<String>,
    pub created_at: i64,
    pub started_at: Option<i64>,
    pub recorded_ms: i64,
    pub failure_reason: Option<String>,
    pub revision: i64,
    pub origin: String,
    pub warning: bool,
}
impl MeetingRow {
    pub fn display_title(&self, offset: i32) -> String {
        self.title.clone().unwrap_or_else(|| fallback_title(self.created_at, offset))
    }
}
const ROW_SQL: &str = "SELECT m.id, m.state, m.title, m.created_at, m.started_at, m.recorded_ms, m.failure_reason, m.revision, m.origin,
  EXISTS(SELECT 1 FROM meeting_tracks t WHERE t.meeting_id=m.id AND t.health IN ('failed','unrecoverable')) AS warning FROM meetings m";
fn row(r: &Row) -> rusqlite::Result<MeetingRow> {
    Ok(MeetingRow {
        id: r.get(0)?,
        state: r.get(1)?,
        title: r.get(2)?,
        created_at: r.get(3)?,
        started_at: r.get(4)?,
        recorded_ms: r.get(5)?,
        failure_reason: r.get(6)?,
        revision: r.get(7)?,
        origin: r.get(8)?,
        warning: r.get(9)?,
    })
}
pub fn page(db: &Db, before: Option<(i64, &str)>, limit: usize) -> Res<Vec<MeetingRow>> {
    let (c, id) = before.unwrap_or((i64::MAX, ""));
    let sql = if before.is_some() {
        format!("{ROW_SQL} WHERE (m.created_at,m.id)<(?1,?2) ORDER BY m.created_at DESC, m.id DESC LIMIT ?3")
    } else {
        format!("{ROW_SQL} WHERE ?1=?1 AND ?2=?2 ORDER BY m.created_at DESC, m.id DESC LIMIT ?3")
    };
    let mut s = db.conn.prepare(&sql)?;
    let rows = s.query_map(params![c, id, limit as i64], row)?.collect::<Result<_, _>>()?;
    Ok(rows)
}
pub fn meeting(db: &Db, id: &str) -> Res<Option<MeetingRow>> {
    Ok(db.conn.query_row(&format!("{ROW_SQL} WHERE m.id=?1"), [id], row).optional()?)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub sequence: i64,
    pub relative_path: String,
    pub state: String,
    pub start_offset_ms: i64,
    pub duration_ms: i64,
    pub open_reason: String,
    pub failure_reason: Option<String>,
    pub input_device_name: Option<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Track {
    pub kind: String,
    pub health: String,
    pub failure_reason: Option<String>,
    pub dropped_frames: i64,
    pub duration_warning: bool,
    pub segments: Vec<Segment>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Detail {
    pub meeting: MeetingRow,
    pub tracks: Vec<Track>,
    pub notes: String,
    pub notes_revision: i64,
    pub pause_count: i64,
    pub outcome_count: i64,
}
impl Detail {
    pub fn track(&self, kind: &str) -> Option<&Track> {
        self.tracks.iter().find(|t| t.kind == kind)
    }
}
pub fn detail(db: &Db, id: &str) -> Res<Option<Detail>> {
    let Some(meeting) = meeting(db, id)? else { return Ok(None) };
    let mut s = db.conn.prepare(
        "SELECT id, type, health, failure_reason, dropped_frames, duration_warning FROM meeting_tracks WHERE meeting_id=?1
         ORDER BY CASE type WHEN 'microphone' THEN 0 ELSE 1 END",
    )?;
    let heads: Vec<(String, String, String, Option<String>, i64, bool)> =
        s.query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)))?.collect::<Result<_, _>>()?;
    let mut seg = db.conn.prepare(
        "SELECT sequence, relative_path, state, start_offset_ms, duration_ms, open_reason, failure_reason, input_device_name
         FROM meeting_segments WHERE track_id=?1 ORDER BY sequence",
    )?;
    let mut tracks = vec![];
    for (track_id, kind, health, failure_reason, dropped_frames, duration_warning) in heads {
        let segments = seg
            .query_map([&track_id], |r| {
                Ok(Segment {
                    sequence: r.get(0)?,
                    relative_path: r.get(1)?,
                    state: r.get(2)?,
                    start_offset_ms: r.get(3)?,
                    duration_ms: r.get(4)?,
                    open_reason: r.get(5)?,
                    failure_reason: r.get(6)?,
                    input_device_name: r.get(7)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        tracks.push(Track { kind, health, failure_reason, dropped_frames, duration_warning, segments });
    }
    let (notes, notes_revision) = notes(db, id)?.unwrap_or_default();
    let count = |sql: &str| db.conn.query_row(sql, [id], |r| r.get::<_, i64>(0));
    Ok(Some(Detail {
        meeting,
        tracks,
        notes,
        notes_revision,
        pause_count: count("SELECT count(*) FROM meeting_pauses WHERE meeting_id=?1")?,
        outcome_count: count("SELECT count(*) FROM meeting_recovery_outcomes WHERE meeting_id=?1")?,
    }))
}
pub fn notes(db: &Db, id: &str) -> Res<Option<(String, i64)>> {
    Ok(db.conn.query_row("SELECT text, revision FROM meeting_notes WHERE meeting_id=?1", [id], |r| Ok((r.get(0)?, r.get(1)?))).optional()?)
}
pub fn set_title(db: &Db, id: &str, title: &str, revision: i64, now: i64) -> Res<i64> {
    let trimmed = title.trim();
    if trimmed.len() > TITLE_MAX_BYTES {
        return Err(MeetingError::TitleTooLarge);
    }
    let current = meeting(db, id)?.ok_or(MeetingError::Missing)?;
    if current.revision != revision {
        return Err(MeetingError::Stale);
    }
    let value = (!trimmed.is_empty()).then_some(trimmed);
    db.conn.execute("UPDATE meetings SET title=?1, revision=revision+1, updated_at=?2 WHERE id=?3", params![value, now, id])?;
    Ok(revision + 1)
}
pub fn save_notes(db: &Db, id: &str, text: &str, revision: i64, now: i64) -> Res<i64> {
    if text.len() > NOTES_MAX_BYTES {
        return Err(MeetingError::NotesTooLarge);
    }
    let (_, current) = notes(db, id)?.ok_or(MeetingError::Missing)?;
    if current != revision {
        return Err(MeetingError::Stale);
    }
    db.conn.execute("UPDATE meeting_notes SET text=?1, updated_at=?2, revision=revision+1 WHERE meeting_id=?3", params![text, now, id])?;
    db.conn.execute("UPDATE meetings SET updated_at=MAX(updated_at,?1) WHERE id=?2", params![now, id])?;
    Ok(revision + 1)
}
pub fn set_run_locally(db: &Db, id: &str, now: i64) -> Res<()> {
    db.conn.execute("UPDATE meetings SET run_locally=1, updated_at=?1 WHERE id=?2", params![now, id])?;
    Ok(())
}
fn place(path: &str) -> &'static str {
    match path {
        "server" => "your server",
        "custom" => "your custom server",
        "local_after_server_failure" => "this Mac (server unavailable)",
        _ => "this Mac",
    }
}
/// "Transcript: your server · Speaker labels: this Mac", or nil when nothing is done.
pub fn provenance(db: &Db, id: &str) -> Res<Option<String>> {
    let one = |sql: &str| db.conn.query_row(sql, [id], |r| r.get::<_, String>(0)).optional();
    let parts = [
        ("Transcript", one("SELECT inference_path FROM meeting_transcriptions WHERE meeting_id=?1 AND state='final'")?),
        ("Speaker labels", one("SELECT r.inference_path FROM meeting_diarization d JOIN diarization_runs r ON r.id=d.accepted_run_id WHERE d.meeting_id=?1")?),
        ("Summary", one("SELECT r.inference_path FROM meeting_analysis a JOIN analysis_runs r ON r.id=a.accepted_run_id WHERE a.meeting_id=?1")?),
    ];
    let text: Vec<String> = parts.iter().filter_map(|(n, p)| p.as_ref().map(|p| format!("{n}: {}", place(p)))).collect();
    Ok((!text.is_empty()).then(|| text.join(" · ")))
}

/// Deleted, or kept with the paths still on disk.
#[derive(Debug, PartialEq)]
pub enum DeleteOutcome {
    Deleted,
    Remaining(Vec<String>),
}
/// Files first; the row goes only when none remain, so a failure can be retried.
pub fn delete_confirmed(db: &Db, root: &Path, id: &str, revision: i64) -> Res<DeleteOutcome> {
    let current = meeting(db, id)?.ok_or(MeetingError::Missing)?;
    if current.revision != revision {
        return Err(MeetingError::Stale);
    }
    if !is_terminal(&current.state) {
        return Err(MeetingError::Active);
    }
    let mut s = db.conn.prepare("SELECT s.relative_path FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id WHERE t.meeting_id=?1")?;
    let paths: Vec<String> = s.query_map([id], |r| r.get(0))?.collect::<Result<_, _>>()?;
    let mut remaining = vec![];
    let prefix = format!("{id}/");
    for path in paths {
        let full = root.join(&path);
        if !path.starts_with(&prefix) || path.contains("..") {
            remaining.push(path);
        } else if let Err(e) = std::fs::remove_file(&full) {
            if e.kind() != std::io::ErrorKind::NotFound {
                remaining.push(path);
            }
        }
    }
    let dir = root.join(id);
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            if remaining.iter().any(|p| root.join(p) == e.path()) {
                continue;
            }
            if std::fs::remove_file(e.path()).is_err() && std::fs::remove_dir_all(e.path()).is_err() {
                remaining.push(format!("{id}/{}", e.file_name().to_string_lossy()));
            }
        }
        let _ = std::fs::remove_dir(&dir);
    }
    if !remaining.is_empty() {
        return Ok(DeleteOutcome::Remaining(remaining));
    }
    let tx = db.conn.unchecked_transaction()?;
    let rev: i64 = tx.query_row("SELECT revision FROM meetings WHERE id=?1", [id], |r| r.get(0))?;
    if rev != revision {
        return Err(MeetingError::Stale);
    }
    tx.execute(
        "UPDATE transcript_usage SET text_bytes=text_bytes-COALESCE((SELECT text_bytes FROM meeting_transcriptions WHERE meeting_id=?1),0),
           segment_rows=segment_rows-COALESCE((SELECT segment_count FROM meeting_transcriptions WHERE meeting_id=?1),0) WHERE id=1",
        [id],
    )?;
    tx.execute("DELETE FROM meetings WHERE id=?1", [id])?;
    tx.commit()?;
    Ok(DeleteOutcome::Deleted)
}

// MARK: library view model

/// `MeetingLibraryViewModel`'s data rules, free of views.
#[derive(Default)]
pub struct Library {
    pub is_loading: bool,
    pub rows: Vec<MeetingRow>,
    pub has_older: bool,
    pub evicted_newest: bool,
    pub notice: Option<String>,
    pub detail_notice: Option<String>,
    pub detail: Option<Detail>,
    pub preview_id: Option<String>,
    pub preview: Option<Detail>,
    pub preview_notice: Option<String>,
    pub deletion_pending: HashSet<String>,
}
pub const PREVIEW_CHARS: usize = 1200;

impl Library {
    pub fn refresh(&mut self, db: &Db, active: Option<&str>) {
        match page(db, None, PAGE_SIZE) {
            Ok(rows) => {
                self.has_older = rows.len() == PAGE_SIZE;
                self.evicted_newest = false;
                self.rows = rows;
                self.notice = None;
                if let Some(id) = active {
                    if let Some(i) = self.rows.iter().position(|r| r.id == id) {
                        let r = self.rows.remove(i);
                        self.rows.insert(0, r);
                    } else if let Ok(Some(r)) = meeting(db, id) {
                        self.rows.insert(0, r);
                    }
                }
            }
            Err(_) => self.notice = Some("Meetings could not be loaded. Check app storage.".into()),
        }
        if let Some(id) = self.detail.as_ref().map(|d| d.meeting.id.clone()) {
            self.open(db, &id);
        }
    }
    pub fn load_older(&mut self, db: &Db) {
        let Some(last) = self.rows.last().cloned() else { return };
        match page(db, Some((last.created_at, &last.id)), PAGE_SIZE) {
            Ok(rows) => {
                self.has_older = rows.len() == PAGE_SIZE;
                self.rows.extend(rows);
                if self.rows.len() > MAX_RESIDENT_ROWS {
                    let excess = self.rows.len() - MAX_RESIDENT_ROWS;
                    self.rows.drain(..excess);
                    self.evicted_newest = true;
                }
            }
            Err(_) => self.notice = Some("Older meetings could not be loaded.".into()),
        }
    }
    pub fn preview(&mut self, db: &Db, id: &str) {
        self.preview_id = Some(id.to_string());
        self.preview_notice = None;
        match detail(db, id) {
            Ok(Some(mut d)) => {
                d.tracks.clear();
                d.pause_count = 0;
                d.outcome_count = 0;
                self.preview = Some(d);
            }
            Ok(None) => {
                self.preview = None;
                self.preview_notice = Some("This note no longer exists.".into());
            }
            Err(_) => {
                self.preview = None;
                self.preview_notice = Some("The overview could not be loaded.".into());
            }
        }
    }
    pub fn release_detail(&mut self) {
        self.detail = None;
        self.preview_id = None;
        self.preview = None;
        self.preview_notice = None;
    }
    pub fn open(&mut self, db: &Db, id: &str) {
        match detail(db, id) {
            Ok(Some(d)) => {
                self.detail = Some(d);
                self.detail_notice = None;
            }
            Ok(None) => {
                self.detail = None;
                self.detail_notice = Some("This meeting no longer exists.".into());
            }
            Err(_) => self.detail_notice = Some("Meeting details could not be loaded.".into()),
        }
    }
    pub fn close_detail(&mut self) {
        self.detail = None;
    }
    pub fn set_title(&mut self, db: &Db, id: &str, title: &str, revision: i64, active: Option<&str>) {
        match set_title(db, id, title, revision, now_ms()) {
            Ok(_) => {
                self.detail_notice = None;
                self.refresh(db, active);
            }
            Err(MeetingError::TitleTooLarge) => self.detail_notice = Some("Titles are limited to 256 bytes.".into()),
            Err(MeetingError::Stale) => {
                self.open(db, id);
                self.detail_notice = Some("The meeting changed. Try again.".into());
            }
            Err(_) => self.detail_notice = Some("The title could not be saved.".into()),
        }
    }
    pub fn delete(&mut self, db: &Db, root: &Path, id: &str, revision: i64, active: Option<&str>) {
        match delete_confirmed(db, root, id, revision) {
            Ok(DeleteOutcome::Deleted) => {
                self.deletion_pending.remove(id);
                self.detail_notice = None;
                if self.detail.as_ref().is_some_and(|d| d.meeting.id == id) {
                    self.detail = None;
                }
                if self.preview_id.as_deref() == Some(id) {
                    self.preview_id = None;
                    self.preview = None;
                }
                self.refresh(db, active);
            }
            Ok(DeleteOutcome::Remaining(paths)) => {
                self.deletion_pending.insert(id.to_string());
                self.detail_notice = Some(format!("Deletion incomplete: {} file(s) remain. Retry after checking the folder.", paths.len()));
            }
            Err(MeetingError::Active) => self.detail_notice = Some("Stop the meeting before deleting it.".into()),
            Err(MeetingError::Stale) => {
                self.open(db, id);
                self.detail_notice = Some("The meeting changed. Try again.".into());
            }
            Err(_) => self.detail_notice = Some("The meeting could not be deleted.".into()),
        }
    }
    pub fn run_locally(&mut self, db: &Db, id: &str, server_only: bool) {
        if server_only {
            self.detail_notice = Some("Server only is on, so this Mac doesn't run models. Change it in Settings › Server.".into());
        } else if set_run_locally(db, id, now_ms()).is_err() {
            self.detail_notice = Some("This meeting can't be moved to this Mac right now.".into());
        }
    }
    pub fn adjacent(&self, id: &str, offset: i64) -> Option<String> {
        let i = self.rows.iter().position(|r| r.id == id)? as i64 + offset;
        (i >= 0).then(|| self.rows.get(i as usize).map(|r| r.id.clone())).flatten()
    }
}

// MARK: notes editor

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveState {
    Idle,
    Saving,
    Saved,
    NotSaved,
}
/// `MeetingNotesEditor` without its timers: the view schedules `flush` 2 s after the last edit and
/// at most 10 s after the first unsaved one. Saving is synchronous here, so one write is in flight.
pub struct NotesEditor {
    pub meeting_id: String,
    pub text: String,
    stored: String,
    pub revision: i64,
    pub is_dirty: bool,
    pub state: SaveState,
    pub notice: Option<String>,
    pub save_count: u32,
    /// The byte range a View-source jump selected.
    pub reveal: Option<(usize, usize)>,
}
impl NotesEditor {
    pub fn new(meeting_id: &str, text: &str, revision: i64) -> Self {
        NotesEditor {
            meeting_id: meeting_id.into(),
            text: text.into(),
            stored: text.into(),
            revision,
            is_dirty: false,
            state: SaveState::Idle,
            notice: None,
            save_count: 0,
            reveal: None,
        }
    }
    /// False when refused over the size limit; the caller keeps the previous text in its field.
    pub fn edit(&mut self, value: &str) -> bool {
        if value == self.text {
            return true;
        }
        if value.len() > NOTES_MAX_BYTES {
            self.notice = Some("Notes are limited to 1 MiB. The last edit was not applied.".into());
            return false;
        }
        self.notice = None;
        self.text = value.into();
        self.is_dirty = value != self.stored;
        true
    }
    pub fn flush(&mut self, db: &Db) {
        if !self.is_dirty {
            return;
        }
        self.state = SaveState::Saving;
        let now = now_ms();
        let saved = match save_notes(db, &self.meeting_id, &self.text, self.revision, now) {
            Err(MeetingError::Stale) => notes(db, &self.meeting_id).ok().flatten().ok_or(MeetingError::Missing).and_then(|(_, latest)| save_notes(db, &self.meeting_id, &self.text, latest, now)),
            other => other,
        };
        match saved {
            Ok(revision) => {
                self.revision = revision;
                self.stored = self.text.clone();
                self.save_count += 1;
                self.is_dirty = false;
                self.state = SaveState::Saved;
                self.notice = None;
            }
            Err(_) => {
                self.state = SaveState::NotSaved;
                self.notice = Some("Notes not saved".into());
            }
        }
    }
    pub fn reveal(&mut self, ordinal: i64, hash: &str) {
        match note_paragraphs(&self.text).into_iter().find(|p| p.0 == ordinal && sha256_hex(&p.1) == hash) {
            Some((_, _, start, end)) => {
                self.notice = None;
                self.reveal = Some((start, end));
            }
            None => {
                self.reveal = None;
                self.notice = Some("This note has changed".into());
            }
        }
    }
}
/// Blank-line-separated paragraphs: (ordinal from 1, trimmed text, byte start, byte end).
pub fn note_paragraphs(text: &str) -> Vec<(i64, String, usize, usize)> {
    let mut out = vec![];
    let mut lines: Vec<(usize, usize)> = vec![];
    let mut at = 0;
    let flush = |lines: &mut Vec<(usize, usize)>, out: &mut Vec<(i64, String, usize, usize)>| {
        if let (Some(a), Some(b)) = (lines.first(), lines.last()) {
            out.push((out.len() as i64 + 1, text[a.0..b.1].trim().to_string(), a.0, b.1));
        }
        lines.clear();
    };
    for line in text.split('\n') {
        if line.trim().is_empty() {
            flush(&mut lines, &mut out);
        } else {
            lines.push((at, at + line.len()));
        }
        at += line.len() + 1;
    }
    flush(&mut lines, &mut out);
    out
}
pub fn sha256_hex(text: &str) -> String {
    crate::history::sha256_hex(text.as_bytes())
}

// MARK: transcript

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Transcription {
    pub state: String,
    pub pass_id: Option<String>,
    pub pass_kind: Option<String>,
    pub engine: Option<String>,
    pub failure_category: Option<String>,
    pub segment_count: i64,
    pub revision: i64,
    pub covered_ms: i64,
    pub recorded_ms_at_pass: i64,
}
impl Transcription {
    /// The pass's own share of the recording; the Swift coordinator's live progress is not persisted.
    pub fn progress(&self) -> f64 {
        if self.recorded_ms_at_pass > 0 { self.covered_ms as f64 / self.recorded_ms_at_pass as f64 } else { 0.0 }
    }
}
pub fn transcription(db: &Db, id: &str) -> Res<Option<Transcription>> {
    Ok(db
        .conn
        .query_row(
            "SELECT state, pass_id, pass_kind, engine, failure_category, segment_count, revision, covered_ms, recorded_ms_at_pass FROM meeting_transcriptions WHERE meeting_id=?1",
            [id],
            |r| {
                Ok(Transcription {
                    state: r.get(0)?,
                    pass_id: r.get(1)?,
                    pass_kind: r.get(2)?,
                    engine: r.get(3)?,
                    failure_category: r.get(4)?,
                    segment_count: r.get(5)?,
                    revision: r.get(6)?,
                    covered_ms: r.get(7)?,
                    recorded_ms_at_pass: r.get(8)?,
                })
            },
        )
        .optional()?)
}
pub fn source_label(tracks: &str) -> &'static str {
    match tracks {
        "mic" => "You",
        "system" => "Others",
        _ => "Unassigned",
    }
}
pub fn source_explanation(tracks: &str) -> &'static str {
    match tracks {
        "mic" => "Microphone audio",
        "system" => "System audio; may include multiple people",
        _ => "Mixed microphone and system audio; speaker unknown",
    }
}
pub fn speaker_label(source: &str, ordinal: i64, name: Option<&str>, in_room: bool) -> String {
    let name = name.filter(|n| !n.is_empty());
    match (source, in_room) {
        ("local", false) => name.map(|n| format!("{n} (You)")).unwrap_or_else(|| "You".into()),
        ("local", true) => name.map(String::from).unwrap_or_else(|| format!("Local {ordinal}")),
        _ => name.map(String::from).unwrap_or_else(|| format!("Speaker {ordinal}")),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum LabelKind {
    Speaker(String),
    Unknown,
    Overlapping,
}
#[derive(Clone, Debug, PartialEq)]
pub struct SegmentLabel {
    pub kind: LabelKind,
    pub text: String,
    pub color: Option<usize>,
    pub edited: bool,
    /// (name, known speaker id) of a Possible match.
    pub suggested: Option<(String, String)>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct TranscriptRow {
    pub id: String,
    pub ordinal: i64,
    pub start_ms: i64,
    pub finality: String,
    pub text: String,
    pub tracks: String,
    pub label: Option<SegmentLabel>,
    pub run_id: Option<String>,
}
pub fn labeled_page(db: &Db, meeting_id: &str, finality: &str, after: Option<i64>, limit: usize) -> Res<Vec<TranscriptRow>> {
    let identities = identities(db, meeting_id)?;
    let mut s = db.conn.prepare_cached(
        "SELECT s.id, s.ordinal, s.start_ms, s.finality, s.normalized_text, s.analysis_tracks,
           r.id, r.in_room, COALESCE(a.manual_kind, a.auto_kind), a.manual_kind IS NOT NULL,
           p.id, p.source, p.label_ordinal, p.color_index, p.display_name
         FROM transcript_segments s
         LEFT JOIN meeting_diarization d ON d.meeting_id=s.meeting_id
         LEFT JOIN diarization_runs r ON r.id=d.accepted_run_id AND s.finality='final'
           AND r.transcript_pass_id=s.pass_id
           AND r.transcript_pass_id=(SELECT pass_id FROM meeting_transcriptions WHERE meeting_id=s.meeting_id)
         LEFT JOIN speaker_assignments a ON a.run_id=r.id AND a.segment_id=s.id
         LEFT JOIN meeting_speakers e ON e.id=CASE WHEN a.manual_kind IS NOT NULL THEN a.manual_speaker_id ELSE a.auto_speaker_id END
         LEFT JOIN meeting_speakers p ON p.id=COALESCE(e.merged_into, e.id)
         WHERE s.meeting_id=?1 AND s.finality=?2 AND s.ordinal>?3 ORDER BY s.ordinal LIMIT ?4",
    )?;
    let rows = s
        .query_map(params![meeting_id, finality, after.unwrap_or(-1), limit.min(TRANSCRIPT_PAGE) as i64], |r| {
            let kind: Option<String> = r.get(8)?;
            let edited: Option<bool> = r.get(9)?;
            let edited = edited.unwrap_or(false);
            let root: Option<String> = r.get(10)?;
            let label = match kind.as_deref() {
                Some("unknown") => Some(SegmentLabel { kind: LabelKind::Unknown, text: "Unknown".into(), color: None, edited, suggested: None }),
                Some("ambiguous") => Some(SegmentLabel { kind: LabelKind::Overlapping, text: "Overlapping".into(), color: None, edited: false, suggested: None }),
                Some("speaker") => match (root, r.get::<_, Option<String>>(11)?, r.get::<_, Option<i64>>(12)?) {
                    (Some(root), Some(source), Some(ordinal)) => {
                        let name: Option<String> = r.get(14)?;
                        let in_room: Option<bool> = r.get(7)?;
                        let mut text = speaker_label(&source, ordinal, name.as_deref(), in_room.unwrap_or(false));
                        let mut suggested = None;
                        if source == "remote" {
                            if let Some(i) = identities.get(&root) {
                                if let ("possible", Some(n), Some(k)) = (i.state.as_str(), &i.known_name, &i.known_id) {
                                    text = format!("{n}?");
                                    suggested = Some((n.clone(), k.clone()));
                                }
                            }
                        }
                        Some(SegmentLabel { kind: LabelKind::Speaker(root), text, color: r.get::<_, Option<i64>>(13)?.map(|c| c as usize), edited, suggested })
                    }
                    _ => None,
                },
                _ => None,
            };
            Ok(TranscriptRow { id: r.get(0)?, ordinal: r.get(1)?, start_ms: r.get(2)?, finality: r.get(3)?, text: r.get(4)?, tracks: r.get(5)?, label, run_id: r.get(6)? })
        })?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}
#[derive(Clone, Debug, PartialEq)]
pub struct SpeakerRef {
    pub id: String,
    pub label: String,
    pub merged_into: Option<String>,
}
pub fn accepted_speakers(db: &Db, meeting_id: &str) -> Res<Option<(String, Vec<SpeakerRef>)>> {
    let accepted: Option<(String, bool)> = db
        .conn
        .query_row(
            "SELECT r.id, r.in_room FROM meeting_diarization d JOIN diarization_runs r ON r.id=d.accepted_run_id
             JOIN meeting_transcriptions t ON t.meeting_id=d.meeting_id AND t.pass_id=r.transcript_pass_id WHERE d.meeting_id=?1",
            [meeting_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let Some((run, in_room)) = accepted else { return Ok(None) };
    let mut s = db.conn.prepare(
        "SELECT id, source, label_ordinal, display_name, merged_into FROM meeting_speakers WHERE run_id=?1 OR (run_id IS NULL AND meeting_id=?2)
         ORDER BY color_index, run_id IS NULL, label_ordinal LIMIT 512",
    )?;
    let speakers = s
        .query_map(params![run, meeting_id], |r| {
            let source: String = r.get(1)?;
            let name: Option<String> = r.get(3)?;
            Ok(SpeakerRef { id: r.get(0)?, label: speaker_label(&source, r.get(2)?, name.as_deref(), in_room), merged_into: r.get(4)? })
        })?
        .collect::<Result<_, _>>()?;
    Ok(Some((run, speakers)))
}

/// Copy text: plain lines, or `Label:` blocks separated by a blank line.
pub struct TextFormatter {
    labeled: bool,
    started: bool,
    current: Option<String>,
}
impl TextFormatter {
    pub fn new(labeled: bool) -> Self {
        TextFormatter { labeled, started: false, current: None }
    }
    pub fn piece(&mut self, text: &str, label: Option<&str>) -> String {
        let started = std::mem::replace(&mut self.started, true);
        if !self.labeled {
            return if started { format!("\n{text}") } else { text.to_string() };
        }
        let label = label.unwrap_or("Unknown");
        if started && self.current.as_deref() == Some(label) {
            return format!("\n{text}");
        }
        self.current = Some(label.to_string());
        format!("{}{label}:\n{text}", if started { "\n\n" } else { "" })
    }
}
pub fn finality_for(row: Option<&Transcription>) -> &'static str {
    match row {
        None => "final",
        Some(t) => match t.state.as_str() {
            "final" => "final",
            "failed" | "interrupted" if t.pass_kind.as_deref() == Some("final") => "final",
            _ => "provisional",
        },
    }
}

/// `TranscriptPager`: 200 rows a page, two pages resident, labels read with their page.
#[derive(Default)]
pub struct Pager {
    pub meeting_id: String,
    pub row: Option<Transcription>,
    pub finality: String,
    pub pages: Vec<Vec<TranscriptRow>>,
    pub notice: Option<String>,
    pub selection: HashSet<String>,
    pub speakers: Option<(String, Vec<SpeakerRef>)>,
    pub highlighted: Option<String>,
    pub final_pass_count: i64,
    last_full: bool,
    pub search_hits: Option<(Vec<(i64, String)>, bool)>,
    pub current_match: Option<usize>,
    pub is_searching: bool,
}
impl Pager {
    pub fn new(meeting_id: &str) -> Self {
        Pager { meeting_id: meeting_id.into(), finality: "final".into(), ..Default::default() }
    }
    pub fn rows(&self) -> impl Iterator<Item = &TranscriptRow> {
        self.pages.iter().flatten()
    }
    pub fn count(&self) -> i64 {
        self.row.as_ref().map_or(0, |r| r.segment_count)
    }
    pub fn has_previous(&self) -> bool {
        self.pages.first().and_then(|p| p.first()).is_some_and(|r| r.ordinal > 0)
    }
    pub fn has_next(&self) -> bool {
        self.last_full
    }
    pub fn previewing_final_pass(&self) -> bool {
        self.row.as_ref().is_some_and(|r| r.state == "finalizing") && self.final_pass_count > 0
    }
    fn refresh_row(&mut self, db: &Db) {
        match transcription(db, &self.meeting_id) {
            Ok(r) => {
                self.row = r;
                self.notice = None;
            }
            Err(_) => self.notice = Some("The transcript could not be loaded.".into()),
        }
        self.final_pass_count = 0;
        if let Some(Transcription { state, pass_id: Some(pass), .. }) = &self.row {
            if state == "finalizing" {
                self.final_pass_count = db
                    .conn
                    .query_row("SELECT count(*) FROM transcript_segments WHERE meeting_id=?1 AND pass_id=?2", params![self.meeting_id, pass], |r| r.get(0))
                    .unwrap_or(0);
            }
        }
        self.finality = if self.previewing_final_pass() { "final".into() } else { finality_for(self.row.as_ref()).into() };
        self.speakers = if self.finality == "final" && !self.previewing_final_pass() { accepted_speakers(db, &self.meeting_id).ok().flatten() } else { None };
    }
    fn fetch(&mut self, db: &Db, after: i64, limit: usize) -> Option<Vec<TranscriptRow>> {
        match labeled_page(db, &self.meeting_id, &self.finality, Some(after), limit) {
            Ok(mut rows) => {
                self.notice = None;
                let run = self.speakers.as_ref().map(|s| s.0.clone());
                for r in &mut rows {
                    if r.run_id.is_none() || r.run_id != run {
                        r.label = None;
                    }
                }
                Some(rows)
            }
            Err(_) => {
                self.notice = Some("The transcript could not be loaded.".into());
                None
            }
        }
    }
    pub fn load_first(&mut self, db: &Db) {
        self.refresh_row(db);
        self.pages.clear();
        self.selection.clear();
        self.last_full = false;
        let start = if self.previewing_final_pass() { (self.final_pass_count - TRANSCRIPT_PAGE as i64).max(0) } else { 0 };
        if let Some(page) = self.fetch(db, start - 1, TRANSCRIPT_PAGE) {
            self.last_full = !self.previewing_final_pass() && page.len() == TRANSCRIPT_PAGE;
            if !page.is_empty() {
                self.pages = vec![page];
            }
        }
    }
    /// The 5-second poll during a final pass.
    pub fn refresh_finalizing(&mut self, db: &Db) {
        let before = (self.row.as_ref().map(|r| r.state.clone()), self.finality.clone(), self.final_pass_count);
        self.refresh_row(db);
        if before != (self.row.as_ref().map(|r| r.state.clone()), self.finality.clone(), self.final_pass_count) {
            self.load_first(db);
        }
    }
    fn evict(&mut self, keep_end: bool) {
        while self.pages.len() > 2 {
            let removed = if keep_end { self.pages.remove(0) } else { self.pages.pop().unwrap() };
            for r in removed {
                self.selection.remove(&r.id);
            }
        }
    }
    pub fn load_next(&mut self, db: &Db) {
        let Some(last) = self.pages.last().and_then(|p| p.last()).map(|r| r.ordinal) else { return };
        if !self.last_full {
            return;
        }
        match self.fetch(db, last, TRANSCRIPT_PAGE) {
            Some(page) if !page.is_empty() => {
                self.last_full = page.len() == TRANSCRIPT_PAGE;
                self.pages.push(page);
                self.evict(true);
            }
            _ => self.last_full = false,
        }
    }
    pub fn load_previous(&mut self, db: &Db) {
        let Some(first) = self.pages.first().and_then(|p| p.first()).map(|r| r.ordinal) else { return };
        if first <= 0 {
            return;
        }
        let start = (first - TRANSCRIPT_PAGE as i64).max(0);
        if let Some(page) = self.fetch(db, start - 1, (first - start) as usize) {
            if !page.is_empty() {
                self.pages.insert(0, page);
                self.evict(false);
                self.last_full = self.pages.last().map_or(0, |p| p.len()) == TRANSCRIPT_PAGE;
            }
        }
    }
    fn load_at(&mut self, db: &Db, ordinal: i64, segment: &str) {
        if let Some(page) = self.fetch(db, ordinal - 1, TRANSCRIPT_PAGE) {
            if !page.is_empty() {
                self.last_full = page.len() == TRANSCRIPT_PAGE;
                self.highlighted = page.iter().any(|r| r.id == segment).then(|| segment.to_string());
                self.pages = vec![page];
                self.selection.clear();
            }
        }
    }
    pub fn reveal(&mut self, db: &Db, segment: &str) {
        if self.finality != "final" {
            return;
        }
        if self.rows().any(|r| r.id == segment) {
            self.highlighted = Some(segment.to_string());
            return;
        }
        let ordinal: Option<i64> = db.conn.query_row("SELECT ordinal FROM transcript_segments WHERE id=?1 AND meeting_id=?2", params![segment, self.meeting_id], |r| r.get(0)).optional().ok().flatten();
        if let Some(o) = ordinal {
            self.load_at(db, o, segment);
        }
    }
    pub fn refresh_labels(&mut self, db: &Db) {
        self.refresh_row(db);
        for i in 0..self.pages.len() {
            let Some(first) = self.pages[i].first().map(|r| r.ordinal) else { continue };
            let len = self.pages[i].len();
            if let Some(fresh) = self.fetch(db, first - 1, len) {
                self.pages[i] = fresh;
            }
        }
    }
    /// A row shows its label when it starts a group: the same root, kind or audio source.
    pub fn starts_group(index: usize, rows: &[&TranscriptRow]) -> bool {
        if index == 0 {
            return true;
        }
        let (cur, prev) = (rows[index].label.as_ref(), rows[index - 1].label.as_ref());
        if cur.is_none() && prev.is_none() {
            return rows[index - 1].tracks != rows[index].tracks;
        }
        cur.map(|l| &l.kind) != prev.map(|l| &l.kind)
    }
    pub fn toggle_selection(&mut self, id: &str) {
        if !self.selection.remove(id) {
            self.selection.insert(id.to_string());
        }
    }
    pub fn selection_text(&self) -> String {
        let mut f = TextFormatter::new(self.speakers.is_some());
        self.rows().filter(|r| self.selection.contains(&r.id)).map(|r| f.piece(&r.text, r.label.as_ref().map(|l| l.text.as_str()))).collect()
    }
    pub fn matches(row: &TranscriptRow, query: &str) -> bool {
        query.is_empty() || contains(&row.text, query) || row.label.as_ref().is_some_and(|l| contains(&l.text, query))
    }
    fn walk(&self, db: &Db, mut visit: impl FnMut(&TranscriptRow) -> bool) -> Res<()> {
        let run = self.speakers.as_ref().map(|s| s.0.clone());
        let mut after = -1;
        loop {
            let mut rows = labeled_page(db, &self.meeting_id, &self.finality, Some(after), TRANSCRIPT_PAGE)?;
            let n = rows.len();
            for r in &mut rows {
                if r.run_id.is_none() || r.run_id != run {
                    r.label = None;
                }
                if !visit(r) {
                    return Ok(());
                }
                after = r.ordinal;
            }
            if n < TRANSCRIPT_PAGE {
                return Ok(());
            }
        }
    }
    pub fn search(&mut self, db: &Db, query: &str) {
        self.current_match = None;
        self.is_searching = false;
        if query.is_empty() {
            self.search_hits = None;
            return;
        }
        let mut hits = vec![];
        let mut truncated = false;
        let walked = self.walk(db, |r| {
            if !Self::matches(r, query) {
                return true;
            }
            if hits.len() >= SEARCH_LIMIT {
                truncated = true;
                return false;
            }
            hits.push((r.ordinal, r.id.clone()));
            true
        });
        match walked {
            Ok(()) => self.search_hits = Some((hits, truncated)),
            Err(_) => {
                self.notice = Some("The transcript could not be searched.".into());
                self.search_hits = None;
            }
        }
    }
    pub fn show_match(&mut self, db: &Db, forward: bool) {
        let Some((hits, _)) = self.search_hits.clone() else { return };
        if hits.is_empty() {
            return;
        }
        let n = hits.len();
        let index = match self.current_match {
            Some(c) => (c + if forward { 1 } else { n - 1 }) % n,
            None => {
                let top = self.pages.first().and_then(|p| p.first()).map_or(0, |r| r.ordinal);
                if forward { hits.iter().position(|h| h.0 >= top).unwrap_or(0) } else { hits.iter().rposition(|h| h.0 < top).unwrap_or(n - 1) }
            }
        };
        self.current_match = Some(index);
        let (ordinal, id) = &hits[index];
        if self.rows().any(|r| &r.id == id) {
            self.highlighted = Some(id.clone());
        } else {
            self.load_at(db, *ordinal, id);
        }
    }
    /// "Searching…", "No matches", "41 matches" or "3 of 41".
    pub fn match_count_text(&self) -> String {
        if self.is_searching {
            return "Searching…".into();
        }
        let Some((hits, truncated)) = &self.search_hits else { return String::new() };
        if hits.is_empty() {
            return "No matches".into();
        }
        let total = format!("{}{}", group_digits(hits.len()), if *truncated { "+" } else { "" });
        if let Some(i) = self.current_match {
            return format!("{} of {total}", group_digits(i + 1));
        }
        if hits.len() == 1 && !truncated { "1 match".into() } else { format!("{total} matches") }
    }
    pub fn no_resident_match_text(&self) -> &'static str {
        if self.is_searching {
            return "Searching the whole transcript…";
        }
        match &self.search_hits {
            Some((hits, _)) if !hits.is_empty() => "No matches in this part of the transcript. Use the arrows to go to the others.",
            _ => "No matches.",
        }
    }
    /// The whole transcript; Err(None) past 20 MiB, Err(Some) on a read failure.
    pub fn full_text(&self, db: &Db) -> Result<String, Option<MeetingError>> {
        let mut f = TextFormatter::new(self.speakers.is_some());
        let mut out = String::new();
        let mut too_long = false;
        self.walk(db, |r| {
            out.push_str(&f.piece(&r.text, r.label.as_ref().map(|l| l.text.as_str())));
            too_long = out.len() > FULL_TEXT_LIMIT;
            !too_long
        })
        .map_err(Some)?;
        if too_long { Err(None) } else { Ok(out) }
    }
    /// Writes in 64 KiB chunks; a failed export leaves no file.
    pub fn export(&self, db: &Db, path: &Path) -> std::io::Result<()> {
        use std::io::Write;
        let result = (|| {
            let mut file = std::fs::File::create(path)?;
            let mut f = TextFormatter::new(self.speakers.is_some());
            let mut buf = String::new();
            let mut io_err = None;
            self.walk(db, |r| {
                buf.push_str(&f.piece(&r.text, r.label.as_ref().map(|l| l.text.as_str())));
                if buf.len() >= 64 * 1024 {
                    if let Err(e) = file.write_all(buf.as_bytes()) {
                        io_err = Some(e);
                        return false;
                    }
                    buf.clear();
                }
                true
            })
            .map_err(|_| std::io::Error::other("read failed"))?;
            if let Some(e) = io_err {
                return Err(e);
            }
            file.write_all(buf.as_bytes())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(path);
        }
        result
    }
}
fn group_digits(n: usize) -> String {
    if n >= 1000 { format!("{},{:03}", n / 1000, n % 1000) } else { n.to_string() }
}
/// Places "Microphone changed" dividers before the first row at or after each switch.
pub fn microphone_dividers(switches: &[&Segment], rows: &[&TranscriptRow]) -> (HashMap<String, Vec<Option<String>>>, Vec<Option<String>>) {
    let mut before: HashMap<String, Vec<Option<String>>> = HashMap::new();
    let mut trailing = vec![];
    for s in switches {
        match rows.iter().find(|r| r.start_ms >= s.start_offset_ms) {
            Some(r) => before.entry(r.id.clone()).or_default().push(s.input_device_name.clone()),
            None => trailing.push(s.input_device_name.clone()),
        }
    }
    (before, trailing)
}

// MARK: speakers

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Identity {
    pub state: String,
    pub origin: String,
    pub known_id: Option<String>,
    pub known_name: Option<String>,
    pub second: Option<(String, String)>,
    pub needs_choice: bool,
    pub sample_offer: bool,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Merged {
    pub id: String,
    pub label: String,
}
#[derive(Clone, Debug, PartialEq)]
pub struct SpeakerSummary {
    pub id: String,
    pub source: String,
    pub ordinal: i64,
    pub color: usize,
    pub name: Option<String>,
    pub in_room: bool,
    pub quotes: Vec<String>,
    pub includes: Vec<Merged>,
    pub identity: Option<Identity>,
}
impl SpeakerSummary {
    pub fn is_you(&self) -> bool {
        self.source == "local" && !self.in_room
    }
    pub fn anonymous(&self) -> String {
        speaker_label(&self.source, self.ordinal, None, self.in_room)
    }
    pub fn label(&self) -> String {
        speaker_label(&self.source, self.ordinal, self.name.as_deref(), self.in_room)
    }
}
fn accepted_run(c: &Connection, meeting_id: &str) -> Res<Option<(String, bool)>> {
    Ok(c.query_row(
        "SELECT r.id, r.in_room FROM meeting_diarization d JOIN diarization_runs r ON r.id=d.accepted_run_id WHERE d.meeting_id=?1",
        [meeting_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()?)
}
type IdRow = (String, String, Option<String>, Option<String>);
fn is_linked(r: &IdRow) -> bool {
    r.2.is_some() && (r.0 == "recognized" || r.0 == "confirmed")
}
/// `SpeakerIdentityQuery.identities` with `MergedIdentityRule`, per display root.
pub fn identities(db: &Db, meeting_id: &str) -> Res<HashMap<String, Identity>> {
    let mut result = HashMap::new();
    let Some((run, _)) = accepted_run(&db.conn, meeting_id)? else { return Ok(result) };
    let mut s = db.conn.prepare_cached("SELECT id, merged_into FROM meeting_speakers WHERE (run_id=?1 AND speech_ms>0) OR (run_id IS NULL AND meeting_id=?2)")?;
    let speakers: Vec<(String, Option<String>)> = s.query_map(params![run, meeting_id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
    let mut s = db.conn.prepare_cached(
        "SELECT a.meeting_speaker_id, a.scope, a.state, a.origin, a.known_speaker_id, k.display_name, a.second_known_speaker_id, n.display_name
         FROM identity_assignments a LEFT JOIN known_speakers k ON k.id=a.known_speaker_id LEFT JOIN known_speakers n ON n.id=a.second_known_speaker_id WHERE a.meeting_id=?1",
    )?;
    let mut own: HashMap<String, (IdRow, Option<(String, String)>)> = HashMap::new();
    let mut resolved: HashMap<String, IdRow> = HashMap::new();
    let rows: Vec<_> = s
        .query_map([meeting_id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                (r.get::<_, String>(2)?, r.get::<_, String>(3)?, r.get::<_, Option<String>>(4)?, r.get::<_, Option<String>>(5)?),
                r.get::<_, Option<String>>(6)?,
                r.get::<_, Option<String>>(7)?,
            ))
        })?
        .collect::<Result<_, _>>()?;
    for (speaker, scope, row, second, second_name) in rows {
        if scope == "merged" {
            resolved.insert(speaker, row);
        } else {
            own.insert(speaker, (row, second.zip(second_name)));
        }
    }
    for (root, target) in &speakers {
        if target.is_some() {
            continue;
        }
        let members: Vec<&String> = speakers.iter().filter(|(_, t)| t.as_ref() == Some(root)).map(|(id, _)| id).collect();
        let root_row = own.get(root).map(|o| o.0.clone());
        let (row, needs_choice): (Option<IdRow>, bool) = if let Some(r) = resolved.get(root) {
            (Some(r.clone()), false)
        } else if members.is_empty() {
            (root_row.clone(), false)
        } else {
            let mut all: Vec<IdRow> = root_row.iter().cloned().collect();
            all.extend(members.iter().filter_map(|m| own.get(*m).map(|o| o.0.clone())));
            let linked: Vec<&IdRow> = all.iter().filter(|r| is_linked(r)).collect();
            let distinct: HashSet<&Option<String>> = linked.iter().map(|r| &r.2).collect();
            if all.iter().any(|r| r.0 == "possible") || distinct.len() > 1 {
                (Some(("unknown".into(), "kept_unknown".into(), None, None)), true)
            } else if distinct.is_empty() {
                (root_row.clone(), false)
            } else {
                (Some(root_row.clone().filter(is_linked).unwrap_or_else(|| linked[0].clone())), false)
            }
        };
        let mut identity = Identity { state: "unknown".into(), origin: "automatic_match".into(), needs_choice, ..Default::default() };
        if let Some((state, origin, known, name)) = row {
            if state == "possible" {
                identity.second = own.get(root).and_then(|o| o.1.clone());
            }
            identity.state = state;
            identity.origin = origin;
            identity.known_id = known;
            identity.known_name = name;
        }
        let mut ids = vec![root.as_str()];
        ids.extend(members.iter().map(|m| m.as_str()));
        identity.sample_offer = ids.iter().any(|id| {
            db.conn
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM speaker_turns WHERE run_id=?1 AND speaker_id=?2 AND overlapped=0 AND end_ms-start_ms>=3400 AND (engine_quality IS NULL OR engine_quality>=0.5))",
                    params![run, id],
                    |r| r.get(0),
                )
                .unwrap_or(false)
        });
        result.insert(root.clone(), identity);
    }
    Ok(result)
}
/// Longest segments, spread over the meeting's thirds; at most three, in transcript order.
fn select_quotes(mut candidates: Vec<(i64, i64, String)>) -> Vec<String> {
    candidates.sort_by_key(|c| (std::cmp::Reverse(c.2.chars().count()), c.0));
    let long: Vec<&(i64, i64, String)> = candidates.iter().filter(|c| c.2.split_whitespace().count() >= 4).collect();
    let mut chosen: Vec<(i64, i64, String)> = if long.is_empty() {
        candidates.iter().take(3).cloned().collect()
    } else {
        let mut c: Vec<_> = (0..3).filter_map(|t| long.iter().find(|x| x.1 == t).map(|x| (*x).clone())).collect();
        for x in &long {
            if c.len() < 3 && !c.contains(x) {
                c.push((*x).clone());
            }
        }
        c
    };
    chosen.sort_by_key(|c| c.0);
    chosen.into_iter().map(|c| c.2).collect()
}
pub fn speaker_summaries(db: &Db, meeting_id: &str) -> Res<Vec<SpeakerSummary>> {
    let Some((run, in_room)) = accepted_run(&db.conn, meeting_id)? else { return Ok(vec![]) };
    let mut s = db.conn.prepare(
        "SELECT id, source, label_ordinal, color_index, display_name, merged_into FROM meeting_speakers
         WHERE (run_id=?1 AND speech_ms>0) OR (run_id IS NULL AND meeting_id=?2)
         ORDER BY color_index, run_id IS NULL, first_ms, cluster_key LIMIT 512",
    )?;
    let rows: Vec<(String, String, i64, i64, Option<String>, Option<String>)> =
        s.query_map(params![run, meeting_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)))?.collect::<Result<_, _>>()?;
    let mut summaries = vec![];
    let mut members: HashMap<String, Vec<(String, i64, String)>> = HashMap::new();
    for (id, source, ordinal, color, name, merged) in rows {
        if let Some(target) = merged {
            members.entry(target).or_default().push((source, ordinal, id));
        } else {
            summaries.push(SpeakerSummary { id, source, ordinal, color: color as usize, name, in_room, quotes: vec![], includes: vec![], identity: None });
        }
    }
    let mut q = db.conn.prepare(
        "WITH effective AS (
           SELECT t.ordinal, t.start_ms, t.normalized_text AS text, COALESCE(e.merged_into, e.id) AS root
           FROM speaker_assignments a JOIN transcript_segments t ON t.id=a.segment_id
           JOIN meeting_speakers e ON e.id=CASE WHEN a.manual_kind IS NOT NULL THEN a.manual_speaker_id ELSE a.auto_speaker_id END
           WHERE a.run_id=?1 AND COALESCE(a.manual_kind, a.auto_kind)='speaker'
         ), span AS (
           SELECT MAX(1, MAX(t.end_ms)) AS total FROM transcript_segments t JOIN diarization_runs r ON r.id=?1 AND t.pass_id=r.transcript_pass_id
         ), ranked AS (
           SELECT root, ordinal, text, MIN(2, start_ms * 3 / span.total) AS third FROM effective, span
         ), numbered AS (
           SELECT *, ROW_NUMBER() OVER (PARTITION BY root, third ORDER BY length(text) DESC, ordinal) AS rank FROM ranked
         )
         SELECT root, ordinal, third, text FROM numbered WHERE rank<=10 ORDER BY root, third, rank",
    )?;
    let mut candidates: HashMap<String, Vec<(i64, i64, String)>> = HashMap::new();
    for row in q.query_map([&run], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, String>(3)?)))? {
        let (root, ordinal, third, text) = row?;
        candidates.entry(root).or_default().push((ordinal, third, text));
    }
    let ids = identities(db, meeting_id)?;
    for s in &mut summaries {
        s.quotes = select_quotes(candidates.remove(&s.id).unwrap_or_default());
        let mut m = members.remove(&s.id).unwrap_or_default();
        m.sort();
        s.includes = m.into_iter().map(|(source, ordinal, id)| Merged { label: speaker_label(&source, ordinal, None, in_room), id }).collect();
        s.identity = ids.get(&s.id).cloned();
    }
    Ok(summaries)
}
/// Err when a name can't be saved; Ok(None) for a blank one.
pub fn validate_name(raw: &str) -> Result<Option<String>, &'static str> {
    let name = raw.trim();
    if name.is_empty() {
        return Ok(None);
    }
    if name.chars().any(char::is_control) {
        return Err("Remove the control character.");
    }
    if name.chars().count() > NAME_MAX {
        return Err("Use 80 characters or fewer.");
    }
    Ok(Some(name.to_string()))
}
fn reserve_corrections(c: &Connection, count: i64, meeting_id: &str) -> Res<()> {
    let existing: i64 = c.query_row("SELECT count(*) FROM speaker_corrections WHERE meeting_id=?1", [meeting_id], |r| r.get(0))?;
    if existing + count > CORRECTIONS_PER_MEETING { Err(MeetingError::CorrectionCapacity) } else { Ok(()) }
}
#[allow(clippy::too_many_arguments)]
fn insert_correction(c: &Connection, meeting: &str, run: &str, kind: &str, speaker: Option<&str>, target: Option<&str>, segment: Option<&str>, previous: Option<&str>, new: Option<&str>, now: i64) -> Res<()> {
    c.execute(
        "INSERT INTO speaker_corrections (id, meeting_id, run_id, kind, speaker_id, target_speaker_id, segment_id, previous_value, new_value, needs_review, created_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,0,?10)",
        params![new_id(), meeting, run, kind, speaker, target, segment, previous, new, now],
    )?;
    Ok(())
}
fn speaker_row(c: &Connection, id: &str, run: &str, meeting: &str) -> Res<(Option<String>, Option<String>)> {
    c.query_row(
        "SELECT display_name, merged_into FROM meeting_speakers WHERE id=?1 AND (run_id=?2 OR (run_id IS NULL AND meeting_id=?3))",
        params![id, run, meeting],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()?
    .ok_or(MeetingError::Missing)
}
/// Every name in one transaction, one `rename` correction per change.
pub fn save_names(db: &Db, meeting: &str, names: &[(String, Option<String>)], now: i64) -> Res<usize> {
    let tx = db.conn.unchecked_transaction()?;
    let (run, _) = accepted_run(&tx, meeting)?.ok_or(MeetingError::Missing)?;
    let mut changes = vec![];
    for (id, name) in names {
        let (previous, _) = speaker_row(&tx, id, &run, meeting)?;
        if previous != *name {
            changes.push((id, previous, name));
        }
    }
    if changes.is_empty() {
        return Ok(0);
    }
    reserve_corrections(&tx, changes.len() as i64, meeting)?;
    for (id, previous, name) in &changes {
        tx.execute("UPDATE meeting_speakers SET display_name=?1 WHERE id=?2", params![name, id])?;
        insert_correction(&tx, meeting, &run, "rename", Some(id), None, None, previous.as_deref(), name.as_deref(), now)?;
    }
    tx.commit()?;
    Ok(changes.len())
}
pub fn merge(db: &Db, meeting: &str, speaker: &str, target: &str, now: i64) -> Res<usize> {
    let tx = db.conn.unchecked_transaction()?;
    let (run, _) = accepted_run(&tx, meeting)?.ok_or(MeetingError::Missing)?;
    let (_, source_merged) = speaker_row(&tx, speaker, &run, meeting)?;
    let (_, target_merged) = speaker_row(&tx, target, &run, meeting)?;
    let root = target_merged.unwrap_or_else(|| target.to_string());
    if root == speaker {
        return Err(MeetingError::Invalid);
    }
    let mut moved = vec![speaker.to_string()];
    let mut s = tx.prepare("SELECT id FROM meeting_speakers WHERE merged_into=?1 ORDER BY rowid")?;
    moved.extend(s.query_map([speaker], |r| r.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?);
    drop(s);
    if source_merged.as_deref() == Some(&root) && moved.len() == 1 {
        return Ok(0);
    }
    reserve_corrections(&tx, moved.len() as i64, meeting)?;
    for id in &moved {
        tx.execute("UPDATE meeting_speakers SET merged_into=?1 WHERE id=?2", params![root, id])?;
        insert_correction(&tx, meeting, &run, "merge", Some(id), Some(&root), None, None, None, now)?;
    }
    tx.commit()?;
    Ok(moved.len())
}
pub fn unmerge(db: &Db, meeting: &str, speaker: &str, now: i64) -> Res<()> {
    let tx = db.conn.unchecked_transaction()?;
    let (run, _) = accepted_run(&tx, meeting)?.ok_or(MeetingError::Missing)?;
    let (_, merged) = speaker_row(&tx, speaker, &run, meeting)?;
    let target = merged.ok_or(MeetingError::Invalid)?;
    reserve_corrections(&tx, 1, meeting)?;
    tx.execute("UPDATE meeting_speakers SET merged_into=NULL WHERE id=?1", [speaker])?;
    tx.execute("DELETE FROM identity_assignments WHERE meeting_speaker_id=?1 AND scope='merged'", [&target])?;
    tx.execute(
        "UPDATE speaker_corrections SET undone_at=?1 WHERE id=(SELECT id FROM speaker_corrections WHERE meeting_id=?2 AND kind='merge' AND speaker_id=?3
           AND undone_at IS NULL ORDER BY created_at DESC, rowid DESC LIMIT 1)",
        params![now, meeting, speaker],
    )?;
    insert_correction(&tx, meeting, &run, "unmerge", Some(speaker), Some(&target), None, None, None, now)?;
    tx.commit()?;
    Ok(())
}
#[derive(Clone, Debug, PartialEq)]
pub enum Correction {
    Speaker(String),
    Unknown,
    New,
}
/// Sets the row's `manual_*` columns; the automatic assignment stays.
pub fn correct_segment(db: &Db, meeting: &str, segment: &str, to: &Correction, now: i64) -> Res<Option<String>> {
    let tx = db.conn.unchecked_transaction()?;
    let (run, _) = accepted_run(&tx, meeting)?.ok_or(MeetingError::Missing)?;
    let (auto_kind, auto_speaker, manual_kind, manual_speaker, start_ms): (String, Option<String>, Option<String>, Option<String>, i64) = tx
        .query_row(
            "SELECT a.auto_kind, a.auto_speaker_id, a.manual_kind, a.manual_speaker_id, s.start_ms FROM speaker_assignments a JOIN transcript_segments s ON s.id=a.segment_id WHERE a.run_id=?1 AND a.segment_id=?2",
            params![run, segment],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()?
        .ok_or(MeetingError::Missing)?;
    reserve_corrections(&tx, 1, meeting)?;
    let speaker = match to {
        Correction::Speaker(id) => {
            speaker_row(&tx, id, &run, meeting)?;
            Some(id.clone())
        }
        Correction::Unknown => None,
        Correction::New => {
            let id = new_id();
            let (ordinal, colors, manual): (i64, i64, i64) = tx.query_row(
                "SELECT COALESCE(MAX(CASE WHEN source='remote' THEN label_ordinal END),0)+1, COUNT(*), COALESCE(SUM(run_id IS NULL),0) FROM meeting_speakers WHERE run_id=?1 OR (run_id IS NULL AND meeting_id=?2)",
                params![run, meeting],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?;
            tx.execute(
                "INSERT INTO meeting_speakers (id, meeting_id, run_id, cluster_key, source, track, origin, label_ordinal, color_index, first_ms) VALUES (?1,?2,NULL,?3,'remote',NULL,'manual',?4,?5,?6)",
                params![id, meeting, manual, ordinal, colors % 8, start_ms],
            )?;
            Some(id)
        }
    };
    let previous_kind = manual_kind.clone().unwrap_or(auto_kind);
    let previous_speaker = if manual_kind.is_none() { auto_speaker } else { manual_speaker };
    tx.execute(
        "UPDATE speaker_assignments SET manual_kind=?1, manual_speaker_id=?2, manual_at=?3 WHERE run_id=?4 AND segment_id=?5",
        params![if speaker.is_none() { "unknown" } else { "speaker" }, speaker, now, run, segment],
    )?;
    insert_correction(
        &tx,
        meeting,
        &run,
        "segment",
        previous_speaker.as_deref(),
        speaker.as_deref(),
        Some(segment),
        (previous_kind != "speaker").then_some(previous_kind.as_str()),
        speaker.is_none().then_some("unknown"),
        now,
    )?;
    tx.commit()?;
    Ok(speaker)
}
pub fn review_notices(db: &Db, meeting: &str) -> Res<Vec<(String, String)>> {
    let mut s = db.conn.prepare("SELECT id, COALESCE(new_value,'') FROM speaker_corrections WHERE meeting_id=?1 AND needs_review=1 ORDER BY created_at, rowid LIMIT 256")?;
    let rows = s.query_map([meeting], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
    Ok(rows)
}
pub fn dismiss_review(db: &Db, id: &str) -> Res<()> {
    db.conn.execute("UPDATE speaker_corrections SET needs_review=0 WHERE id=?1", [id])?;
    Ok(())
}
pub fn name_suggestions(db: &Db, prefix: &str, limit: usize) -> Res<Vec<String>> {
    let pattern = format!("{}%", prefix.trim().replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
    let mut s = db.conn.prepare(
        "SELECT s.display_name FROM meeting_speakers s LEFT JOIN speaker_corrections c ON c.speaker_id=s.id AND c.kind='rename'
         WHERE s.display_name LIKE ?1 ESCAPE '\\' GROUP BY s.display_name ORDER BY MAX(COALESCE(c.created_at, 0)) DESC, s.display_name LIMIT ?2",
    )?;
    let rows = s.query_map(params![pattern, limit.min(8) as i64], |r| r.get(0))?.collect::<Result<_, _>>()?;
    Ok(rows)
}
#[derive(Clone, Debug, PartialEq)]
pub struct KnownSpeaker {
    pub id: String,
    pub name: String,
    pub samples: i64,
    pub is_local: bool,
}
pub fn known_speakers(db: &Db) -> Res<Vec<KnownSpeaker>> {
    let mut s = db.conn.prepare(
        "SELECT k.id, k.display_name, k.is_local_user, (SELECT count(*) FROM voice_samples v WHERE v.known_speaker_id=k.id AND v.active=1) FROM known_speakers k ORDER BY k.display_name, k.created_at, k.id",
    )?;
    let rows = s.query_map([], |r| Ok(KnownSpeaker { id: r.get(0)?, name: r.get(1)?, is_local: r.get(2)?, samples: r.get(3)? }))?.collect::<Result<_, _>>()?;
    Ok(rows)
}
fn upsert_manual(c: &Connection, meeting: &str, speaker: &str, scope: &str, state: &str, origin: &str, known: Option<&str>, corrected: Option<i64>, now: i64) -> Res<()> {
    let exists: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM meeting_speakers WHERE id=?1 AND meeting_id=?2)", params![speaker, meeting], |r| r.get(0))?;
    if !exists {
        return Err(MeetingError::Missing);
    }
    let confirmed = (state == "confirmed").then_some(now);
    c.execute(
        "INSERT INTO identity_assignments (id, meeting_id, meeting_speaker_id, scope, known_speaker_id, state, origin, confirmed_at, corrected_at, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10)
         ON CONFLICT(meeting_speaker_id, scope) DO UPDATE SET known_speaker_id=excluded.known_speaker_id, state=excluded.state, origin=excluded.origin, run_id=NULL, score=NULL,
           engine=NULL, model_id=NULL, model_revision=NULL, threshold_policy=NULL, second_known_speaker_id=NULL, confirmed_at=excluded.confirmed_at,
           corrected_at=COALESCE(excluded.corrected_at, corrected_at), updated_at=excluded.updated_at",
        params![new_id(), meeting, speaker, scope, known, state, origin, confirmed, corrected, now],
    )?;
    Ok(())
}
fn insert_rejection(c: &Connection, meeting: &str, speaker: &str, candidate: &str, now: i64) -> Res<()> {
    let existing: i64 = c.query_row("SELECT count(*) FROM rejected_candidates r JOIN meeting_speakers s ON s.id=r.meeting_speaker_id WHERE s.meeting_id=?1", [meeting], |r| r.get(0))?;
    let present: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM rejected_candidates WHERE meeting_speaker_id=?1 AND known_speaker_id=?2)", params![speaker, candidate], |r| r.get(0))?;
    if !present && existing >= REJECTED_PER_MEETING {
        return Err(MeetingError::RejectCapacity);
    }
    c.execute("INSERT OR IGNORE INTO rejected_candidates (meeting_speaker_id, known_speaker_id, rejected_at) VALUES (?1,?2,?3)", params![speaker, candidate, now])?;
    Ok(())
}
fn copy_name(c: &Connection, name: &str, speaker: &str, meeting: &str, now: i64) -> Res<()> {
    let previous: Option<String> = c.query_row("SELECT display_name FROM meeting_speakers WHERE id=?1", [speaker], |r| r.get(0)).optional()?.ok_or(MeetingError::Missing)?;
    if previous.as_deref() == Some(name) {
        return Ok(());
    }
    c.execute("UPDATE meeting_speakers SET display_name=?1 WHERE id=?2", params![name, speaker])?;
    if let Some((run, _)) = accepted_run(c, meeting)? {
        reserve_corrections(c, 1, meeting)?;
        insert_correction(c, meeting, &run, "rename", Some(speaker), None, None, previous.as_deref(), Some(name), now)?;
    }
    Ok(())
}
pub fn link(db: &Db, meeting: &str, speaker: &str, known: &str, origin: &str, now: i64) -> Res<()> {
    let tx = db.conn.unchecked_transaction()?;
    let name: String = tx.query_row("SELECT display_name FROM known_speakers WHERE id=?1", [known], |r| r.get(0)).optional()?.ok_or(MeetingError::Missing)?;
    let previous: Option<Option<String>> = tx.query_row("SELECT known_speaker_id FROM identity_assignments WHERE meeting_speaker_id=?1 AND scope='self'", [speaker], |r| r.get(0)).optional()?;
    let mut corrected = None;
    if let (true, Some(Some(p))) = (origin == "manual_correction", &previous) {
        if p != known {
            insert_rejection(&tx, meeting, speaker, p, now)?;
            corrected = Some(now);
        }
    }
    upsert_manual(&tx, meeting, speaker, "self", "confirmed", origin, Some(known), corrected, now)?;
    copy_name(&tx, &name, speaker, meeting, now)?;
    tx.commit()?;
    Ok(())
}
pub fn reject(db: &Db, meeting: &str, speaker: &str, candidate: &str, keep_unknown: bool, now: i64) -> Res<()> {
    let tx = db.conn.unchecked_transaction()?;
    insert_rejection(&tx, meeting, speaker, candidate, now)?;
    if keep_unknown {
        upsert_manual(&tx, meeting, speaker, "self", "rejected_unknown", "kept_unknown", None, None, now)?;
    }
    tx.commit()?;
    Ok(())
}
pub fn unlink(db: &Db, meeting: &str, speaker: &str, now: i64) -> Res<()> {
    upsert_manual(&db.conn, meeting, speaker, "self", "unknown", "kept_unknown", None, None, now)
}
/// `known` None keeps the root Unknown.
pub fn resolve_merged(db: &Db, meeting: &str, root: &str, known: Option<&str>, now: i64) -> Res<()> {
    let tx = db.conn.unchecked_transaction()?;
    match known {
        Some(k) => {
            let name: String = tx.query_row("SELECT display_name FROM known_speakers WHERE id=?1", [k], |r| r.get(0)).optional()?.ok_or(MeetingError::Missing)?;
            upsert_manual(&tx, meeting, root, "merged", "confirmed", "manual_profile_selection", Some(k), None, now)?;
            copy_name(&tx, &name, root, meeting, now)?;
        }
        None => upsert_manual(&tx, meeting, root, "merged", "rejected_unknown", "kept_unknown", None, None, now)?,
    }
    tx.commit()?;
    Ok(())
}
pub fn meetings_with_unknown_remote_speakers(db: &Db, limit: i64) -> Res<i64> {
    let n = db.conn.query_row(
        "SELECT count(*) FROM (SELECT m.id FROM meetings m JOIN meeting_diarization d ON d.meeting_id=m.id AND d.accepted_run_id IS NOT NULL
         WHERE EXISTS (SELECT 1 FROM meeting_speakers s WHERE s.run_id=d.accepted_run_id AND s.source='remote' AND s.speech_ms>0 AND s.merged_into IS NULL
           AND NOT EXISTS (SELECT 1 FROM identity_assignments a WHERE a.meeting_speaker_id=s.id AND a.scope='merged' AND a.known_speaker_id IS NOT NULL)
           AND NOT EXISTS (SELECT 1 FROM identity_assignments a WHERE a.meeting_speaker_id=s.id AND a.scope='self' AND a.state IN ('recognized','possible','confirmed','rejected_unknown')))
         LIMIT ?1)",
        [limit.min(500)],
        |r| r.get(0),
    )?;
    Ok(n)
}
/// (state, failure category) of the current diarization or identification run.
pub fn run_status(db: &Db, table: &str, pointer: &str, meeting: &str) -> Res<Option<(String, Option<String>)>> {
    let sql = format!("SELECT r.state, r.failure_category FROM {pointer} p JOIN {table} r ON r.id=p.current_run_id WHERE p.meeting_id=?1");
    Ok(db.conn.query_row(&sql, [meeting], |r| Ok((r.get(0)?, r.get(1)?))).optional()?)
}

// MARK: assign speakers model

#[derive(Clone, Debug, PartialEq)]
pub enum IdentityAction {
    None,
    Remember,
    RememberNew,
    SamePerson(String),
    NotNow,
    Pick(String),
    Confirm,
    ChooseAnother(String),
    KeepUnknown,
    /// `Some(known)` or keep unknown.
    ResolveMerged(Option<String>),
    RememberLocal,
}
#[derive(Clone, Debug)]
pub struct Section {
    pub speaker: SpeakerSummary,
    pub draft: String,
    pub action: IdentityAction,
    pub also_remember: bool,
    pub picked_name: Option<String>,
    pub enrollment_result: Option<String>,
}
impl Section {
    pub fn error(&self) -> Option<&'static str> {
        validate_name(&self.draft).err()
    }
    pub fn trimmed(&self) -> Option<String> {
        validate_name(&self.draft).ok().flatten()
    }
    pub fn preview(&self) -> String {
        speaker_label(&self.speaker.source, self.speaker.ordinal, self.trimmed().as_deref(), self.speaker.in_room)
    }
}
#[derive(Clone, Debug, PartialEq, Default)]
pub struct IdentityBlock {
    pub match_state: String,
    pub shows_remember: bool,
    pub duplicate_of: Option<KnownSpeaker>,
    pub shows_suggestion_actions: bool,
    pub shows_also_remember: bool,
    pub needs_choice: bool,
    /// The "You" row: true when the voice is already remembered.
    pub local_remembered: Option<bool>,
    pub picker: Vec<KnownSpeaker>,
}
pub const REMEMBER_SENTENCE: &str = "LocalFlow will store data that can recognize this voice in future meetings on this Mac. It stays on this Mac and you can delete it in Settings › Known speakers.";
pub const REMEMBER_QUESTION: &str = "Remember this voice for future meetings?";

/// `AssignSpeakersModel`. Nothing is written until Save except merges, which apply at once.
pub struct AssignModel {
    pub meeting_id: String,
    pub sections: Vec<Section>,
    pub is_loading: bool,
    pub notice: Option<String>,
    pub suggestions: Vec<String>,
    pub reviews: Vec<(String, String)>,
    pub known: Vec<KnownSpeaker>,
    pub enrollment_completed: bool,
    pub did_change_identities: bool,
    pub shows_identity: bool,
}
impl AssignModel {
    pub fn new(db: &Db, meeting_id: &str, shows_identity: bool) -> Self {
        let mut m = AssignModel {
            meeting_id: meeting_id.into(),
            sections: vec![],
            is_loading: true,
            notice: None,
            suggestions: vec![],
            reviews: vec![],
            known: vec![],
            enrollment_completed: false,
            did_change_identities: false,
            shows_identity,
        };
        m.reload(db);
        m.is_loading = false;
        m
    }
    fn reload(&mut self, db: &Db) {
        let load = || -> Res<_> {
            let summaries = speaker_summaries(db, &self.meeting_id)?;
            let reviews = review_notices(db, &self.meeting_id)?;
            let known = if self.shows_identity { known_speakers(db)? } else { vec![] };
            Ok((summaries, reviews, known))
        };
        match load() {
            Ok((summaries, reviews, known)) => {
                let (you, others): (Vec<_>, Vec<_>) = summaries.into_iter().partition(|s| s.is_you());
                let old = std::mem::take(&mut self.sections);
                self.sections = you
                    .into_iter()
                    .chain(others)
                    .map(|speaker| {
                        let previous = old.iter().find(|o| o.speaker.id == speaker.id);
                        Section {
                            draft: previous.map(|p| p.draft.clone()).unwrap_or_else(|| speaker.name.clone().unwrap_or_default()),
                            action: previous.map_or(IdentityAction::None, |p| p.action.clone()),
                            also_remember: previous.is_some_and(|p| p.also_remember),
                            picked_name: previous.and_then(|p| p.picked_name.clone()),
                            enrollment_result: previous.and_then(|p| p.enrollment_result.clone()),
                            speaker,
                        }
                    })
                    .collect();
                self.reviews = reviews;
                self.known = known;
                self.notice = None;
            }
            Err(_) => self.notice = Some("Speakers could not be loaded.".into()),
        }
    }
    fn unresolved_duplicate(&self, s: &Section) -> bool {
        self.shows_identity && s.action == IdentityAction::Remember && s.trimmed().is_some_and(|n| self.known.iter().any(|k| !k.is_local && k.name == n))
    }
    fn unresolved_choice(&self, s: &Section) -> bool {
        self.shows_identity && s.speaker.identity.as_ref().is_some_and(|i| i.needs_choice) && !matches!(s.action, IdentityAction::ResolveMerged(_))
    }
    pub fn can_save(&self) -> bool {
        !self.is_loading && self.sections.iter().all(|s| s.error().is_none() && !self.unresolved_choice(s) && !self.unresolved_duplicate(s))
    }
    pub fn duplicate(&self, id: &str) -> Option<&Section> {
        let i = self.sections.iter().position(|s| s.speaker.id == id)?;
        let name = self.sections[i].trimmed()?;
        self.sections[..i].iter().find(|s| s.trimmed().as_ref() == Some(&name))
    }
    fn apply(&mut self, db: &Db, change: Res<()>) {
        match change {
            Ok(()) => {
                self.notice = None;
                self.reload(db);
            }
            Err(MeetingError::CorrectionCapacity) => self.notice = Some("This meeting has too many speaker changes to save more.".into()),
            Err(_) => self.notice = Some("The change could not be saved.".into()),
        }
    }
    pub fn merge(&mut self, db: &Db, id: &str, target: &str) {
        if id != target {
            let r = merge(db, &self.meeting_id, id, target, now_ms()).map(|_| ());
            self.apply(db, r);
        }
    }
    pub fn unmerge(&mut self, db: &Db, id: &str) {
        let r = unmerge(db, &self.meeting_id, id, now_ms());
        self.apply(db, r);
    }
    pub fn dismiss_review(&mut self, db: &Db, id: &str) {
        match dismiss_review(db, id) {
            Ok(()) => self.reviews.retain(|r| r.0 != id),
            Err(_) => self.notice = Some("The notice could not be dismissed.".into()),
        }
    }
    pub fn set_draft(&mut self, id: &str, text: &str) {
        if let Some(s) = self.sections.iter_mut().find(|s| s.speaker.id == id) {
            s.draft = text.to_string();
            if s.picked_name.as_deref().is_some_and(|p| p != text) {
                s.picked_name = None;
                if matches!(s.action, IdentityAction::Pick(_)) {
                    s.action = IdentityAction::None;
                }
            }
        }
    }
    pub fn refresh_suggestions(&mut self, db: &Db, id: &str) {
        let Some(draft) = self.sections.iter().find(|s| s.speaker.id == id).map(|s| s.draft.clone()) else {
            self.suggestions.clear();
            return;
        };
        let prefix = draft.trim();
        self.suggestions = name_suggestions(db, prefix, 8).unwrap_or_default().into_iter().filter(|s| s != prefix).collect();
    }
    pub fn pick(&mut self, suggestion: &str, id: &str) {
        self.set_draft(id, suggestion);
        self.suggestions.clear();
    }
    pub fn identity_block(&self, id: &str) -> Option<IdentityBlock> {
        if !self.shows_identity {
            return None;
        }
        let s = self.sections.iter().find(|s| s.speaker.id == id)?;
        if s.speaker.is_you() {
            return Some(IdentityBlock { local_remembered: Some(self.known.iter().any(|k| k.is_local)), ..Default::default() });
        }
        let identity = s.speaker.identity.as_ref();
        let state = identity.map_or("", |i| i.state.as_str());
        let name = identity.and_then(|i| i.known_name.clone()).unwrap_or_default();
        let needs_choice = self.unresolved_choice(s);
        let match_state = if needs_choice {
            "Choose an identity".to_string()
        } else {
            match state {
                "recognized" => format!("Recognized as {name}"),
                "possible" => format!("Possible match: {name}?"),
                "confirmed" => "Confirmed".into(),
                _ => "Unknown".into(),
            }
        };
        let linked = identity.is_some_and(|i| i.known_id.is_some()) && state != "possible";
        let typed_new = s.trimmed().is_some() && s.picked_name.is_none() && !linked && state != "possible";
        let duplicate_of = (s.action == IdentityAction::Remember).then(|| s.trimmed()).flatten().and_then(|n| self.known.iter().find(|k| !k.is_local && k.name == n).cloned());
        let shows_also_remember = matches!(s.action, IdentityAction::Confirm | IdentityAction::ChooseAnother(_) | IdentityAction::Pick(_) | IdentityAction::SamePerson(_)) && identity.is_some_and(|i| i.sample_offer);
        let mut picker: Vec<KnownSpeaker> = self.known.iter().filter(|k| !k.is_local).cloned().collect();
        picker.sort_by(|a, b| a.name.cmp(&b.name));
        if let Some(i) = identity.and_then(|i| i.second.as_ref()).and_then(|(sid, _)| picker.iter().position(|k| &k.id == sid)) {
            let k = picker.remove(i);
            picker.insert(0, k);
        }
        Some(IdentityBlock {
            match_state,
            shows_remember: typed_new && !needs_choice,
            duplicate_of,
            shows_suggestion_actions: state == "possible" && !needs_choice,
            shows_also_remember,
            needs_choice,
            local_remembered: None,
            picker,
        })
    }
    pub fn set_action(&mut self, id: &str, action: IdentityAction) {
        if let Some(s) = self.sections.iter_mut().find(|s| s.speaker.id == id) {
            if matches!(action, IdentityAction::None | IdentityAction::Remember | IdentityAction::RememberNew | IdentityAction::NotNow | IdentityAction::KeepUnknown | IdentityAction::ResolveMerged(_) | IdentityAction::RememberLocal) {
                s.also_remember = false;
            }
            s.action = action;
        }
    }
    pub fn set_also_remember(&mut self, id: &str, on: bool) {
        if let Some(s) = self.sections.iter_mut().find(|s| s.speaker.id == id) {
            s.also_remember = on;
        }
    }
    pub fn pick_known(&mut self, known: &str, id: &str) {
        let Some(k) = self.known.iter().find(|k| k.id == known).cloned() else { return };
        if let Some(s) = self.sections.iter_mut().find(|s| s.speaker.id == id) {
            s.draft = k.name.clone();
            s.picked_name = Some(k.name);
            let current = s.speaker.identity.as_ref();
            s.action = if current.is_some_and(|i| (i.state == "possible" || i.known_id.is_some()) && i.known_id.as_deref() != Some(known)) { IdentityAction::ChooseAnother(known.into()) } else { IdentityAction::Pick(known.into()) };
        }
        self.suggestions.clear();
    }
    /// Names in one transaction, then identity actions in section order, then enrollment. Sample
    /// extraction runs in the Mac worker, so each request reports `enrollment_failure`.
    /// Returns true when the sheet may close.
    pub fn save(&mut self, db: &Db, enrollment_failure: &str) -> bool {
        if !self.can_save() {
            return false;
        }
        self.did_change_identities = false;
        let names: Vec<(String, Option<String>)> = self.sections.iter().map(|s| (s.speaker.id.clone(), s.trimmed())).collect();
        match save_names(db, &self.meeting_id, &names, now_ms()) {
            Ok(_) => self.notice = None,
            Err(MeetingError::CorrectionCapacity) => {
                self.notice = Some("This meeting has too many speaker changes to save more.".into());
                return false;
            }
            Err(_) => {
                self.notice = Some("Names could not be saved.".into());
                return false;
            }
        }
        if !self.shows_identity {
            return true;
        }
        let mut requests = vec![];
        for s in self.sections.clone() {
            let (root, m, now) = (&s.speaker.id, self.meeting_id.clone(), now_ms());
            let candidate = s.speaker.identity.as_ref().and_then(|i| i.known_id.clone());
            let result: Res<()> = (|| {
                match &s.action {
                    IdentityAction::None | IdentityAction::NotNow => {}
                    IdentityAction::Remember | IdentityAction::RememberNew | IdentityAction::RememberLocal => requests.push(root.clone()),
                    IdentityAction::SamePerson(k) | IdentityAction::Pick(k) => {
                        link(db, &m, root, k, "manual_profile_selection", now)?;
                        self.did_change_identities = true;
                        if s.also_remember {
                            requests.push(root.clone());
                        }
                    }
                    IdentityAction::Confirm => {
                        if let Some(k) = &candidate {
                            link(db, &m, root, k, "user_confirmation", now)?;
                            self.did_change_identities = true;
                            if s.also_remember {
                                requests.push(root.clone());
                            }
                        }
                    }
                    IdentityAction::ChooseAnother(k) => {
                        link(db, &m, root, k, "manual_correction", now)?;
                        self.did_change_identities = true;
                        if s.also_remember {
                            requests.push(root.clone());
                        }
                    }
                    IdentityAction::KeepUnknown => {
                        match &candidate {
                            Some(k) => reject(db, &m, root, k, true, now)?,
                            None => unlink(db, &m, root, now)?,
                        }
                        self.did_change_identities = true;
                    }
                    IdentityAction::ResolveMerged(k) => {
                        resolve_merged(db, &m, root, k.as_deref(), now)?;
                        self.did_change_identities = true;
                    }
                }
                Ok(())
            })();
            match result {
                Ok(()) => {}
                Err(MeetingError::RejectCapacity) => {
                    self.notice = Some("This meeting has too many rejected matches to save more.".into());
                    return false;
                }
                Err(_) => {
                    self.notice = Some("Speaker identities could not be saved.".into());
                    return false;
                }
            }
        }
        if requests.is_empty() {
            return true;
        }
        for root in requests {
            if let Some(s) = self.sections.iter_mut().find(|s| s.speaker.id == root) {
                s.enrollment_result = Some(enrollment_failure.to_string());
            }
        }
        self.enrollment_completed = true;
        false
    }
}

// MARK: summary read model

#[derive(Clone, Debug, PartialEq)]
pub enum SourceRef {
    Segment(String),
    Note(i64, String),
}
impl SourceRef {
    fn sort_key(&self) -> String {
        match self {
            SourceRef::Segment(id) => format!("s:{id}"),
            SourceRef::Note(o, h) => format!("n:{o}:{h}"),
        }
    }
}
pub fn source_key(sources: &[SourceRef]) -> String {
    let mut keys: Vec<String> = sources.iter().map(SourceRef::sort_key).collect();
    keys.sort();
    keys.join(",")
}
#[derive(Clone, Debug, PartialEq)]
pub enum Owner {
    /// name, palette index, whether it is the local user
    Participant(String, usize, bool),
    /// name, possible (known id, known name)
    Mentioned(String, Option<(String, String)>),
    Unresolved(String),
}
impl Owner {
    pub fn text(&self) -> &str {
        match self {
            Owner::Participant(n, ..) | Owner::Mentioned(n, _) | Owner::Unresolved(n) => n,
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub id: String,
    pub kind: String,
    pub ordinal: i64,
    pub text: String,
    pub ai_text: String,
    pub sources: Vec<SourceRef>,
    /// field to overlay id
    pub overlays: Vec<(String, String)>,
    pub attribution: Option<String>,
    pub owner: Owner,
    pub ai_owner: Owner,
    pub due_date: Option<String>,
    pub ai_due_date: Option<String>,
    pub due_original: Option<String>,
    pub due_state: String,
    pub status: String,
}
impl Item {
    pub fn overlay(&self, field: &str) -> Option<&str> {
        self.overlays.iter().find(|o| o.0 == field).map(|o| o.1.as_str())
    }
    pub fn text_edit(&self) -> Option<&str> {
        self.overlay("task_text").or(self.overlay("decision_text")).or(self.overlay("next_step_text"))
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Topic {
    pub title: String,
    pub summary: String,
    pub bullets: Vec<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct PreviousEdit {
    pub id: String,
    pub field: String,
    pub item_text: Option<String>,
    pub ai_value: Option<String>,
    pub user_value: String,
}
#[derive(Clone, Debug, PartialEq, Default)]
pub struct ReadModel {
    pub summary: String,
    pub ai_summary: String,
    pub summary_sources: Vec<SourceRef>,
    pub summary_overlay: Option<String>,
    pub topics: Vec<Topic>,
    pub action_items: Vec<Item>,
    pub next_steps: Vec<Item>,
    pub decisions: Vec<Item>,
    pub open_questions: Vec<Item>,
    pub risks: Vec<Item>,
    pub previous_edits: Vec<PreviousEdit>,
    pub reading_minutes: i64,
    pub stale: bool,
    pub generated_at: i64,
}
fn words(t: &str) -> i64 {
    t.split([' ', '\n']).filter(|w| !w.is_empty()).count() as i64
}
impl ReadModel {
    fn minutes(&self) -> i64 {
        let mut n = words(&self.summary);
        for t in &self.topics {
            n += words(&t.title) + words(&t.summary) + t.bullets.iter().map(|b| words(b)).sum::<i64>();
        }
        for l in [&self.action_items, &self.next_steps, &self.decisions, &self.open_questions, &self.risks] {
            n += l.iter().map(|i| words(&i.text)).sum::<i64>();
        }
        ((n + 199) / 200).max(1)
    }
}
/// (certainty allows a name, name, anonymous label, color, is local)
fn participant(root: &SpeakerSummary) -> (bool, String, String, usize, bool) {
    let anon = root.anonymous();
    let id = root.identity.as_ref();
    let known = id.and_then(|i| i.known_name.clone());
    if root.source == "local" {
        return (true, known.or(root.name.clone()).unwrap_or_else(|| anon.clone()), anon, root.color, true);
    }
    match id.map(|i| i.state.as_str()) {
        Some("confirmed" | "recognized") => (true, known.unwrap_or_else(|| anon.clone()), anon, root.color, false),
        _ => match root.name.as_deref().filter(|n| !n.is_empty()) {
            Some(local) => (true, local.to_string(), anon, root.color, false),
            None => (false, anon.clone(), anon, root.color, false),
        },
    }
}
fn folded_eq(a: &str, b: &str) -> bool {
    a.to_lowercase() == b.to_lowercase()
}
fn profile_color(id: &str) -> usize {
    let bytes: Vec<u8> = id.chars().filter(char::is_ascii_hexdigit).collect::<Vec<_>>().chunks(2).filter_map(|c| u8::from_str_radix(&c.iter().collect::<String>(), 16).ok()).collect();
    bytes.iter().map(|b| *b as usize).sum::<usize>() % 8
}
fn resolve_owner(kind: Option<&str>, speaker: Option<&str>, name: Option<&str>, roots: &[SpeakerSummary], known: &[KnownSpeaker]) -> Owner {
    match kind {
        Some("participant") => {
            let id = speaker.unwrap_or_default();
            match roots.iter().find(|r| r.id == id) {
                None => match known.iter().find(|k| k.id == id) {
                    Some(k) => Owner::Participant(k.name.clone(), profile_color(id), false),
                    None => Owner::Unresolved("Owner unresolved".into()),
                },
                Some(root) => {
                    let (named, n, anon, color, local) = participant(root);
                    if named { Owner::Participant(n, color, local) } else { Owner::Unresolved(anon) }
                }
            }
        }
        Some("mentioned") => {
            let n = name.unwrap_or_default();
            Owner::Mentioned(n.to_string(), known.iter().find(|k| folded_eq(&k.name, n)).map(|k| (k.id.clone(), k.name.clone())))
        }
        _ => Owner::Unresolved("Owner unresolved".into()),
    }
}
fn sources_of(db: &Db, run: &str) -> Res<HashMap<(String, String), Vec<SourceRef>>> {
    let mut s = db.conn.prepare("SELECT target_kind, target_id, source_kind, segment_id, note_ordinal, note_hash FROM analysis_sources WHERE run_id=?1 ORDER BY target_kind, target_id, ordinal")?;
    let mut out: HashMap<(String, String), Vec<SourceRef>> = HashMap::new();
    let rows = s.query_map([run], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, Option<String>>(3)?, r.get::<_, Option<i64>>(4)?, r.get::<_, Option<String>>(5)?)))?;
    for row in rows {
        let (k, t, sk, seg, ord, hash) = row?;
        let source = if sk == "segment" { seg.map(SourceRef::Segment) } else { ord.map(|o| SourceRef::Note(o, hash.unwrap_or_default())) };
        if let Some(source) = source {
            out.entry((k, t)).or_default().push(source);
        }
    }
    Ok(out)
}
/// `MeetingAnalyzer.currentEvidenceVersion`: the `EvidenceVersion` hash of the evidence as it stands
/// now. None without a final transcript.
pub fn current_evidence_version(db: &Db, meeting: &str) -> Res<Option<String>> {
    let Some(pass) = transcription(db, meeting)?.filter(|t| t.state == "final").and_then(|t| t.pass_id) else { return Ok(None) };
    let mut out: Vec<u8> = vec![];
    let mut line = |fields: &[&str]| {
        for f in fields {
            out.extend_from_slice(format!("{}:", f.len()).as_bytes());
            out.extend_from_slice(f.as_bytes());
            out.push(0x1f);
        }
        out.push(0x0a);
    };
    let upper = |id: &str| id.to_uppercase();
    line(&["evidence_v1"]);
    line(&["meeting", &upper(meeting)]);
    line(&["pass", &upper(&pass)]);
    let mut s = db.conn.prepare_cached("SELECT id, end_ms FROM transcript_segments WHERE meeting_id=?1 AND finality='final' AND pass_id=?2")?;
    let ends: HashMap<String, i64> = s.query_map(params![meeting, pass], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
    let mut after = None;
    loop {
        let rows = labeled_page(db, meeting, "final", after, TRANSCRIPT_PAGE)?;
        for row in &rows {
            let Some(end) = ends.get(&row.id) else { continue };
            let speaker = match row.label.as_ref().map(|l| &l.kind) {
                Some(LabelKind::Speaker(root)) => upper(root),
                Some(LabelKind::Overlapping) => "ambiguous".into(),
                _ => "unknown".into(),
            };
            line(&["segment", &upper(&row.id), &row.ordinal.to_string(), &row.start_ms.to_string(), &end.to_string(), &speaker, &row.text]);
        }
        match rows.last() {
            Some(last) if rows.len() >= TRANSCRIPT_PAGE => after = Some(last.ordinal),
            _ => break,
        }
    }
    // The research R9 table. Names stay out; only whether one was typed matters.
    let local_profile: Option<String> = db.conn.query_row("SELECT id FROM known_speakers WHERE is_local_user=1", [], |r| r.get(0)).optional()?;
    let ids = identities(db, meeting)?;
    let mut roots: Vec<(String, String, String, Option<String>)> = vec![];
    if let Some((_, speakers)) = accepted_speakers(db, meeting)? {
        for root in speakers.iter().filter(|r| r.merged_into.is_none()) {
            let (source, name) = db.conn.query_row("SELECT source, display_name FROM meeting_speakers WHERE id=?1", [&root.id], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?)))?;
            roots.push((upper(&root.id), root.id.clone(), source, name));
        }
    }
    roots.sort();
    for (id, stored, source, name) in &roots {
        if source == "local" {
            line(&["local", id, if local_profile.is_some() { "1" } else { "0" }]);
            continue;
        }
        let identity = ids.get(stored);
        let origin = identity.map_or("none", |i| i.origin.as_str());
        match identity.map(|i| i.state.as_str()) {
            Some(state @ ("confirmed" | "recognized")) => line(&["root", id, state, origin, &identity.and_then(|i| i.known_id.as_deref()).map(upper).unwrap_or_else(|| "none".into())]),
            _ if name.is_some() => line(&["root", id, "local_name", "none", "none"]),
            Some("possible") => line(&["root", id, "possible", origin, "none"]),
            _ => line(&["root", id, "unknown", origin, "none"]),
        }
    }
    let text: Option<String> = db.conn.query_row("SELECT text FROM meeting_notes WHERE meeting_id=?1", [meeting], |r| r.get(0)).optional()?;
    for (ordinal, paragraph, ..) in note_paragraphs(&text.unwrap_or_default()) {
        line(&["note", &ordinal.to_string(), &paragraph]);
    }
    line(&["language", &evidence_language(db, meeting)?, "1"]);
    line(&["versions", "1", "chunking_v2", "16384", "caps_v1"]);
    Ok(Some(crate::history::sha256_hex(&out)))
}
/// `LanguagePolicy.resolve`: the language the pass decoded in, then the meeting's choice.
// ponytail: Swift's last step is NLLanguageRecognizer, which only Apple has. A final pass's text does
// not change, so the accepted summary's recorded language stands in for it until Feature 025.
fn evidence_language(db: &Db, meeting: &str) -> Res<String> {
    let pipeline: Option<String> = db.conn.query_row("SELECT pipeline_version FROM meeting_transcriptions WHERE meeting_id=?1", [meeting], |r| r.get(0))?;
    let pipeline = pipeline.unwrap_or_default();
    let tags: Vec<&str> = pipeline.split('+').filter(|t| t.starts_with("lang_")).collect();
    if let [tag] = tags[..] {
        let parts: Vec<&str> = tag.split('_').collect();
        if let ["lang", lang @ ("sk" | "en"), "prompt", "v1" | "v2"] = parts[..] {
            return Ok(lang.into());
        }
    }
    let chosen: Option<String> = db.conn.query_row("SELECT language FROM meetings WHERE id=?1", [meeting], |r| r.get(0))?;
    match chosen.as_deref() {
        Some("slovak") => return Ok("sk".into()),
        Some("english") => return Ok("en".into()),
        _ => {}
    }
    let stored: Option<String> = db.conn.query_row("SELECT s.language FROM analysis_summaries s JOIN meeting_analysis a ON a.accepted_run_id=s.run_id WHERE a.meeting_id=?1", [meeting], |r| r.get(0)).optional()?;
    Ok(stored.unwrap_or_else(|| "mixed".into()))
}
/// `AnalysisStore.readModel` with overlays and live owner names applied. None without an accepted run.
pub fn read_model(db: &Db, meeting: &str) -> Res<Option<ReadModel>> {
    let accepted: Option<(String, String, Option<String>, Option<i64>, i64)> = db
        .conn
        .query_row(
            "SELECT r.id, r.evidence_version, a.accepted_evidence_version, r.completed_at, r.created_at FROM meeting_analysis a JOIN analysis_runs r ON r.id=a.accepted_run_id WHERE a.meeting_id=?1",
            [meeting],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()?;
    let Some((run, evidence, accepted_evidence, completed, created)) = accepted else { return Ok(None) };
    let roots = speaker_summaries(db, meeting)?;
    let known = known_speakers(db)?;
    let sources = sources_of(db, &run)?;
    let summary: Option<String> = db.conn.query_row("SELECT text FROM analysis_summaries WHERE run_id=?1", [&run], |r| r.get(0)).optional()?;
    let ai_summary = summary.unwrap_or_default();
    let mut model = ReadModel {
        summary: ai_summary.clone(),
        ai_summary,
        summary_sources: sources.get(&("summary".to_string(), run.clone())).cloned().unwrap_or_default(),
        // `SummaryModel`: the live evidence hash against the run's, or the pointer's own flag.
        stale: accepted_evidence.as_ref().is_some_and(|a| *a != evidence) || current_evidence_version(db, meeting).ok().flatten().is_some_and(|c| c != evidence),
        generated_at: completed.unwrap_or(created),
        ..Default::default()
    };
    let mut s = db.conn.prepare("SELECT title, summary, bullets_json FROM analysis_topics WHERE run_id=?1 ORDER BY ordinal")?;
    model.topics = s
        .query_map([&run], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)))?
        .map(|t| t.map(|(title, summary, b)| Topic { title, summary, bullets: serde_json::from_str(&b).unwrap_or_default() }))
        .collect::<Result<_, _>>()?;
    type OverlayRow = (String, Option<String>, String, String, String, Option<String>, Option<String>);
    let mut s = db.conn.prepare("SELECT id, item_id, target_kind, field, user_value, ai_value_snapshot, item_text_snapshot FROM analysis_overlays WHERE meeting_id=?1 ORDER BY created_at, id")?;
    let overlays: Vec<OverlayRow> = s.query_map([meeting], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)))?.collect::<Result<_, _>>()?;
    let mut by_item: HashMap<String, Vec<&OverlayRow>> = HashMap::new();
    for o in &overlays {
        match (o.2.as_str(), &o.1) {
            ("summary", _) => {
                model.summary = o.4.clone();
                model.summary_overlay = Some(o.0.clone());
            }
            (_, Some(item)) => by_item.entry(item.clone()).or_default().push(o),
            (_, None) => {
                let value = match o.3.as_str() {
                    "owner" => match serde_json::from_str::<serde_json::Value>(&o.4).ok().as_ref().and_then(|v| v.get("kind")).and_then(|k| k.as_str()) {
                        Some("mentioned") => serde_json::from_str::<serde_json::Value>(&o.4).ok().and_then(|v| v.get("name").and_then(|n| n.as_str()).map(String::from)).unwrap_or_default(),
                        Some("participant") => "a participant".into(),
                        _ => "unassigned".into(),
                    },
                    "due_date" => serde_json::from_str::<serde_json::Value>(&o.4).ok().and_then(|v| v.get("date").and_then(|d| d.as_str()).map(String::from)).unwrap_or_else(|| "no date".into()),
                    _ => o.4.clone(),
                };
                model.previous_edits.push(PreviousEdit { id: o.0.clone(), field: o.3.clone(), item_text: o.6.clone(), ai_value: o.5.clone(), user_value: value });
            }
        }
    }
    let mut s = db.conn.prepare("SELECT id, kind, ordinal, text, owner_kind, owner_speaker_id, owner_name, due_state, due_date, due_original FROM analysis_items WHERE run_id=?1 ORDER BY kind, ordinal")?;
    type ItemRow = (String, String, i64, String, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>);
    let items: Vec<ItemRow> = s.query_map([&run], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?, r.get(9)?)))?.collect::<Result<_, _>>()?;
    let labels = segment_labels(db, meeting, &roots)?;
    for (id, kind, ordinal, ai_text, owner_kind, owner_speaker, owner_name, due_state, due_date, due_original) in items {
        let mut text = ai_text.clone();
        let (mut edited_owner, mut edited_due, mut status) = (None, None, "open".to_string());
        let mut overlay_ids = vec![];
        for o in by_item.get(&id).map(Vec::as_slice).unwrap_or_default() {
            overlay_ids.push((o.3.clone(), o.0.clone()));
            match o.3.as_str() {
                "owner" => edited_owner = serde_json::from_str::<serde_json::Value>(&o.4).ok(),
                "due_date" => edited_due = serde_json::from_str::<serde_json::Value>(&o.4).ok().map(|v| v.get("date").and_then(|d| d.as_str()).map(String::from)),
                "status" => status = o.4.clone(),
                "summary_text" => {}
                _ => text = o.4.clone(),
            }
        }
        let ai_owner = resolve_owner(owner_kind.as_deref(), owner_speaker.as_deref(), owner_name.as_deref(), &roots, &known);
        let owner = match &edited_owner {
            Some(v) => resolve_owner(v.get("kind").and_then(|k| k.as_str()), v.get("speaker_id").and_then(|k| k.as_str()), v.get("name").and_then(|k| k.as_str()), &roots, &known),
            None => ai_owner.clone(),
        };
        let item_sources = sources.get(&("item".to_string(), id.clone())).cloned().unwrap_or_default();
        let attribution = item_sources.iter().find_map(|s| if let SourceRef::Segment(id) = s { labels.get(id).cloned() } else { None });
        let item = Item {
            id,
            kind: kind.clone(),
            ordinal,
            text,
            ai_text,
            sources: item_sources,
            overlays: overlay_ids,
            attribution,
            owner,
            ai_owner,
            due_date: edited_due.clone().unwrap_or_else(|| due_date.clone()),
            ai_due_date: due_date,
            due_original,
            due_state: due_state.unwrap_or_else(|| "absent".into()),
            status,
        };
        match kind.as_str() {
            "action_item" => model.action_items.push(item),
            "next_step" => model.next_steps.push(item),
            "decision" => model.decisions.push(item),
            "open_question" => model.open_questions.push(item),
            _ => model.risks.push(item),
        }
    }
    model.reading_minutes = model.minutes();
    Ok(Some(model))
}
/// The final pass's effective speaker label per segment, for attribution.
fn segment_labels(db: &Db, meeting: &str, roots: &[SpeakerSummary]) -> Res<HashMap<String, String>> {
    let mut out = HashMap::new();
    let Some((run, _)) = accepted_run(&db.conn, meeting)? else { return Ok(out) };
    let mut s = db.conn.prepare(
        "SELECT a.segment_id, COALESCE(a.manual_kind, a.auto_kind), COALESCE(e.merged_into, e.id) FROM speaker_assignments a
         LEFT JOIN meeting_speakers e ON e.id=CASE WHEN a.manual_kind IS NOT NULL THEN a.manual_speaker_id ELSE a.auto_speaker_id END WHERE a.run_id=?1",
    )?;
    let rows = s.query_map([&run], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?)))?;
    for row in rows {
        let (seg, kind, root) = row?;
        let label = match kind.as_str() {
            "ambiguous" => "Overlapping".to_string(),
            "unknown" => "Unknown".to_string(),
            _ => root.and_then(|id| roots.iter().find(|r| r.id == id)).map(|r| {
                let (named, n, anon, ..) = participant(r);
                if named { n } else { anon }
            }).unwrap_or_else(|| "Unknown".into()),
        };
        out.insert(seg, label);
    }
    Ok(out)
}
/// Owner menu rows: (root id, label, color).
pub fn owner_choices(roots: &[SpeakerSummary]) -> Vec<(String, String, usize)> {
    roots
        .iter()
        .map(|r| {
            let (named, n, anon, color, _) = participant(r);
            (r.id.clone(), if named { n } else { anon }, color)
        })
        .collect()
}
pub enum OverlayTarget<'a> {
    Summary,
    Item(&'a str),
}
/// Upsert on (item, field) or the meeting's summary overlay; refuses beyond the cap.
#[allow(clippy::too_many_arguments)]
pub fn set_overlay(db: &Db, meeting: &str, target: OverlayTarget, field: &str, value: &str, ai_value: Option<&str>, item_text: Option<&str>, key: &str, now: i64) -> Res<()> {
    let tx = db.conn.unchecked_transaction()?;
    let item = if let OverlayTarget::Item(i) = target { Some(i) } else { None };
    let item_kind: Option<String> = match item {
        Some(i) => tx.query_row("SELECT kind FROM analysis_items WHERE id=?1", [i], |r| r.get(0)).optional()?,
        None => None,
    };
    let existing: Option<String> = match item {
        Some(i) => tx.query_row("SELECT id FROM analysis_overlays WHERE item_id=?1 AND field=?2", params![i, field], |r| r.get(0)).optional()?,
        None => tx.query_row("SELECT id FROM analysis_overlays WHERE meeting_id=?1 AND target_kind='summary' AND field=?2", params![meeting, field], |r| r.get(0)).optional()?,
    };
    match existing {
        Some(id) => {
            tx.execute(
                "UPDATE analysis_overlays SET user_value=?1, ai_value_snapshot=?2, item_text_snapshot=?3, source_key=?4, updated_at=?5 WHERE id=?6",
                params![value, ai_value, item_text, key, now, id],
            )?;
        }
        None => {
            let count: i64 = tx.query_row("SELECT count(*) FROM analysis_overlays WHERE meeting_id=?1", [meeting], |r| r.get(0))?;
            if count >= OVERLAY_CAP {
                return Err(MeetingError::OverlayCapacity);
            }
            tx.execute(
                "INSERT INTO analysis_overlays (id, meeting_id, item_id, target_kind, item_kind, field, user_value, ai_value_snapshot, item_text_snapshot, source_key, created_at, updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?11)",
                params![new_id(), meeting, item, if item.is_some() { "item" } else { "summary" }, item_kind, field, value, ai_value, item_text, key, now],
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}
pub fn remove_overlay(db: &Db, id: &str) -> Res<()> {
    db.conn.execute("DELETE FROM analysis_overlays WHERE id=?1", [id])?;
    Ok(())
}
pub fn remove_all_overlays(db: &Db, meeting: &str) -> Res<()> {
    db.conn.execute("DELETE FROM analysis_overlays WHERE meeting_id=?1", [meeting])?;
    Ok(())
}
pub fn owner_value_participant(id: &str) -> String {
    format!("{{\"kind\":\"participant\",\"speaker_id\":\"{id}\"}}")
}
pub fn owner_value_mentioned(name: &str) -> String {
    serde_json::json!({"kind":"mentioned","name":name}).to_string()
}
pub const OWNER_VALUE_NONE: &str = "{\"kind\":\"none\"}";
pub fn due_value(date: Option<&str>) -> String {
    match date {
        Some(d) => format!("{{\"date\":\"{d}\"}}"),
        None => "{\"date\":null}".into(),
    }
}
/// `AnalysisReport.text`: plain text in reading order, never an id.
pub fn report_text(model: &ReadModel, title: &str, date: &str) -> String {
    let mut lines: Vec<String> = vec![title.into(), date.into(), String::new(), "Summary".into(), model.summary.clone(), String::new()];
    for t in &model.topics {
        lines.push(t.title.clone());
        if !t.summary.is_empty() {
            lines.push(t.summary.clone());
        }
        lines.extend(t.bullets.iter().map(|b| format!("- {b}")));
        lines.push(String::new());
    }
    if !model.action_items.is_empty() {
        lines.push("Action items".into());
        for i in model.action_items.iter().filter(|i| i.status != "dismissed") {
            let mut line = format!("- {} {}", if i.status == "completed" { "[x]" } else { "[ ]" }, i.text);
            match &i.owner {
                Owner::Participant(n, ..) | Owner::Mentioned(n, _) => line += &format!(" — {n}"),
                Owner::Unresolved(_) => line += " — (owner unresolved)",
            }
            if let Some(d) = &i.due_date {
                line += &format!(" (due {})", due_text(d));
            }
            lines.push(line);
        }
        lines.push(String::new());
    }
    for (heading, rows) in [("Next steps", &model.next_steps), ("Decisions", &model.decisions), ("Open questions", &model.open_questions), ("Risks / blockers", &model.risks)] {
        if !rows.is_empty() {
            lines.push(heading.into());
            lines.extend(rows.iter().map(|r| format!("- {}", r.text)));
            lines.push(String::new());
        }
    }
    lines.push("Generated by LocalFlow from the meeting transcript and notes.".into());
    lines.join("\n")
}
/// "Generated…" summary state for one meeting, from stored rows: the header's input.
#[derive(Clone, Debug, PartialEq)]
pub enum SummaryHeader {
    NotEligible(&'static str),
    Eligible,
    Pending(i64),
    Running(String),
    Failed(String),
    Succeeded,
}
pub const NOT_FINISHED: &str = "The transcript is not finished yet.";
pub const TRANSCRIPTION_OFF: &str = "Transcription is off for this meeting.";
pub fn summary_header(db: &Db, meeting: &str) -> Res<SummaryHeader> {
    let current: Option<(String, Option<String>)> = run_status(db, "analysis_runs", "meeting_analysis", meeting)?;
    let accepted: bool = db.conn.query_row("SELECT accepted_run_id IS NOT NULL FROM meeting_analysis WHERE meeting_id=?1", [meeting], |r| r.get(0)).optional()?.unwrap_or(false);
    let eligible = || -> Res<SummaryHeader> {
        Ok(match transcription(db, meeting)?.map(|t| t.state).as_deref() {
            Some("final") => SummaryHeader::Eligible,
            None | Some("not_requested") => SummaryHeader::NotEligible(TRANSCRIPTION_OFF),
            _ => SummaryHeader::NotEligible(NOT_FINISHED),
        })
    };
    Ok(match current.as_ref().map(|c| c.0.as_str()) {
        Some("pending") => SummaryHeader::Pending(0),
        Some("running") => SummaryHeader::Running("Analyzing".into()),
        Some("failed" | "timed_out" | "interrupted") => SummaryHeader::Failed(analysis_failure_text(current.as_ref().and_then(|c| c.1.as_deref()).unwrap_or("interrupted")).into()),
        _ if accepted => SummaryHeader::Succeeded,
        _ => eligible()?,
    })
}
/// `text` with each anonymous label replaced by the speaker's current name, on word boundaries.
pub fn renamed(text: &str, labels: &[(String, String)]) -> String {
    let mut shown = text.to_string();
    for (anon, name) in labels {
        if anon == name {
            continue;
        }
        let mut out = String::new();
        let mut rest = shown.as_str();
        while let Some(i) = rest.find(anon.as_str()) {
            let before = rest[..i].chars().last();
            let after = rest[i + anon.len()..].chars().next();
            out.push_str(&rest[..i]);
            out.push_str(if before.is_some_and(char::is_alphanumeric) || after.is_some_and(char::is_alphanumeric) { anon } else { name });
            rest = &rest[i + anon.len()..];
        }
        out.push_str(rest);
        shown = out;
    }
    shown
}
/// Byte ranges naming a speaker, with the color and root. Longest name first, a first name counts
/// from three characters, up to three trailing lowercase letters cover Slovak case endings.
pub fn speaker_mentions(text: &str, speakers: &[(String, String, usize)]) -> Vec<(usize, usize, String, usize)> {
    let mut names: Vec<(String, String, usize)> = vec![];
    for (id, label, color) in speakers {
        if label == "You" {
            continue;
        }
        let name = label.replace(" (You)", "");
        if let Some(first) = name.split(' ').next() {
            if first.chars().count() >= 3 && first != name && !name.ends_with(|c: char| c.is_numeric()) {
                names.push((first.to_string(), id.clone(), *color));
            }
        }
        names.push((name, id.clone(), *color));
    }
    names.sort_by_key(|n| std::cmp::Reverse(n.0.chars().count()));
    let mut found: Vec<(usize, usize, String, usize)> = vec![];
    for (name, id, color) in names {
        let mut from = 0;
        while let Some(i) = text[from..].find(&name).map(|i| i + from) {
            let start_ok = !text[..i].chars().last().is_some_and(char::is_alphabetic);
            let mut end = i + name.len();
            let mut tail = 0;
            while tail < 3 {
                match text[end..].chars().next() {
                    Some(c) if c.is_lowercase() => {
                        end += c.len_utf8();
                        tail += 1;
                    }
                    _ => break,
                }
            }
            let end_ok = !text[end..].chars().next().is_some_and(char::is_alphanumeric);
            if start_ok && end_ok && !found.iter().any(|f| i < f.1 && f.0 < end) {
                found.push((i, end, id.clone(), color));
            }
            from = i + name.len();
        }
    }
    found.sort_by_key(|f| f.0);
    found
}

// MARK: seed. Synthetic rows only: names, words and timings below are invented.

const HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const EVIDENCE: &str = "1111111111111111111111111111111111111111111111111111111111111111";

fn insert_meeting(c: &Connection, id: &str, state: &str, title: Option<&str>, created: i64, recorded: i64, reason: Option<&str>, origin: &str) {
    c.execute(
        "INSERT INTO meetings (id, state, title, created_at, started_at, stopped_at, completed_at, wall_clock_ms, recorded_ms, finalization_stage, failure_reason, updated_at, revision, origin)
         VALUES (?1,?2,?3,?4,?4,?5,?5,?6,?6,'both',?7,?4,0,?8)",
        params![id, state, title, created, created + recorded, recorded, reason, origin],
    )
    .unwrap();
    c.execute("INSERT INTO meeting_notes (meeting_id, text, author, updated_at, revision) VALUES (?1,'','user',?2,0)", params![id, created]).unwrap();
    c.execute("INSERT INTO meeting_diarization (meeting_id, updated_at) VALUES (?1,?2)", params![id, created]).unwrap();
    c.execute("INSERT INTO meeting_identification (meeting_id, updated_at) VALUES (?1,?2)", params![id, created]).unwrap();
    c.execute("INSERT INTO meeting_analysis (meeting_id, updated_at) VALUES (?1,?2)", params![id, created]).unwrap();
}
fn insert_transcription(c: &Connection, id: &str, state: &str, pass: Option<&str>, category: Option<&str>, count: i64, bytes: i64, now: i64, path: &str) {
    let kind = pass.map(|_| "final");
    c.execute(
        "INSERT INTO meeting_transcriptions (meeting_id, state, live_requested, pass_id, pass_kind, engine, failure_category, segment_count, text_bytes, updated_at, inference_path)
         VALUES (?1,?2,0,?3,?4,'whisper.cpp',?5,?6,?7,?8,?9)",
        params![id, state, pass, kind, category, count, bytes, now, path],
    )
    .unwrap();
}
fn insert_track(c: &Connection, id: &str, meeting: &str, kind: &str, health: &str, reason: Option<&str>, dropped: i64, warning: i64, duration: i64) {
    c.execute(
        "INSERT INTO meeting_tracks (id, meeting_id, type, codec, container, sample_rate, channel_count, bitrate, health, failure_reason, total_duration_ms, total_bytes, duration_warning, dropped_frames)
         VALUES (?1,?2,?3,'aac_lc','adts',48000,1,64000,?4,?5,?6,0,?7,?8)",
        params![id, meeting, kind, health, reason, duration, warning, dropped],
    )
    .unwrap();
}
fn insert_file_row(c: &Connection, track: &str, meeting: &str, seq: i64, offset: i64, duration: i64, reason: &str, device: Option<&str>, created: i64) {
    c.execute(
        "INSERT INTO meeting_segments (id, track_id, sequence, relative_path, state, start_offset_ms, duration_ms, byte_size, started_at, host_start_ns, open_reason, input_device_name)
         VALUES (?1,?2,?3,?4,'finalized',?5,?6,0,?7,0,?8,?9)",
        params![new_id(), track, seq, format!("{meeting}/{track}-{seq}.aac"), offset, duration, created, reason, device],
    )
    .unwrap();
}
const LINES: [&str; 12] = [
    "Let us start with the release date for the desk lamp prototype.",
    "The hinge samples came back on Tuesday and two of them are too stiff.",
    "I can ask the workshop to loosen the tolerance before the next batch.",
    "We still need a price from the second supplier before we decide.",
    "Marta said the quote should arrive by the end of the week.",
    "Then we hold the order until we have both numbers in front of us.",
    "What about the packaging, is the cardboard version good enough?",
    "It survived the drop test, although one corner dented a little.",
    "A dented corner is fine for samples but not for the shop shelf.",
    "I will write up the test results and send them around tomorrow.",
    "Good, and the photos of the finished lamp can wait until next month.",
    "That works for me, so we can finish here and pick this up on Friday.",
];

/// `MeetingCoordinator.start`'s refusals before anything is created, in Swift's order.
pub fn start_refusal(busy: bool, dictating: bool, microphone_denied: bool, screen_denied: bool, free_bytes: Option<u64>) -> Option<&'static str> {
    if busy {
        Some("Meeting is busy")
    } else if dictating {
        Some("Dictation in progress")
    } else if microphone_denied {
        Some("Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone.")
    } else if screen_denied {
        Some("System audio needs Screen & System Audio Recording. Enable LocalFlow in System Settings > Privacy & Security > Screen & System Audio Recording.")
    } else if free_bytes.is_some_and(|f| f < 500_000_000) {
        Some("Not enough free space to record (needs at least 500 MB)")
    } else {
        None
    }
}
/// Recording continues under this warning.
pub fn low_space_warning(free_bytes: Option<u64>) -> Option<&'static str> {
    free_bytes.filter(|f| *f < 2_000_000_000).map(|_| "Less than 2 GB free")
}
/// A bounded admission queue: the running item counts against the capacity.
pub fn admit(queue: &mut Vec<String>, id: &str, running: bool, capacity: usize) -> bool {
    if queue.iter().any(|q| q == id) {
        return true;
    }
    if queue.len() + usize::from(running) >= capacity {
        return false;
    }
    queue.push(id.to_string());
    true
}
pub const QUEUE_CAPACITY: usize = 100;

/// `TrackPlaybackController.load`.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct PlaybackQueue {
    /// (relative path, offset in the concatenated timeline).
    pub items: Vec<(String, i64)>,
    pub skipped: Vec<String>,
    pub duration_ms: i64,
    pub notice: Option<&'static str>,
}
pub fn playback_queue(track: &Track, root: &Path) -> PlaybackQueue {
    let mut q = PlaybackQueue::default();
    let mut segments: Vec<&Segment> = track.segments.iter().collect();
    segments.sort_by_key(|s| s.sequence);
    for s in segments {
        match s.state.as_str() {
            "finalized" if root.join(&s.relative_path).exists() => {
                q.items.push((s.relative_path.clone(), q.duration_ms));
                q.duration_ms += s.duration_ms;
            }
            "finalized" => q.skipped.push(format!("Segment {}: Not playable: {}", s.sequence, failure_reason_text("file_missing", None))),
            "open" => q.skipped.push(format!("Segment {}: Not playable: still open", s.sequence)),
            _ => q.skipped.push(format!("Segment {}: Not playable: {}", s.sequence, failure_reason_text(s.failure_reason.as_deref().unwrap_or("unrecoverable_media"), None))),
        }
    }
    q.notice = q.items.is_empty().then_some("No playable audio");
    q
}

/// `meetingsWithUnknownRemoteSpeakers`: newest first, at most 500.
pub fn past_search_candidates(db: &Db, except: Option<&str>) -> Res<Vec<String>> {
    let rows = db.conn.prepare(
        "SELECT m.id FROM meetings m JOIN meeting_diarization d ON d.meeting_id=m.id AND d.accepted_run_id IS NOT NULL
         WHERE EXISTS (SELECT 1 FROM meeting_speakers s WHERE s.run_id=d.accepted_run_id AND s.source='remote' AND s.speech_ms>0 AND s.merged_into IS NULL
           AND NOT EXISTS (SELECT 1 FROM identity_assignments a WHERE a.meeting_speaker_id=s.id AND a.scope='merged' AND a.known_speaker_id IS NOT NULL)
           AND NOT EXISTS (SELECT 1 FROM identity_assignments a WHERE a.meeting_speaker_id=s.id AND a.scope='self' AND a.state IN ('recognized','possible','confirmed','rejected_unknown')))
         ORDER BY m.created_at DESC, m.id DESC LIMIT 500",
    )?
    .query_map([], |r| r.get::<_, String>(0))?
    .collect::<Result<Vec<_>, _>>()?;
    Ok(rows.into_iter().filter(|id| Some(id.as_str()) != except).collect())
}

/// `AssignSpeakersModel`'s enrollment outcomes.
#[derive(Debug, Clone, PartialEq)]
pub enum EnrollOutcome {
    Stored(i64),
    NoUsableSample,
    Disabled,
    Failed(String),
}
impl EnrollOutcome {
    pub fn text(&self) -> String {
        match self {
            EnrollOutcome::Stored(1) => "1 sample stored".into(),
            EnrollOutcome::Stored(n) => format!("{n} samples stored"),
            EnrollOutcome::NoUsableSample => "No usable voice sample was found in this meeting".into(),
            EnrollOutcome::Disabled => "Speaker identification is turned off.".into(),
            EnrollOutcome::Failed(text) => text.clone(),
        }
    }
}

/// What launch reconciliation did: `ReconciliationSummary` and `TranscriptReconciler.Summary`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Recovery {
    pub meetings_found: i64,
    pub recovered: i64,
    pub unrecoverable: i64,
    pub transcripts_interrupted: i64,
    pub transcripts_failed: i64,
    /// `finalizing` rows of finished meetings, which Swift resumes automatically.
    pub transcripts_to_resume: i64,
    pub orphans_reconstructed: i64,
    /// Rows and directory entries past the per-launch bound.
    pub deferred: i64,
}
impl Recovery {
    /// The two notices Swift publishes after reconciling.
    pub fn notices(&self) -> Vec<String> {
        let mut out = vec![];
        if self.meetings_found > 0 || self.orphans_reconstructed > 0 || self.deferred > 0 {
            let mut parts = vec![];
            if self.recovered > 0 {
                parts.push(format!("{} meeting{} recovered", self.recovered, if self.recovered == 1 { "" } else { "s" }));
            }
            if self.unrecoverable > 0 {
                parts.push(format!("{} with audio that could not be made playable", self.unrecoverable));
            }
            if self.orphans_reconstructed > 0 {
                parts.push(format!("{} found without a record", self.orphans_reconstructed));
            }
            let failed = self.meetings_found - self.recovered - self.unrecoverable;
            if failed > 0 {
                parts.push(format!("{failed} marked failed"));
            }
            if self.deferred > 0 {
                parts.push(format!("{} deferred to the next launch", self.deferred));
            }
            out.push(parts.join(", "));
        }
        let retryable = self.transcripts_interrupted + self.transcripts_failed;
        if retryable > 0 {
            out.push(if retryable == 1 { "1 transcript was interrupted; choose Retry to finish it".to_string() } else { format!("{retryable} transcripts were interrupted; choose Retry to finish them") });
        }
        out
    }
}

/// Old speaker to new speaker from turn overlap (`carry_ovl0.50_ratio2_v1`): at least half
/// of the old speaker's speech, twice the next best, the new speaker's strict best, and unclaimed.
fn carry_map(old: &[(String, String, i64)], new: &[(String, String)], overlaps: &HashMap<(String, String), i64>) -> HashMap<String, String> {
    let overlap = |o: &str, n: &str| overlaps.get(&(o.to_string(), n.to_string())).copied().unwrap_or(0);
    let mut proposed = HashMap::new();
    for (id, track, speech) in old.iter().filter(|s| s.2 > 0) {
        let mut candidates: Vec<(&String, i64)> = new.iter().filter(|n| n.1 == *track).map(|n| (&n.0, overlap(id, &n.0))).collect();
        candidates.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
        let Some(&(best, ms)) = candidates.first().filter(|c| c.1 > 0) else { continue };
        let next = candidates.get(1).map_or(0, |c| c.1);
        let alone = old.iter().filter(|r| r.1 == *track && r.0 != *id).all(|r| overlap(&r.0, best) < ms);
        if ms * 100 >= 50 * speech && ms * 100 >= 200 * next && alone {
            proposed.insert(id.clone(), best.clone());
        }
    }
    let targets: Vec<String> = proposed.values().cloned().collect();
    proposed.retain(|_, n| targets.iter().filter(|t| *t == n).count() == 1);
    proposed
}

/// A rerun inherits the superseded run's names, merges and segment corrections; what does not
/// map safely becomes a `needs_review` row. Call inside the transaction that adopts `run`.
// ponytail: all turns in memory and no identity rows; the diarization worker that calls this
// brings Swift's paged sweep and `carryManualIdentities` when it lands.
pub fn carry_over(db: &Db, meeting: &str, previous: &str, run: &str, now: i64) -> Res<()> {
    let c = &db.conn;
    type Row6 = (String, Option<String>, String, i64, Option<String>, Option<String>, i64);
    let speakers = |where_run: Option<&str>| -> Res<Vec<Row6>> {
        Ok(c.prepare("SELECT id,track,source,label_ordinal,display_name,merged_into,speech_ms FROM meeting_speakers WHERE meeting_id=?1 AND run_id IS ?2 ORDER BY id")?
            .query_map(params![meeting, where_run], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)))?
            .collect::<Result<_, _>>()?)
    };
    let (old, new, manual) = (speakers(Some(previous))?, speakers(Some(run))?, speakers(None)?);
    let mut overlaps: HashMap<(String, String), i64> = HashMap::new();
    let mut stmt = c.prepare(
        "SELECT a.speaker_id,b.speaker_id,sum(min(a.end_ms,b.end_ms)-max(a.start_ms,b.start_ms)) FROM speaker_turns a JOIN speaker_turns b
         ON a.track=b.track AND a.start_ms<b.end_ms AND b.start_ms<a.end_ms WHERE a.run_id=?1 AND b.run_id=?2 AND a.speaker_id IS NOT NULL AND b.speaker_id IS NOT NULL GROUP BY 1,2",
    )?;
    for row in stmt.query_map([previous, run], |r| Ok(((r.get(0)?, r.get(1)?), r.get(2)?)))? {
        let (pair, ms) = row?;
        overlaps.insert(pair, ms);
    }
    let old_keys: Vec<_> = old.iter().filter_map(|s| s.1.clone().map(|t| (s.0.clone(), t, s.6))).collect();
    let new_keys: Vec<_> = new.iter().filter_map(|s| s.1.clone().map(|t| (s.0.clone(), t))).collect();
    let mapping = carry_map(&old_keys, &new_keys, &overlaps);
    let is_manual = |id: &str| manual.iter().any(|m| m.0 == id);
    let target = |id: &str| if is_manual(id) { Some(id.to_string()) } else { mapping.get(id).cloned() };
    let in_room: bool = c.query_row("SELECT in_room FROM diarization_runs WHERE id=?1", [previous], |r| r.get(0))?;
    let label = |s: &Row6| speaker_label(&s.2, s.3, s.4.as_deref(), in_room);
    let correct = |kind: &str, speaker: Option<&str>, to: Option<&str>, segment: Option<&str>, before: Option<&str>, after: Option<&str>, review: bool| -> Res<()> {
        c.execute(
            "INSERT INTO speaker_corrections (id,meeting_id,run_id,kind,speaker_id,target_speaker_id,segment_id,previous_value,new_value,needs_review,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![new_id(), meeting, run, kind, speaker, to, segment, before, after, review, now],
        )?;
        Ok(())
    };
    for s in old.iter().filter(|s| s.4.is_some()) {
        if let Some(mapped) = mapping.get(&s.0) {
            c.execute("UPDATE meeting_speakers SET display_name=?1 WHERE id=?2 AND display_name IS NULL", params![s.4, mapped])?;
            correct("rename", Some(mapped), None, None, None, s.4.as_deref(), false)?;
        } else {
            correct("rename", Some(&s.0), None, None, None, s.4.as_deref(), true)?;
        }
    }
    let everyone: Vec<&Row6> = old.iter().chain(manual.iter()).collect();
    for s in &everyone {
        let Some(root) = s.5.as_deref() else { continue };
        if is_manual(&s.0) && is_manual(root) {
            continue;
        }
        match (target(&s.0), target(root)) {
            (Some(member), Some(into)) if member != into => {
                c.execute("UPDATE meeting_speakers SET merged_into=?1 WHERE id=?2", params![into, member])?;
                correct("merge", Some(&member), Some(&into), None, None, None, false)?;
            }
            _ => {
                if is_manual(&s.0) {
                    c.execute("UPDATE meeting_speakers SET merged_into=NULL WHERE id=?1", [&s.0])?;
                }
                let root_label = everyone.iter().find(|r| r.0 == root).map(|r| label(r)).unwrap_or_default();
                correct("merge", Some(&s.0), Some(root), None, Some(&root_label), Some(&label(s)), true)?;
            }
        }
    }
    let pass = |id: &str| c.query_row("SELECT transcript_pass_id FROM diarization_runs WHERE id=?1", [id], |r| r.get::<_, String>(0));
    let same_pass = pass(previous)? == pass(run)?;
    let manual_rows: Vec<(String, String, Option<String>)> = c
        .prepare("SELECT segment_id,manual_kind,manual_speaker_id FROM speaker_assignments WHERE run_id=?1 AND manual_kind IS NOT NULL ORDER BY segment_id")?
        .query_map([previous], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<Result<_, _>>()?;
    for (segment, kind, speaker) in manual_rows {
        let into = speaker.as_deref().and_then(target);
        if same_pass && (kind == "unknown" || into.is_some()) {
            let changed = c.execute(
                "UPDATE speaker_assignments SET manual_kind=?1,manual_speaker_id=?2,manual_at=?3 WHERE run_id=?4 AND segment_id=?5",
                params![kind, into, now, run, segment],
            )?;
            if changed == 1 {
                correct("segment", None, into.as_deref(), Some(&segment), None, into.is_none().then_some("unknown"), false)?;
            }
        } else {
            let text = speaker.as_deref().and_then(|id| everyone.iter().find(|r| r.0 == id)).map_or("Unknown".to_string(), |s| label(s));
            correct("segment", speaker.as_deref(), None, Some(&segment), None, Some(&text), true)?;
        }
    }
    Ok(())
}

/// Runs once per launch, before Start is enabled: `MeetingReconciler`, then `TranscriptReconciler`,
/// then the speaker and summary run reconcilers, each bounded to 100 rows. Nothing is deleted.
/// The caller holds `.instance.lock`, the same flock Swift takes, so no writer owns an open segment.
pub fn reconcile_launch(db: &Db, root: &Path, now: i64) -> Res<Recovery> {
    let c = &db.conn;
    let mut out = Recovery::default();
    let active: i64 = c.query_row("SELECT count(*) FROM meetings WHERE state IN ('created','preparing','recording','paused','finalizing')", [], |r| r.get(0))?;
    out.deferred += (active - 100).max(0);
    let rows: Vec<ActiveRow> = c
        .prepare("SELECT id,state,finalization_stage,stopped_at,updated_at FROM meetings WHERE state IN ('created','preparing','recording','paused','finalizing') ORDER BY created_at,id LIMIT 100")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?
        .collect::<Result<_, _>>()?;
    for row in &rows {
        out.meetings_found += 1;
        // As Swift: one meeting's failure doesn't stop the others. The row stays active, so the next launch retries it.
        match reconcile_active(db, root, row, now) {
            Ok(Some(true)) => out.recovered += 1,
            Ok(Some(false)) => out.unrecoverable += 1,
            Ok(None) | Err(_) => {}
        }
    }
    reconstruct_orphans(db, root, now, &mut out)?;
    let transcripts: Vec<(String, String, i64, i64)> = c
        .prepare("SELECT meeting_id,state,segment_count,revision FROM meeting_transcriptions WHERE state IN ('pending','live','finalizing') ORDER BY updated_at LIMIT 100")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .collect::<Result<_, _>>()?;
    for (id, state, count, revision) in transcripts {
        let Some((meeting_state, stage)): Option<(String, Option<String>)> = c.query_row("SELECT state,finalization_stage FROM meetings WHERE id=?1", [&id], |r| Ok((r.get(0)?, r.get(1)?))).optional()? else { continue };
        if !is_terminal(&meeting_state) {
            continue;
        }
        let failed = meeting_state == "failed";
        if state == "finalizing" && !failed {
            out.transcripts_to_resume += 1;
            continue;
        }
        let target = if failed { "failed" } else { "interrupted" };
        c.execute(
            "UPDATE meeting_transcriptions SET state=?1,live_state=NULL,failure_category='finalization_interrupted',failure_detail=?2,updated_at=?3,revision=revision+1 WHERE meeting_id=?4 AND revision=?5",
            params![target, format!("found={state}"), now, id, revision],
        )?;
        outcome(c, &id, now, &meeting_state, stage.as_deref(), [count, 0, 0, 0], false, &format!("transcript:{state}->{target} finalization_interrupted"))?;
        if failed {
            out.transcripts_failed += 1;
        } else {
            out.transcripts_interrupted += 1;
        }
    }
    // A pending speaker run waits for the queue; Swift hands it back, so it stays pending here.
    for table in ["diarization_runs", "identification_runs"] {
        c.execute(&format!("UPDATE {table} SET state='interrupted',failure_category='interrupted',completed_at=?1 WHERE id IN (SELECT id FROM {table} WHERE state='running' ORDER BY created_at LIMIT 100)"), [now])?;
    }
    c.execute("UPDATE analysis_runs SET state='interrupted',completed_at=?1,failure_category='interrupted',duration_ms=max(0,?1-coalesce(started_at,created_at)) WHERE id IN (SELECT id FROM analysis_runs WHERE state IN ('pending','running') ORDER BY created_at LIMIT 100)", [now])?;
    Ok(out)
}
type ActiveRow = (String, String, Option<String>, Option<i64>, i64);
#[derive(Default)]
struct Tally {
    recovered: i64,
    unrecoverable: i64,
    missing: i64,
    truncated: i64,
}
/// `MeetingReconciler.reconcile`. None marked failed; otherwise whether some segment ended up playable.
fn reconcile_active(db: &Db, root: &Path, (id, found, stage, stopped, updated): &ActiveRow, now: i64) -> Res<Option<bool>> {
    let tx = db.conn.unchecked_transaction()?;
    let c: &Connection = &tx;
    let tracks: Vec<(String, String)> = c.prepare("SELECT id,health FROM meeting_tracks WHERE meeting_id=?1")?.query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
    let mut per_track = vec![];
    for (track, health) in tracks {
        let segments: Vec<ActiveSegment> = c
            .prepare("SELECT id,state,relative_path,duration_ms,byte_size,close_reason,dropped_frames FROM meeting_segments WHERE track_id=?1 ORDER BY sequence")?
            .query_map([&track], |r| Ok(ActiveSegment { id: r.get(0)?, state: r.get(1)?, path: r.get(2)?, duration: r.get(3)?, bytes: r.get(4)?, close: r.get(5)?, dropped: r.get(6)? }))?
            .collect::<Result<_, _>>()?;
        per_track.push((track, health, segments));
    }
    if found == "created" || per_track.iter().all(|t| t.2.is_empty()) {
        c.execute("UPDATE meetings SET state='failed',failure_reason='not_running_at_last_state',failure_detail=?1,updated_at=?2,revision=revision+1 WHERE id=?3", params![format!("found={found}"), now, id])?;
        recompute_durations(c, id, now)?;
        outcome(c, id, now, found, stage.as_deref(), [0; 4], false, "no media; marked failed")?;
        tx.commit()?;
        return Ok(None);
    }
    let mut tally = Tally::default();
    let mut any_validated = false;
    for (track, health, segments) in &per_track {
        let mut validated = 0;
        for segment in segments {
            if recover_segment(c, root, track, segment, &mut tally)? {
                validated += 1;
            }
        }
        any_validated |= validated > 0;
        if validated == 0 && !segments.is_empty() && (health == "healthy" || health == "failed") {
            c.execute("UPDATE meeting_tracks SET health='unrecoverable',failure_reason=COALESCE(failure_reason,'unrecoverable_media'),failed_at=COALESCE(failed_at,?1) WHERE id=?2", params![now, track])?;
        } else if health == "healthy" {
            c.execute("UPDATE meeting_tracks SET health='finalized' WHERE id=?1", [track])?;
        }
    }
    c.execute(
        "UPDATE meetings SET state='interrupted',failure_reason='not_running_at_last_state',failure_detail=?1,completed_at=?2,updated_at=?2,revision=revision+1 WHERE id=?3",
        params![format!("found={found} stage={}", stage.as_deref().unwrap_or("none")), now, id],
    )?;
    // Swift's effect order: the warnings read durations before the stop time and the pause close land.
    recompute_durations(c, id, now)?;
    let recorded: i64 = c.query_row("SELECT recorded_ms FROM meetings WHERE id=?1", [id], |r| r.get(0))?;
    c.execute("UPDATE meeting_tracks SET duration_warning=CASE WHEN dropped_frames>0 OR abs(total_duration_ms-?1)>?2 THEN 1 ELSE 0 END WHERE meeting_id=?3", params![recorded, (recorded / 100).max(2000), id])?;
    if stopped.is_none() {
        c.execute("UPDATE meetings SET stopped_at=?1 WHERE id=?2", params![updated, id])?;
    }
    let paused = c.execute("UPDATE meeting_pauses SET ended_at=max(started_at,?1),closed_by='reconciliation' WHERE meeting_id=?2 AND ended_at IS NULL", params![updated, id])? > 0;
    recompute_durations(c, id, now)?;
    let summary = format!("recovered={} unrecoverable={} missing={} truncated={}", tally.recovered, tally.unrecoverable, tally.missing, tally.truncated);
    outcome(c, id, now, found, stage.as_deref(), [tally.recovered, tally.unrecoverable, tally.missing, tally.truncated], paused, &summary)?;
    tx.commit()?;
    Ok(Some(any_validated))
}
struct ActiveSegment {
    id: String,
    state: String,
    path: String,
    duration: i64,
    bytes: i64,
    close: Option<String>,
    dropped: i64,
}
/// `MeetingStorageRoot.isValid`: stays relative to the root.
fn valid_relative_path(path: &str) -> bool {
    !path.is_empty() && !path.starts_with('/') && !path.contains('\0') && path.split('/').all(|p| !p.is_empty() && p != "." && p != "..")
}
/// `MeetingReconciler.recover`: true when the segment ends up finalized with playable frames.
fn recover_segment(c: &Connection, root: &Path, track: &str, s: &ActiveSegment, tally: &mut Tally) -> Res<bool> {
    let final_path = s.path.strip_suffix(".part").unwrap_or(&s.path);
    if s.state == "unrecoverable" || !valid_relative_path(final_path) || !valid_relative_path(&s.path) {
        return Ok(false);
    }
    let last = root.join(final_path);
    let source = if s.state == "finalized" {
        if last.exists() {
            if s.path != final_path {
                finalize_segment(c, track, s, s.duration, s.bytes, final_path, s.close.as_deref().unwrap_or("recovered"))?;
            }
            return Ok(true);
        }
        root.join(format!("{final_path}.part"))
    } else if root.join(&s.path).exists() {
        root.join(&s.path)
    } else {
        last.clone() // Renamed but the row never caught up: validate the final file in place.
    };
    let unrecoverable = |reason: &str, note: Option<String>| -> Res<bool> {
        c.execute("UPDATE meeting_segments SET state='unrecoverable',failure_reason=?1,recovery_note=?2 WHERE id=?3", params![reason, note, s.id])?;
        track_totals(c, track)?;
        Ok(false)
    };
    if !source.exists() {
        tally.missing += 1;
        return unrecoverable("file_missing", None);
    }
    let Ok(scan) = adts_scan(&source) else {
        tally.missing += 1;
        return unrecoverable("file_missing", None);
    };
    if scan.frames == 0 {
        tally.unrecoverable += 1;
        return unrecoverable("unrecoverable_media", Some(format!("frames=0 bytes={}", scan.trailing)));
    }
    // Only the bytes after the last complete frame go, and only when a rename or a torn tail asks for it.
    if (source != last || scan.trailing > 0) && truncate_and_rename(&source, &last, scan.bytes).is_err() {
        tally.unrecoverable += 1;
        return unrecoverable("unrecoverable_media", Some("rename failed".into()));
    }
    finalize_segment(c, track, s, scan.duration_ms(), scan.bytes as i64, final_path, "recovered")?;
    c.execute("UPDATE meeting_segments SET recovery_note=?1 WHERE id=?2", params![format!("truncated={} frames={}", scan.trailing, scan.frames), s.id])?;
    tally.recovered += 1;
    tally.truncated += scan.trailing as i64;
    Ok(true)
}
fn finalize_segment(c: &Connection, track: &str, s: &ActiveSegment, duration: i64, bytes: i64, path: &str, reason: &str) -> Res<()> {
    c.execute(
        "UPDATE meeting_segments SET state='finalized',duration_ms=?1,byte_size=?2,relative_path=?3,close_reason=?4,dropped_frames=?5 WHERE id=?6",
        params![duration.max(0), bytes.max(0), path, reason, s.dropped.max(0), s.id],
    )?;
    track_totals(c, track)
}
/// `MeetingStore.recomputeTrackTotals`.
fn track_totals(c: &Connection, track: &str) -> Res<()> {
    c.execute(
        "UPDATE meeting_tracks SET total_duration_ms=(SELECT COALESCE(SUM(duration_ms),0) FROM meeting_segments WHERE track_id=?1 AND state='finalized'),
         total_bytes=(SELECT COALESCE(SUM(byte_size),0) FROM meeting_segments WHERE track_id=?1),
         dropped_frames=(SELECT COALESCE(SUM(dropped_frames),0) FROM meeting_segments WHERE track_id=?1) WHERE id=?1",
        [track],
    )?;
    Ok(())
}
/// `MeetingStore.recomputeDurations`: every pause clamped to the wall-clock window, an open one included.
fn recompute_durations(c: &Connection, id: &str, now: i64) -> Res<()> {
    let (started, stopped): (Option<i64>, Option<i64>) = c.query_row("SELECT started_at,stopped_at FROM meetings WHERE id=?1", [id], |r| Ok((r.get(0)?, r.get(1)?)))?;
    let Some(started) = started else { return Ok(()) };
    let end = started.max(stopped.unwrap_or(now));
    let paused: i64 = c.query_row(
        "SELECT COALESCE(SUM(max(0,min(COALESCE(ended_at,?1),?1)-max(started_at,?2))),0) FROM meeting_pauses WHERE meeting_id=?3",
        params![end, started, id],
        |r| r.get(0),
    )?;
    c.execute("UPDATE meetings SET wall_clock_ms=?1,recorded_ms=?2 WHERE id=?3", params![end - started, (end - started - paused).max(0), id])?;
    Ok(())
}
/// `ADTSValidator.scan`: complete frames, their length in bytes, the sample rate and channels.
#[derive(Debug, Default, PartialEq, Eq)]
struct AdtsScan {
    frames: i64,
    bytes: u64,
    trailing: u64,
    sample_rate: i64,
    channels: i64,
}
impl AdtsScan {
    fn duration_ms(&self) -> i64 {
        if self.sample_rate > 0 { self.frames * 1024 * 1000 / self.sample_rate } else { 0 }
    }
}
/// Sync word, MPEG-4, layer 0, AAC-LC and a frame longer than its header: (length, rate, channels).
fn adts_header(b: &[u8; 7]) -> Option<(u64, i64, i64)> {
    const RATES: [i64; 16] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350, 0, 0, 0];
    if b[0] != 0xFF || b[1] & 0xF6 != 0xF0 || b[2] >> 6 != 1 {
        return None;
    }
    let rate = RATES[((b[2] >> 2) & 0x0F) as usize];
    let channels = (((b[2] & 1) << 2) | (b[3] >> 6)) as i64;
    let length = ((b[3] as u64 & 3) << 11) | ((b[4] as u64) << 3) | (b[5] as u64 >> 5);
    (rate > 0 && channels > 0 && length > 7).then_some((length, rate, channels))
}
/// Stops at the first inconsistent header or at the end. Reads headers only and refuses a symlink.
fn adts_scan(path: &Path) -> std::io::Result<AdtsScan> {
    use std::io::{Read, Seek, SeekFrom};
    let meta = std::fs::symlink_metadata(path)?;
    if !meta.is_file() {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    let mut file = std::fs::File::open(path)?;
    let mut scan = AdtsScan::default();
    let mut header = [0u8; 7];
    while meta.len() - scan.bytes >= 7 {
        file.seek(SeekFrom::Start(scan.bytes))?;
        file.read_exact(&mut header)?;
        let Some((length, rate, channels)) = adts_header(&header) else { break };
        if scan.frames > 0 && (rate, channels) != (scan.sample_rate, scan.channels) {
            break;
        }
        if scan.frames == 0 {
            (scan.sample_rate, scan.channels) = (rate, channels);
        }
        if meta.len() - scan.bytes < length {
            break;
        }
        scan.bytes += length;
        scan.frames += 1;
    }
    scan.trailing = meta.len() - scan.bytes;
    Ok(scan)
}
/// `MeetingReconciler.parse`: `mic-0001.aac` or `system-0001.aac.part`.
fn parse_segment_name(name: &str) -> Option<(&'static str, i64, bool)> {
    let (name, part) = name.strip_suffix(".part").map_or((name, false), |n| (n, true));
    let name = name.strip_suffix(".aac")?;
    for (kind, prefix) in [("microphone", "mic-"), ("system", "system-")] {
        if let Some(digits) = name.strip_prefix(prefix) {
            let sequence = digits.parse::<i64>().ok().filter(|s| digits.len() == 4 && digits.bytes().all(|b| b.is_ascii_digit()) && *s >= 1)?;
            return Some((kind, sequence, part));
        }
    }
    None
}
/// Swift's `UUID(uuidString:)` shape, returned in its uppercase form.
fn parse_uuid(name: &str) -> Option<String> {
    let shape = name.len() == 36 && name.bytes().enumerate().all(|(i, b)| if matches!(i, 8 | 13 | 18 | 23) { b == b'-' } else { b.is_ascii_hexdigit() });
    shape.then(|| name.to_uppercase())
}
/// `FileSegmentWriter.truncateAndRename`: refuses a symlink and fsyncs the file and its folder.
fn truncate_and_rename(from: &Path, to: &Path, length: u64) -> std::io::Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(from)?;
    file.set_len(length)?;
    file.sync_all()?;
    std::fs::rename(from, to)?;
    #[cfg(unix)]
    if let Some(folder) = to.parent() {
        std::fs::File::open(folder)?.sync_all()?;
    }
    Ok(())
}
/// `reconstructOrphans`: a meeting folder with no row becomes an `interrupted` meeting.
/// Nothing is deleted. 1,000 directory entries a launch; the rest are deferred.
fn reconstruct_orphans(db: &Db, root: &Path, now: i64, out: &mut Recovery) -> Res<()> {
    let Ok(listing) = std::fs::read_dir(root) else { return Ok(()) };
    let mut entries: Vec<String> = listing.flatten().filter_map(|e| e.file_name().into_string().ok()).collect();
    entries.sort();
    out.deferred += (entries.len() as i64 - 1000).max(0);
    for entry in entries.iter().take(1000) {
        let Some(id) = parse_uuid(entry) else { continue };
        let known: bool = db.conn.query_row("SELECT EXISTS(SELECT 1 FROM meetings WHERE upper(id)=?1)", [&id], |r| r.get(0))?;
        let dir = root.join(entry);
        let Ok(meta) = std::fs::symlink_metadata(&dir) else { continue };
        if known || !meta.is_dir() {
            continue;
        }
        let created = meta.modified().ok().and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok()).map_or(now, |d| d.as_millis() as i64);
        if reconstruct_orphan(db, &id, &dir, created, now).is_ok() {
            out.orphans_reconstructed += 1;
        }
    }
    Ok(())
}
fn reconstruct_orphan(db: &Db, id: &str, dir: &Path, created: i64, now: i64) -> Res<()> {
    let mut names: Vec<String> = std::fs::read_dir(dir).map_or(vec![], |l| l.flatten().filter_map(|e| e.file_name().into_string().ok()).collect());
    names.sort();
    let tx = db.conn.unchecked_transaction()?;
    let (mic, sys) = (new_id(), new_id());
    let (mut offsets, mut totals, mut channels) = ([0i64; 2], [0i64; 2], [1i64, 2]);
    let (mut validated, mut seen) = ([false; 2], [false; 2]);
    let (mut recovered, mut unrecoverable, mut truncated, mut files) = (0i64, 0i64, 0i64, 0i64);
    let mut segments = vec![];
    for name in &names {
        let Some((kind, sequence, part)) = parse_segment_name(name) else { continue };
        let k = (kind == "system") as usize;
        seen[k] = true;
        files += 1;
        let prefix = if k == 0 { "mic" } else { "system" };
        let final_name = format!("{prefix}-{sequence:04}.aac");
        let path = dir.join(name);
        let scan = adts_scan(&path).ok().filter(|s| s.frames > 0);
        let usable = scan.as_ref().is_some_and(|s| !(part || s.trailing > 0) || truncate_and_rename(&path, &dir.join(&final_name), s.bytes).is_ok());
        let note = scan.is_none().then(|| "reconstructed frames=0".to_string());
        let reason = if sequence == 1 { "start" } else { "resume" };
        let track = if k == 0 { &mic } else { &sys };
        match scan.filter(|_| usable) {
            Some(s) => {
                truncated += s.trailing as i64;
                recovered += 1;
                validated[k] = true;
                if k == 1 {
                    channels[1] = s.channels.clamp(1, 2);
                }
                segments.push((new_id(), track.clone(), sequence, format!("{id}/{final_name}"), "finalized", offsets[k], s.duration_ms(), s.bytes as i64, reason, Some("recovered"), Some(format!("reconstructed truncated={}", s.trailing)), None));
                offsets[k] += s.duration_ms();
                totals[k] += s.bytes as i64;
            }
            None => {
                unrecoverable += 1;
                segments.push((new_id(), track.clone(), sequence, format!("{id}/{name}"), "unrecoverable", offsets[k], 0, 0, reason, None, note, Some("unrecoverable_media")));
            }
        }
    }
    let c = &tx;
    c.execute(
        "INSERT INTO meetings (id,state,created_at,started_at,stopped_at,completed_at,wall_clock_ms,recorded_ms,failure_reason,failure_detail,updated_at,revision) VALUES (?1,'interrupted',?2,?2,?2,?3,0,?4,'record_missing','reconstructed',?3,0)",
        params![id, created, now, offsets[0].max(offsets[1])],
    )?;
    c.execute("INSERT INTO meeting_notes (meeting_id,text,author,updated_at,revision) VALUES (?1,'','user',?2,0)", params![id, now])?;
    c.execute("INSERT INTO meeting_diarization (meeting_id,in_room,updated_at,revision) VALUES (?1,0,?2,0)", params![id, now])?;
    c.execute("INSERT INTO meeting_identification (meeting_id,updated_at) VALUES (?1,?2)", params![id, now])?;
    c.execute("INSERT INTO meeting_analysis (meeting_id,updated_at,revision) VALUES (?1,?2,0)", params![id, now])?;
    for (k, (track, kind, bitrate)) in [(&mic, "microphone", 64000), (&sys, "system", 96000)].into_iter().enumerate() {
        let (health, reason, failed) = match (validated[k], seen[k]) {
            (true, _) => ("finalized", None, None),
            (false, true) => ("unrecoverable", Some("unrecoverable_media"), Some(now)),
            (false, false) => ("unrecoverable", Some("file_missing"), Some(now)),
        };
        c.execute(
            "INSERT INTO meeting_tracks (id,meeting_id,type,codec,container,sample_rate,channel_count,bitrate,health,failure_reason,failed_at,total_duration_ms,total_bytes) VALUES (?1,?2,?3,'aac_lc','adts',48000,?4,?5,?6,?7,?8,?9,?10)",
            params![track, id, kind, channels[k], bitrate, health, reason, failed, offsets[k], totals[k]],
        )?;
    }
    for (segment, track, sequence, path, state, start, duration, bytes, reason, close, note, failure) in segments {
        c.execute(
            "INSERT INTO meeting_segments (id,track_id,sequence,relative_path,state,start_offset_ms,duration_ms,byte_size,started_at,host_start_ns,open_reason,close_reason,recovery_note,failure_reason) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,0,?10,?11,?12,?13)",
            params![segment, track, sequence, path, state, start, duration, bytes, created, reason, close, note, failure],
        )?;
    }
    c.execute(
        "INSERT INTO meeting_recovery_outcomes (id,meeting_id,ran_at,found_state,segments_recovered,segments_unrecoverable,bytes_truncated,summary) VALUES (?1,?2,?3,'interrupted',?4,?5,?6,?7)",
        params![new_id(), id, now, recovered, unrecoverable, truncated, format!("record missing; files={files}")],
    )?;
    tx.commit()?;
    Ok(())
}
/// `counts`: segments recovered, unrecoverable and missing, then bytes truncated.
#[allow(clippy::too_many_arguments)]
fn outcome(c: &Connection, id: &str, now: i64, found: &str, stage: Option<&str>, counts: [i64; 4], paused: bool, summary: &str) -> Res<()> {
    c.execute(
        "INSERT INTO meeting_recovery_outcomes (id,meeting_id,ran_at,found_state,found_stage,segments_recovered,segments_unrecoverable,segments_missing,bytes_truncated,pause_closed,summary) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
        params![new_id(), id, now, found, stage, counts[0], counts[1], counts[2], counts[3], paused as i64, summary],
    )?;
    Ok(())
}

pub fn seed(db: &Db) {
    let c = &db.conn;
    let now = now_ms();
    let day = 86_400_000;
    c.execute("INSERT OR IGNORE INTO transcript_usage (id, text_bytes, segment_rows, schema_version) VALUES (1,0,0,1)", []).unwrap();

    // Today: the full picture. Final transcript, speakers, identity and a summary.
    let m = SEED_FULL;
    let created = now - 3_600_000;
    insert_meeting(c, m, "completed", Some("Lamp prototype review"), created, 754_000, None, "local");
    c.execute("UPDATE meeting_notes SET text=?1 WHERE meeting_id=?2", params![SEED_NOTES, m]).unwrap();
    let (mic, sys) = (seed_uuid(0xA1), seed_uuid(0xA2));
    insert_track(c, &mic, m, "microphone", "finalized", None, 0, 0, 754_000);
    insert_track(c, &sys, m, "system", "finalized", None, 0, 0, 754_000);
    insert_file_row(c, &mic, m, 1, 0, 400_000, "start", Some("Built-in Microphone"), created);
    insert_file_row(c, &mic, m, 2, 400_000, 354_000, "device_changed", Some("Desk USB Microphone"), created + 400_000);
    insert_file_row(c, &sys, m, 1, 0, 754_000, "start", None, created);
    let pass = seed_uuid(0xB0);
    let run = seed_uuid(0xB1);
    let (you, s1, s2, s3) = (seed_uuid(0xC0), seed_uuid(0xC1), seed_uuid(0xC2), seed_uuid(0xC3));
    let bytes: i64 = LINES.iter().map(|l| l.len() as i64).sum();
    insert_transcription(c, m, "final", Some(&pass), None, LINES.len() as i64, bytes, now, "local");
    // Records the decoded language, so Swift and Rust resolve the same one without detection.
    c.execute("UPDATE meeting_transcriptions SET pipeline_version='fixture+lang_en_prompt_v1' WHERE meeting_id=?1", [m]).unwrap();
    c.execute("UPDATE transcript_usage SET text_bytes=text_bytes+?1, segment_rows=segment_rows+?2 WHERE id=1", params![bytes, LINES.len() as i64]).unwrap();
    c.execute(
        "INSERT INTO diarization_runs (id, meeting_id, transcript_pass_id, state, \"trigger\", in_room, engine, model_id, model_revision, model_manifest_hash, pipeline_version, created_at, completed_at, inferred_speaker_count, inference_path)
         VALUES (?1,?2,?3,'succeeded','automatic',0,'fixture','fixture','1',?4,'1',?5,?5,4,'server')",
        params![run, m, pass, HASH, now],
    )
    .unwrap();
    c.execute("UPDATE meeting_diarization SET accepted_run_id=?1, current_run_id=?1 WHERE meeting_id=?2", params![run, m]).unwrap();
    for (id, key, source, track, ordinal, color, name) in [
        (&you, 0, "local", "microphone", 1, 0, None),
        (&s1, 1, "remote", "system", 1, 1, Some("Marta Kováčová")),
        (&s2, 2, "remote", "system", 2, 2, None),
        (&s3, 3, "remote", "system", 3, 3, None),
    ] {
        c.execute(
            "INSERT INTO meeting_speakers (id, meeting_id, run_id, cluster_key, source, track, origin, label_ordinal, color_index, display_name, first_ms, speech_ms)
             VALUES (?1,?2,?3,?4,?5,?6,'engine',?7,?8,?9,?4,120000)",
            params![id, m, run, key, source, track, ordinal, color, name],
        )
        .unwrap();
    }
    c.execute("INSERT INTO speaker_turns (run_id, speaker_id, track, start_ms, end_ms, overlapped) VALUES (?1,?2,'system',0,8000,0)", params![run, s2]).unwrap();
    let who = [&you, &s1, &you, &s2, &s1, &you, &s2, &s3, &s3, &you, &s1, &you];
    let mut ids = vec![];
    for (i, line) in LINES.iter().enumerate() {
        let id = seed_uuid(0xD00 + i as u64);
        let start = i as i64 * 60_000;
        let tracks = if who[i] == &you { "mic" } else { "system" };
        c.execute(
            "INSERT INTO transcript_segments (id, meeting_id, pass_id, finality, ordinal, stretch_sequence, start_ms, end_ms, window_index, timing_basis, raw_text, assembled_text, normalized_text, engine, model_id, model_revision, pipeline_version, analysis_tracks, created_at)
             VALUES (?1,?2,?3,'final',?4,1,?5,?6,?4,'word',?7,?7,?7,'whisper.cpp','fixture','1','1',?8,?9)",
            params![id, m, pass, i as i64, start, start + 58_000, line, tracks, now],
        )
        .unwrap();
        let kind = if i == 7 { "unknown" } else { "speaker" };
        let speaker = (i != 7).then_some(who[i]);
        c.execute("INSERT INTO speaker_assignments (run_id, segment_id, auto_kind, auto_speaker_id) VALUES (?1,?2,?3,?4)", params![run, id, kind, speaker]).unwrap();
        ids.push(id);
    }
    // Identity: a Possible match on Speaker 2, a known speaker for the picker.
    let (known_a, known_b) = (seed_uuid(0xE1), seed_uuid(0xE2));
    for (id, name) in [(&known_a, "Tomas Novak"), (&known_b, "Jana Horvathova")] {
        c.execute("INSERT INTO known_speakers (id, display_name, created_at, updated_at) VALUES (?1,?2,?3,?3)", params![id, name, now]).unwrap();
    }
    let idrun = seed_uuid(0xE3);
    c.execute(
        "INSERT INTO identification_runs (id, meeting_id, diarization_run_id, state, \"trigger\", engine, model_id, model_revision, model_manifest_hash, dimension, pipeline_version, threshold_policy, created_at, completed_at)
         VALUES (?1,?2,?3,'succeeded','automatic','fixture','fixture','1',?4,4,'1','fixture',?5,?5)",
        params![idrun, m, run, HASH, now],
    )
    .unwrap();
    c.execute("UPDATE meeting_identification SET accepted_run_id=?1, current_run_id=?1 WHERE meeting_id=?2", params![idrun, m]).unwrap();
    c.execute(
        "INSERT INTO identity_assignments (id, meeting_id, meeting_speaker_id, scope, known_speaker_id, state, origin, run_id, score, engine, model_id, model_revision, threshold_policy, second_known_speaker_id, created_at, updated_at)
         VALUES (?1,?2,?3,'self',?4,'possible','automatic_match',?5,0.7,'fixture','fixture','1','fixture',?6,?7,?7)",
        params![new_id(), m, s2, known_a, idrun, known_b, now],
    )
    .unwrap();
    // Summary with every chip kind.
    let arun = seed_uuid(0xF0);
    c.execute(
        "INSERT INTO analysis_runs (id, meeting_id, state, \"trigger\", evidence_version, transcript_pass_id, protocol_version, schema_version, backend_model, created_at, completed_at)
         VALUES (?1,?2,'succeeded','automatic',?3,?4,1,1,'fixture',?5,?5)",
        params![arun, m, EVIDENCE, pass, now - 600_000],
    )
    .unwrap();
    c.execute("UPDATE meeting_analysis SET accepted_run_id=?1, current_run_id=?1, accepted_evidence_version=?2 WHERE meeting_id=?3", params![arun, EVIDENCE, m]).unwrap();
    c.execute(
        "INSERT INTO analysis_summaries (run_id, meeting_id, text, language, whole_meeting) VALUES (?1,?2,?3,'en',1)",
        params![arun, m, "The team reviewed the desk lamp prototype. Marta will chase the second supplier, and Speaker 2 reported on the hinges.\n\nThe order waits until both quotes are in, and the packaging needs one more look."],
    )
    .unwrap();
    source(c, &arun, m, "summary", &arun, 0, Some(&ids[0]), None);
    let topic = seed_uuid(0xF1);
    c.execute(
        "INSERT INTO analysis_topics (id, run_id, meeting_id, ordinal, title, summary, bullets_json) VALUES (?1,?2,?3,0,'Hinges and supplier','Hinge samples and quotes.',?4)",
        params![topic, arun, m, "[\"Two hinge samples are too stiff\",\"The workshop can loosen the tolerance\",\"A second quote is due by the end of the week\"]"],
    )
    .unwrap();
    let item = |n: u64, kind: &str, ordinal: i64, text: &str, owner: (Option<&str>, Option<&str>, Option<&str>, Option<&str>, Option<&str>), due: (Option<&str>, Option<&str>, Option<&str>), src: Option<usize>| {
        let id = seed_uuid(0xF10 + n);
        let source_seg = (due.0.is_some() && due.0 != Some("absent")).then(|| ids[0].clone());
        c.execute(
            "INSERT INTO analysis_items (id, run_id, meeting_id, kind, ordinal, text, owner_kind, owner_speaker_id, owner_name, owner_certainty, ownership_state, due_state, due_date, due_original, due_source_segment_id)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
            params![id, arun, m, kind, ordinal, text, owner.0, owner.1, owner.2, owner.3, owner.4, due.0, due.1, due.2, source_seg],
        )
        .unwrap();
        if let Some(s) = src {
            source(c, &arun, m, "item", &id, 0, Some(&ids[s]), None);
        }
        id
    };
    let none = (None, None, None, None, None);
    let no_due = (None, None, None);
    item(0, "action_item", 0, "Ask the workshop to loosen the hinge tolerance", (Some("participant"), Some(&you), None, Some("local_user"), Some("explicit")), (Some("explicit_absolute"), Some("2026-11-06"), Some("Friday")), Some(2));
    item(1, "action_item", 1, "Chase the second supplier for a quote", (Some("participant"), Some(&s1), None, Some("local_name"), Some("explicit")), (Some("unresolved"), None, Some("soon")), Some(4));
    item(2, "action_item", 2, "Write up the drop test results", (Some("mentioned"), None, Some("Tomas Novak"), None, Some("supported")), (Some("absent"), None, None), Some(9));
    item(3, "action_item", 3, "Book the photo session", (Some("none"), None, None, None, Some("unresolved")), (Some("absent"), None, None), Some(10));
    item(4, "next_step", 0, "Pick the review up again on Friday", none, no_due, Some(11));
    item(5, "decision", 0, "Hold the order until both quotes are in", none, no_due, Some(5));
    item(6, "open_question", 0, "Is the cardboard packaging good enough for the shelf?", none, no_due, Some(6));
    item(7, "risk", 0, "Stiff hinges could delay the release date", none, no_due, Some(1));
    let notes_hash = sha256_hex(SEED_NOTES.split("\n\n").next().unwrap_or_default());
    source(c, &arun, m, "item", &seed_uuid(0xF15), 1, None, Some((1, &notes_hash)));
    // The summary was made from this exact evidence, so it starts out current.
    let current = current_evidence_version(db, m).unwrap().unwrap();
    c.execute("UPDATE analysis_runs SET evidence_version=?1 WHERE id=?2", params![current, arun]).unwrap();
    c.execute("UPDATE meeting_analysis SET accepted_evidence_version=?1 WHERE meeting_id=?2", params![current, m]).unwrap();

    // Yesterday: untitled, notes only, transcription off, with a track warning.
    let m = SEED_UNTITLED;
    insert_meeting(c, m, "completed", None, now - day, 120_000, None, "local");
    c.execute("UPDATE meeting_notes SET text='Call the supplier about delivery dates.' WHERE meeting_id=?1", [m]).unwrap();
    insert_track(c, &seed_uuid(0x201), m, "microphone", "finalized", None, 12, 1, 118_000);
    insert_transcription(c, m, "not_requested", None, None, 0, 0, now, "local");

    // Interrupted by an unclean exit, with a failed transcript.
    let m = SEED_INTERRUPTED;
    insert_meeting(c, m, "interrupted", Some("Budget call"), now - 2 * day, 300_000, Some("not_running_at_last_state"), "local");
    insert_track(c, &seed_uuid(0x301), m, "microphone", "failed", Some("device_lost"), 0, 0, 200_000);
    insert_transcription(c, m, "failed", None, Some("runtime_failure"), 0, 0, now, "local");

    // Copied from the phone; the transcript is pending.
    let m = SEED_IPHONE;
    insert_meeting(c, m, "completed", Some("Site visit notes"), now - 3 * day, 60_000, None, "iphone");
    insert_track(c, &seed_uuid(0x401), m, "microphone", "finalized", None, 0, 0, 60_000);
    insert_transcription(c, m, "pending", None, None, 0, 0, now, "local");

    // Failed at start.
    let m = SEED_FAILED;
    insert_meeting(c, m, "failed", Some("Standup"), now - 4 * day, 0, Some("both_sources_failed"), "local");
    insert_transcription(c, m, "failed", None, Some("model_unavailable"), 0, 0, now, "local");

    // Enough older rows that "Load older notes" appears.
    for i in 0..24u64 {
        let m = seed_uuid(0x1000 + i);
        insert_meeting(c, &m, "completed", Some(&format!("Weekly planning {}", i + 1)), now - (5 + i as i64) * day, 1_800_000, None, "local");
        insert_transcription(c, &m, "not_requested", None, None, 0, 0, now, "local");
    }
}
pub const SEED_FULL: &str = "11111111-1111-4111-8111-111111111111";
pub const SEED_UNTITLED: &str = "22222222-2222-4222-8222-222222222222";
pub const SEED_INTERRUPTED: &str = "33333333-3333-4333-8333-333333333333";
pub const SEED_IPHONE: &str = "44444444-4444-4444-8444-444444444444";
pub const SEED_FAILED: &str = "55555555-5555-4555-8555-555555555555";
const SEED_NOTES: &str = "Hinges: ask about a softer spring.\n\nPackaging idea: a paper sleeve instead of a box.";
fn seed_uuid(n: u64) -> String {
    format!("AAAAAAAA-0000-4000-8000-{n:012X}")
}
fn source(c: &Connection, run: &str, meeting: &str, kind: &str, target: &str, ordinal: i64, segment: Option<&str>, note: Option<(i64, &str)>) {
    c.execute(
        "INSERT INTO analysis_sources (run_id, meeting_id, target_kind, target_id, ordinal, source_kind, segment_id, note_ordinal, note_hash) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
        params![run, meeting, kind, target, ordinal, if segment.is_some() { "segment" } else { "note" }, segment, note.map(|n| n.0), note.map(|n| n.1)],
    )
    .unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> Db {
        let db = Db::memory();
        seed(&db);
        db
    }

    // parity: NOTE-063..NOTE-065 NOTE-067 NOTE-103 SUM-034 SUM-078
    #[test]
    fn dates_format_like_swift() {
        // 2026-09-24 14:05:00 UTC
        let ms = 1_790_258_700_000;
        assert_eq!(date_time_text(ms, 0), "24 Sep 2026, 14:05");
        assert_eq!(date_time_text(ms, 3600), "24 Sep 2026, 15:05");
        assert_eq!(fallback_title(ms, 0), "Meeting 24 Sep 2026, 14:05");
        let today = local_day(ms, 0);
        assert_eq!(day_heading(ms, 0, today), "TODAY, SEP 24");
        assert_eq!(day_heading(ms, 0, today + 1), "YESTERDAY, SEP 24");
        assert_eq!(day_heading(ms, 0, today + 9), "THU, SEP 24");
        assert_eq!(duration_text(754_000), "12:34");
        assert_eq!(duration_text(3_754_000), "1:02:34");
        assert_eq!(due_text("2026-09-21"), "21 Sep");
        assert_eq!(generated_text(ms, 0), "Generated 24 Sep, 14:05 · AI-generated");
    }

    #[test]
    fn hash_is_sha256() {
        assert_eq!(sha256_hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    #[test]
    fn ids_are_uppercase_v4() {
        let id = new_id();
        assert_eq!(id, id.to_uppercase());
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
        assert_ne!(id, new_id());
    }

    // The seed's phone note has a pending transcript, as Swift's reference shows after launch.
    // parity: MEET-091
    #[test]
    fn launch_reconciliation_ends_what_no_process_owns() {
        let db = db();
        let root = std::env::temp_dir().join("lf-reconcile-none");
        let state = |id: &str| db.conn.query_row("SELECT state,failure_category FROM meeting_transcriptions WHERE meeting_id=?1", [id], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?))).unwrap();
        assert_eq!(state(SEED_IPHONE).0, "pending");
        // An active row with no media, one with a missing file and an open pause, a finalizing transcript.
        db.conn.execute("UPDATE meetings SET state='recording',failure_reason=NULL,failure_detail=NULL,completed_at=NULL WHERE id=?1", [SEED_FAILED]).unwrap();
        db.conn.execute("UPDATE meetings SET state='paused' WHERE id=?1", [SEED_UNTITLED]).unwrap();
        db.conn.execute("INSERT INTO meeting_pauses (id,meeting_id,started_at,reason) VALUES ('p',?1,1,'user')", [SEED_UNTITLED]).unwrap();
        insert_file_row(&db.conn, &seed_uuid(0x201), SEED_UNTITLED, 1, 0, 1000, "start", None, 1);
        db.conn.execute("UPDATE meeting_transcriptions SET state='finalizing' WHERE meeting_id=?1", [SEED_FULL]).unwrap();
        db.conn.execute("UPDATE analysis_runs SET state='running' WHERE meeting_id=?1", [SEED_FULL]).unwrap();

        let r = reconcile_launch(&db, &root, 99).unwrap();
        assert_eq!((r.meetings_found, r.recovered, r.unrecoverable), (2, 0, 1));
        assert_eq!(r.transcripts_to_resume, 1);
        assert_eq!(state(SEED_FULL).0, "finalizing", "a finished meeting's finalization resumes");
        assert_eq!(state(SEED_IPHONE), ("interrupted".to_string(), Some("finalization_interrupted".to_string())));
        let m = |id| meeting(&db, id).unwrap().unwrap();
        assert_eq!((m(SEED_FAILED).state.as_str(), m(SEED_FAILED).failure_reason.as_deref()), ("failed", Some("not_running_at_last_state")));
        assert_eq!(m(SEED_UNTITLED).state, "interrupted");
        let closed: Option<String> = db.conn.query_row("SELECT closed_by FROM meeting_pauses WHERE id='p'", [], |r| r.get(0)).unwrap();
        assert_eq!(closed.as_deref(), Some("reconciliation"));
        let outcome: String = db.conn.query_row("SELECT summary FROM meeting_recovery_outcomes WHERE meeting_id=?1 ORDER BY ran_at,id", [SEED_IPHONE], |r| r.get(0)).unwrap();
        assert_eq!(outcome, "transcript:pending->interrupted finalization_interrupted");
        assert!(r.notices().iter().any(|n| n == "1 transcript was interrupted; choose Retry to finish it" || n.contains("transcripts were interrupted")));
        let run: String = db.conn.query_row("SELECT state FROM analysis_runs WHERE meeting_id=?1 ORDER BY created_at DESC LIMIT 1", [SEED_FULL], |r| r.get(0)).unwrap();
        assert_eq!(run, "interrupted");
        assert_eq!(reconcile_launch(&db, &root, 100).unwrap().meetings_found, 0, "a second run finds nothing active");
    }

    // Mirrors `MeetingReconcilerTests`: Swift truncates only the torn tail, finalizes, and keeps zero-frame files.
    // parity: MEET-091
    #[test]
    fn active_rows_recover_as_swift_does_and_lose_no_frames() {
        let db = db();
        let c = &db.conn;
        let root = std::env::temp_dir().join(format!("lf-recover-{}", new_id()));
        let m = "AAAAAAAA-0000-4000-8000-000000000001";
        std::fs::create_dir_all(root.join(m)).unwrap();
        insert_meeting(c, m, "completed", None, 1000, 0, None, "local");
        c.execute("UPDATE meetings SET state='finalizing',finalization_stage='mic',started_at=1000,stopped_at=NULL,completed_at=NULL,updated_at=61000 WHERE id=?1", [m]).unwrap();
        c.execute("INSERT INTO meeting_pauses (id,meeting_id,started_at,reason) VALUES ('open',?1,41000,'user')", [m]).unwrap();
        let (mic, sys) = (seed_uuid(0x9301), seed_uuid(0x9302));
        insert_track(c, &mic, m, "microphone", "healthy", None, 0, 0, 0);
        insert_track(c, &sys, m, "system", "healthy", None, 0, 0, 0);
        let seg = |id: &str, track: &str, n: i64, path: String, state: &str, duration: i64, bytes: i64| {
            c.execute("INSERT INTO meeting_segments (id,track_id,sequence,relative_path,state,start_offset_ms,duration_ms,byte_size,started_at,host_start_ns,open_reason,dropped_frames) VALUES (?1,?2,?3,?4,?5,0,?6,?7,1000,0,'start',0)", params![id, track, n, path, state, duration, bytes]).unwrap();
        };
        let at = |name: &str| root.join(m).join(name);
        // Torn tail on an open part; a part already renamed; a finalized row with stale .part; a missing one.
        std::fs::write(at("mic-0001.aac.part"), adts(40, 30)).unwrap();
        std::fs::write(at("mic-0002.aac"), adts(2, 0)).unwrap();
        std::fs::write(at("mic-0003.aac"), adts(1, 0)).unwrap();
        seg("s1", &mic, 1, format!("{m}/mic-0001.aac.part"), "open", 0, 0);
        seg("s2", &mic, 2, format!("{m}/mic-0002.aac.part"), "open", 0, 0);
        seg("s3", &mic, 3, format!("{m}/mic-0003.aac.part"), "finalized", 21, 100);
        seg("s4", &mic, 4, format!("{m}/mic-0004.aac.part"), "open", 0, 0);
        // A whole track with no frame stays a .part on disk, byte for byte.
        std::fs::write(at("system-0001.aac.part"), b"not audio").unwrap();
        seg("z1", &sys, 1, format!("{m}/system-0001.aac.part"), "open", 0, 0);

        let r = reconcile_launch(&db, &root, 70_000).unwrap();
        assert_eq!((r.meetings_found, r.recovered, r.unrecoverable), (1, 1, 0));
        assert_eq!(std::fs::metadata(at("mic-0001.aac")).unwrap().len(), 4000, "40 whole frames kept, 30 torn bytes cut");
        assert!(!at("mic-0001.aac.part").exists());
        assert_eq!(std::fs::read(at("mic-0002.aac")).unwrap(), adts(2, 0), "an untorn final file isn't rewritten");
        assert_eq!(std::fs::read(at("system-0001.aac.part")).unwrap(), b"not audio", "zero frames: nothing cut, nothing renamed");
        assert!(!at("system-0001.aac").exists());
        let seg_row = |id: &str| -> (String, String, i64, i64, Option<String>, Option<String>, Option<String>) {
            c.query_row("SELECT state,relative_path,duration_ms,byte_size,close_reason,failure_reason,recovery_note FROM meeting_segments WHERE id=?1", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?))).unwrap()
        };
        let frames = |n: i64| n * 1024 * 1000 / 48000;
        assert_eq!(seg_row("s1"), ("finalized".into(), format!("{m}/mic-0001.aac"), frames(40), 4000, Some("recovered".into()), None, Some("truncated=30 frames=40".into())));
        assert_eq!(seg_row("s2"), ("finalized".into(), format!("{m}/mic-0002.aac"), frames(2), 200, Some("recovered".into()), None, Some("truncated=0 frames=2".into())));
        assert_eq!(seg_row("s3"), ("finalized".into(), format!("{m}/mic-0003.aac"), 21, 100, Some("recovered".into()), None, None), "stale metadata: the row catches up, its figures stay");
        assert_eq!(seg_row("s4"), ("unrecoverable".into(), format!("{m}/mic-0004.aac.part"), 0, 0, None, Some("file_missing".into()), None));
        assert_eq!(seg_row("z1"), ("unrecoverable".into(), format!("{m}/system-0001.aac.part"), 0, 0, None, Some("unrecoverable_media".into()), Some("frames=0 bytes=9".into())));
        let track = |id: &str| -> (String, Option<String>, i64, i64) {
            c.query_row("SELECT health,failure_reason,total_duration_ms,total_bytes FROM meeting_tracks WHERE id=?1", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).unwrap()
        };
        assert_eq!(track(&mic), ("finalized".into(), None, frames(40) + frames(2) + 21, 4300));
        assert_eq!(track(&sys), ("unrecoverable".into(), Some("unrecoverable_media".into()), 0, 0));
        let row: (String, String, String) = c.query_row("SELECT state,failure_reason,failure_detail FROM meetings WHERE id=?1", [m], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
        assert_eq!(row, ("interrupted".into(), "not_running_at_last_state".into(), "found=finalizing stage=mic".into()));
        let times: (Option<i64>, Option<i64>, i64, i64) = c.query_row("SELECT stopped_at,completed_at,wall_clock_ms,recorded_ms FROM meetings WHERE id=?1", [m], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).unwrap();
        assert_eq!(times, (Some(61_000), Some(70_000), 60_000, 40_000), "stopped at the last write; the open pause closes there and doesn't count");
        let pause: (i64, String) = c.query_row("SELECT ended_at,closed_by FROM meeting_pauses WHERE id='open'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!(pause, (61_000, "reconciliation".into()));
        let warned: i64 = c.query_row("SELECT duration_warning FROM meeting_tracks WHERE id=?1", [&mic], |r| r.get(0)).unwrap();
        assert_eq!(warned, 1, "under a second of audio against 40 s recorded");
        let o: (String, Option<String>, i64, i64, i64, i64, i64, String) = c.query_row("SELECT found_state,found_stage,segments_recovered,segments_unrecoverable,segments_missing,bytes_truncated,pause_closed,summary FROM meeting_recovery_outcomes WHERE meeting_id=?1", [m], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?))).unwrap();
        assert_eq!(o, ("finalizing".into(), Some("mic".into()), 2, 1, 1, 30, 1, "recovered=2 unrecoverable=1 missing=1 truncated=30".into()));

        let before = std::fs::read(at("mic-0001.aac")).unwrap();
        assert_eq!(reconcile_launch(&db, &root, 80_000).unwrap().meetings_found, 0, "a second run finds nothing active");
        assert_eq!(std::fs::read(at("mic-0001.aac")).unwrap(), before);
        std::fs::remove_dir_all(root).unwrap();
    }

    // A symlinked or escaping path is never opened for truncation.
    // parity: MEET-091
    #[cfg(unix)]
    #[test]
    fn recovery_refuses_symlinks_and_paths_outside_the_root() {
        let db = db();
        let c = &db.conn;
        let root = std::env::temp_dir().join(format!("lf-recover-link-{}", new_id()));
        let m = "AAAAAAAA-0000-4000-8000-000000000002";
        std::fs::create_dir_all(root.join(m)).unwrap();
        let target = root.join("elsewhere.aac");
        std::fs::write(&target, adts(1, 7)).unwrap();
        std::os::unix::fs::symlink(&target, root.join(m).join("mic-0001.aac.part")).unwrap();
        insert_meeting(c, m, "completed", None, 1000, 0, None, "local");
        c.execute("UPDATE meetings SET state='recording',completed_at=NULL WHERE id=?1", [m]).unwrap();
        let mic = seed_uuid(0x9311);
        insert_track(c, &mic, m, "microphone", "healthy", None, 0, 0, 0);
        for (id, n, path) in [("l1", 1, format!("{m}/mic-0001.aac.part")), ("l2", 2, "../elsewhere.aac.part".to_string())] {
            c.execute("INSERT INTO meeting_segments (id,track_id,sequence,relative_path,state,start_offset_ms,duration_ms,byte_size,started_at,host_start_ns,open_reason) VALUES (?1,?2,?3,?4,'open',0,0,0,1000,0,'start')", params![id, mic, n, path]).unwrap();
        }
        reconcile_launch(&db, &root, 9).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), adts(1, 7), "the link's target keeps its tail");
        let state = |id: &str| c.query_row("SELECT state FROM meeting_segments WHERE id=?1", [id], |r| r.get::<_, String>(0)).unwrap();
        assert_eq!((state("l1").as_str(), state("l2").as_str()), ("unrecoverable", "open"), "as Swift: the link reads as missing; an invalid path is skipped");
        std::fs::remove_dir_all(root).unwrap();
    }

    /// An ADTS file of `frames` 48 kHz stereo frames of 100 bytes, then `tail` loose bytes.
    fn adts(frames: usize, tail: usize) -> Vec<u8> {
        let frame = [0xFF, 0xF1, 0x4C, 0x80, 0x0C, 0x80, 0xFC].into_iter().chain([0; 93]);
        let mut out: Vec<u8> = frame.cycle().take(frames * 100).collect();
        out.extend(vec![0u8; tail]);
        out
    }

    // parity: MEET-091
    #[test]
    fn orphan_folder_becomes_an_interrupted_meeting_and_a_notice() {
        let db = db();
        let root = std::env::temp_dir().join(format!("lf-orphan-{}", new_id()));
        let id = "11111111-2222-4333-8444-555555555555".to_uppercase();
        let dir = root.join(&id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("mic-0001.aac"), adts(3, 0)).unwrap();
        std::fs::write(dir.join("mic-0002.aac.part"), adts(2, 5)).unwrap();
        std::fs::write(dir.join("system-0001.aac"), b"not audio").unwrap();
        std::fs::write(dir.join("notes.txt"), b"ignored").unwrap();
        std::fs::create_dir_all(root.join("not-a-meeting")).unwrap();
        std::fs::create_dir_all(root.join(SEED_FULL)).unwrap();

        let r = reconcile_launch(&db, &root, 99).unwrap();
        assert_eq!(r.orphans_reconstructed, 1, "the known meeting's folder and the stray one are left alone");
        assert!(r.notices()[0].contains("1 found without a record"), "{:?}", r.notices());
        let m = meeting(&db, &id).unwrap().unwrap();
        assert_eq!((m.state.as_str(), m.failure_reason.as_deref()), ("interrupted", Some("record_missing")));
        assert_eq!(m.recorded_ms, 5 * 1024 * 1000 / 48000, "the longest track's validated frames");
        assert_eq!(std::fs::metadata(dir.join("mic-0002.aac")).unwrap().len(), 200, "the torn tail goes and .part is renamed");
        assert!(!dir.join("mic-0002.aac.part").exists());
        assert!(dir.join("system-0001.aac").exists(), "nothing is deleted");
        let tracks: Vec<(String, String, Option<String>)> = db.conn.prepare("SELECT type,health,failure_reason FROM meeting_tracks WHERE meeting_id=?1 ORDER BY type").unwrap().query_map([&id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().map(Result::unwrap).collect();
        assert_eq!(tracks, [("microphone".to_string(), "finalized".to_string(), None), ("system".to_string(), "unrecoverable".to_string(), Some("unrecoverable_media".to_string()))]);
        let outcome: (i64, i64, i64, String) = db.conn.query_row("SELECT segments_recovered,segments_unrecoverable,bytes_truncated,summary FROM meeting_recovery_outcomes WHERE meeting_id=?1", [&id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).unwrap();
        assert_eq!(outcome, (2, 1, 5, "record missing; files=3".to_string()));
        assert_eq!(reconcile_launch(&db, &root, 100).unwrap().orphans_reconstructed, 0, "the row exists now");
        std::fs::remove_dir_all(root).unwrap();
    }

    // parity: MEET-091
    #[test]
    fn notice_counts_orphans_and_deferred_in_swifts_order() {
        let r = Recovery { meetings_found: 3, recovered: 1, unrecoverable: 1, orphans_reconstructed: 2, deferred: 4, ..Default::default() };
        assert_eq!(r.notices(), ["1 meeting recovered, 1 with audio that could not be made playable, 2 found without a record, 1 marked failed, 4 deferred to the next launch"]);
        assert_eq!(Recovery { deferred: 1, ..Default::default() }.notices(), ["1 deferred to the next launch"]);
        assert!(Recovery::default().notices().is_empty());
    }

    #[test]
    fn adts_scan_stops_at_a_torn_or_changed_frame() {
        let dir = std::env::temp_dir().join(format!("lf-adts-{}", new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.aac");
        std::fs::write(&path, adts(2, 40)).unwrap();
        assert_eq!(adts_scan(&path).unwrap(), AdtsScan { frames: 2, bytes: 200, trailing: 40, sample_rate: 48000, channels: 2 });
        let mut changed = adts(2, 0);
        changed[102] = 0x50; // 44.1 kHz in the second frame
        std::fs::write(&path, changed).unwrap();
        assert_eq!(adts_scan(&path).unwrap().frames, 1);
        assert_eq!(parse_segment_name("system-0012.aac.part"), Some(("system", 12, true)));
        assert_eq!(parse_segment_name("mic-12.aac"), None);
        assert_eq!(parse_segment_name("mic-0000.aac"), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    // parity: SPK-106
    #[test]
    fn a_rerun_inherits_names_merges_and_corrections() {
        let db = db();
        let c = &db.conn;
        let run = |id: &str| {
            c.execute("INSERT INTO diarization_runs (id,meeting_id,transcript_pass_id,state,\"trigger\",in_room,engine,model_id,model_revision,model_manifest_hash,pipeline_version,created_at)
                       SELECT ?1,meeting_id,transcript_pass_id,'succeeded',\"trigger\",in_room,engine,model_id,model_revision,model_manifest_hash,pipeline_version,created_at FROM diarization_runs WHERE meeting_id=?2 LIMIT 1", params![id, SEED_FULL]).unwrap();
        };
        run("r1");
        run("r2");
        let speaker = |id: &str, run: &str, key: i64, name: Option<&str>| {
            c.execute("INSERT INTO meeting_speakers (id,meeting_id,run_id,cluster_key,source,track,origin,display_name,speech_ms) VALUES (?1,?2,?3,?4,'remote','system','engine',?5,1000)", params![id, SEED_FULL, run, key, name]).unwrap();
        };
        let turn = |run: &str, id: &str, a: i64, b: i64| {
            c.execute("INSERT INTO speaker_turns (run_id,speaker_id,track,start_ms,end_ms) VALUES (?1,?2,'system',?3,?4)", params![run, id, a, b]).unwrap();
        };
        speaker("old-a", "r1", 10, Some("Marta"));
        speaker("old-b", "r1", 11, None);
        speaker("old-gone", "r1", 12, Some("Tomas"));
        speaker("new-a", "r2", 20, None);
        speaker("new-b", "r2", 21, None);
        c.execute("UPDATE meeting_speakers SET merged_into='old-a' WHERE id='old-b'", []).unwrap();
        turn("r1", "old-a", 0, 1000);
        turn("r2", "new-a", 0, 1000);
        turn("r1", "old-b", 2000, 3000);
        turn("r2", "new-b", 2000, 3000);
        turn("r1", "old-gone", 5000, 6000); // nothing in r2 overlaps it
        let segment: String = c.query_row("SELECT id FROM transcript_segments WHERE meeting_id=?1 LIMIT 1", [SEED_FULL], |r| r.get(0)).unwrap();
        c.execute("INSERT INTO speaker_assignments (run_id,segment_id,auto_kind,manual_kind,manual_speaker_id,manual_at) VALUES ('r1',?1,'unknown','speaker','old-a',1)", [&segment]).unwrap();
        c.execute("INSERT INTO speaker_assignments (run_id,segment_id,auto_kind) VALUES ('r2',?1,'unknown')", [&segment]).unwrap();

        carry_over(&db, SEED_FULL, "r1", "r2", 50).unwrap();

        let name: Option<String> = c.query_row("SELECT display_name FROM meeting_speakers WHERE id='new-a'", [], |r| r.get(0)).unwrap();
        assert_eq!(name.as_deref(), Some("Marta"));
        let merged: Option<String> = c.query_row("SELECT merged_into FROM meeting_speakers WHERE id='new-b'", [], |r| r.get(0)).unwrap();
        assert_eq!(merged.as_deref(), Some("new-a"));
        let manual: Option<String> = c.query_row("SELECT manual_speaker_id FROM speaker_assignments WHERE run_id='r2' AND segment_id=?1", [&segment], |r| r.get(0)).unwrap();
        assert_eq!(manual.as_deref(), Some("new-a"));
        let review: (String, String) = c.query_row("SELECT speaker_id,new_value FROM speaker_corrections WHERE run_id='r2' AND needs_review=1", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!(review, ("old-gone".to_string(), "Tomas".to_string()), "an unmapped name asks for review, and only it");
    }

    #[test]
    fn carry_map_refuses_weak_ties_and_double_claims() {
        let key = |o: &str, n: &str, ms: i64| ((o.to_string(), n.to_string()), ms);
        let old = |id: &str, speech: i64| (id.to_string(), "system".to_string(), speech);
        let new = |id: &str| (id.to_string(), "system".to_string());
        let map = |o: Vec<(String, String, i64)>, n: Vec<(String, String)>, v: Vec<((String, String), i64)>| carry_map(&o, &n, &v.into_iter().collect());
        assert_eq!(map(vec![old("a", 100)], vec![new("x")], vec![key("a", "x", 50)]).len(), 1, "exactly half maps");
        assert!(map(vec![old("a", 100)], vec![new("x")], vec![key("a", "x", 49)]).is_empty(), "under half");
        assert!(map(vec![old("a", 100)], vec![new("x"), new("y")], vec![key("a", "x", 60), key("a", "y", 31)]).is_empty(), "under twice the next best");
        assert!(map(vec![old("a", 100), old("b", 100)], vec![new("x")], vec![key("a", "x", 60), key("b", "x", 60)]).is_empty(), "a tie maps nobody");
    }

    // parity: NOTE-032 NOTE-056 NOTE-058 NOTE-060 NOTE-061 NOTE-106
    #[test]
    fn library_pages_and_evicts() {
        let db = db();
        let mut l = Library::default();
        l.refresh(&db, None);
        assert_eq!(l.rows.len(), 20);
        assert!(l.has_older);
        assert_eq!(l.rows[0].id, SEED_FULL);
        l.load_older(&db);
        assert_eq!(l.rows.len(), 29);
        assert!(!l.has_older);
        assert!(!l.evicted_newest);
        // A pinned active meeting moves to the front.
        l.refresh(&db, Some(SEED_FAILED));
        assert_eq!(l.rows[0].id, SEED_FAILED);
    }

    // parity: MEET-021 NOTE-093
    #[test]
    fn stale_title_and_delete_reload_and_say_the_meeting_changed() {
        let db = db();
        let root = std::env::temp_dir().join(format!("lf-stale-{}", new_id()));
        let mut lib = Library::default();
        lib.open(&db, SEED_FULL);
        set_title(&db, SEED_FULL, "Moved on", 0, 5).unwrap();
        lib.set_title(&db, SEED_FULL, "Mine", 0, None);
        assert_eq!(lib.detail_notice.as_deref(), Some("The meeting changed. Try again."));
        assert_eq!(lib.detail.as_ref().unwrap().meeting.title.as_deref(), Some("Moved on"), "the detail was read again");
        set_title(&db, SEED_FULL, "Moved again", 1, 6).unwrap();
        lib.detail_notice = None;
        lib.delete(&db, &root, SEED_FULL, 1, None);
        assert_eq!(lib.detail_notice.as_deref(), Some("The meeting changed. Try again."));
        assert_eq!(lib.detail.as_ref().unwrap().meeting.title.as_deref(), Some("Moved again"), "the detail was read again");
        assert!(meeting(&db, SEED_FULL).unwrap().is_some());
    }

    // parity: MEET-019 MEET-020 MEET-021
    #[test]
    fn title_revision_rules() {
        let db = db();
        assert_eq!(set_title(&db, SEED_FULL, "  New  ", 0, 5).unwrap(), 1);
        assert_eq!(meeting(&db, SEED_FULL).unwrap().unwrap().title.as_deref(), Some("New"));
        assert!(matches!(set_title(&db, SEED_FULL, "x", 0, 5), Err(MeetingError::Stale)));
        assert!(matches!(set_title(&db, SEED_FULL, &"x".repeat(257), 1, 5), Err(MeetingError::TitleTooLarge)));
        set_title(&db, SEED_FULL, "   ", 1, 5).unwrap();
        assert_eq!(meeting(&db, SEED_FULL).unwrap().unwrap().title, None);
    }

    // parity: MEET-058 MEET-060 MEET-063
    #[test]
    fn evidence_hash_matches_the_swift_stream_and_tracks_changes() {
        let db = Db::memory();
        seed(&db);
        let original = current_evidence_version(&db, SEED_FULL).unwrap().unwrap();
        assert!(!read_model(&db, SEED_FULL).unwrap().unwrap().stale, "a seeded summary starts current");
        // The stream by hand for a one-segment meeting, framed as `EvidenceVersion.compute` does.
        let m = "bbbbbbbb-0000-4000-8000-000000000001";
        let pass = "bbbbbbbb-0000-4000-8000-000000000002";
        insert_meeting(&db.conn, m, "completed", None, 1, 1, None, "local");
        insert_transcription(&db.conn, m, "final", Some(pass), None, 1, 2, 1, "local");
        db.conn.execute("UPDATE meeting_transcriptions SET pipeline_version='x+lang_sk_prompt_v2' WHERE meeting_id=?1", [m]).unwrap();
        db.conn.execute("UPDATE meeting_notes SET text=' one \n\ntwo' WHERE meeting_id=?1", [m]).unwrap();
        db.conn.execute(
            "INSERT INTO transcript_segments (id, meeting_id, pass_id, finality, ordinal, stretch_sequence, start_ms, end_ms, window_index, timing_basis, raw_text, assembled_text, normalized_text, engine, model_id, model_revision, pipeline_version, analysis_tracks, created_at)
             VALUES ('bbbbbbbb-0000-4000-8000-000000000003',?1,?2,'final',0,1,5,9,0,'word','hé','hé','hé','e','m','1','1','mic',1)",
            params![m, pass],
        )
        .unwrap();
        let expected = "11:evidence_v1\x1f\n7:meeting\x1f36:BBBBBBBB-0000-4000-8000-000000000001\x1f\n4:pass\x1f36:BBBBBBBB-0000-4000-8000-000000000002\x1f\n7:segment\x1f36:BBBBBBBB-0000-4000-8000-000000000003\x1f1:0\x1f1:5\x1f1:9\x1f7:unknown\x1f3:hé\x1f\n4:note\x1f1:1\x1f3:one\x1f\n4:note\x1f1:2\x1f3:two\x1f\n8:language\x1f2:sk\x1f1:1\x1f\n8:versions\x1f1:1\x1f11:chunking_v2\x1f5:16384\x1f7:caps_v1\x1f\n";
        assert_eq!(current_evidence_version(&db, m).unwrap().unwrap(), sha256_hex(expected));
        // Renaming a speaker keeps a typed name's certainty out of the text, but a first name changes it.
        db.conn.execute("UPDATE meeting_notes SET text=text||'\n\nmore' WHERE meeting_id=?1", [SEED_FULL]).unwrap();
        assert!(read_model(&db, SEED_FULL).unwrap().unwrap().stale, "a changed note marks the summary stale");
        db.conn.execute("UPDATE meeting_notes SET text=?1 WHERE meeting_id=?2", params![SEED_NOTES, SEED_FULL]).unwrap();
        assert_eq!(current_evidence_version(&db, SEED_FULL).unwrap().unwrap(), original);
        db.conn.execute("UPDATE meeting_speakers SET display_name='Someone Else' WHERE display_name='Marta Kováčová'", []).unwrap();
        assert_eq!(current_evidence_version(&db, SEED_FULL).unwrap().unwrap(), original, "a rename of a named speaker keeps the version");
        db.conn.execute("UPDATE meeting_speakers SET display_name='New Name' WHERE id=?1", [seed_uuid(0xC2)]).unwrap();
        assert!(read_model(&db, SEED_FULL).unwrap().unwrap().stale, "naming an unknown speaker changes the version");
    }

    // parity: MEET-058 MEET-060 MEET-063
    #[test]
    fn notes_editor_saves_and_retries_stale() {
        let db = db();
        let mut e = NotesEditor::new(SEED_UNTITLED, "Call the supplier about delivery dates.", 0);
        e.edit("changed");
        assert!(e.is_dirty);
        save_notes(&db, SEED_UNTITLED, "elsewhere", 0, 1).unwrap();
        e.flush(&db);
        assert!(!e.is_dirty);
        assert_eq!(notes(&db, SEED_UNTITLED).unwrap().unwrap(), ("changed".to_string(), 2));
        assert!(!e.edit(&"x".repeat(NOTES_MAX_BYTES + 1)));
        assert_eq!(e.notice.as_deref(), Some("Notes are limited to 1 MiB. The last edit was not applied."));
        assert_eq!(e.text, "changed");
    }

    // parity: NOTE-089 NOTE-093 MEET-017 MEET-045
    #[test]
    fn delete_keeps_row_while_files_remain_then_removes() {
        let db = db();
        let root = std::env::temp_dir().join(format!("lf-del-{}", new_id()));
        std::fs::create_dir_all(root.join(SEED_FULL)).unwrap();
        let mut s = db.conn.prepare("SELECT s.relative_path FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id WHERE t.meeting_id=?1").unwrap();
        let paths: Vec<String> = s.query_map([SEED_FULL], |r| r.get(0)).unwrap().map(Result::unwrap).collect();
        for p in &paths {
            std::fs::write(root.join(p), b"x").unwrap();
        }
        assert!(matches!(delete_confirmed(&db, &root, SEED_FULL, 7), Err(MeetingError::Stale)));
        let bytes_before: i64 = db.conn.query_row("SELECT text_bytes FROM transcript_usage", [], |r| r.get(0)).unwrap();
        assert!(bytes_before > 0);
        assert_eq!(delete_confirmed(&db, &root, SEED_FULL, 0).unwrap(), DeleteOutcome::Deleted);
        assert!(meeting(&db, SEED_FULL).unwrap().is_none());
        assert!(!root.join(SEED_FULL).exists());
        let after: i64 = db.conn.query_row("SELECT text_bytes FROM transcript_usage", [], |r| r.get(0)).unwrap();
        assert_eq!(after, 0);
        std::fs::remove_dir_all(root).unwrap();
    }

    // parity: MEET-049 MEET-053 MEET-054
    #[test]
    fn provenance_reads_stored_paths() {
        let db = db();
        assert_eq!(provenance(&db, SEED_FULL).unwrap().unwrap(), "Transcript: this Mac · Speaker labels: your server · Summary: this Mac");
        assert_eq!(provenance(&db, SEED_UNTITLED).unwrap(), None);
    }

    // parity: TRANS-014 TRANS-016 TRANS-018 TRANS-019 TRANS-020 TRANS-021 TRANS-032 TRANS-036 TRANS-038 TRANS-048
    #[test]
    fn pager_labels_search_and_copy() {
        let db = db();
        let mut p = Pager::new(SEED_FULL);
        p.load_first(&db);
        assert_eq!(p.rows().count(), 12);
        assert!(!p.has_next());
        let rows: Vec<&TranscriptRow> = p.rows().collect();
        assert_eq!(rows[0].label.as_ref().unwrap().text, "You");
        assert_eq!(rows[1].label.as_ref().unwrap().text, "Marta Kováčová");
        assert_eq!(rows[3].label.as_ref().unwrap().text, "Tomas Novak?");
        assert_eq!(rows[7].label.as_ref().unwrap().text, "Unknown");
        let (id0, id1) = (rows[0].id.clone(), rows[1].id.clone());
        p.search(&db, "hinge");
        assert_eq!(p.match_count_text(), "1 match");
        p.show_match(&db, true);
        assert_eq!(p.match_count_text(), "1 of 1");
        assert!(p.highlighted.is_some());
        p.search(&db, "the");
        assert_eq!(p.match_count_text(), "11 matches");
        p.search(&db, "zebra");
        assert_eq!(p.match_count_text(), "No matches");
        p.toggle_selection(&id0);
        p.toggle_selection(&id1);
        assert_eq!(p.selection_text(), format!("You:\n{}\n\nMarta Kováčová:\n{}", LINES[0], LINES[1]));
        let full = p.full_text(&db).unwrap();
        assert!(full.starts_with(&format!("You:\n{}", LINES[0])));
        let path = std::env::temp_dir().join(format!("lf-export-{}.txt", new_id()));
        p.export(&db, &path).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), full);
        std::fs::remove_file(path).unwrap();
    }

    /// Adds segments after the seed's twelve, in the same pass.
    fn more_segments(db: &Db, total: i64) {
        let actual: Vec<String> = db.conn.prepare("SELECT name FROM pragma_table_info('transcript_segments')").unwrap().query_map([], |r| r.get(0)).unwrap().map(|n| n.unwrap()).collect();
        let copied = actual.iter().filter(|c| *c != "id" && *c != "ordinal").cloned().collect::<Vec<_>>().join(",");
        db.conn
            .execute_batch(&format!(
                "WITH RECURSIVE n(i) AS (SELECT 12 UNION ALL SELECT i+1 FROM n WHERE i<{}) INSERT INTO transcript_segments (id, ordinal, {copied}) SELECT lower(hex(randomblob(16))), i, {copied} FROM n, (SELECT * FROM transcript_segments WHERE meeting_id='{SEED_FULL}' AND ordinal=0)",
                total - 1
            ))
            .unwrap();
    }

    // parity: TRANS-038 TRANS-039
    #[test]
    fn pager_edges_load_the_next_and_previous_pages() {
        let db = db();
        more_segments(&db, 650);
        let mut p = Pager::new(SEED_FULL);
        p.load_first(&db);
        assert_eq!(p.rows().count(), TRANSCRIPT_PAGE);
        assert!(!p.has_previous() && p.has_next());
        p.load_next(&db);
        p.load_next(&db);
        // Two resident pages: the first was evicted, so the top edge can load again.
        assert_eq!(p.rows().next().unwrap().ordinal, TRANSCRIPT_PAGE as i64);
        assert_eq!(p.rows().count(), 2 * TRANSCRIPT_PAGE);
        assert!(p.has_previous());
        p.load_previous(&db);
        assert_eq!(p.rows().next().unwrap().ordinal, 0);
        assert_eq!(p.rows().count(), 2 * TRANSCRIPT_PAGE);
        let top = p.rows().next().unwrap().id.clone();
        p.toggle_selection(&top);
        p.load_next(&db);
        assert!(!p.selection.contains(&top), "eviction removes its rows from the selection");
    }

    // parity: TRANS-014
    #[test]
    fn search_stops_at_a_thousand_matches_and_marks_it() {
        let db = db();
        more_segments(&db, 1100);
        let mut p = Pager::new(SEED_FULL);
        p.load_first(&db);
        p.search(&db, "e");
        let (hits, truncated) = p.search_hits.clone().unwrap();
        assert_eq!((hits.len(), truncated), (SEARCH_LIMIT, true));
        assert_eq!(SEARCH_LIMIT, 1000);
        assert_eq!(p.match_count_text(), "1,000+ matches");
    }

    // parity: TRANS-016
    #[test]
    fn matches_wrap_and_load_their_page() {
        let db = db();
        more_segments(&db, 650);
        let mut p = Pager::new(SEED_FULL);
        p.load_first(&db);
        p.search(&db, "e");
        let n = p.search_hits.as_ref().unwrap().0.len();
        p.show_match(&db, false);
        assert_eq!(p.current_match, Some(n - 1), "backwards from the top goes to the last");
        let last = p.search_hits.as_ref().unwrap().0[n - 1].clone();
        assert!(p.rows().any(|r| r.id == last.1), "its page loaded");
        assert_eq!(p.highlighted.as_deref(), Some(last.1.as_str()));
        p.show_match(&db, true);
        assert_eq!(p.current_match, Some(0), "forward from the last wraps");
    }

    // parity: TRANS-042
    #[test]
    fn finalizing_previews_the_last_page_of_the_pass() {
        let db = db();
        more_segments(&db, 250);
        db.conn.execute_batch(&format!("PRAGMA ignore_check_constraints=ON; UPDATE transcript_segments SET finality='final' WHERE meeting_id='{SEED_FULL}'; UPDATE meeting_transcriptions SET state='finalizing' WHERE meeting_id='{SEED_FULL}';")).unwrap();
        let mut p = Pager::new(SEED_FULL);
        p.load_first(&db);
        assert!(p.previewing_final_pass());
        assert_eq!(p.final_pass_count, 250);
        assert_eq!(p.rows().next().unwrap().ordinal, 50, "the last {TRANSCRIPT_PAGE} of 250");
        assert!(!p.has_next(), "a preview doesn't page forward");
    }

    // parity: SUM-004
    #[test]
    fn reading_time_rounds_up_with_a_minimum_of_one() {
        let mut m = ReadModel::default();
        assert_eq!(m.minutes(), 1);
        m.summary = vec!["word"; 200].join(" ");
        assert_eq!(m.minutes(), 1);
        m.summary.push_str(" more");
        assert_eq!(m.minutes(), 2);
    }

    // parity: SPK-043 SPK-058 SPK-059 SPK-060 SPK-071
    #[test]
    fn corrections_and_merges_persist() {
        let db = db();
        let roots = speaker_summaries(&db, SEED_FULL).unwrap();
        assert_eq!(roots.len(), 4);
        assert!(roots[0].is_you());
        assert_eq!(roots[0].quotes.len(), 3);
        let segment = seed_uuid(0xD00);
        let new = correct_segment(&db, SEED_FULL, &segment, &Correction::New, 9).unwrap().unwrap();
        let row: (String, i64, i64, String) = db.conn.query_row("SELECT source, label_ordinal, color_index, origin FROM meeting_speakers WHERE id=?1", [&new], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).unwrap();
        assert_eq!(row, ("remote".to_string(), 4, 4, "manual".to_string()));
        correct_segment(&db, SEED_FULL, &segment, &Correction::Unknown, 9).unwrap();
        let kind: String = db.conn.query_row("SELECT manual_kind FROM speaker_assignments WHERE segment_id=?1", [&segment], |r| r.get(0)).unwrap();
        assert_eq!(kind, "unknown");
        let (a, b) = (roots[2].id.clone(), roots[3].id.clone());
        assert_eq!(merge(&db, SEED_FULL, &a, &b, 9).unwrap(), 1);
        let merged = speaker_summaries(&db, SEED_FULL).unwrap();
        assert_eq!(merged.iter().find(|s| s.id == b).unwrap().includes[0].label, "Speaker 2");
        unmerge(&db, SEED_FULL, &a, 10).unwrap();
        let undone: i64 = db.conn.query_row("SELECT count(*) FROM speaker_corrections WHERE kind='merge' AND undone_at=10", [], |r| r.get(0)).unwrap();
        assert_eq!(undone, 1);
    }

    // parity: SPK-041 SPK-042
    #[test]
    fn corrections_write_manual_columns_and_a_segment_correction() {
        let db = db();
        let target = speaker_summaries(&db, SEED_FULL).unwrap()[2].id.clone();
        let segment = seed_uuid(0xD00);
        correct_segment(&db, SEED_FULL, &segment, &Correction::Speaker(target.clone()), 9).unwrap();
        let row: (String, Option<String>, i64) = db.conn.query_row("SELECT manual_kind, manual_speaker_id, manual_at FROM speaker_assignments WHERE segment_id=?1", [&segment], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
        assert_eq!(row, ("speaker".to_string(), Some(target), 9));
        correct_segment(&db, SEED_FULL, &segment, &Correction::Unknown, 10).unwrap();
        let (kind, value): (String, Option<String>) = db.conn.query_row("SELECT kind, new_value FROM speaker_corrections WHERE segment_id=?1 ORDER BY created_at DESC LIMIT 1", [&segment], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!((kind.as_str(), value.as_deref()), ("segment", Some("unknown")));
    }

    // parity: SPK-058 SPK-060 SPK-071
    #[test]
    fn merges_stay_one_level_deep_and_undo_clears_the_merged_identity() {
        let db = db();
        let roots = speaker_summaries(&db, SEED_FULL).unwrap();
        // You first, then colour order among the rest.
        assert!(roots[0].is_you());
        assert!(roots[1..].windows(2).all(|w| w[0].color <= w[1].color));
        let (a, b, c) = (roots[1].id.clone(), roots[2].id.clone(), roots[3].id.clone());
        let before: i64 = db.conn.query_row("SELECT count(*) FROM speaker_corrections WHERE kind='merge'", [], |r| r.get(0)).unwrap();
        assert_eq!(merge(&db, SEED_FULL, &a, &b, 9).unwrap(), 1);
        assert_eq!(merge(&db, SEED_FULL, &b, &c, 9).unwrap(), 2, "a root moves with its member");
        let into = |id: &str| -> Option<String> { db.conn.query_row("SELECT merged_into FROM meeting_speakers WHERE id=?1", [id], |r| r.get(0)).unwrap() };
        assert_eq!((into(&a), into(&b)), (Some(c.clone()), Some(c.clone())), "depth stays one");
        let after: i64 = db.conn.query_row("SELECT count(*) FROM speaker_corrections WHERE kind='merge'", [], |r| r.get(0)).unwrap();
        assert_eq!(after - before, 3, "one correction per moved speaker");
        db.conn.execute("INSERT INTO identity_assignments (id, meeting_id, meeting_speaker_id, scope, state, origin, created_at, updated_at) VALUES ('m1',?1,?2,'merged','unknown','user_confirmation',1,1)", params![SEED_FULL, c]).unwrap();
        unmerge(&db, SEED_FULL, &a, 11).unwrap();
        assert_eq!(into(&a), None);
        let merged: i64 = db.conn.query_row("SELECT count(*) FROM identity_assignments WHERE meeting_speaker_id=?1 AND scope='merged'", [&c], |r| r.get(0)).unwrap();
        assert_eq!(merged, 0);
        let unmerges: i64 = db.conn.query_row("SELECT count(*) FROM speaker_corrections WHERE kind='unmerge' AND speaker_id=?1 AND created_at=11", [&a], |r| r.get(0)).unwrap();
        assert_eq!(unmerges, 1);
    }

    // parity: SPK-066
    #[test]
    fn suggestions_put_the_latest_rename_first_and_stop_at_eight() {
        let db = db();
        let run: String = db.conn.query_row("SELECT accepted_run_id FROM meeting_diarization WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap();
        let ids: Vec<String> = speaker_summaries(&db, SEED_FULL).unwrap().iter().map(|s| s.id.clone()).collect();
        save_names(&db, SEED_FULL, &[(ids[1].clone(), Some("Zora Old".into()))], 100).unwrap();
        save_names(&db, SEED_FULL, &[(ids[2].clone(), Some("Zora New".into()))], 200).unwrap();
        assert_eq!(name_suggestions(&db, "Zora", 8).unwrap(), vec!["Zora New".to_string(), "Zora Old".to_string()]);
        assert_eq!(name_suggestions(&db, "", 8).unwrap()[0], "Zora New", "an empty field shows the recent ones");
        for i in 0..12 {
            db.conn.execute("INSERT INTO meeting_speakers (id, meeting_id, run_id, cluster_key, source, label_ordinal, color_index, first_ms, speech_ms, display_name, origin) VALUES (?1,?2,NULL,?1,'remote',?3,0,0,0,?4,'manual')", params![format!("x{i}"), SEED_FULL, 50 + i, format!("Yan {i}")]).unwrap();
        }
        assert_eq!(name_suggestions(&db, "Yan", 8).unwrap().len(), 8);
        assert_eq!(name_suggestions(&db, "Yan", 50).unwrap().len(), 8);
    }

    // parity: SPK-097 SPK-098 SPK-100
    #[test]
    fn saving_records_renames_and_identity_origins() {
        let db = db();
        let mut m = AssignModel::new(&db, SEED_FULL, true);
        let known = m.known.iter().find(|k| !k.is_local).unwrap().id.clone();
        let other = {
            db.conn.execute("INSERT INTO known_speakers (id, display_name, is_local_user, revision, created_at, updated_at) VALUES ('k9','Second',0,0,1,1)", []).unwrap();
            "k9".to_string()
        };
        let (a, b, c) = (m.sections[1].speaker.id.clone(), m.sections[3].speaker.id.clone(), m.sections[2].speaker.id.clone());
        m.set_draft(&b, "Dana");
        m.set_action(&a, IdentityAction::Pick(known.clone()));
        m.set_action(&c, IdentityAction::ChooseAnother(other.clone()));
        let renames = |db: &Db| -> i64 { db.conn.query_row("SELECT count(*) FROM speaker_corrections WHERE kind='rename' AND speaker_id=?1", [&b], |r| r.get(0)).unwrap() };
        let start = renames(&db);
        assert!(m.save(&db, "unused"));
        assert_eq!(renames(&db), start + 1, "one rename per change");
        let origin = |id: &str| -> String { db.conn.query_row("SELECT origin FROM identity_assignments WHERE meeting_speaker_id=?1 AND scope='self'", [id], |r| r.get(0)).unwrap() };
        assert_eq!(origin(&a), "manual_profile_selection");
        assert_eq!(origin(&c), "manual_correction");
        let mut m = AssignModel::new(&db, SEED_FULL, true);
        assert!(m.save(&db, "unused"));
        assert_eq!(renames(&db), start + 1, "an unchanged name writes nothing");
        // A merged root resolves to a known speaker or to Keep Unknown under scope merged.
        resolve_merged(&db, SEED_FULL, &a, Some(&known), 5).unwrap();
        let (state, linked): (String, Option<String>) = db.conn.query_row("SELECT state, known_speaker_id FROM identity_assignments WHERE meeting_speaker_id=?1 AND scope='merged'", [&a], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!(linked.as_deref(), Some(known.as_str()), "state {state}");
        resolve_merged(&db, SEED_FULL, &a, None, 6).unwrap();
        let linked: Option<String> = db.conn.query_row("SELECT known_speaker_id FROM identity_assignments WHERE meeting_speaker_id=?1 AND scope='merged'", [&a], |r| r.get(0)).unwrap();
        assert_eq!(linked, None);
    }

    // parity: SPK-069 SPK-070 SPK-097 SPK-098
    #[test]
    fn assign_model_saves_names_and_identities() {
        let db = db();
        let mut m = AssignModel::new(&db, SEED_FULL, true);
        let id = m.sections[3].speaker.id.clone();
        m.set_draft(&id, "A\u{7}");
        assert_eq!(m.sections[3].error(), Some("Remove the control character."));
        assert!(!m.can_save());
        m.set_draft(&id, "  Marta Kováčová ");
        assert_eq!(m.duplicate(&id).unwrap().speaker.label(), "Marta Kováčová");
        m.set_draft(&id, "Dana");
        assert!(m.can_save());
        let possible = m.sections[2].speaker.id.clone();
        assert!(m.identity_block(&possible).unwrap().shows_suggestion_actions);
        m.set_action(&possible, IdentityAction::Confirm);
        assert!(m.save(&db, "unused"));
        assert!(m.did_change_identities);
        let name: String = db.conn.query_row("SELECT display_name FROM meeting_speakers WHERE id=?1", [&id], |r| r.get(0)).unwrap();
        assert_eq!(name, "Dana");
        let state: String = db.conn.query_row("SELECT state FROM identity_assignments WHERE meeting_speaker_id=?1 AND scope='self'", [&possible], |r| r.get(0)).unwrap();
        assert_eq!(state, "confirmed");
        // Enrollment can't run here: the failure text is surfaced and nothing claims a sample.
        let mut m = AssignModel::new(&db, SEED_FULL, true);
        let you = m.sections[0].speaker.id.clone();
        m.set_action(&you, IdentityAction::RememberLocal);
        assert!(!m.save(&db, "failed text"));
        assert!(m.enrollment_completed);
        assert_eq!(m.sections[0].enrollment_result.as_deref(), Some("failed text"));
    }

    // parity: SUM-005 SUM-006 SUM-007 SUM-019 SUM-033 SUM-037 SUM-044 SUM-054 SUM-063 SUM-073 SUM-074 SUM-077 SUM-086
    #[test]
    fn summary_overlays_and_report() {
        let db = db();
        let model = read_model(&db, SEED_FULL).unwrap().unwrap();
        assert_eq!(summary_header(&db, SEED_FULL).unwrap(), SummaryHeader::Succeeded);
        assert_eq!(summary_header(&db, SEED_UNTITLED).unwrap(), SummaryHeader::NotEligible(TRANSCRIPTION_OFF));
        assert_eq!(summary_header(&db, SEED_IPHONE).unwrap(), SummaryHeader::NotEligible(NOT_FINISHED));
        assert_eq!(model.action_items.len(), 4);
        assert!(matches!(&model.action_items[0].owner, Owner::Participant(_, 0, true)));
        assert_eq!(model.action_items[1].owner.text(), "Marta Kováčová");
        assert!(matches!(&model.action_items[2].owner, Owner::Mentioned(n, Some(_)) if n == "Tomas Novak"));
        assert!(matches!(&model.action_items[3].owner, Owner::Unresolved(_)));
        assert_eq!(model.action_items[0].attribution.as_deref(), Some("You"));
        let item = &model.action_items[0];
        set_overlay(&db, SEED_FULL, OverlayTarget::Item(&item.id), "status", "completed", Some("open"), Some(&item.ai_text), "", 5).unwrap();
        set_overlay(&db, SEED_FULL, OverlayTarget::Summary, "summary_text", "Edited.", Some("x"), Some("x"), "", 5).unwrap();
        let edited = read_model(&db, SEED_FULL).unwrap().unwrap();
        assert_eq!(edited.summary, "Edited.");
        assert_eq!(edited.action_items[0].status, "completed");
        let report = report_text(&edited, "T", "1 Sep 2026");
        assert!(report.contains("- [x] Ask the workshop to loosen the hinge tolerance — You (due 6 Nov)"));
        assert!(report.contains("- [ ] Book the photo session — (owner unresolved)"));
        assert!(report.contains("Risks / blockers"));
        assert!(report.ends_with("Generated by LocalFlow from the meeting transcript and notes."));
        remove_all_overlays(&db, SEED_FULL).unwrap();
        assert_eq!(read_model(&db, SEED_FULL).unwrap().unwrap().summary, edited.ai_summary);
    }

    // parity: SUM-033 SUM-054 SUM-055
    #[test]
    fn report_lists_title_date_and_blockers_without_dismissed_items() {
        let db = db();
        let model = read_model(&db, SEED_FULL).unwrap().unwrap();
        let gone = &model.action_items[1];
        set_overlay(&db, SEED_FULL, OverlayTarget::Item(&gone.id), "status", "dismissed", Some("open"), Some(&gone.ai_text), "", 5).unwrap();
        let report = report_text(&read_model(&db, SEED_FULL).unwrap().unwrap(), "T", "1 Sep 2026");
        let lines: Vec<&str> = report.lines().collect();
        assert_eq!(&lines[..2], ["T", "1 Sep 2026"], "{report}");
        assert!(lines.contains(&"Summary"), "{report}");
        assert!(lines.contains(&"Risks / blockers"), "{report}");
        assert!(!lines.contains(&"Risks"), "the report has its own heading");
        assert!(!report.contains(&gone.text), "dismissed items are omitted");
        for topic in &model.topics {
            assert!(lines.contains(&topic.title.as_str()), "{report}");
        }
    }

    // parity: SUM-086
    #[test]
    fn read_model_orders_by_stored_ordinals_and_keeps_snapshots() {
        let db = db();
        let before = read_model(&db, SEED_FULL).unwrap().unwrap();
        db.conn.execute_batch("UPDATE analysis_topics SET ordinal=100-ordinal; UPDATE analysis_items SET ordinal=100-ordinal WHERE kind='action_item';").unwrap();
        let after = read_model(&db, SEED_FULL).unwrap().unwrap();
        let titles = |m: &ReadModel| m.topics.iter().map(|t| t.title.clone()).collect::<Vec<_>>();
        let tasks = |m: &ReadModel| m.action_items.iter().map(|i| i.id.clone()).collect::<Vec<_>>();
        assert_eq!(titles(&after), titles(&before).into_iter().rev().collect::<Vec<_>>());
        assert_eq!(tasks(&after), tasks(&before).into_iter().rev().collect::<Vec<_>>());
        let item = &before.action_items[0];
        set_overlay(&db, SEED_FULL, OverlayTarget::Item(&item.id), "status", "completed", Some("open"), Some("snap"), "", 5).unwrap();
        set_overlay(&db, SEED_FULL, OverlayTarget::Item(&item.id), "task_text", "Edited.", Some("x"), Some("y"), "", 5).unwrap();
        db.conn.execute_batch("UPDATE analysis_overlays SET orphaned_at=1, item_id=NULL, created_at=2 WHERE field='status'; UPDATE analysis_overlays SET orphaned_at=1, item_id=NULL, created_at=1 WHERE field='task_text';").unwrap();
        let edits = read_model(&db, SEED_FULL).unwrap().unwrap().previous_edits;
        assert_eq!(edits.iter().map(|e| e.field.as_str()).collect::<Vec<_>>(), ["task_text", "status"], "created_at order");
        assert_eq!((edits[1].ai_value.as_deref(), edits[1].item_text.as_deref()), (Some("open"), Some("snap")));
    }

    // parity: SUM-084
    #[test]
    fn mentions_prefer_full_names_and_endings() {
        let speakers = vec![("a".to_string(), "Marta Kováčová".to_string(), 1), ("b".to_string(), "Speaker 2".to_string(), 2), ("c".to_string(), "You".to_string(), 0)];
        let found = speaker_mentions("Marta Kováčová met Martami and Speaker 2, not Speaker 20 or You.", &speakers);
        let words: Vec<&str> = found.iter().map(|f| &"Marta Kováčová met Martami and Speaker 2, not Speaker 20 or You."[f.0..f.1]).collect();
        assert_eq!(words, vec!["Marta Kováčová", "Martami", "Speaker 2"]);
        assert_eq!(renamed("Speaker 1 and Speaker 10", &[("Speaker 1".into(), "Ada".into())]), "Ada and Speaker 10");
    }

    // parity: MEET-059
    #[test]
    fn paragraphs_and_reveal() {
        let db = db();
        let d = detail(&db, SEED_FULL).unwrap().unwrap();
        let mut e = NotesEditor::new(SEED_FULL, &d.notes, d.notes_revision);
        let ps = note_paragraphs(&e.text);
        assert_eq!(ps.len(), 2);
        e.reveal(1, &sha256_hex(&ps[0].1));
        assert_eq!(e.reveal, Some((ps[0].2, ps[0].3)));
        e.reveal(1, "bad");
        assert_eq!(e.notice.as_deref(), Some("This note has changed"));
    }

    // parity: MEET-027..MEET-037 NOTE-028 LIVE-040
    #[test]
    fn failure_reasons_read_like_swift() {
        assert_eq!(failure_reason_text("storage_write_failed", None), "Recording stopped: audio could not be written to disk. What was recorded so far was kept.");
        assert_eq!(failure_reason_text("storage_unavailable", None), "Recording stopped: the meeting folder is unavailable.");
        assert_eq!(failure_reason_text("encoder_failed", None), "Recording stopped: the audio encoder failed. What was recorded so far was kept.");
        assert_eq!(failure_reason_text("not_running_at_last_state", None), "LocalFlow did not exit cleanly during this meeting. Recorded audio was recovered where possible.");
        assert_eq!(failure_reason_text("device_lost", None), "The microphone disconnected. The meeting continued with system audio.");
        assert_eq!(failure_reason_text("stream_stopped", None), "System audio stopped. The meeting continued with the microphone.");
        assert_eq!(failure_reason_text("permission_revoked", Some("microphone")), "Microphone permission was revoked during the meeting.");
        assert_eq!(failure_reason_text("permission_revoked", Some("system")), "System audio permission was revoked during the meeting.");
        assert_eq!(failure_reason_text("permission_revoked", None), "Audio permission was revoked during the meeting.");
        assert_eq!(failure_reason_text("both_sources_failed", None), "Recording stopped because both audio sources failed.");
        assert_eq!(failure_reason_text("record_missing", None), "Files were found without a meeting record. They were kept and listed here.");
        assert_eq!(failure_reason_text("file_missing", None), "The audio file for this segment is missing.");
        assert_eq!(failure_reason_text("segment_open_failed", None), "The meeting could not start because an audio file could not be created.");
        assert_eq!(failure_reason_text("media_unrecoverable", None), "This track could not be made playable. The file was kept.");
    }

    // parity: TRANS-060..TRANS-071 TRANS-059
    #[test]
    fn transcript_failures_read_like_swift() {
        assert_eq!(transcript_failure_text("finalization_interrupted", 7, true, false), "Finalization was interrupted. It will resume automatically.");
        assert_eq!(transcript_failure_text("model_unavailable", 7, false, true), "Whisper Turbo is not installed. Install the meeting model in Settings to transcribe.");
        assert_eq!(transcript_failure_text("model_unavailable", 7, false, false), "The speech model is not installed. Install it in Settings to transcribe.");
        assert_eq!(transcript_failure_text("model_provisioning", 7, false, false), "The speech model could not be verified. Reinstall it in Settings.");
        assert_eq!(transcript_failure_text("model_load_failure", 7, false, false), "The speech model failed to load. The recording was not affected.");
        assert_eq!(transcript_failure_text("audio_decode_failure", 7, false, false), "A recorded track could not be decoded. The recording was kept.");
        assert_eq!(transcript_failure_text("analysis_stream_failure", 7, false, false), "Audio could not be prepared for transcription. The recording was kept.");
        assert_eq!(transcript_failure_text("runtime_failure", 7, false, true), "Meeting transcription failed. The recording was kept; choose Retry to try again.");
        assert_eq!(transcript_failure_text("runtime_failure", 7, false, false), "Transcription stopped because the speech model failed. The recording continues.");
        assert_eq!(transcript_failure_text("finalization_interrupted", 7, true, false), "Finalization was interrupted. It will resume automatically.");
        assert_eq!(transcript_failure_text("finalization_interrupted", 7, false, false), "Finalization was interrupted. Choose Retry to finish it.");
        assert_eq!(transcript_failure_text("persistence_failure", 7, false, false), "Transcript could not be saved. The recording continues; retry later.");
        assert_eq!(transcript_failure_text("storage_limit", 7, false, false), "Transcript storage limit reached (7 segments kept). Delete old meetings to free space.");
    }

    // parity: TRANS-004..TRANS-010
    #[test]
    fn badges_read_like_swift() {
        assert_eq!(badge_text("not_requested", 0.42), "Not requested");
        assert_eq!(badge_text("pending", 0.42), "Pending");
        assert_eq!(badge_text("live", 0.42), "Live");
        assert_eq!(badge_text("finalizing", 0.42), "Finalizing 42 %");
        assert_eq!(badge_text("final", 0.42), "Final");
        assert_eq!(badge_text("failed", 0.42), "Failed");
        assert_eq!(badge_text("interrupted", 0.42), "Interrupted");
    }

    // parity: TRANS-074..TRANS-084
    #[test]
    fn section_status_reads_like_swift() {
        assert_eq!(section_status_text("pending", "", None, 0.0), "Pending");
        assert_eq!(section_status_text("live", "", Some("x"), 0.0), "Transcription failed: x");
        assert_eq!(section_status_text("not_requested", "", None, 0.0), "Transcription off");
        assert_eq!(section_status_text("final", "", None, 0.0), "Final");
        assert_eq!(section_status_text("failed", "", None, 0.0), "Transcription failed");
        assert_eq!(section_status_text("interrupted", "", None, 0.0), "Interrupted");
        assert_eq!(section_status_text("live", "catching_up", None, 0.0), "Catching up");
        assert_eq!(section_status_text("live", "degraded", None, 0.0), "Degraded — some live text skipped; the full transcript is produced when the meeting stops");
        assert_eq!(section_status_text("live", "suspended", None, 0.0), "Live transcription suspended — catching up");
        assert_eq!(section_status_text("live", "stopped", None, 0.0), "Live preview stopped");
        assert_eq!(section_status_text("live", "healthy", None, 0.0), "Transcribing");
    }

    // parity: SPK-009..SPK-018
    #[test]
    fn diarization_failures_read_like_swift() {
        assert_eq!(diarization_failure_text("model_unavailable"), "Speaker labeling model isn't installed. Install it in Settings → Models.");
        assert_eq!(diarization_failure_text("os_unsupported"), "Speaker labeling needs macOS 15 or later.");
        assert_eq!(diarization_failure_text("model_load_failure"), "The speaker labeling model couldn't be loaded.");
        assert_eq!(diarization_failure_text("audio_missing"), "This meeting's audio isn't available, so speakers can't be labeled.");
        assert_eq!(diarization_failure_text("audio_decode_failure"), "This meeting's audio couldn't be read.");
        assert_eq!(diarization_failure_text("runtime_failure"), "Speaker labeling stopped unexpectedly.");
        assert_eq!(diarization_failure_text("transcript_changed"), "The transcript changed while speakers were being labeled.");
        assert_eq!(diarization_failure_text("persistence_failure"), "Speaker labels couldn't be saved.");
        assert_eq!(diarization_failure_text("persistence_capacity"), "Speaker labels couldn't be saved. Meeting storage is full.");
        assert_eq!(diarization_failure_text("interrupted"), "Speaker labeling was interrupted.");
    }

    // parity: SPK-025..SPK-032
    #[test]
    fn identification_failures_read_like_swift() {
        assert_eq!(identification_failure_text("os_unsupported"), "Speaker identification needs macOS 15 or later.");
        assert_eq!(identification_failure_text("model_load_failure"), "The voice model couldn't be loaded.");
        assert_eq!(identification_failure_text("audio_missing"), "This meeting's audio isn't available, so speakers can't be identified.");
        assert_eq!(identification_failure_text("runtime_failure"), "Speaker identification stopped unexpectedly.");
        assert_eq!(identification_failure_text("diarization_changed"), "Speaker labels changed while speakers were being identified.");
        assert_eq!(identification_failure_text("persistence_failure"), "Speaker identities couldn't be saved.");
        assert_eq!(identification_failure_text("persistence_capacity"), "Speaker identities couldn't be saved. Meeting storage is full.");
        assert_eq!(identification_failure_text("interrupted"), "Speaker identification was interrupted.");
    }

    // parity: SUM-020..SUM-030
    #[test]
    fn summary_failures_read_like_swift() {
        assert_eq!(analysis_failure_text("server_unreachable"), "Your server could not be reached.");
        assert_eq!(analysis_failure_text("authentication_failed"), "The server rejected the credential.");
        assert_eq!(analysis_failure_text("backend_unavailable"), "The server's language model is not running.");
        assert_eq!(analysis_failure_text("backend_busy"), "The server is busy with dictation. Try again in a moment.");
        assert_eq!(analysis_failure_text("timeout"), "The summary took too long and was stopped.");
        assert_eq!(analysis_failure_text("malformed_response"), "The server sent a summary LocalFlow could not read.");
        assert_eq!(analysis_failure_text("source_validation"), "The summary did not pass LocalFlow's checks and was not saved.");
        assert_eq!(analysis_failure_text("too_long"), "This meeting is too long to summarize with the current limits.");
        assert_eq!(analysis_failure_text("persistence_failure"), "The summary couldn't be saved.");
        assert_eq!(analysis_failure_text("persistence_capacity"), "The summary couldn't be saved. Meeting storage is full.");
        assert_eq!(analysis_failure_text("interrupted"), "The summary was interrupted.");
    }

    // parity: NOTE-033..NOTE-038
    #[test]
    fn today_summary_reads_like_swift() {
        for s in ["created", "preparing", "recording"] {
            assert_eq!(today_summary(Some(s), 3), "Recording now");
        }
        assert_eq!(today_summary(Some("paused"), 3), "Recording paused");
        assert_eq!(today_summary(Some("finalizing"), 3), "Finishing the recording");
        assert_eq!(today_summary(None, 0), "No meetings today");
        assert_eq!(today_summary(None, 1), "1 meeting today");
        assert_eq!(today_summary(None, 4), "4 meetings today");
    }

    // parity: TRANS-022 TRANS-017 TRANS-023 TRANS-024 TRANS-025
    #[test]
    fn match_counts_and_empty_texts() {
        let db = db();
        let mut p = Pager::new(SEED_FULL);
        p.load_first(&db);
        p.is_searching = true;
        assert_eq!(p.match_count_text(), "Searching…");
        assert_eq!(p.no_resident_match_text(), "Searching the whole transcript…");
        p.is_searching = false;
        p.search(&db, "zebra");
        assert_eq!(p.no_resident_match_text(), "No matches.");
        p.search(&db, "the");
        assert_eq!(p.no_resident_match_text(), "No matches in this part of the transcript. Use the arrows to go to the others.");
        p.search_hits.as_mut().unwrap().1 = true;
        assert_eq!(p.match_count_text(), "11+ matches");
    }

    // parity: SUM-046 SUM-082
    #[test]
    fn removing_one_overlay_restores_the_generated_value() {
        let db = db();
        let model = read_model(&db, SEED_FULL).unwrap().unwrap();
        set_overlay(&db, SEED_FULL, OverlayTarget::Summary, "summary_text", "Edited.", Some("x"), Some("x"), "", 5).unwrap();
        let id: String = db.conn.query_row("SELECT id FROM analysis_overlays WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap();
        remove_overlay(&db, &id).unwrap();
        assert_eq!(read_model(&db, SEED_FULL).unwrap().unwrap().summary, model.ai_summary);
        let left: i64 = db.conn.query_row("SELECT count(*) FROM analysis_overlays WHERE id=?1", [&id], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
    }
}
