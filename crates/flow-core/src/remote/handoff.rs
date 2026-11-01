//! `MeetingHandoff` (ADR 0033): a finished meeting goes to the server whole, and its transcript,
//! labels and summary come back in one merge. The audio stays here until a merge or forever on a
//! failure; only the server's copy and the staged `bundle.sqlite` are ever removed. The persisted
//! state is the bundle under `Handoff/<id>/` plus the server's own state, so restarts lose nothing.
use super::transfer::{self, Action, Call, Failure, Reply, Request, State, private_dir, valid_id};
use crate::db::Db;
use crate::history::now_ms;
use crate::settings::{Service, remote_state, routing};
use crate::prefs::Prefs;
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The meeting's slice for the server.
const INPUTS: [(&str, &str); 12] = [
    ("meetings", "id=?1"),
    ("meeting_tracks", "meeting_id=?1"),
    ("meeting_segments", "track_id IN (SELECT id FROM meeting_tracks WHERE meeting_id=?1)"),
    ("meeting_pauses", "meeting_id=?1"),
    ("meeting_notes", "meeting_id=?1"),
    ("meeting_transcriptions", "meeting_id=?1"),
    ("transcript_segments", "meeting_id=?1"),
    ("transcript_live_gaps", "meeting_id=?1"),
    ("meeting_diarization", "meeting_id=?1"),
    ("meeting_analysis", "meeting_id=?1"),
    ("vocabulary_entries", "1 OR ?1"),
    ("vocabulary_state", "1 OR ?1"),
];
/// What the server's run replaces, parents first. `%@` is the schema.
const OUTPUTS: [(&str, &str); 16] = [
    ("meeting_transcriptions", "meeting_id=?1"),
    ("transcript_segments", "meeting_id=?1"),
    ("transcript_live_gaps", "meeting_id=?1"),
    ("diarization_runs", "meeting_id=?1"),
    ("meeting_speakers", "meeting_id=?1"),
    ("meeting_diarization", "meeting_id=?1"),
    ("speaker_turns", "run_id IN (SELECT id FROM %@.diarization_runs WHERE meeting_id=?1)"),
    ("speaker_assignments", "run_id IN (SELECT id FROM %@.diarization_runs WHERE meeting_id=?1)"),
    ("speaker_corrections", "meeting_id=?1"),
    ("analysis_runs", "meeting_id=?1"),
    ("meeting_analysis", "meeting_id=?1"),
    ("analysis_summaries", "meeting_id=?1"),
    ("analysis_topics", "meeting_id=?1"),
    ("analysis_items", "meeting_id=?1"),
    ("analysis_sources", "meeting_id=?1"),
    ("analysis_overlays", "meeting_id=?1"),
];
/// A phone meeting's recording rows in a downloaded bundle.
const RECORDING_ROWS: [(&str, &str); 5] = [
    ("meetings", "id=?1"),
    ("meeting_tracks", "meeting_id=?1"),
    ("meeting_segments", "track_id IN (SELECT id FROM %@.meeting_tracks WHERE meeting_id=?1)"),
    ("meeting_pauses", "meeting_id=?1"),
    ("meeting_notes", "meeting_id=?1"),
];
const INFERENCE_TABLES: [&str; 3] = ["meeting_transcriptions", "diarization_runs", "analysis_runs"];
const MAX_RELATIVE_PATH: usize = 255;
/// Progress handler ticks a bundle's queries may run, 10,000 VM steps each: seconds of work, far
/// beyond any real meeting's rows.
const BUNDLE_TICKS: u32 = 100_000;
/// A row citing a segment outside its meeting: a foreign key alone would let one meeting's analysis
/// quote another's transcript.
const OUTSIDE_CITATIONS: [&str; 3] = [
    "SELECT EXISTS(SELECT 1 FROM main.analysis_sources WHERE meeting_id=?1 AND segment_id NOT IN (SELECT id FROM main.transcript_segments WHERE meeting_id=?1))",
    "SELECT EXISTS(SELECT 1 FROM main.analysis_items WHERE meeting_id=?1 AND due_source_segment_id NOT IN (SELECT id FROM main.transcript_segments WHERE meeting_id=?1))",
    "SELECT EXISTS(SELECT 1 FROM main.speaker_assignments WHERE run_id IN (SELECT id FROM main.diarization_runs WHERE meeting_id=?1) AND segment_id NOT IN (SELECT id FROM main.transcript_segments WHERE meeting_id=?1))",
];
/// `serverProgressInterval`: a processing meeting is asked this often.
pub const PROGRESS_EVERY: Duration = Duration::from_secs(10);
/// `phoneImportInterval`.
pub const IMPORT_EVERY: Duration = Duration::from_secs(600);

#[derive(Clone, Debug, PartialEq)]
pub enum Step {
    /// The meeting doesn't go to the server, or no longer does. Nothing is staged.
    NotHandedOff,
    /// Queued, or not reachable right now. The code is `server_failure`, `queued` or `checksum_mismatch`.
    Waiting(String),
    /// Running; the fraction done once the processor has reported.
    Processing(Option<f64>),
    Merged { labeled: bool },
}

impl From<rusqlite::Error> for Failure {
    fn from(_: rusqlite::Error) -> Failure {
        Failure::Local
    }
}
impl From<crate::db::DbError> for Failure {
    fn from(_: crate::db::DbError) -> Failure {
        Failure::Local
    }
}

/// `MeetingStorageRoot.resolve`: a stored path stays inside the root. A bundle's path is server data.
fn resolve(root: &Path, relative: &str) -> Option<PathBuf> {
    let safe = !relative.is_empty() && relative.len() <= MAX_RELATIVE_PATH && !relative.starts_with('/') && !relative.contains(['\0', '\\', ':']) && relative.split('/').all(|p| !p.is_empty() && p != "." && p != ".." && !windows_special(p));
    safe.then(|| root.join(relative))
}

/// Windows strips a trailing dot or space and opens a device for a reserved name, with any extension.
/// Refused on every platform: a bundle is the same data wherever it lands.
fn windows_special(part: &str) -> bool {
    if part.ends_with(['.', ' ']) {
        return true;
    }
    let stem = part.split('.').next().unwrap_or(part).trim_end_matches(' ').to_ascii_uppercase();
    let numbered = (stem.starts_with("COM") || stem.starts_with("LPT")) && stem.chars().count() == 4 && stem.chars().last().is_some_and(|c| matches!(c, '1'..='9' | '¹' | '²' | '³'));
    numbered || ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(&stem.as_str())
}

/// Attaches a server's database as `result` with nothing in it able to run: no view or trigger, no
/// untrusted schema function, and a limit on the work its queries do.
fn attach_result(conn: &Connection, url: &Path) -> Result<(), Failure> {
    limit_work(conn, BUNDLE_TICKS);
    conn.execute_batch("PRAGMA trusted_schema=OFF")?;
    conn.execute("ATTACH DATABASE ?1 AS result", [url.to_string_lossy()])?;
    let active: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM result.sqlite_master WHERE type IN ('view','trigger') OR sql LIKE 'CREATE VIRTUAL%')", [], |r| r.get(0))?;
    if active { Err(Failure::Refused) } else { Ok(()) }
}

fn limit_work(conn: &Connection, ticks: u32) {
    let mut left = ticks;
    conn.progress_handler(10_000, Some(move || {
        left = left.saturating_sub(1);
        left == 0
    }));
}

fn refuse_outside_citations(conn: &Connection, id: &str) -> Result<(), Failure> {
    for query in OUTSIDE_CITATIONS {
        if conn.query_row(query, [id], |r| r.get(0))? {
            return Err(Failure::Refused);
        }
    }
    Ok(())
}

/// `<data>/Handoff/<id>` folders with a staged bundle.
fn staged_in(directory: &Path) -> Vec<String> {
    std::fs::read_dir(directory).into_iter().flatten().flatten().filter_map(|e| e.file_name().into_string().ok()).filter(|n| valid_id(n) && directory.join(n).join("bundle.sqlite").exists()).collect()
}

/// Turning off: every staged bundle goes, so none reaches the next server paired. The recordings stay
/// under `root`, and `pending` exports the meeting again under whatever route comes next.
pub fn forget_staged(root: &Path) {
    let directory = root.parent().unwrap_or(root).join("Handoff");
    for id in staged_in(&directory) {
        let _ = std::fs::remove_dir_all(directory.join(id));
    }
}

/// Comma-joined quoted columns both schemas have: `trigger` is a keyword.
fn columns(conn: &Connection, table: &str, a: &str, b: &str) -> rusqlite::Result<String> {
    Ok(column_names(conn, table, a)?.iter().filter(|c| column_names(conn, table, b).is_ok_and(|other| other.contains(c))).map(|c| format!("\"{c}\"")).collect::<Vec<_>>().join(","))
}
fn column_names(conn: &Connection, table: &str, schema: &str) -> rusqlite::Result<Vec<String>> {
    conn.prepare("SELECT name FROM pragma_table_info(?1, ?2)")?.query_map([table, schema], |r| r.get(0))?.collect()
}

fn insert_from_result(conn: &Connection, table: &str, filter: &str, id: &str) -> rusqlite::Result<()> {
    let mut list = columns(conn, table, "main", "result")?;
    // speaker_turns has an integer key; this database numbers its own rows.
    if table == "speaker_turns" {
        list = list.split(',').filter(|c| *c != "\"id\"").collect::<Vec<_>>().join(",");
    }
    conn.execute(&format!("INSERT INTO main.{table}({list}) SELECT {list} FROM result.{table} WHERE {}", filter.replace("%@", "result")), [id])?;
    Ok(())
}

/// The server ran these stages; returns whether a diarization run was accepted.
fn finish_merge(conn: &Connection, id: &str) -> rusqlite::Result<bool> {
    for table in INFERENCE_TABLES {
        if column_names(conn, table, "main")?.iter().any(|c| c == "inference_path") {
            conn.execute(&format!("UPDATE main.{table} SET inference_path='server' WHERE meeting_id=?1"), [id])?;
        }
    }
    Ok(conn.query_row("SELECT accepted_run_id IS NOT NULL FROM main.meeting_diarization WHERE meeting_id=?1", [id], |r| r.get(0)).optional()?.unwrap_or(false))
}

/// The bundle-side wall of the handoff. A `Mutex` keeps it one operation at a time, as Swift's actor.
pub struct Handoff {
    call: Box<dyn Fn(&Request) -> Result<Reply, Failure> + Send + Sync>,
    database: PathBuf,
    root: PathBuf,
    directory: PathBuf,
    upload_retry: Duration,
    lock: Mutex<()>,
}

impl Handoff {
    /// `root` is `<data>/Meetings`; bundles sit beside it in `<data>/Handoff`.
    pub fn new(call: impl Fn(&Request) -> Result<Reply, Failure> + Send + Sync + 'static, database: &Path, root: &Path) -> Handoff {
        let directory = root.parent().unwrap_or(root).join("Handoff");
        Handoff { call: Box::new(call), database: database.into(), root: root.into(), directory, upload_retry: Duration::from_secs(1), lock: Mutex::new(()) }
    }

    fn dir(&self, id: &str) -> PathBuf {
        self.directory.join(id)
    }
    fn request(&self, request: Request) -> Result<Reply, Failure> {
        (self.call)(&request)
    }
    fn forget(&self, id: &str) {
        let _ = std::fs::remove_dir_all(self.dir(id));
    }
    fn abandon(&self, id: &str) {
        let _ = self.request(Request::new(Action::Delete, Some(id)));
        self.forget(id);
    }

    /// Meetings with a staged bundle: their handoff continues across launches and route changes.
    pub fn in_flight(&self) -> Vec<String> {
        staged_in(&self.directory)
    }

    /// One pass of the meeting's handoff.
    pub fn step(&self, id: &str, eligible: bool, language: &str) -> Step {
        let _one = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        match self.advance(id, eligible, language) {
            Ok(step) => step,
            Err(Failure::NotOffered) => {
                self.forget(id);
                Step::NotHandedOff
            }
            Err(Failure::Refused) => {
                self.abandon(id);
                Step::NotHandedOff
            }
            Err(Failure::Waiting(code)) => Step::Waiting(code),
            Err(Failure::ChecksumMismatch) => Step::Waiting("checksum_mismatch".into()),
            Err(Failure::Local) => Step::Waiting("unreachable".into()),
        }
    }

    fn advance(&self, id: &str, eligible: bool, language: &str) -> Result<Step, Failure> {
        let bundle = self.dir(id).join("bundle.sqlite");
        if !bundle.exists() {
            if !eligible || !self.export(id, &bundle, language)? {
                return Ok(Step::NotHandedOff);
            }
        } else {
            let db = Db::open(&self.database)?;
            let local: Option<bool> = db.conn.query_row("SELECT run_locally FROM meetings WHERE id=?1", [id], |r| r.get(0)).optional()?;
            // Moved to this device, or deleted while the delete couldn't reach the server.
            // The bundle goes only once the server answered, so a later step repeats the delete.
            if local != Some(false) {
                self.request(Request::new(Action::Delete, Some(id)))?;
                self.forget(id);
                return Ok(Step::NotHandedOff);
            }
        }
        let list = self.request(Request::new(Action::List, None))?;
        let entry = list.meetings.unwrap_or_default().into_iter().find(|e| e.meeting.eq_ignore_ascii_case(id));
        match entry.as_ref().map(|e| e.state) {
            None | Some(State::Missing | State::Receiving) => {
                self.upload(id, &bundle)?;
                self.request(Request::new(Action::Start, Some(id)))?;
                Ok(Step::Waiting("queued".into()))
            }
            Some(State::Queued) => Ok(Step::Waiting("queued".into())),
            Some(State::Processing) => Ok(Step::Processing(entry.and_then(|e| e.progress).map(|p| f64::from(p) / 100.))),
            Some(State::Failed) => {
                self.abandon(id);
                Ok(Step::NotHandedOff)
            }
            Some(State::Done) => {
                let result = self.dir(id).join("result.sqlite");
                self.fetch(id, None, &result)?;
                let Ok(labeled) = self.merge(id, &result) else {
                    self.abandon(id);
                    return Ok(Step::NotHandedOff);
                };
                let _ = self.request(Request::new(Action::Delete, Some(id)));
                self.forget(id);
                Ok(Step::Merged { labeled })
            }
        }
    }

    fn with_call<T>(&self, f: impl FnOnce(Call) -> T) -> T {
        f(&*self.call)
    }

    /// A checksum failure on the way back is a broken result: it would fail the same way again.
    fn fetch(&self, id: &str, name: Option<&str>, target: &Path) -> Result<(), Failure> {
        self.with_call(|call| transfer::get(id, name, target, call)).map_err(|e| if e == Failure::ChecksumMismatch { Failure::Refused } else { e })
    }

    /// The finished segments, then the bundle.
    fn upload(&self, id: &str, bundle: &Path) -> Result<(), Failure> {
        let db = Db::open(&self.database)?;
        let paths: Vec<String> = db.conn.prepare("SELECT s.relative_path FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id WHERE t.meeting_id=?1 AND s.state='finalized' ORDER BY s.relative_path")?.query_map([id], |r| r.get(0))?.collect::<Result<_, _>>()?;
        drop(db);
        for relative in paths {
            let file = resolve(&self.root, &relative).ok_or(Failure::Refused)?;
            let name = file.file_name().and_then(|n| n.to_str()).ok_or(Failure::Refused)?;
            self.with_call(|call| transfer::put(id, name, &file, self.upload_retry, call))?;
        }
        self.with_call(|call| transfer::put(id, "bundle.sqlite", bundle, self.upload_retry, call))
    }

    /// Stages `bundle.sqlite`. False when the meeting isn't finished or a label or summary already exists.
    pub fn export(&self, id: &str, url: &Path, language: &str) -> Result<bool, Failure> {
        let db = Db::open(&self.database)?;
        let terminal: bool = db.conn.query_row("SELECT state IN ('completed','interrupted','failed') FROM meetings WHERE id=?1", [id], |r| r.get(0)).optional()?.unwrap_or(false);
        let labeled: bool = db.conn.query_row("SELECT EXISTS(SELECT 1 FROM meeting_diarization WHERE meeting_id=?1 AND (accepted_run_id IS NOT NULL OR current_run_id IS NOT NULL)) OR EXISTS(SELECT 1 FROM meeting_analysis WHERE meeting_id=?1 AND (accepted_run_id IS NOT NULL OR current_run_id IS NOT NULL))", [id], |r| r.get(0))?;
        if !terminal || labeled {
            return Ok(false);
        }
        let folder = url.parent().ok_or(Failure::Local)?;
        private_dir(folder)?;
        let staging = folder.join("staging.sqlite");
        let _ = std::fs::remove_file(&staging);
        // Same schema as this database, so every table exists with its constraints.
        drop(Db::open_or_create(&staging)?);
        let conn = &db.conn;
        conn.execute("ATTACH DATABASE ?1 AS bundle", [staging.to_string_lossy()])?;
        let tx = conn.unchecked_transaction()?;
        for (table, filter) in INPUTS {
            let list = columns(conn, table, "main", "bundle")?;
            // The filter names unqualified tables; `main` is searched first.
            conn.execute(&format!("INSERT OR REPLACE INTO bundle.{table}({list}) SELECT {list} FROM main.{table} WHERE {filter}"), [id])?;
        }
        conn.execute("UPDATE bundle.meetings SET language=?1 WHERE id=?2 AND language IS NULL", [language, id])?;
        // The bundle's capacity counter covers only this meeting.
        conn.execute_batch("UPDATE bundle.transcript_usage SET text_bytes=COALESCE((SELECT text_bytes FROM bundle.meeting_transcriptions),0), segment_rows=COALESCE((SELECT segment_count FROM bundle.meeting_transcriptions),0)")?;
        tx.commit()?;
        conn.execute_batch("DETACH DATABASE bundle")?;
        std::fs::rename(&staging, url)?;
        Ok(true)
    }

    /// Replaces this meeting's transcript, labels and summary with the server's rows in one
    /// transaction, keeping the capacity counter exact. The recording's own rows aren't touched.
    pub fn merge(&self, id: &str, url: &Path) -> Result<bool, Failure> {
        let db = Db::open(&self.database)?;
        let conn = &db.conn;
        attach_result(conn, url)?;
        let tx = conn.unchecked_transaction()?;
        let is_final: Option<bool> = conn.query_row("SELECT state='final' FROM result.meeting_transcriptions WHERE meeting_id=?1", [id], |r| r.get(0)).optional()?;
        let present = conn.query_row("SELECT 1 FROM main.meetings WHERE id=?1", [id], |_| Ok(())).optional()?.is_some();
        if is_final != Some(true) || !present {
            return Err(Failure::Refused);
        }
        conn.execute_batch("PRAGMA defer_foreign_keys=ON")?;
        conn.execute(
            "UPDATE main.transcript_usage SET
              text_bytes=text_bytes-COALESCE((SELECT text_bytes FROM main.meeting_transcriptions WHERE meeting_id=?1),0)+(SELECT text_bytes FROM result.meeting_transcriptions WHERE meeting_id=?1),
              segment_rows=segment_rows-COALESCE((SELECT segment_count FROM main.meeting_transcriptions WHERE meeting_id=?1),0)+(SELECT segment_count FROM result.meeting_transcriptions WHERE meeting_id=?1)
             WHERE id=1",
            [id],
        )?;
        for (table, filter) in OUTPUTS.into_iter().rev() {
            conn.execute(&format!("DELETE FROM main.{table} WHERE {}", filter.replace("%@", "main")), [id])?;
        }
        for (table, filter) in OUTPUTS {
            insert_from_result(conn, table, filter, id)?;
        }
        refuse_outside_citations(conn, id)?;
        let labeled = finish_merge(conn, id)?;
        tx.commit()?;
        Ok(labeled)
    }

    /// The meeting is about to be deleted: nothing of it stays on the server.
    pub fn meeting_will_delete(&self, id: &str) {
        let _one = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        // On a failure the bundle stays, and the step that finds its meeting gone deletes again.
        if self.dir(id).join("bundle.sqlite").exists() && self.request(Request::new(Action::Delete, Some(id))).is_ok() {
            self.forget(id);
        }
    }

    /// Imports every finished phone meeting waiting here: another device's, with a copy asked for,
    /// released, `done`. A failure leaves this device unchanged and keeps the server copy for the
    /// next call. A meeting already here isn't imported again; its server copy goes.
    pub fn import_phone_meetings(&self) -> Vec<(String, bool)> {
        let _one = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let Ok(list) = self.request(Request::new(Action::List, None)) else { return vec![] };
        let mut imported = vec![];
        for entry in list.meetings.unwrap_or_default() {
            if entry.mine || !entry.copy || !entry.released || entry.state != State::Done {
                continue;
            }
            let id = entry.meeting;
            let folder = self.directory.join(format!("Import-{id}"));
            let outcome = self.import_meeting(&id, &folder);
            let _ = std::fs::remove_dir_all(&folder);
            match outcome {
                Ok(Some(labeled)) => imported.push((id.clone(), labeled)),
                Ok(None) => {}
                Err(_) => continue,
            }
            let _ = self.request(Request::new(Action::Delete, Some(&id)));
        }
        imported
    }

    fn import_meeting(&self, id: &str, folder: &Path) -> Result<Option<bool>, Failure> {
        let db = Db::open(&self.database)?;
        if db.conn.query_row("SELECT 1 FROM meetings WHERE id=?1", [id], |_| Ok(())).optional()?.is_some() {
            return Ok(None);
        }
        let _ = std::fs::remove_dir_all(folder);
        private_dir(folder)?;
        let bundle = folder.join("bundle.sqlite");
        self.fetch(id, None, &bundle)?;
        attach_result(&db.conn, &bundle)?;
        let rows: Vec<(String, bool)> = db.conn.prepare("SELECT s.relative_path, s.state='finalized' FROM result.meeting_segments s JOIN result.meeting_tracks t ON t.id=s.track_id WHERE t.meeting_id=?1 ORDER BY s.relative_path")?.query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
        // Every file is downloaded and verified before anything is placed.
        let mut files = vec![];
        for (relative, finalized) in rows {
            // Every row's path is checked: these rows get stored, whether or not a file comes with them.
            let target = resolve(&self.root, &relative).filter(|_| relative.starts_with(&format!("{id}/"))).ok_or(Failure::Refused)?;
            if !finalized {
                continue;
            }
            if target.exists() {
                return Err(Failure::Refused);
            }
            let name = target.file_name().and_then(|n| n.to_str()).ok_or(Failure::Refused)?.to_string();
            let download = folder.join(&name);
            self.fetch(id, Some(&name), &download)?;
            files.push((download, target));
        }
        let mut placed = vec![];
        let outcome = (|| {
            for (download, target) in &files {
                private_dir(target.parent().ok_or(Failure::Local)?)?;
                std::fs::rename(download, target)?;
                placed.push(target.clone());
            }
            insert_imported(&db.conn, id)
        })();
        if outcome.is_err() {
            placed.iter().for_each(|p| drop(std::fs::remove_file(p)));
            if !placed.is_empty() {
                let _ = std::fs::remove_dir_all(self.root.join(id));
            }
        }
        outcome.map(Some)
    }
}

fn insert_imported(conn: &Connection, id: &str) -> Result<bool, Failure> {
    let tx = conn.unchecked_transaction()?;
    let is_final: Option<bool> = conn.query_row("SELECT state='final' FROM result.meeting_transcriptions WHERE meeting_id=?1", [id], |r| r.get(0)).optional()?;
    let finished: Option<bool> = conn.query_row("SELECT state IN ('completed','interrupted') FROM result.meetings WHERE id=?1", [id], |r| r.get(0)).optional()?;
    let present = conn.query_row("SELECT 1 FROM main.meetings WHERE id=?1", [id], |_| Ok(())).optional()?.is_some();
    if is_final != Some(true) || finished != Some(true) || present {
        return Err(Failure::Refused);
    }
    conn.execute_batch("PRAGMA defer_foreign_keys=ON")?;
    conn.execute(
        "UPDATE main.transcript_usage SET
          text_bytes=text_bytes+(SELECT text_bytes FROM result.meeting_transcriptions WHERE meeting_id=?1),
          segment_rows=segment_rows+(SELECT segment_count FROM result.meeting_transcriptions WHERE meeting_id=?1)
         WHERE id=1",
        [id],
    )?;
    for (table, filter) in RECORDING_ROWS.into_iter().chain(OUTPUTS) {
        insert_from_result(conn, table, filter, id)?;
    }
    refuse_outside_citations(conn, id)?;
    conn.execute("UPDATE main.meetings SET origin='iphone', run_locally=0 WHERE id=?1", [id])?;
    let labeled = finish_merge(conn, id)?;
    tx.commit()?;
    Ok(labeled)
}

/// `ServerWaits`: when each waiting meeting is next tried.
#[derive(Default)]
pub struct Waits {
    attempts: HashMap<String, u32>,
    retry: HashMap<String, Instant>,
}

impl Waits {
    /// `every`: a fixed interval that doesn't back off. Otherwise 30 s doubling to 10 minutes.
    pub fn wait(&mut self, id: &str, every: Option<Duration>, now: Instant) {
        let attempt = self.attempts.get(id).copied().unwrap_or(0);
        self.attempts.insert(id.into(), if every.is_some() { 0 } else { attempt + 1 });
        let delay = every.unwrap_or(Duration::from_secs(600.min(30u64 << attempt.min(5))));
        self.retry.insert(id.into(), now + delay);
    }
    pub fn due(&self, id: &str, now: Instant) -> bool {
        self.retry.get(id).is_none_or(|at| *at <= now)
    }
    pub fn remove(&mut self, id: &str) {
        self.attempts.remove(id);
        self.retry.remove(id);
    }
    /// The server answered: nothing waits on a long backoff any more.
    pub fn reachable(&mut self, now: Instant) {
        self.attempts.clear();
        self.retry.values_mut().for_each(|at| *at = now);
    }
}

/// What this device does with a finished meeting's transcript.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// `eligible`: the server runs transcripts and summaries and offers the handoff.
    Hand,
    /// The server has to run it and can't yet: pairing isn't approved, its capabilities aren't known
    /// to include the handoff, or server-only is on. The row reads "Waiting for your server".
    Wait,
    /// This client has no local run, so the meeting gets no transcript.
    Off,
}

pub fn route(p: &Prefs) -> Route {
    let r = routing(p);
    if r.capabilities.ops.contains("handoff") && r.served(Service::FinalTranscript) && r.served(Service::Summaries) {
        Route::Hand
    } else if r.server_only || remote_state(p) == "pending" || (r.routes && r.use_for_everything && r.meetings == "server" && r.summaries == "server" && r.consent_current) {
        Route::Wait
    } else {
        Route::Off
    }
}

/// Finished meetings whose transcript the handoff owes.
pub fn pending(db: &Db) -> rusqlite::Result<Vec<String>> {
    db.conn.prepare("SELECT m.id FROM meetings m JOIN meeting_transcriptions t ON t.meeting_id=m.id WHERE m.state IN ('completed','interrupted','failed') AND t.state IN ('pending','finalizing') AND m.run_locally=0 ORDER BY m.created_at")?.query_map([], |r| r.get(0))?.collect()
}

/// The server won't produce it. The audio stays and Retry shows.
pub fn fail_transcription(db: &Db, id: &str, detail: &str) -> rusqlite::Result<usize> {
    db.conn.execute("UPDATE meeting_transcriptions SET state='failed', failure_category='runtime_failure', failure_detail=?2, updated_at=?3, revision=revision+1 WHERE meeting_id=?1 AND state IN ('pending','finalizing')", params![id, detail, now_ms()])
}

/// Transcribe or Retry: back in the queue.
pub fn request_again(db: &Db, id: &str) -> rusqlite::Result<usize> {
    db.conn.execute("UPDATE meeting_transcriptions SET state='pending', failure_category=NULL, failure_detail=NULL, updated_at=?2, revision=revision+1 WHERE meeting_id=?1 AND state IN ('not_requested','failed','interrupted')", params![id, now_ms()])
}

/// One tick's inputs, read from preferences on the foreground.
#[derive(Clone, Debug)]
pub struct Plan {
    pub route: Route,
    /// The server offers the op, whatever this device routes there: phone meetings still come.
    pub offers: bool,
    pub language: String,
}

/// What a tick changed, for the Notetaker.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Tick {
    pub waiting: BTreeSet<String>,
    /// Rows changed: re-read the library and the open note.
    pub changed: bool,
    /// A meeting's step ran and the server answered.
    pub answered: bool,
    /// Meetings whose transcript and speakers just merged: their evidence settled.
    pub merged: Vec<String>,
}

/// The automatic retries: at most one meeting's step per tick, so uploads run one at a time on the
/// caller's background thread.
pub struct Queue {
    handoff: Arc<Handoff>,
    waits: Waits,
    last_import: Option<Instant>,
}

impl Queue {
    pub fn new(handoff: Arc<Handoff>) -> Queue {
        Queue { handoff, waits: Waits::default(), last_import: None }
    }

    pub fn tick(&mut self, plan: &Plan, now: Instant) -> Result<Tick, Failure> {
        let db = Db::open(&self.handoff.database)?;
        let flying = self.handoff.in_flight();
        let mut tick = Tick::default();
        let mut queued = pending(&db)?;
        if plan.route == Route::Off {
            for id in queued.drain(..).filter(|id| !flying.contains(id)) {
                tick.changed |= fail_transcription(&db, &id, "server_off")? > 0;
            }
        }
        // A bundle in flight finishes whatever the route is now.
        let mut work: Vec<String> = flying.clone();
        if plan.route == Route::Hand {
            work.extend(queued.iter().filter(|id| !flying.contains(id)).cloned());
        }
        tick.waiting = queued.iter().chain(&flying).cloned().collect();
        if let Some(id) = work.iter().find(|id| self.waits.due(id, now)).cloned() {
            let local: bool = db.conn.query_row("SELECT run_locally FROM meetings WHERE id=?1", [&id], |r| r.get(0)).optional()?.unwrap_or(true);
            let eligible = plan.route == Route::Hand && !local;
            match self.handoff.step(&id, eligible, &plan.language) {
                Step::NotHandedOff => {
                    self.waits.remove(&id);
                    tick.waiting.remove(&id);
                    tick.changed = true;
                    if !local {
                        fail_transcription(&db, &id, "server_refused")?;
                    }
                }
                Step::Waiting(code) => {
                    self.waits.wait(&id, None, now);
                    if code == "queued" {
                        tick.answered = true;
                    }
                }
                Step::Processing(_) => {
                    self.waits.wait(&id, Some(PROGRESS_EVERY), now);
                    tick.answered = true;
                }
                Step::Merged { .. } => {
                    self.waits.remove(&id);
                    tick.waiting.remove(&id);
                    tick.changed = true;
                    tick.answered = true;
                    tick.merged.push(id);
                }
            }
        }
        if plan.offers && self.last_import.is_none_or(|at| now.duration_since(at) >= IMPORT_EVERY) {
            self.last_import = Some(now);
            tick.changed |= !self.handoff.import_phone_meetings().is_empty();
        }
        Ok(tick)
    }
}

#[cfg(test)]
mod tests;
