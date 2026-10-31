//! Store and logic behind the Transcriptions page: ports of `TranscriptionStore`, the history half
//! of `PendingRemoteDictationStore` and `HistoryViewModel`.
use crate::db::Db;
use crate::dictionary::nfc;
use rusqlite::{OptionalExtension, Row, params};
use serde_json::{Value, json};
use std::path::Path;

pub const PAGE_SIZE: usize = 20;
pub const RESIDENT_LIMIT: usize = 200;
pub const MAX_ATTEMPTS: usize = 10;
pub const MAX_PENDING_OVERALL: usize = 2;
pub const MAX_PENDING_ROWS: usize = 20;
pub const PENDING_MAX_AGE_MS: i64 = 24 * 3_600_000;
pub const SEARCH_LIMIT_MESSAGE: &str = "Search is limited to 256 Unicode scalars and 1 KiB. Shorten your search.";
pub const READ_ERROR: &str = "History could not be read. Your saved text has not been deleted. Try again.";
pub const ACTION_ERROR: &str = "The change could not be saved. The saved text is still available. Refresh and try again.";
pub const DETAIL_ERROR: &str = "Processing details could not be read. Try again.";
pub const PENDING_ERROR: &str = "The waiting dictation could not be changed. Try again.";
pub const LEGACY_DETAIL: &str = "Legacy: raw output and processing metadata unavailable";
const MAX_REWRITE_INPUT: usize = 65_536;
const MAX_REWRITE_SCALARS: usize = 20_000;

// ---- Small helpers shared with the other stores ----

pub fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// Uppercase v4 UUID, as Swift's `uuidString`. SQLite supplies the random bytes.
pub fn new_uuid(db: &Db) -> String {
    let h: String = db.conn.query_row("SELECT hex(randomblob(16))", [], |r| r.get(0)).unwrap_or_else(|_| format!("{:032X}", now_ms()));
    let variant = u8::from_str_radix(&h[16..17], 16).unwrap_or(8) & 3 | 8;
    format!("{}-{}-4{}-{variant:X}{}-{}", &h[..8], &h[8..12], &h[13..16], &h[17..20], &h[20..32])
}

/// SHA-256, hand-written because `flow-core`'s dependencies stop at rusqlite and serde.
pub fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be,
        0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa,
        0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85,
        0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
        0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut m = data.to_vec();
    m.push(0x80);
    while m.len() % 64 != 56 {
        m.push(0);
    }
    m.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for chunk in m.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([chunk[4 * i], chunk[4 * i + 1], chunk[4 * i + 2], chunk[4 * i + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7].wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [t1.wrapping_add(t2), v[0], v[1], v[2], v[3].wrapping_add(t1), v[4], v[5], v[6]];
        }
        for i in 0..8 {
            h[i] = h[i].wrapping_add(v[i]);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

/// A timestamp in local time. SQLite's `localtime` is the only clock conversion `flow-core` needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Local {
    pub year: i64,
    pub month: i64,
    pub day: i64,
    pub hour: i64,
    pub minute: i64,
    /// 0 is Sunday.
    pub weekday: i64,
}

pub fn local(db: &Db, ms: i64) -> Local {
    let s: String = db
        .conn
        .query_row("SELECT strftime('%Y %m %d %H %M %w', ?/1000, 'unixepoch', 'localtime')", [ms], |r| r.get(0))
        .unwrap_or_else(|_| "1970 01 01 00 00 4".into());
    let p: Vec<i64> = s.split(' ').map(|x| x.parse().unwrap_or(0)).collect();
    Local { year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4], weekday: p[5] }
}

/// Days since 1970-01-01 for a calendar date (Hinnant's days_from_civil).
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + if m <= 2 { 1 } else { 0 }, m, doy - (153 * mp + 2) / 5 + 1)
}

impl Local {
    pub fn day_number(&self) -> i64 {
        days_from_civil(self.year, self.month, self.day)
    }
}

pub const MONTHS: [&str; 12] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

pub fn month_short(m: i64) -> &'static str {
    &MONTHS[(m - 1).clamp(0, 11) as usize][..3]
}

/// The system locale's formats, set once at launch by the composition root. Without one (Windows
/// until its service is written, and tests) the fallbacks below print a fixed en-GB shape.
#[derive(Clone, Copy)]
pub struct Region {
    /// (milliseconds, template such as "dMMM" or "short-time", read the fields as UTC).
    pub date: fn(i64, &str, bool) -> Option<String>,
    /// (value, exact fraction digits).
    pub number: fn(f64, u8) -> Option<String>,
    /// 1 is Sunday, as in `Calendar.firstWeekday`.
    pub first_weekday: i64,
}

thread_local! {
    // ponytail: per thread, because every format call is on the UI thread; tests get their own.
    static REGION: std::cell::Cell<Option<Region>> = const { std::cell::Cell::new(None) };
}

pub fn set_region(region: Region) {
    REGION.with(|r| r.set(Some(region)));
}

pub fn region() -> Option<Region> {
    REGION.with(|r| r.get())
}

/// A date in the region's format; `None` when no region is set.
pub fn region_date(ms: i64, template: &str, utc: bool) -> Option<String> {
    region().and_then(|r| (r.date)(ms, template, utc))
}

pub fn region_number(value: f64, digits: u8) -> Option<String> {
    region().and_then(|r| (r.number)(value, digits))
}

/// `.dateTime.hour().minute()`.
pub fn time_of(db: &Db, ms: i64) -> String {
    region_date(ms, "jmm", false).unwrap_or_else(|| {
        let l = local(db, ms);
        format!("{:02}:{:02}", l.hour, l.minute)
    })
}

/// `.dateTime.day().month().hour().minute()`, for a waiting recording.
pub fn day_time(db: &Db, ms: i64) -> String {
    region_date(ms, "dMMMjmm", false).unwrap_or_else(|| {
        let l = local(db, ms);
        format!("{} {}, {:02}:{:02}", l.day, month_short(l.month), l.hour, l.minute)
    })
}

/// Swift's `.day().month(.abbreviated)`, with the year when it isn't this year.
pub fn short_day(db: &Db, ms: i64) -> String {
    let d = local(db, ms);
    let now = local(db, now_ms());
    region_date(ms, if d.year == now.year { "dMMM" } else { "yMMMd" }, false).unwrap_or_else(|| if d.year == now.year { format!("{} {}", d.day, month_short(d.month)) } else { format!("{} {} {}", d.day, month_short(d.month), d.year) })
}

/// Swift's `Double.description` for values that appear in the detail view.
pub fn double_text(v: f64) -> String {
    if v.fract() == 0.0 && v.abs() < 1e16 { format!("{v:.1}") } else { format!("{v}") }
}

// ---- Entries ----

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: String,
    pub text: String,
    pub created_at: i64,
    pub delivery_state: String,
    pub recovery_state: String,
    pub quality: String,
    pub stop_reason: String,
    pub target_bundle_id: Option<String>,
    pub attempt_id: Option<String>,
    pub revision: i64,
    pub rewrite_state: String,
    pub delivered_source: Option<String>,
    pub delivered_rewrite_attempt_id: Option<String>,
    pub recognition_path: String,
    pub server_failure: Option<String>,
    pub input_device_name: Option<String>,
    pub input_device_kind: Option<String>,
}

const ENTRY_COLUMNS: &str = "id,text,created_at,delivery_state,recovery_state,quality,stop_reason,target_bundle_id,attempt_id,revision,rewrite_state,delivered_source,delivered_rewrite_attempt_id,recognition_path,server_failure,input_device_name,input_device_kind";

fn entry_row(r: &Row) -> rusqlite::Result<Entry> {
    Ok(Entry {
        id: r.get(0)?,
        text: r.get(1)?,
        created_at: r.get(2)?,
        delivery_state: r.get(3)?,
        recovery_state: r.get(4)?,
        quality: r.get(5)?,
        stop_reason: r.get(6)?,
        target_bundle_id: r.get(7)?,
        attempt_id: r.get(8)?,
        revision: r.get(9)?,
        rewrite_state: r.get(10)?,
        delivered_source: r.get(11)?,
        delivered_rewrite_attempt_id: r.get(12)?,
        recognition_path: r.get(13)?,
        server_failure: r.get(14)?,
        input_device_name: r.get(15)?,
        input_device_kind: r.get(16)?,
    })
}

impl Entry {
    pub fn quality_label(&self) -> Option<&'static str> {
        match self.quality.as_str() {
            "incomplete" => Some("Incomplete"),
            "duration_limited" => Some("Cut short at 180 seconds"),
            _ => None,
        }
    }
    pub fn is_confirmed(&self) -> bool {
        self.delivery_state == "confirmed"
    }
    pub fn is_attempting(&self) -> bool {
        self.delivery_state == "attempting"
    }
    pub fn microphone_label(&self) -> String {
        let valid = self.input_device_kind.as_deref().is_some_and(|k| ["builtIn", "usb", "bluetooth", "iPhone", "virtual", "other", "systemDefault"].contains(&k));
        match (&self.input_device_name, valid) {
            (Some(n), true) if !n.is_empty() => format!("Microphone: {n}"),
            _ => "Microphone: Not recorded".into(),
        }
    }
    /// FR-019: "Server", "Local" or "Local after server failure (reason)".
    pub fn path_label(&self, shows_local: bool) -> Option<String> {
        match self.recognition_path.as_str() {
            "server" => Some("Server".into()),
            "local_after_server_failure" => {
                Some(format!("Local after server failure ({})", failure_label(self.server_failure.as_deref().unwrap_or("unreachable"))))
            }
            _ => shows_local.then(|| "Local".into()),
        }
    }
}

pub fn failure_label(raw: &str) -> &'static str {
    match raw {
        "timeout" => "no answer",
        "busy" => "busy",
        "unauthorized" => "sign-in needed",
        "not_approved" => "not approved",
        "revoked" => "removed",
        "pin_mismatch" => "identity changed",
        "worker_unavailable" => "recognizer unavailable",
        "protocol_error" => "invalid reply",
        "limit_exceeded" => "too long",
        "pending_retry" => "retried",
        _ => "unreachable",
    }
}

pub fn spaced(raw: &str) -> String {
    raw.replace('_', " ")
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cursor {
    pub created_at: i64,
    pub id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Older,
    Newer,
}

#[derive(Debug, Default)]
pub struct Page {
    pub entries: Vec<Entry>,
    pub has_more: bool,
    pub watermark: Option<Cursor>,
}

/// Over 256 scalars or 1 KiB is refused, not trimmed.
pub fn query_is_valid(q: &str) -> bool {
    q.chars().count() <= 256 && q.len() <= 1024
}

/// Swift: NFC both sides, Foundation `.caseInsensitive, .literal`, `en_US_POSIX`. Diacritic-sensitive.
/// ponytail: `to_lowercase` stands in for Foundation folding; ß and similar expansions can differ.
pub fn matches(text: &str, query: &str) -> bool {
    if query.is_empty() {
        return true;
    }
    if text.len() > 65_536 {
        return false;
    }
    nfc(text).to_lowercase().contains(&nfc(query).to_lowercase())
}

/// One page in `created_at DESC, id DESC` order. Newer pages come back reversed so the order holds.
pub fn page(db: &Db, query: &str, cursor: Option<&Cursor>, direction: Direction, watermark: Option<&Cursor>) -> rusqlite::Result<Page> {
    let ceiling = match watermark {
        Some(w) => Some(w.clone()),
        None => db
            .conn
            .query_row("SELECT created_at,id FROM transcriptions ORDER BY created_at DESC,id DESC LIMIT 1", [], |r| Ok(Cursor { created_at: r.get(0)?, id: r.get(1)? }))
            .optional()?,
    };
    let Some(ceiling) = ceiling else { return Ok(Page::default()) };
    let (op, order) = if direction == Direction::Older { ("<", "DESC") } else { (">", "ASC") };
    let mut boundary = cursor.cloned();
    let mut found: Vec<Entry> = Vec::new();
    let mut has_more = false;
    // Custom SQL functions aren't compiled in, so matching runs here, over the same batches.
    'batches: loop {
        let bound = if boundary.is_some() { format!("AND (created_at,id) {op} (?3,?4)") } else { String::new() };
        let sql = format!("SELECT {ENTRY_COLUMNS} FROM transcriptions WHERE (created_at,id) <= (?1,?2) {bound} ORDER BY created_at {order},id {order} LIMIT {PAGE_SIZE}");
        let mut stmt = db.conn.prepare_cached(&sql)?;
        let batch: Vec<Entry> = if let Some(b) = &boundary {
            stmt.query_map(params![ceiling.created_at, ceiling.id, b.created_at, b.id], entry_row)?.collect::<Result<_, _>>()?
        } else {
            stmt.query_map(params![ceiling.created_at, ceiling.id], entry_row)?.collect::<Result<_, _>>()?
        };
        let Some(last) = batch.last() else { break };
        boundary = Some(Cursor { created_at: last.created_at, id: last.id.clone() });
        let short = batch.len() < PAGE_SIZE;
        for e in batch {
            if matches(&e.text, query) {
                if found.len() == PAGE_SIZE {
                    has_more = true;
                    break 'batches;
                }
                found.push(e);
            }
        }
        if short {
            break;
        }
    }
    if direction == Direction::Newer {
        found.reverse();
    }
    Ok(Page { entries: found, has_more, watermark: Some(ceiling) })
}

/// Changes whenever a row is added, removed or revised, so a page can refresh only then.
pub fn signature(db: &Db) -> (i64, i64) {
    db.conn.query_row("SELECT COUNT(*), COALESCE(SUM(revision),0) FROM transcriptions", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap_or((0, 0))
}

pub fn get(db: &Db, id: &str) -> rusqlite::Result<Option<Entry>> {
    db.conn.query_row(&format!("SELECT {ENTRY_COLUMNS} FROM transcriptions WHERE id=?"), [id], entry_row).optional()
}

// ---- Detail ----

#[derive(Clone, Debug, PartialEq)]
pub struct Context {
    pub outcome: String,
    pub snapshot: Option<Value>,
    pub pre_spelling_text: Option<String>,
    pub spelling_changes: Vec<SpellingChange>,
    pub rewrite_note: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpellingChange {
    pub original: String,
    pub replacement: String,
    pub source_part: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Envelope {
    pub entry: Entry,
    /// The decoded `content` object.
    pub detail: Option<Value>,
    pub content_hash: String,
    pub context: Option<Context>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum LoadError {
    Missing,
    Invalid,
}

fn decode_detail(json: &str, schema: i64, stored_hash: &str, text: &str) -> Option<Value> {
    if schema != 1 || json.len() > 262_144 {
        return None;
    }
    let body = json.strip_prefix("{\"content\":")?;
    let split = body.rfind(",\"contentHash\":\"")?;
    let (raw, tail) = body.split_at(split);
    let hash = tail.strip_prefix(",\"contentHash\":\"")?.strip_suffix("\"}")?;
    if hash != stored_hash || sha256_hex(raw.as_bytes()) != hash {
        return None;
    }
    let content: Value = serde_json::from_str(raw).ok()?;
    if content["normalizedHash"].as_str()? != sha256_hex(text.as_bytes()) || content["schemaVersion"].as_i64()? != 1 {
        return None;
    }
    Some(content)
}

pub fn part_label(part: &str) -> &'static str {
    match part {
        "window_title" | "windowTitle" => "Window title",
        "before_cursor" | "beforeCursor" => "Text before the cursor",
        "after_cursor" | "afterCursor" => "Text after the cursor",
        _ => "Selected text",
    }
}

/// One read: entry, quality detail, context.
pub fn envelope(db: &Db, id: &str) -> Result<Envelope, LoadError> {
    let entry = get(db, id).map_err(|_| LoadError::Invalid)?.ok_or(LoadError::Missing)?;
    let row: Option<(i64, String, String)> = db
        .conn
        .query_row("SELECT schema_version,detail_json,content_hash FROM transcription_quality WHERE transcription_id=?", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(|_| LoadError::Invalid)?;
    let (detail, content_hash) = match row {
        Some((schema, json, hash)) => (Some(decode_detail(&json, schema, &hash, &entry.text).ok_or(LoadError::Invalid)?), hash),
        None => (None, String::new()),
    };
    let context = db
        .conn
        .query_row("SELECT outcome,snapshot_json,pre_spelling_text,spelling_changes_json,rewrite_note FROM dictation_contexts WHERE transcription_id=?", [id], |r| {
            let snapshot: Option<String> = r.get(1)?;
            let changes: Option<String> = r.get(3)?;
            Ok(Context {
                outcome: r.get(0)?,
                snapshot: snapshot.and_then(|s| serde_json::from_str(&s).ok()).filter(|v: &Value| v["schema_version"] == 1),
                pre_spelling_text: r.get(2)?,
                spelling_changes: changes
                    .and_then(|c| serde_json::from_str::<Vec<Value>>(&c).ok())
                    .unwrap_or_default()
                    .iter()
                    .map(|c| SpellingChange {
                        original: c["original"].as_str().unwrap_or("").into(),
                        replacement: c["replacement"].as_str().unwrap_or("").into(),
                        source_part: c["source_part"].as_str().unwrap_or("").into(),
                    })
                    .collect(),
                rewrite_note: r.get(4)?,
            })
        })
        .optional()
        .map_err(|_| LoadError::Invalid)?;
    Ok(Envelope { entry, detail, content_hash, context })
}

pub fn context_label(context: Option<&Context>) -> &'static str {
    match context.map(|c| c.outcome.as_str()) {
        None => "Context: not recorded",
        Some("used") => "Context: used",
        Some("off") => "Context: off",
        Some("excluded_app") => "Context: excluded app",
        Some("own_app") => "Context: LocalFlow window",
        Some("secure_field") => "Context: secure field",
        Some("no_permission") => "Context unavailable: permission",
        Some("nothing_readable") => "Context: nothing readable",
        Some("timed_out") => "Context: timed out",
        Some("no_target") => "Context: no text field",
        Some(_) => "Context unavailable: field changed during capture",
    }
}

pub fn context_rewrite_line(context: Option<&Context>, latest: Option<&Attempt>) -> Option<&'static str> {
    if context.and_then(|c| c.rewrite_note.as_deref()) == Some("server_unsupported") {
        return Some("Context not sent: server unsupported");
    }
    let latest = latest?;
    latest.context_hash.as_ref()?;
    Some(if latest.failure_category.as_deref() == Some("context_copied") {
        "Rewrite used on-screen text you did not say; inserted your transcript."
    } else {
        "Context sent to the rewrite server"
    })
}

/// Bounded user-facing text per failure category, history variant.
pub fn rewrite_notice(category: &str) -> &'static str {
    match category {
        "server_unreachable" => "Rewrite server unreachable.",
        "transport_error" => "Rewrite connection failed.",
        "timeout" => "Rewrite took too long.",
        "authentication_failed" => "Rewrite server rejected the credential. Check Settings.",
        "backend_unavailable" => "Rewrite model is not available on the server.",
        "malformed_response" | "unsupported_schema_version" | "request_mismatch" => "Rewrite server sent an unusable reply.",
        "empty_response" | "oversized_response" | "server_validation_failed" => "Rewrite result was rejected.",
        "missing_credential" => "Rewriting skipped: no credential for this server.",
        "insecure_endpoint_blocked" => "Rewriting skipped: unencrypted connection blocked.",
        "invalid_settings" => "Rewriting skipped: the endpoint is invalid.",
        "input_too_large" => "Rewriting skipped: the text is too long.",
        "capacity_exceeded" => "Rewriting skipped: history is full.",
        "attempt_limit" => "This dictation already has ten rewrite attempts.",
        "concurrency_limit" => "Two rewrites are still running.",
        "interrupted" => "Rewrite was interrupted by a restart.",
        _ => "Rewrite used on-screen text you did not say.",
    }
}

/// A line of the "Processing details" block.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Line {
    Meta(String, String),
    Heading(String),
    Plain(String),
}

fn meta(label: impl Into<String>, value: Option<String>) -> Line {
    Line::Meta(label.into(), value.unwrap_or_else(|| "Unavailable".into()))
}

fn text_of(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

fn ids(v: &Value) -> String {
    let items: Vec<&str> = v.as_array().map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    if items.is_empty() { "None".into() } else { items.join(", ") }
}

fn capitalized(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().chain(c.flat_map(char::to_lowercase)).collect()).unwrap_or_default()
}

/// Rows of "Processing details", in Swift's order.
pub fn processing_lines(d: &Value) -> Vec<Line> {
    let p = &d["provenance"];
    let n = |k: &str| p[k].as_i64().unwrap_or(0);
    let mut out = vec![
        meta("Engine", text_of(&p["engine"])),
        meta("SDK", text_of(&p["sdkVersion"])),
        meta("Model", text_of(&p["modelID"])),
        meta("Model revision", text_of(&p["modelRevision"])),
        meta("Build", text_of(&p["build"])),
        meta("Uncommitted build changes", p["dirty"].as_bool().map(|b| if b { "Yes" } else { "No" }.into())),
        meta("Language", if p["automaticLanguage"].as_bool().unwrap_or(false) { Some("Automatic; no hint".into()) } else { text_of(&p["languageHint"]) }),
        meta("Assembly", text_of(&d["assemblyVersion"])),
        meta("Normalization", text_of(&d["normalizationVersion"])),
        meta("Vocabulary revision", Some(d["vocabularyRevision"].as_i64().unwrap_or(0).to_string())),
        meta("Applied formatting rules", Some(ids(&d["appliedRuleIDs"]))),
        meta("Applied vocabulary entries", Some(ids(&d["appliedEntryIDs"]))),
        meta("Ambiguous vocabulary entries", Some(ids(&d["ambiguousEntryIDs"]))),
        meta("Operating system", text_of(&p["operatingSystem"])),
        meta("Unicode runtime", text_of(&p["foldingRuntime"])),
        meta("Audio", Some(format!("{} Hz, {} channel, {}", n("sampleRate"), n("channels"), p["inputSampleFormat"].as_str().unwrap_or("")))),
        meta("Input", Some(format!("{} samples; {} seconds", n("inputSamples"), double_text(p["inputDurationSeconds"].as_f64().unwrap_or(0.0))))),
        meta("Windows", Some(format!("{} samples; overlap {}; stride {}", n("windowSamples"), n("overlapSamples"), n("strideSamples")))),
        meta("Minimum padded input", Some(format!("{} samples", n("minimumPaddedSamples")))),
    ];
    if let Some(stages) = p["stageDurations"].as_object() {
        // serde_json's map is ordered, so these are sorted like Swift's `keys.sorted()`.
        for (k, v) in stages {
            out.push(meta(format!("{} duration", capitalized(k)), Some(format!("{} seconds", double_text(v.as_f64().unwrap_or(0.0))))));
        }
    }
    let windows = d["rawWindows"].as_array().cloned().unwrap_or_default();
    for w in &windows {
        out.push(meta(
            format!("Window {} timing evidence", w["sequence"].as_i64().unwrap_or(0) + 1),
            Some(format!(
                "{}; {} recorded tokens; {} padded samples",
                w["timingValidation"].as_str().unwrap_or(""),
                w["timings"].as_array().map_or(0, Vec::len),
                w["paddedSampleCount"].as_i64().unwrap_or(0)
            )),
        ));
    }
    for s in d["seams"].as_array().cloned().unwrap_or_default() {
        out.push(meta(
            format!("Join before window {}", s["window"].as_i64().unwrap_or(0) + 1),
            Some(format!("{}; {} words discarded", s["decision"].as_str().unwrap_or(""), s["discardedLexicalWords"].as_i64().unwrap_or(0))),
        ));
    }
    out.push(Line::Heading("Processing reasons".into()));
    let reasons = d["completionReasons"].as_array().cloned().unwrap_or_default();
    if reasons.is_empty() {
        out.push(Line::Plain("None recorded".into()));
    }
    for r in reasons {
        let window = r["window"].as_i64().map(|w| format!(" (window {})", w + 1)).unwrap_or_default();
        out.push(Line::Plain(format!("{}{window}", r["code"].as_str().unwrap_or(""))));
    }
    out.push(Line::Heading("Unavailable evidence".into()));
    let missing = p["unavailableMetadata"].as_array().cloned().unwrap_or_default();
    if missing.is_empty() {
        out.push(Line::Plain("None recorded".into()));
    }
    for m in missing {
        out.push(meta(m["field"].as_str().unwrap_or(""), text_of(&m["reason"])));
    }
    let selected = d["selectedAttempt"].as_i64().unwrap_or(0);
    for (i, a) in d["attempts"].as_array().cloned().unwrap_or_default().iter().enumerate() {
        out.push(meta(
            format!("Attempt {}{}", i + 1, if i as i64 == selected { " (selected)" } else { "" }),
            Some(format!(
                "{}; {}; {}",
                a["engine"].as_str().unwrap_or(""),
                a["status"].as_str().unwrap_or(""),
                a["duration"].as_f64().map_or("Duration unavailable".into(), |v| format!("{} seconds", double_text(v)))
            )),
        ));
    }
    out
}

pub fn hash_lines(d: &Value, content_hash: &str) -> Vec<Line> {
    let p = &d["provenance"];
    let mut out = vec![
        meta("Content", Some(content_hash.into())),
        meta("Assembled", text_of(&d["assembledHash"])),
        meta("Normalized", text_of(&d["normalizedHash"])),
        meta("Vocabulary", text_of(&d["vocabularyHash"])),
        meta("Model manifest", text_of(&p["modelManifestHash"])),
    ];
    for w in d["rawWindows"].as_array().cloned().unwrap_or_default() {
        out.push(meta(format!("Raw window {}", w["sequence"].as_i64().unwrap_or(0) + 1), text_of(&w["textHash"])));
    }
    if let Some(a) = p["artifactHashes"].as_object() {
        for (k, v) in a {
            out.push(meta(k.clone(), text_of(v)));
        }
    }
    out
}

/// "Context as captured" rows.
pub fn snapshot_lines(s: &Value) -> Vec<(String, String)> {
    let mut out = Vec::new();
    if let Some(a) = s["app_name"].as_str() {
        out.push(("App".to_string(), a.to_string()));
    }
    out.push(("Field".to_string(), spaced(s["field_kind"].as_str().unwrap_or("unknown"))));
    for key in ["window_title", "before_cursor", "after_cursor", "selected_text"] {
        if let Some(t) = s[key].as_str() {
            out.push((part_label(key).to_string(), t.to_string()));
        }
    }
    let join = |v: &Value, field: Option<&str>| -> String {
        v.as_array()
            .map(|a| a.iter().filter_map(|i| field.map_or(i.as_str(), |f| i[f].as_str())).collect::<Vec<_>>().join(", "))
            .unwrap_or_default()
    };
    let terms = join(&s["terms"], Some("text"));
    if !terms.is_empty() {
        out.push(("Terms".to_string(), terms));
    }
    let short = join(&s["truncated"], None);
    if !short.is_empty() {
        out.push(("Shortened".to_string(), short));
    }
    out
}

// ---- Rewrite attempts ----

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attempt {
    pub id: String,
    pub ordinal: i64,
    pub mode: String,
    pub state: String,
    pub input_text: String,
    pub output_text: Option<String>,
    pub failure_category: Option<String>,
    pub stale: bool,
    pub duration_ms: Option<i64>,
    pub first_byte_ms: Option<i64>,
    pub delivered: bool,
    pub context_hash: Option<String>,
    pub backend_model: Option<String>,
    pub prompt_version: Option<i64>,
    pub shield_version: Option<i64>,
}

pub fn mode_title(mode: &str) -> String {
    capitalized(mode)
}

impl Attempt {
    pub fn title(&self) -> String {
        format!("Attempt {} · {} · {}", self.ordinal, mode_title(&self.mode), self.state)
    }
    pub fn deliverable(&self) -> Option<&str> {
        if self.state == "succeeded" { self.output_text.as_deref() } else { None }
    }
    pub fn summary(&self) -> String {
        let mut parts = vec![self.duration_ms.map_or("duration unavailable".to_string(), |d| format!("{d} ms total"))];
        if let Some(f) = self.first_byte_ms {
            parts.push(format!("{f} ms to first byte"));
        }
        if let Some(c) = &self.failure_category {
            parts.push(c.clone());
        }
        if self.context_hash.is_some() {
            parts.push("context sent".into());
        }
        if self.stale {
            parts.push("stale".into());
        }
        if self.delivered {
            parts.push("delivered".into());
        }
        let opt = |v: Option<i64>| v.map_or("unknown".to_string(), |n| n.to_string());
        parts.push(format!("{}+p{}+s{}", self.backend_model.as_deref().unwrap_or("unknown"), opt(self.prompt_version), opt(self.shield_version)));
        parts.join(" · ")
    }
}

pub fn attempts(db: &Db, id: &str) -> rusqlite::Result<Vec<Attempt>> {
    let mut s = db.conn.prepare_cached(
        "SELECT id,ordinal,mode,state,input_text,output_text,failure_category,stale,duration_ms,first_byte_ms,delivered,context_hash,backend_model,prompt_version,shield_version FROM rewrite_attempts WHERE transcription_id=? ORDER BY ordinal",
    )?;
    s.query_map([id], |r| {
        Ok(Attempt {
            id: r.get(0)?,
            ordinal: r.get(1)?,
            mode: r.get(2)?,
            state: r.get(3)?,
            input_text: r.get(4)?,
            output_text: r.get(5)?,
            failure_category: r.get(6)?,
            stale: r.get::<_, i64>(7)? != 0,
            duration_ms: r.get(8)?,
            first_byte_ms: r.get(9)?,
            delivered: r.get::<_, i64>(10)? != 0,
            context_hash: r.get(11)?,
            backend_model: r.get(12)?,
            prompt_version: r.get(13)?,
            shield_version: r.get(14)?,
        })
    })?
    .collect()
}

#[derive(Debug, PartialEq, Eq)]
pub enum StoreError {
    Stale,
    Busy,
    Missing,
    InvalidAttempt,
    /// A refusal with its failure category.
    Refused(&'static str),
    Sql(String),
}

impl From<rusqlite::Error> for StoreError {
    fn from(e: rusqlite::Error) -> Self {
        StoreError::Sql(e.to_string())
    }
}

fn reserved_for(input_bytes: usize) -> i64 {
    (4 * input_bytes).min(MAX_REWRITE_INPUT) as i64
}

fn mirror_rewrite_state(db: &Db, id: &str) -> rusqlite::Result<()> {
    db.conn.execute(
        "UPDATE transcriptions SET rewrite_state=coalesce((SELECT state FROM rewrite_attempts WHERE transcription_id=?1 ORDER BY ordinal DESC LIMIT 1),'not_requested') WHERE id=?1",
        [id],
    )?;
    Ok(())
}

pub const MAX_ROWS: i64 = 100_000;
pub const MAX_PAYLOAD_BYTES: i64 = 1024 * 1024 * 1024;
const RESERVATION_BYTES: i64 = 393_216 + 106_496;
const RESERVE_FREE_BYTES: u64 = 129 * 1024 * 1024 + RESERVATION_BYTES as u64;

/// `TranscriptionStore.reserve()` as a question: is there room for one more recording?
pub fn has_room(db: &Db, free_bytes: Option<u64>) -> bool {
    let usage: rusqlite::Result<(i64, i64)> = db.conn.query_row("SELECT row_count,payload_bytes FROM history_usage WHERE id=1", [], |r| Ok((r.get(0)?, r.get(1)?)));
    free_bytes.is_none_or(|f| f >= RESERVE_FREE_BYTES) && usage.is_ok_and(|(rows, bytes)| rows < MAX_ROWS && bytes + RESERVATION_BYTES <= MAX_PAYLOAD_BYTES)
}

fn pending_rewrites(db: &Db) -> usize {
    db.conn.query_row("SELECT count(*) FROM rewrite_attempts WHERE state='pending'", [], |r| r.get::<_, i64>(0)).unwrap_or(0) as usize
}

/// What `RewriteCoordinator.admit` decided before any network work.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Admission {
    NotEligible,
    Refused(&'static str),
    Admitted(String),
}

/// The admission order of `RewriteCoordinator.admit`: enabled and text, settings, then `begin_rewrite`.
pub fn admit_rewrite(db: &Db, dictation: &str, text: &str, mode: &str, enabled: bool, settings: &crate::settings::RewriteSettings) -> Admission {
    if !enabled || text.trim().is_empty() {
        return Admission::NotEligible;
    }
    if settings.valid() && settings.is_unencrypted_remote() && !settings.insecure_override {
        return Admission::Refused("insecure_endpoint_blocked");
    }
    if settings.valid() && !settings.is_loopback() && !settings.credential_present {
        return Admission::Refused("missing_credential");
    }
    if !settings.valid() {
        return Admission::Refused("invalid_settings");
    }
    match begin_rewrite(db, dictation, mode, text, &settings.origin) {
        Ok(id) => Admission::Admitted(id),
        Err(StoreError::Refused(category)) => Admission::Refused(category),
        Err(_) => Admission::Refused("capacity_exceeded"),
    }
}

/// An admitted attempt, on its way to `POST /v1/rewrite`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RewriteRequest {
    pub dictation: String,
    pub attempt: String,
    pub mode: &'static str,
    pub text: String,
    pub origin: String,
}

const MAX_REWRITE_LINE: usize = 8_192;
const MAX_REWRITE_RESULT: usize = 65_536;

/// `RewriteFailureCategory.forServerCode`.
fn server_code_category(code: &str) -> &'static str {
    match code {
        "shield_restore_failed" | "backend_error" | "too_large" | "invalid_request" => "server_validation_failed",
        "output_too_large" => "oversized_response",
        "backend_timeout" | "backend_first_token_timeout" | "backend_unavailable" | "server_busy" => "backend_unavailable",
        "unauthorized" => "authentication_failed",
        "unsupported_version" => "unsupported_schema_version",
        _ => "malformed_response",
    }
}

/// `RewriteFailureCategory.forHTTPStatus`.
fn http_status_category(status: u16, code: Option<&str>) -> &'static str {
    match status {
        400 if code == Some("unsupported_version") => "unsupported_schema_version",
        400 | 413 => "server_validation_failed",
        401 | 403 => "authentication_failed",
        429 | 503 => "backend_unavailable",
        _ => "transport_error",
    }
}

/// `RewriteResultValidator`, one line at a time: `Some` is the validated text, an error ends the attempt.
// ponytail: skips `isTranslation`, which needs NLLanguageRecognizer; a `Services` method when Rust has a language recognizer.
fn rewrite_line(line: &[u8], request: &RewriteRequest) -> Result<Option<String>, &'static str> {
    use serde_json::Value;
    let v: Value = serde_json::from_slice(line).map_err(|_| "malformed_response")?;
    let event = v.get("event").and_then(Value::as_str).ok_or("malformed_response")?;
    if event != "result" && line.len() > MAX_REWRITE_LINE {
        return Err("malformed_response");
    }
    let check_id = || match v.get("request_id").and_then(Value::as_str) {
        None => Err("malformed_response"),
        Some(id) if !id.eq_ignore_ascii_case(&request.attempt) => Err("request_mismatch"),
        Some(_) => Ok(()),
    };
    match event {
        "result" => {
            if v.get("schema_version").and_then(Value::as_i64) != Some(1) {
                return Err("unsupported_schema_version");
            }
            check_id()?;
            if v.get("mode").and_then(Value::as_str) != Some(request.mode) {
                return Err("malformed_response");
            }
            let text = v.get("text").and_then(Value::as_str).ok_or("malformed_response")?;
            if text.trim().is_empty() {
                return Err("empty_response");
            }
            if text.len() > (4 * request.text.len()).min(MAX_REWRITE_RESULT) {
                return Err("oversized_response");
            }
            let identity = |parent: &str, field: &str| v.get(parent).and_then(|o| o.get(field)).and_then(Value::as_str).is_some_and(|s| !s.is_empty() && s.len() <= 128);
            let count = |parent: &str, field: &str| v.get(parent).and_then(|o| o.get(field)).and_then(Value::as_i64).is_some_and(|n| n >= 0);
            let complete = identity("server", "name")
                && identity("server", "version")
                && identity("backend", "kind")
                && identity("backend", "model")
                && v.get("prompt_version").and_then(Value::as_i64).is_some_and(|n| n >= 0)
                && count("shield", "version")
                && count("shield", "placeholders")
                && count("shield", "restored")
                && v.get("timing").is_some_and(Value::is_object);
            if !complete {
                return Err("malformed_response");
            }
            if text.contains(['⟦', '⟧']) {
                return Err("server_validation_failed");
            }
            Ok(Some(text.to_string()))
        }
        "error" => {
            let code = v.get("code").and_then(Value::as_str).ok_or("malformed_response")?;
            check_id()?;
            Err(server_code_category(code))
        }
        _ => check_id().map(|()| None),
    }
}

/// `RewriteClient.rewrite`: protocol v1. Blocking; run it off the UI thread.
// ponytail: never sends v2 context, the snapshot has no Rust capture yet. Cancel marks the row and lets this run out its timeout.
pub fn send_rewrite(request: &RewriteRequest, secret: Option<&str>, timeout: std::time::Duration) -> Result<String, &'static str> {
    use std::io::{BufRead, BufReader, Read};
    let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(timeout)).max_redirects(0).http_status_as_error(false).proxy(None).build().into();
    let body = serde_json::json!({"schema_version": 1, "request_id": request.attempt, "mode": request.mode, "text": request.text, "language_hints": [], "stream_deltas": false});
    let mut post = agent.post(format!("{}/v1/rewrite", request.origin.trim_end_matches('/'))).header("Content-Type", "application/json").header("Accept", "application/x-ndjson");
    if let Some(secret) = secret {
        post = post.header("Authorization", format!("Bearer {secret}"));
    }
    let failed = |e: ureq::Error| match e {
        ureq::Error::Timeout(_) => "timeout",
        ureq::Error::HostNotFound | ureq::Error::ConnectionFailed => "server_unreachable",
        ureq::Error::Io(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => "server_unreachable",
        ureq::Error::Io(e) if e.kind() == std::io::ErrorKind::TimedOut => "timeout",
        _ => "transport_error",
    };
    let mut response = post.send(body.to_string()).map_err(failed)?;
    let status = response.status().as_u16();
    if status != 200 {
        let body = response.body_mut().with_config().limit(MAX_REWRITE_LINE as u64).read_to_vec().unwrap_or_default();
        let code = serde_json::from_slice::<serde_json::Value>(&body).ok();
        return Err(http_status_category(status, code.as_ref().and_then(|v| v.get("error")?.get("code")?.as_str())));
    }
    let cap = (4 * request.text.len() + MAX_REWRITE_LINE).min(73_728);
    let mut total = 0;
    for line in BufReader::new(response.into_body().into_reader().take(cap as u64 + 1)).split(b'\n') {
        let line = line.map_err(|e| if e.kind() == std::io::ErrorKind::TimedOut { "timeout" } else { "transport_error" })?;
        total += line.len() + 1;
        if total > cap + 1 {
            return Err("oversized_response");
        }
        if let Some(text) = rewrite_line(&line, request)? {
            return Ok(text);
        }
    }
    Err("malformed_response")
}

/// Attempt admission: rechecks limits, reserves quota, inserts the pending row, mirrors the state.
pub fn begin_rewrite(db: &Db, transcription: &str, mode: &str, input: &str, origin: &str) -> Result<String, StoreError> {
    if input.is_empty() || input.len() > MAX_REWRITE_INPUT || input.chars().count() > MAX_REWRITE_SCALARS {
        return Err(StoreError::Refused("input_too_large"));
    }
    if get(db, transcription)?.is_none() {
        return Err(StoreError::Missing);
    }
    let tx = db.conn.unchecked_transaction()?;
    let count: i64 = tx.query_row("SELECT count(*) FROM rewrite_attempts WHERE transcription_id=?", [transcription], |r| r.get(0))?;
    if count as usize >= MAX_ATTEMPTS {
        return Err(StoreError::Refused("attempt_limit"));
    }
    let here: i64 = tx.query_row("SELECT count(*) FROM rewrite_attempts WHERE transcription_id=? AND state='pending'", [transcription], |r| r.get(0))?;
    let overall: i64 = tx.query_row("SELECT count(*) FROM rewrite_attempts WHERE state='pending'", [], |r| r.get(0))?;
    if here > 0 || overall as usize >= MAX_PENDING_OVERALL {
        return Err(StoreError::Refused("concurrency_limit"));
    }
    let id = new_uuid(db);
    let ordinal: i64 = tx.query_row("SELECT coalesce(max(ordinal),0)+1 FROM rewrite_attempts WHERE transcription_id=?", [transcription], |r| r.get(0))?;
    tx.execute(
        "INSERT INTO rewrite_attempts (id,transcription_id,ordinal,mode,state,input_text,input_hash,started_at,protocol_version,endpoint_origin,insecure_override,context_hash) VALUES (?,?,?,?,'pending',?,?,?,1,?,0,NULL)",
        params![id, transcription, ordinal, mode, input, sha256_hex(input.as_bytes()), now_ms(), origin],
    )?;
    tx.execute("UPDATE history_usage SET payload_bytes=payload_bytes+? WHERE id=1", [input.len() as i64 + reserved_for(input.len())])?;
    mirror_rewrite_state(db, transcription)?;
    tx.commit()?;
    Ok(id)
}

fn pending_attempt(db: &Db, id: &str) -> Result<(String, String), StoreError> {
    db.conn
        .query_row("SELECT transcription_id,input_text FROM rewrite_attempts WHERE id=? AND state='pending'", [id], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()?
        .ok_or(StoreError::InvalidAttempt)
}

pub fn record_rewrite_result(db: &Db, id: &str, output: &str, duration_ms: Option<i64>) -> Result<(), StoreError> {
    let (transcription, input) = pending_attempt(db, id)?;
    if output.len() > MAX_REWRITE_INPUT {
        return Err(StoreError::Refused("oversized_response"));
    }
    let tx = db.conn.unchecked_transaction()?;
    tx.execute(
        "UPDATE rewrite_attempts SET state='succeeded',output_text=?,output_hash=?,unchanged=?,duration_ms=? WHERE id=?",
        params![output, sha256_hex(output.as_bytes()), (output == input) as i64, duration_ms, id],
    )?;
    tx.execute("UPDATE history_usage SET payload_bytes=payload_bytes-?+? WHERE id=1", [reserved_for(input.len()), output.len() as i64])?;
    mirror_rewrite_state(db, &transcription)?;
    tx.commit()?;
    Ok(())
}

/// `timed_out` for a timeout, `failed` with its category, or `cancelled` when `category` is `None`.
pub fn terminate_rewrite(db: &Db, id: &str, category: Option<&str>, duration_ms: Option<i64>) -> Result<(), StoreError> {
    let (transcription, input) = pending_attempt(db, id)?;
    let state = match category {
        None => "cancelled",
        Some("timeout") => "timed_out",
        Some(_) => "failed",
    };
    let tx = db.conn.unchecked_transaction()?;
    tx.execute("UPDATE rewrite_attempts SET state=?,failure_category=?,duration_ms=? WHERE id=?", params![state, category, duration_ms, id])?;
    tx.execute("UPDATE history_usage SET payload_bytes=max(0,payload_bytes-?) WHERE id=1", [reserved_for(input.len())])?;
    mirror_rewrite_state(db, &transcription)?;
    tx.commit()?;
    Ok(())
}

/// After a crash: `attempting` becomes `uncertain`, pending attempts become failed + `interrupted`.
pub fn startup_repair(db: &Db) -> Result<(), StoreError> {
    db.conn.execute("UPDATE transcriptions SET delivery_state='uncertain',recovery_state='needs_review',revision=revision+1 WHERE delivery_state='attempting'", [])?;
    let pending: Vec<String> = {
        let mut s = db.conn.prepare("SELECT id FROM rewrite_attempts WHERE state='pending'")?;
        s.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?
    };
    for id in pending {
        terminate_rewrite(db, &id, Some("interrupted"), None)?;
    }
    Ok(())
}

// ---- Delivery and deletion ----

pub fn delete_confirmed(db: &Db, id: &str, revision: i64) -> Result<(), StoreError> {
    let current = get(db, id)?.filter(|e| e.revision == revision).ok_or(StoreError::Stale)?;
    if current.is_attempting() || current.rewrite_state == "pending" {
        return Err(StoreError::Busy);
    }
    let tx = db.conn.unchecked_transaction()?;
    let bytes: i64 = tx.query_row(
        "SELECT length(cast(?1 AS blob))
          + coalesce((SELECT length(cast(detail_json AS blob)) FROM transcription_quality WHERE transcription_id=?2),0)
          + coalesce((SELECT sum(length(cast(input_text AS blob))+length(cast(coalesce(output_text,'') AS blob))) FROM rewrite_attempts WHERE transcription_id=?2),0)
          + coalesce((SELECT coalesce(length(cast(snapshot_json AS blob)),0)+coalesce(length(cast(pre_spelling_text AS blob)),0)+coalesce(length(cast(spelling_changes_json AS blob)),0) FROM dictation_contexts WHERE transcription_id=?2),0)",
        params![current.text, id],
        |r| r.get(0),
    )?;
    tx.execute("DELETE FROM transcriptions WHERE id=? AND revision=?", params![id, revision])?;
    tx.execute("UPDATE history_usage SET row_count=row_count-1,payload_bytes=payload_bytes-? WHERE id=1", [bytes])?;
    tx.commit()?;
    Ok(())
}

/// Returns the attempt id and the new revision.
pub fn begin_attempt(db: &Db, id: &str, revision: i64) -> Result<(String, i64), StoreError> {
    let current = get(db, id)?.ok_or(StoreError::Missing)?;
    if current.revision != revision {
        return Err(StoreError::Stale);
    }
    if current.is_attempting() {
        return Err(StoreError::Busy);
    }
    let attempt = new_uuid(db);
    db.conn.execute(
        "UPDATE transcriptions SET delivery_state='attempting',recovery_state='needs_review',attempt_id=?,attempt_started_at=?,revision=? WHERE id=?",
        params![attempt, now_ms(), revision + 1, id],
    )?;
    Ok((attempt, revision + 1))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Confirmed,
    NotInserted,
    Uncertain,
}

/// swift-note HIST-177: Swift writes the delivery source for every outcome, so this does too.
pub fn record_outcome(db: &Db, id: &str, revision: i64, attempt: &str, outcome: Outcome, rewrite: Option<&str>) -> Result<Entry, StoreError> {
    let current = get(db, id)?.ok_or(StoreError::InvalidAttempt)?;
    if current.revision != revision || current.attempt_id.as_deref() != Some(attempt) || !current.is_attempting() {
        return Err(StoreError::InvalidAttempt);
    }
    let (state, recovery) = match outcome {
        Outcome::Confirmed => ("confirmed", "resolved"),
        Outcome::NotInserted => ("not_inserted", "needs_review"),
        Outcome::Uncertain => ("uncertain", "needs_review"),
    };
    let tx = db.conn.unchecked_transaction()?;
    if let Some(a) = rewrite {
        let n = tx.execute("UPDATE rewrite_attempts SET delivered=1 WHERE id=? AND transcription_id=? AND state='succeeded'", params![a, id])?;
        if n == 0 {
            return Err(StoreError::InvalidAttempt);
        }
    }
    tx.execute(
        "UPDATE transcriptions SET delivery_state=?,recovery_state=?,revision=?,delivered_source=?,delivered_rewrite_attempt_id=? WHERE id=?",
        params![state, recovery, revision + 1, if rewrite.is_some() { "rewrite" } else { "faithful" }, rewrite, id],
    )?;
    tx.commit()?;
    get(db, id)?.ok_or(StoreError::Missing)
}

// ---- Dictations waiting for the server ----

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingItem {
    pub id: String,
    pub audio_file: String,
    pub sample_count: i64,
    pub created_at: i64,
    pub last_failure: Option<String>,
}

impl PendingItem {
    pub fn status(&self, now: i64) -> &'static str {
        if now - self.created_at >= PENDING_MAX_AGE_MS { "Retries stopped after 24 hours" } else { "Waiting for server" }
    }
    /// swift-note HIST-189: integer division, so under a second reads "0 s of audio".
    pub fn length_label(&self) -> String {
        format!("{} s of audio", self.sample_count / 16_000)
    }
}

/// Read errors give an empty list.
pub fn pending_items(db: &Db) -> Vec<PendingItem> {
    let read = || -> rusqlite::Result<Vec<PendingItem>> {
        let mut s = db.conn.prepare_cached("SELECT id,audio_file,sample_count,created_at,last_failure FROM pending_remote_dictations ORDER BY created_at, id")?;
        s.query_map([], |r| Ok(PendingItem { id: r.get(0)?, audio_file: r.get(1)?, sample_count: r.get(2)?, created_at: r.get(3)?, last_failure: r.get(4)? }))?.collect()
    };
    read().unwrap_or_default()
}

fn plain_file_name(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\\') && name.len() <= 255
}

pub fn remove_pending(db: &Db, dir: &Path, id: &str) -> Result<(), StoreError> {
    let item = pending_items(db).into_iter().find(|i| i.id == id);
    db.conn.execute("DELETE FROM pending_remote_dictations WHERE id=?", [id])?;
    if let Some(i) = item.filter(|i| plain_file_name(&i.audio_file)) {
        let path = dir.join(i.audio_file);
        if path.exists() {
            std::fs::remove_file(path).map_err(|e| StoreError::Sql(e.to_string()))?;
        }
    }
    Ok(())
}

/// 16 kHz mono 32-bit float WAV (format 3).
pub fn wav(samples: &[u8]) -> Vec<u8> {
    let mut d = Vec::with_capacity(44 + samples.len());
    d.extend_from_slice(b"RIFF");
    d.extend_from_slice(&(36 + samples.len() as u32).to_le_bytes());
    d.extend_from_slice(b"WAVEfmt ");
    d.extend_from_slice(&16u32.to_le_bytes());
    d.extend_from_slice(&3u16.to_le_bytes());
    d.extend_from_slice(&1u16.to_le_bytes());
    d.extend_from_slice(&16_000u32.to_le_bytes());
    d.extend_from_slice(&64_000u32.to_le_bytes());
    d.extend_from_slice(&4u16.to_le_bytes());
    d.extend_from_slice(&32u16.to_le_bytes());
    d.extend_from_slice(b"data");
    d.extend_from_slice(&(samples.len() as u32).to_le_bytes());
    d.extend_from_slice(samples);
    d
}

/// Writes atomically; keeps the pending row.
pub fn export_pending(item: &PendingItem, dir: &Path, destination: &Path) -> std::io::Result<()> {
    if !plain_file_name(&item.audio_file) {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    let data = wav(&std::fs::read(dir.join(&item.audio_file))?);
    let tmp = destination.with_extension(format!("tmp-{}", now_ms()));
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, destination)
}

// ---- View model ----

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DateGroup {
    pub title: String,
    pub entries: Vec<Entry>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Placement {
    Replace,
    AppendOlder,
    PrependNewer,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum RewriteMode {
    #[default]
    Clean,
    Polished,
    Concise,
}

impl RewriteMode {
    pub const ALL: [RewriteMode; 3] = [RewriteMode::Clean, RewriteMode::Polished, RewriteMode::Concise];
    pub fn title(self) -> &'static str {
        match self {
            RewriteMode::Clean => "Clean",
            RewriteMode::Polished => "Polished",
            RewriteMode::Concise => "Concise",
        }
    }
    pub fn raw(self) -> &'static str {
        match self {
            RewriteMode::Clean => "clean",
            RewriteMode::Polished => "polished",
            RewriteMode::Concise => "concise",
        }
    }
}

/// `HistoryViewModel`. Reads are synchronous on the UI thread, so its generation counters and worker
/// disappear: there's never an older result to discard.
/// ponytail: synchronous reads; move to a background executor if a page read shows up in a profile.
#[derive(Default)]
pub struct Model {
    pub entries: Vec<Entry>,
    pub has_older: bool,
    pub has_newer: bool,
    pub is_loading: bool,
    pub error: Option<String>,
    pub search_text: String,
    pub selected: Option<Entry>,
    pub detail_id: Option<String>,
    pub envelope: Option<Envelope>,
    pub detail_loading: bool,
    pub detail_error: Option<String>,
    pub attempts: Vec<Attempt>,
    pub rewrite_notice: Option<String>,
    pub rewrite_mode: RewriteMode,
    /// False until a rewrite client exists in Rust; the button is then disabled, never faked.
    pub has_rewriter: bool,
    /// Pending attempts on every dictation, as of the last read of the open detail.
    pub rewrites_running: usize,
    pub rewrite_busy: bool,
    pub pending_items: Vec<PendingItem>,
    pub pending_error: Option<String>,
    pub local_speech: bool,
    watermark: Option<Cursor>,
}

impl Model {
    /// Sets the search text. `false` means it was over the limit: the text reverts with an error.
    pub fn set_search(&mut self, text: &str) -> bool {
        if !query_is_valid(text) {
            self.error = Some(SEARCH_LIMIT_MESSAGE.into());
            return false;
        }
        self.search_text = text.to_string();
        true
    }

    pub fn refresh(&mut self, db: &Db) {
        self.request(db, None, Direction::Older, Placement::Replace);
        if self.detail_id.is_some() {
            self.retry_detail(db);
        }
        self.refresh_pending(db);
    }

    /// The debounced search and the post-rewrite refresh: a replacing page, nothing else.
    pub fn reload_list(&mut self, db: &Db) {
        self.request(db, None, Direction::Older, Placement::Replace);
    }

    pub fn refresh_pending(&mut self, db: &Db) {
        self.pending_items = pending_items(db);
    }

    pub fn load_older(&mut self, db: &Db) {
        let Some(last) = self.entries.last() else { return };
        if !self.has_older {
            return;
        }
        let cursor = Cursor { created_at: last.created_at, id: last.id.clone() };
        self.request(db, Some(cursor), Direction::Older, Placement::AppendOlder);
    }

    pub fn load_newer(&mut self, db: &Db) {
        let Some(first) = self.entries.first() else { return };
        if !self.has_newer {
            return;
        }
        let cursor = Cursor { created_at: first.created_at, id: first.id.clone() };
        self.request(db, Some(cursor), Direction::Newer, Placement::PrependNewer);
    }

    fn request(&mut self, db: &Db, cursor: Option<Cursor>, direction: Direction, placement: Placement) {
        if placement == Placement::Replace {
            self.watermark = None;
        }
        match page(db, &self.search_text, cursor.as_ref(), direction, self.watermark.as_ref()) {
            Ok(p) => {
                self.watermark = p.watermark.clone();
                self.error = None;
                self.place(p, placement);
            }
            Err(_) => self.error = Some(READ_ERROR.into()),
        }
    }

    fn place(&mut self, page: Page, placement: Placement) {
        match placement {
            Placement::Replace => {
                self.entries = page.entries;
                self.has_older = page.has_more;
                self.has_newer = false;
            }
            Placement::AppendOlder => {
                self.entries.extend(page.entries);
                self.has_older = page.has_more;
                if self.entries.len() > RESIDENT_LIMIT {
                    self.entries.drain(..self.entries.len() - RESIDENT_LIMIT);
                    self.has_newer = true;
                }
            }
            Placement::PrependNewer => {
                let mut window = page.entries;
                window.append(&mut self.entries);
                if window.len() > RESIDENT_LIMIT {
                    window.truncate(RESIDENT_LIMIT);
                    self.has_older = true;
                }
                self.entries = window;
                self.has_newer = page.has_more;
            }
        }
    }

    pub fn is_no_matches(&self) -> bool {
        !self.search_text.is_empty() && self.entries.is_empty() && !self.is_loading
    }

    /// Consecutive rows by local day. swift-note HIST-178: `now_ms` is passed in; the page only
    /// refreshes it while on screen, as Swift's `regroup` does.
    pub fn date_groups(&self, db: &Db, now_ms: i64) -> Vec<DateGroup> {
        let today = local(db, now_ms).day_number();
        let mut groups: Vec<(i64, DateGroup)> = Vec::new();
        for e in &self.entries {
            let d = local(db, e.created_at);
            let day = d.day_number();
            match groups.last_mut() {
                Some((g, group)) if *g == day => group.entries.push(e.clone()),
                _ => {
                    let title = if day == today {
                        "Today".to_string()
                    } else if day == today - 1 {
                        "Yesterday".to_string()
                    } else {
                        format!("{} {} {}", d.day, MONTHS[(d.month - 1) as usize], d.year)
                    };
                    groups.push((day, DateGroup { title, entries: vec![e.clone()] }));
                }
            }
        }
        groups.into_iter().map(|(_, g)| g).collect()
    }

    pub fn show_detail(&mut self, db: &Db, id: &str) {
        self.detail_id = Some(id.to_string());
        self.attempts.clear();
        self.rewrite_notice = None;
        self.retry_detail(db);
    }

    pub fn retry_detail(&mut self, db: &Db) {
        let Some(id) = self.detail_id.clone() else { return };
        self.envelope = None;
        self.detail_error = None;
        match envelope(db, &id) {
            Ok(e) => {
                self.attempts = attempts(db, &id).unwrap_or_default();
                self.rewrites_running = pending_rewrites(db);
                self.envelope = Some(e);
            }
            Err(LoadError::Missing) => self.did_delete(&id),
            Err(LoadError::Invalid) => self.detail_error = Some(DETAIL_ERROR.into()),
        }
        self.detail_loading = false;
    }

    pub fn clear_detail(&mut self) {
        self.detail_id = None;
        self.envelope = None;
        self.attempts.clear();
        self.rewrite_notice = None;
        self.detail_error = None;
        self.detail_loading = false;
    }

    pub fn did_delete(&mut self, id: &str) {
        if self.detail_id.as_deref() == Some(id) {
            self.clear_detail();
        }
        if self.selected.as_ref().is_some_and(|e| e.id == id) {
            self.selected = None;
        }
        self.entries.retain(|e| e.id != id);
    }

    /// The dialog's Delete. A store refusal shows the action error.
    pub fn delete_selected(&mut self, db: &Db) -> bool {
        let Some(entry) = self.selected.take() else { return false };
        match delete_confirmed(db, &entry.id, entry.revision) {
            Ok(()) => {
                self.did_delete(&entry.id);
                self.refresh(db);
                true
            }
            Err(_) => {
                self.error = Some(ACTION_ERROR.into());
                false
            }
        }
    }

    pub fn current_rewrite(&self) -> Option<&Attempt> {
        self.attempts.iter().rev().find(|a| a.state == "succeeded" && !a.stale && a.output_text.is_some())
    }
    pub fn pending_rewrite(&self) -> Option<&Attempt> {
        self.attempts.iter().rev().find(|a| a.state == "pending")
    }
    pub fn rewrite_limit_explanation(&self) -> Option<&'static str> {
        (self.attempts.len() >= MAX_ATTEMPTS).then(|| rewrite_notice("attempt_limit"))
    }
    pub fn can_request_rewrite(&self) -> bool {
        self.has_rewriter
            && !self.rewrite_busy
            && self.rewrite_limit_explanation().is_none()
            && self.pending_rewrite().is_none()
            && self.rewrites_running < MAX_PENDING_OVERALL
            && self.envelope.as_ref().is_some_and(|e| e.entry.quality == "complete")
    }
    pub fn delivered_line(&self) -> String {
        let Some(entry) = self.envelope.as_ref().map(|e| &e.entry) else { return "Delivered: nothing yet".into() };
        let delivered = entry.delivered_rewrite_attempt_id.as_ref().and_then(|id| self.attempts.iter().find(|a| &a.id == id));
        let base = if let Some(a) = delivered {
            format!("Delivered: rewrite attempt {} ({})", a.ordinal, mode_title(&a.mode))
        } else if entry.delivered_source.as_deref() == Some("faithful") {
            "Delivered: saved text".to_string()
        } else {
            "Delivered: nothing yet".to_string()
        };
        match self.current_rewrite() {
            Some(c) if entry.delivered_source.is_some() && Some(&c.id) != entry.delivered_rewrite_attempt_id.as_ref() => {
                format!("{base}. The current rewrite is not the text that was delivered.")
            }
            _ => base,
        }
    }
    pub fn rewrite_state_line(&self) -> String {
        let state = self.attempts.last().map(|a| a.state.as_str()).or(self.envelope.as_ref().map(|e| e.entry.rewrite_state.as_str())).unwrap_or("not_requested");
        format!("Rewrite: {}", spaced(state))
    }

    /// Re-reads the attempt rows and the entry for the open detail only.
    pub fn reload_attempts(&mut self, db: &Db) {
        let Some(id) = self.detail_id.clone() else { return };
        self.attempts = attempts(db, &id).unwrap_or_default();
        self.rewrites_running = pending_rewrites(db);
        if let Ok(Some(entry)) = get(db, &id) {
            if let Some(i) = self.entries.iter().position(|e| e.id == id) {
                self.entries[i] = entry.clone();
            }
            if let Some(env) = &mut self.envelope {
                env.entry = entry;
            }
        }
    }

    /// The Rewrite/Retry button: the first attempt's input, or the saved text. An admitted attempt
    /// comes back as the request to send; `finish_rewrite` takes the answer.
    pub fn request_rewrite(&mut self, db: &Db, enabled: bool, settings: &crate::settings::RewriteSettings) -> Option<RewriteRequest> {
        if !self.can_request_rewrite() {
            return None;
        }
        let (id, saved) = (self.detail_id.clone()?, self.envelope.as_ref()?.entry.text.clone());
        let input = self.attempts.first().map_or(saved, |a| a.input_text.clone());
        let mode = self.rewrite_mode.raw();
        let mut request = None;
        self.rewrite_notice = match admit_rewrite(db, &id, &input, mode, enabled, settings) {
            Admission::NotEligible => None,
            Admission::Refused(category) => Some(rewrite_notice(category).into()),
            Admission::Admitted(attempt) => {
                request = Some(RewriteRequest { dictation: id, attempt, mode, text: input, origin: settings.origin.clone() });
                None
            }
        };
        self.reload_list(db);
        self.reload_attempts(db);
        request
    }

    /// Stores the answer. A row that is no longer pending was cancelled: its answer is dropped.
    pub fn finish_rewrite(&mut self, db: &Db, request: &RewriteRequest, answer: Result<String, &'static str>, duration_ms: i64) {
        let stored = match &answer {
            Ok(text) => record_rewrite_result(db, &request.attempt, text, Some(duration_ms)),
            Err(category) => terminate_rewrite(db, &request.attempt, Some(category), Some(duration_ms)),
        };
        if stored.is_ok() && self.detail_id.as_deref() == Some(&request.dictation) {
            self.rewrite_notice = answer.err().map(|category| rewrite_notice(category).into());
        }
        self.reload_list(db);
        self.reload_attempts(db);
    }

    /// Marks the pending attempt cancelled. No network task exists in Rust yet to stop.
    pub fn cancel_rewrite(&mut self, db: &Db) {
        let Some(id) = self.pending_rewrite().map(|a| a.id.clone()) else { return };
        if terminate_rewrite(db, &id, None, None).is_ok() {
            self.rewrite_notice = Some("Rewrite cancelled.".into());
        }
        self.reload_attempts(db);
    }

    pub fn discard_pending(&mut self, db: &Db, dir: &Path, id: &str) {
        self.pending_error = None;
        if remove_pending(db, dir, id).is_err() {
            self.pending_error = Some(PENDING_ERROR.into());
        }
        self.refresh_pending(db);
        self.reload_list(db);
    }

    pub fn export_pending(&mut self, db: &Db, dir: &Path, id: &str, to: &Path) {
        self.pending_error = None;
        let done = pending_items(db).iter().find(|i| i.id == id).map(|i| export_pending(i, dir, to).is_ok());
        if done != Some(true) {
            self.pending_error = Some(PENDING_ERROR.into());
        }
        self.refresh_pending(db);
    }

    /// `Recognize Locally` without a speech engine: fails as a failed action does in Swift.
    pub fn report_pending_failure(&mut self) {
        self.pending_error = Some(PENDING_ERROR.into());
    }
}

// ---- Seed ----

pub fn seed_id(n: i64) -> String {
    format!("00000000-0000-4000-8000-{n:012X}")
}

const MINUTE: i64 = 60_000;
const DAY: i64 = 24 * 60 * MINUTE;

/// A quality detail the Swift decoder accepts: sorted keys and whole seconds, so bytes match its encoder.
fn detail_json(text: &str, windows: &[(i64, i64, &str)], reasons: Value, full: bool) -> (String, String) {
    let raw: Vec<Value> = windows
        .iter()
        .enumerate()
        .map(|(i, (start, count, t))| {
            json!({"paddedSampleCount": (*count).max(4800), "sampleCount": count, "sampleStart": start, "sequence": i, "text": t,
                   "textHash": sha256_hex(t.as_bytes()), "timingValidation": "unavailable"})
        })
        .collect();
    let samples = windows.iter().map(|(s, c, _)| s + c).max().unwrap_or(48_000);
    let seconds = json!(samples / 16_000);
    assert_eq!(samples % 16_000, 0, "seed durations are whole seconds");
    let provenance = if full {
        json!({"artifactHashes": {"encoder.mlmodelc": sha256_hex(b"seed-encoder"), "joint.mlmodelc": sha256_hex(b"seed-joint")},
               "automaticLanguage": false, "build": "1.0-seed", "channels": 1, "dirty": false, "engine": "seed-engine",
               "foldingRuntime": "seed-unicode-1", "inputDurationSeconds": seconds, "inputSampleFormat": "float32_pcm", "inputSamples": samples,
               "languageHint": "en", "minimumPaddedSamples": 4800, "modelID": "seed-model", "modelManifestHash": sha256_hex(b"seed-manifest"),
               "modelRevision": "rev-1", "operatingSystem": "seed-os-26", "overlapSamples": 32000, "sampleRate": 16000, "sdkVersion": "0.0-seed",
               "stageDurations": {"assembly": 0.25, "normalization": 0.5, "recognition": 1.5}, "strideSamples": 207360,
               "unavailableMetadata": [], "windowSamples": 239360})
    } else {
        let missing: Vec<Value> = ["sdk_version", "model_id", "model_revision", "model_manifest_hash", "artifact_hashes", "build", "dirty", "operating_system", "folding_runtime", "recognition_duration", "assembly_duration", "normalization_duration"]
            .iter()
            .map(|f| json!({"field": f, "reason": "not_recorded"}))
            .collect();
        json!({"artifactHashes": {}, "automaticLanguage": true, "channels": 1, "engine": "seed-engine", "inputDurationSeconds": seconds,
               "inputSampleFormat": "float32_pcm", "inputSamples": samples, "minimumPaddedSamples": 4800, "overlapSamples": 0, "sampleRate": 16000,
               "stageDurations": {}, "strideSamples": 239360, "unavailableMetadata": missing, "windowSamples": 239360})
    };
    let assembled: Vec<&str> = windows.iter().map(|w| w.2).collect();
    let assembled = assembled.join(" ");
    let content = json!({
        "appliedEntryIDs": if full { json!([seed_id(9001)]) } else { json!([]) },
        "appliedRuleIDs": if full { json!(["N001", "N004"]) } else { json!([]) },
        "assembledHash": sha256_hex(assembled.as_bytes()),
        "assembledText": assembled,
        "assemblyVersion": "assembly-v1",
        "attempts": [{"duration": 1.5, "engine": "seed-engine", "id": "initial", "status": "completed"}],
        "completionReasons": reasons,
        "normalizationVersion": "normalization-v1",
        "normalizedHash": sha256_hex(text.as_bytes()),
        "provenance": provenance,
        "rawWindows": raw,
        "schemaVersion": 1,
        "selectedAttempt": 0,
        "serializationVersion": "quality-content-v1",
        "vocabularyHash": sha256_hex(b"localflow-vocabulary-v1:[]"),
        "vocabularyRevision": 0,
    });
    let raw = serde_json::to_string(&content).expect("seed json");
    let hash = sha256_hex(raw.as_bytes());
    (format!("{{\"content\":{raw},\"contentHash\":\"{hash}\"}}"), hash)
}

struct SeedRow {
    text: &'static str,
    ago: i64,
    delivery: &'static str,
    quality: &'static str,
    stop: &'static str,
    bundle: Option<&'static str>,
    path: &'static str,
    failure: Option<&'static str>,
    device: Option<(&'static str, &'static str)>,
}

fn seed_rows() -> Vec<SeedRow> {
    let row = |text, ago, delivery, bundle| SeedRow { text, ago, delivery, quality: "complete", stop: "key_release", bundle, path: "local", failure: None, device: Some(("Studio Microphone", "usb")) };
    let mut rows = vec![
        row("Move the kickoff to Thursday and ask Northwind to send the updated floor plan before noon.", 2 * MINUTE, "confirmed", Some("com.apple.mail")),
        SeedRow { quality: "incomplete", stop: "device_loss", delivery: "not_inserted", ..row("Remember to check the Kubernetes rollout notes once the", 7 * MINUTE, "", Some("com.tinyspeck.slackmacgap")) },
        SeedRow { path: "server", ..row("Draft a short update for the Acme Robotics team about the new sensor calibration schedule.", 12 * MINUTE, "confirmed", Some("com.openai.chat")) },
        SeedRow { path: "local_after_server_failure", failure: Some("timeout"), ..row("Add oat milk, coffee beans and two lemons to the shopping list for Saturday.", DAY + 30 * MINUTE, "uncertain", Some("com.apple.Notes")) },
        SeedRow { quality: "duration_limited", stop: "duration_limit", device: None, ..row("Walk through the quarterly plan section by section, starting with hiring and then moving on to the budget, the roadmap and the open questions about office space in Tallinn.", DAY + 90 * MINUTE, "not_attempted", None) },
    ];
    let filler = [
        "Please confirm the delivery window for the replacement parts.",
        "Book the small meeting room for the design review on Monday morning.",
        "The second draft reads better, but the introduction still needs a stronger opening line.",
        "Send Brunel the invoice and copy the accounts team.",
        "Summarize the customer interview in three bullet points and highlight anything about pricing.",
        "Ask Qwen support whether the model card lists the supported languages.",
        "Thanks for the quick turnaround, this looks great.",
    ];
    let bundles = [Some("com.apple.mail"), Some("com.apple.Notes"), Some("com.openai.chat"), Some("com.tinyspeck.slackmacgap"), Some("com.apple.MobileSMS"), Some("com.microsoft.Word"), None];
    for i in 0..48i64 {
        let u = i as usize;
        // Most days in a two-week run up to two days ago, then scattered over five months.
        let days = if i < 16 { 2 + i / 2 } else { 12 + (i - 15) * 3 };
        rows.push(row(filler[u % filler.len()], days * DAY + (i % 9) * 47 * MINUTE, "confirmed", bundles[u % bundles.len()]));
    }
    rows
}

pub fn seed(db: &Db) {
    let now = now_ms();
    let insert_quality = |id: &str, json: &str, hash: &str| {
        db.conn.execute("INSERT INTO transcription_quality VALUES (?,1,?,?)", params![id, json, hash]).expect("seed quality");
    };
    for (i, r) in seed_rows().iter().enumerate() {
        let n = i as i64 + 1;
        let id = seed_id(n);
        let recovery = if r.delivery == "confirmed" { "resolved" } else { "needs_review" };
        let source = if r.delivery == "not_attempted" { None } else { Some("faithful") };
        db.conn
            .execute(
                "INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason,target_bundle_id,revision,delivered_source,recognition_path,server_failure,input_device_name,input_device_kind) VALUES (?,?,?,?,?,?,?,?,1,?,?,?,?,?)",
                params![id, r.text, now - r.ago, r.delivery, recovery, r.quality, r.stop, r.bundle, source, r.path, r.failure, r.device.map(|d| d.0), r.device.map(|d| d.1)],
            )
            .expect("seed transcription");
        // Row 2 stays legacy-free with reasons; row 5 is the legacy example with no quality row.
        match n {
            5 => {}
            1 => {
                let half = r.text.find(" and ask").unwrap_or(0);
                let (a, b) = r.text.split_at(half);
                let (json, hash) = detail_json(r.text, &[(0, 239_360, a), (207_360, 32_640, b.trim_start())], json!([]), true);
                insert_quality(&id, &json, &hash);
            }
            2 => {
                let (json, hash) = detail_json(r.text, &[(0, 48_000, r.text)], json!([{"code": "capture_failure"}, {"code": "uncertain_join", "window": 0}]), false);
                insert_quality(&id, &json, &hash);
            }
            _ => {
                let seconds = (r.text.split_whitespace().count() as i64 / 2).max(1);
                let (json, hash) = detail_json(r.text, &[(0, seconds * 16_000, r.text)], json!([]), false);
                insert_quality(&id, &json, &hash);
            }
        }
    }
    seed_detail_extras(db);
    db.conn
        .execute_batch(
            "UPDATE history_usage SET row_count=(SELECT count(*) FROM transcriptions),
             payload_bytes=(SELECT coalesce(sum(length(cast(text AS blob))),0) FROM transcriptions)
              +(SELECT coalesce(sum(length(cast(detail_json AS blob))),0) FROM transcription_quality)
              +(SELECT coalesce(sum(length(cast(input_text AS blob))+length(cast(coalesce(output_text,'') AS blob))),0) FROM rewrite_attempts)
              +(SELECT coalesce(sum(coalesce(length(cast(snapshot_json AS blob)),0)+coalesce(length(cast(pre_spelling_text AS blob)),0)+coalesce(length(cast(spelling_changes_json AS blob)),0)),0) FROM dictation_contexts)
             WHERE id=1",
        )
        .expect("seed usage");
}

/// Context and rewrite attempts for the rows the detail sheet shows off.
fn seed_detail_extras(db: &Db) {
    let first = seed_id(1);
    let snapshot = json!({"after_cursor": " Best regards", "app_category": "email", "app_name": "Mail", "before_cursor": "Hi team,", "field_kind": "multi_line",
        "schema_version": 1, "style_hints": false, "terms": [{"kind": "name", "source": "window_title", "text": "Northwind"}], "truncated": ["before_cursor"], "window_title": "Kickoff"})
    .to_string();
    let changes = json!([{"length": 9, "match": "exact_fold", "original": "north wind", "replacement": "Northwind", "source_part": "window_title", "start": 40}]).to_string();
    db.conn
        .execute(
            "INSERT INTO dictation_contexts (transcription_id,outcome,capture_ms,app_bundle_id,snapshot_json,snapshot_hash,pre_spelling_text,spelling_changes_json,speller_version) VALUES (?,'used',12,'com.apple.mail',?,?,?,?,1)",
            params![first, snapshot, sha256_hex(snapshot.as_bytes()), "Move the kickoff to Thursday and ask north wind to send the updated floor plan before noon.", changes],
        )
        .expect("seed context");
    let text = "Move the kickoff to Thursday and ask Northwind to send the updated floor plan before noon.";
    let start = now_ms() - MINUTE;
    let insert = |n: i64, ordinal: i64, mode: &str, state: &str, output: Option<&str>, category: Option<&str>, delivered: i64, context: Option<String>| {
        db.conn
            .execute(
                "INSERT INTO rewrite_attempts (id,transcription_id,ordinal,mode,state,input_text,input_hash,output_text,output_hash,unchanged,failure_category,started_at,duration_ms,first_byte_ms,protocol_version,backend_model,prompt_version,shield_version,endpoint_origin,delivered,context_hash) VALUES (?,?,?,?,?,?,?,?,?,0,?,?,420,85,?,?,3,2,'https://rewrite.example.test',?,?)",
                params![seed_id(n), first, ordinal, mode, state, text, sha256_hex(text.as_bytes()), output, output.map(|o| sha256_hex(o.as_bytes())), category, start,
                    if context.is_some() { 2 } else { 1 }, output.map(|_| "seed-model-1"), delivered, context],
            )
            .expect("seed attempt");
    };
    insert(9101, 1, "clean", "failed", None, Some("server_unreachable"), 0, None);
    let rewritten = "Please move the kickoff to Thursday, and ask Northwind to send the updated floor plan before noon.";
    insert(9102, 2, "polished", "succeeded", Some(rewritten), None, 1, Some(sha256_hex(snapshot.as_bytes())));
    db.conn
        .execute(
            "UPDATE transcriptions SET rewrite_state='succeeded',delivered_source='rewrite',delivered_rewrite_attempt_id=? WHERE id=?",
            params![seed_id(9102), first],
        )
        .expect("seed delivered");
}

/// Waiting dictations with audio files, used by a scenario and tests rather than the default seed,
/// because Swift drops rows whose audio file is missing at startup.
pub fn seed_pending(db: &Db, dir: &Path) {
    let _ = std::fs::create_dir_all(dir);
    let now = now_ms();
    for (n, age, samples) in [(9201, PENDING_MAX_AGE_MS + MINUTE, 160_000), (9202, 3 * MINUTE, 48_000)] {
        let id = seed_id(n);
        let file = format!("{id}.f32");
        let _ = std::fs::write(dir.join(&file), vec![0u8; samples as usize * 4]);
        let _ = db.conn.execute(
            "INSERT OR IGNORE INTO pending_remote_dictations (id,audio_file,sample_count,created_at,attempts,next_attempt_at,last_failure) VALUES (?,?,?,?,1,?,'unreachable')",
            params![id, file, samples, now - age, now + 600_000],
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seeded() -> Db {
        let db = Db::memory();
        seed(&db);
        db
    }

    #[test]
    fn sha256_and_uuid_are_standard() {
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        let u = new_uuid(&Db::memory());
        assert_eq!(u.len(), 36);
        assert_eq!(&u[14..15], "4");
        assert!(u.chars().all(|c| !c.is_lowercase()));
        assert_eq!(civil_from_days(days_from_civil(2026, 10, 31)), (2026, 10, 31));
    }

    // parity: HIST-016 HIST-017 HIST-018 HIST-019 HIST-020 HIST-021 HIST-022 HIST-024 HIST-036 HIST-086
    #[test]
    fn paging_search_and_the_resident_window() {
        let db = seeded();
        let mut m = Model::default();
        m.refresh(&db);
        assert_eq!(m.entries.len(), PAGE_SIZE);
        assert!(m.has_older && !m.has_newer);
        assert!(m.entries.windows(2).all(|w| (w[0].created_at, &w[0].id) >= (w[1].created_at, &w[1].id)));
        // A row newer than the watermark stays out until a replacing refresh.
        db.conn.execute(&format!("INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason) VALUES ('{}','Newest row',{},'not_attempted','needs_review','complete','key_release')", seed_id(7777), now_ms() + 5000), []).unwrap();
        m.load_older(&db);
        assert!(!m.entries.iter().any(|e| e.text == "Newest row"));
        assert!(m.entries.len() > PAGE_SIZE);
        m.reload_list(&db);
        assert_eq!(m.entries[0].text, "Newest row");
        // Case-insensitive, diacritic-sensitive, not trimmed.
        assert!(matches("Zürich office", "ZÜRICH"));
        assert!(!matches("Zürich office", "Zurich"));
        assert!(!matches("abc", " abc"));
        m.set_search("NORTHWIND");
        m.reload_list(&db);
        assert!(!m.entries.is_empty() && m.entries.iter().all(|e| e.text.contains("Northwind")));
        m.set_search("no such text anywhere");
        m.reload_list(&db);
        assert!(m.is_no_matches());
        // Over the limit: reverts with the copy.
        assert!(!m.set_search(&"x".repeat(257)));
        assert_eq!(m.search_text, "no such text anywhere");
        assert_eq!(m.error.as_deref(), Some(SEARCH_LIMIT_MESSAGE));
        assert!(query_is_valid(&"x".repeat(256)) && !query_is_valid(&"é".repeat(513)));
        // Resident cap drops the far end and reopens it.
        let mut w = Model { entries: (0..195).map(|i| Entry { id: seed_id(i), ..m_entry() }).collect(), ..Default::default() };
        w.place(Page { entries: (195..215).map(|i| Entry { id: seed_id(i), ..m_entry() }).collect(), has_more: false, watermark: None }, Placement::AppendOlder);
        assert_eq!(w.entries.len(), RESIDENT_LIMIT);
        assert!(w.has_newer && !w.has_older);
        assert_eq!(w.entries[0].id, seed_id(15));
        w.place(Page { entries: (0..15).map(|i| Entry { id: seed_id(i), ..m_entry() }).collect(), has_more: false, watermark: None }, Placement::PrependNewer);
        assert_eq!(w.entries.len(), RESIDENT_LIMIT);
        assert!(w.has_older && !w.has_newer);
    }

    fn m_entry() -> Entry {
        get(&seeded(), &seed_id(1)).unwrap().unwrap()
    }

    // parity: HIST-035 HIST-043 HIST-045 HIST-046 HIST-098 HIST-099 HIST-100 HIST-101
    #[test]
    fn labels_and_day_groups() {
        let db = seeded();
        let mut m = Model::default();
        m.refresh(&db);
        let g = m.date_groups(&db, now_ms());
        assert_eq!(g[0].title, "Today");
        assert!(g.iter().any(|x| x.title == "Yesterday"));
        assert!(g.iter().skip(2).all(|x| x.title.split(' ').count() == 3));
        let e = |n| get(&db, &seed_id(n)).unwrap().unwrap();
        assert_eq!(e(2).quality_label(), Some("Incomplete"));
        assert_eq!(e(5).quality_label(), Some("Cut short at 180 seconds"));
        assert_eq!(e(1).quality_label(), None);
        assert_eq!(e(1).path_label(false), None);
        assert_eq!(e(1).path_label(true).as_deref(), Some("Local"));
        assert_eq!(e(3).path_label(false).as_deref(), Some("Server"));
        assert_eq!(e(4).path_label(false).as_deref(), Some("Local after server failure (no answer)"));
        assert_eq!(failure_label("pin_mismatch"), "identity changed");
        assert_eq!(e(1).microphone_label(), "Microphone: Studio Microphone");
        assert_eq!(e(5).microphone_label(), "Microphone: Not recorded");
        assert_eq!(spaced("permission_revoked"), "permission revoked");
    }

    // parity: HIST-096 HIST-111 HIST-112 HIST-113 HIST-114 HIST-115 HIST-116 HIST-117 HIST-118 HIST-120 HIST-121 HIST-122 HIST-123 HIST-125 HIST-126 HIST-127 HIST-129 HIST-131 HIST-132 HIST-138 HIST-141 HIST-158 HIST-088
    #[test]
    fn detail_decodes_and_lists_every_row() {
        let db = seeded();
        let env = envelope(&db, &seed_id(1)).unwrap();
        let d = env.detail.as_ref().unwrap();
        let lines = processing_lines(d);
        let has = |l: &str, v: &str| lines.iter().any(|x| matches!(x, Line::Meta(a, b) if a == l && b == v));
        assert!(has("Engine", "seed-engine"));
        assert!(has("Language", "en"));
        assert!(has("Uncommitted build changes", "No"));
        assert!(has("Applied formatting rules", "N001, N004"));
        assert!(has("Ambiguous vocabulary entries", "None"));
        assert!(has("Audio", "16000 Hz, 1 channel, float32_pcm"));
        assert!(has("Input", "240000 samples; 15.0 seconds"));
        assert!(has("Windows", "239360 samples; overlap 32000; stride 207360"));
        assert!(has("Minimum padded input", "4800 samples"));
        assert!(has("Recognition duration", "1.5 seconds"));
        assert!(has("Window 1 timing evidence", "unavailable; 0 recorded tokens; 239360 padded samples"));
        assert!(has("Attempt 1 (selected)", "seed-engine; completed; 1.5 seconds"));
        assert!(lines.contains(&Line::Plain("None recorded".into())));
        let hashes = hash_lines(d, &env.content_hash);
        assert!(hashes.iter().any(|x| matches!(x, Line::Meta(a, _) if a == "encoder.mlmodelc")));
        assert!(hashes.iter().any(|x| matches!(x, Line::Meta(a, _) if a == "Raw window 2")));
        // A sparse detail lists its missing metadata and its reasons.
        let sparse = processing_lines(envelope(&db, &seed_id(2)).unwrap().detail.as_ref().unwrap());
        assert!(sparse.contains(&Line::Plain("capture_failure".into())));
        assert!(sparse.contains(&Line::Plain("uncertain_join (window 1)".into())));
        assert!(sparse.contains(&Line::Meta("SDK".into(), "Unavailable".into())));
        assert!(sparse.contains(&Line::Meta("sdk_version".into(), "not_recorded".into())));
        assert!(sparse.contains(&Line::Meta("Language".into(), "Automatic; no hint".into())));
        // Context.
        let c = env.context.as_ref().unwrap();
        assert_eq!(context_label(Some(c)), "Context: used");
        assert_eq!(context_label(None), "Context: not recorded");
        assert_eq!(c.spelling_changes[0].replacement, "Northwind");
        assert_eq!(part_label(&c.spelling_changes[0].source_part), "Window title");
        let snap = snapshot_lines(c.snapshot.as_ref().unwrap());
        assert!(snap.contains(&("Field".to_string(), "multi line".to_string())));
        assert!(snap.contains(&("Terms".to_string(), "Northwind".to_string())));
        assert!(snap.contains(&("Shortened".to_string(), "before_cursor".to_string())));
        // Rewrite lines.
        let mut m = Model::default();
        m.show_detail(&db, &seed_id(1));
        assert_eq!(m.rewrite_state_line(), "Rewrite: succeeded");
        assert_eq!(m.delivered_line(), "Delivered: rewrite attempt 2 (Polished)");
        assert_eq!(m.current_rewrite().unwrap().ordinal, 2);
        assert_eq!(context_rewrite_line(Some(c), m.attempts.last()), Some("Context sent to the rewrite server"));
        assert!(m.attempts[1].summary().contains("420 ms total · 85 ms to first byte · context sent · delivered · seed-model-1+p3+s2"));
        assert!(m.attempts[0].summary().contains("server_unreachable"));
        m.show_detail(&db, &seed_id(3));
        assert_eq!(m.delivered_line(), "Delivered: saved text");
        m.show_detail(&db, &seed_id(5));
        assert_eq!(m.delivered_line(), "Delivered: nothing yet");
        assert!(m.envelope.as_ref().unwrap().detail.is_none());
        // Damaged JSON is an error, a missing row closes the detail.
        db.conn.execute("UPDATE transcription_quality SET detail_json='{}' WHERE transcription_id=?", [seed_id(3)]).unwrap();
        m.show_detail(&db, &seed_id(3));
        assert_eq!(m.detail_error.as_deref(), Some(DETAIL_ERROR));
        m.show_detail(&db, "missing");
        assert_eq!(m.detail_id, None);
    }

    // parity: HIST-087
    #[test]
    fn rewrite_attempts_has_swifts_columns_and_rules() {
        let db = seeded();
        let columns: Vec<String> = db
            .conn
            .prepare("SELECT name FROM pragma_table_info('rewrite_attempts')")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        for c in [
            "id",
            "transcription_id",
            "ordinal",
            "mode",
            "state",
            "input_text",
            "input_hash",
            "output_text",
            "output_hash",
            "unchanged",
            "failure_category",
            "stale",
            "started_at",
            "protocol_version",
        ] {
            assert!(columns.iter().any(|x| x == c), "{c} in {columns:?}");
        }
        let id = seed_id(3);
        let text = get(&db, &id).unwrap().unwrap().text;
        let attempt = begin_rewrite(&db, &id, "clean", &text, "https://x.test").unwrap();
        let ordinal: i64 = db
            .conn
            .query_row(
                "SELECT ordinal FROM rewrite_attempts WHERE id=?1",
                [&attempt],
                |r| r.get(0),
            )
            .unwrap();
        assert!(
            db.conn
                .execute(
                    "UPDATE rewrite_attempts SET ordinal=11 WHERE id=?1",
                    [&attempt]
                )
                .is_err(),
            "1 to 10"
        );
        assert_eq!(ordinal, 1);
        db.conn
            .execute("DELETE FROM transcriptions WHERE id=?1", [&id])
            .unwrap();
        assert!(attempts(&db, &id).unwrap().is_empty(), "cascade");
    }

    // parity: HIST-062 HIST-063 HIST-150 HIST-151 HIST-152 HIST-153 HIST-175 HIST-176 HIST-149 HIST-155
    #[test]
    fn delivery_rewrite_and_delete_writes() {
        let db = seeded();
        let usage = || -> (i64, i64) { db.conn.query_row("SELECT row_count,payload_bytes FROM history_usage", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap() };
        let id = seed_id(3);
        let e = get(&db, &id).unwrap().unwrap();
        // Delivery.
        assert_eq!(
            begin_attempt(&db, &id, e.revision + 9).unwrap_err(),
            StoreError::Stale
        );
        assert_eq!(
            delete_confirmed(&db, &id, e.revision + 9).unwrap_err(),
            StoreError::Stale
        );
        let (attempt, rev) = begin_attempt(&db, &id, e.revision).unwrap();
        assert!(get(&db, &id).unwrap().unwrap().is_attempting());
        assert_eq!(begin_attempt(&db, &id, rev).unwrap_err(), StoreError::Busy);
        assert_eq!(delete_confirmed(&db, &id, rev).unwrap_err(), StoreError::Busy);
        let done = record_outcome(&db, &id, rev, &attempt, Outcome::NotInserted, None).unwrap();
        assert_eq!((done.delivery_state.as_str(), done.recovery_state.as_str(), done.delivered_source.as_deref()), ("not_inserted", "needs_review", Some("faithful")));
        // Rewrite accounting.
        let before = usage().1;
        let a = begin_rewrite(&db, &id, "clean", &e.text, "https://x.test").unwrap();
        assert_eq!(usage().1, before + e.text.len() as i64 * 5);
        assert_eq!(get(&db, &id).unwrap().unwrap().rewrite_state, "pending");
        assert_eq!(begin_rewrite(&db, &id, "clean", &e.text, "https://x.test").unwrap_err(), StoreError::Refused("concurrency_limit"));
        assert_eq!(delete_confirmed(&db, &id, done.revision).unwrap_err(), StoreError::Busy);
        record_rewrite_result(&db, &a, "Short.", Some(9)).unwrap();
        assert_eq!(usage().1, before + e.text.len() as i64 + 6);
        let b = begin_rewrite(&db, &id, "concise", &e.text, "https://x.test").unwrap();
        terminate_rewrite(&db, &b, Some("timeout"), None).unwrap();
        assert_eq!(get(&db, &id).unwrap().unwrap().rewrite_state, "timed_out");
        let c = begin_rewrite(&db, &id, "concise", &e.text, "https://x.test").unwrap();
        let mut m = Model::default();
        m.show_detail(&db, &id);
        assert!(!m.can_request_rewrite(), "no rewriter");
        m.has_rewriter = true;
        assert!(!m.can_request_rewrite(), "pending attempt");
        m.cancel_rewrite(&db);
        assert_eq!(m.rewrite_notice.as_deref(), Some("Rewrite cancelled."));
        assert_eq!(attempts(&db, &id).unwrap().iter().find(|x| x.id == c).unwrap().state, "cancelled");
        assert!(m.can_request_rewrite());
        // Startup repair.
        let (_, rev2) = begin_attempt(&db, &id, done.revision).unwrap();
        let p = begin_rewrite(&db, &id, "clean", &e.text, "https://x.test").unwrap();
        startup_repair(&db).unwrap();
        let repaired = get(&db, &id).unwrap().unwrap();
        assert_eq!((repaired.delivery_state.as_str(), repaired.revision), ("uncertain", rev2 + 1));
        assert_eq!(attempts(&db, &id).unwrap().iter().find(|x| x.id == p).unwrap().failure_category.as_deref(), Some("interrupted"));
        // Attempt limit.
        for _ in 0..6 {
            let n = begin_rewrite(&db, &id, "clean", &e.text, "https://x.test").unwrap();
            terminate_rewrite(&db, &n, None, None).unwrap();
        }
        assert_eq!(begin_rewrite(&db, &id, "clean", &e.text, "https://x.test").unwrap_err(), StoreError::Refused("attempt_limit"));
        m.reload_attempts(&db);
        assert_eq!(m.rewrite_limit_explanation(), Some("This dictation already has ten rewrite attempts."));
        assert!(!m.can_request_rewrite());
        // Delete: cascades and subtracts every byte.
        let (rows, _) = usage();
        delete_confirmed(&db, &id, repaired.revision).unwrap();
        assert_eq!(usage().0, rows - 1);
        let left: i64 = db.conn.query_row("SELECT count(*) FROM rewrite_attempts WHERE transcription_id=?", [&id], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
        assert_eq!(delete_confirmed(&db, &id, repaired.revision).unwrap_err(), StoreError::Stale);
    }

    fn rewrite_ready() -> (Db, Model, String) {
        let db = Db::memory();
        seed(&db);
        let id = seed_id(40);
        let mut m = Model::default();
        m.show_detail(&db, &id);
        for a in m.attempts.clone() {
            db.conn.execute("DELETE FROM rewrite_attempts WHERE id=?", [&a.id]).unwrap();
        }
        db.conn.execute("UPDATE transcriptions SET quality='complete' WHERE id=?", [&id]).unwrap();
        m.has_rewriter = true;
        m.show_detail(&db, &id);
        assert!(m.can_request_rewrite(), "the baseline each condition below turns off");
        (db, m, id)
    }

    // parity: HIST-147
    #[test]
    fn rewrite_gate_needs_a_rewriter() {
        let (_, mut m, _) = rewrite_ready();
        m.has_rewriter = false;
        assert!(!m.can_request_rewrite());
    }

    #[test]
    fn rewrite_gate_needs_an_idle_entry() {
        let (_, mut m, _) = rewrite_ready();
        m.rewrite_busy = true;
        assert!(!m.can_request_rewrite());
    }

    #[test]
    fn rewrite_gate_stops_at_ten_attempts() {
        let (db, mut m, id) = rewrite_ready();
        let text = m.envelope.as_ref().unwrap().entry.text.clone();
        for n in 0..MAX_ATTEMPTS {
            assert!(m.can_request_rewrite(), "attempt {n}");
            let a = begin_rewrite(&db, &id, "clean", &text, "https://x.test").unwrap();
            terminate_rewrite(&db, &a, Some("timeout"), None).unwrap();
            m.reload_attempts(&db);
        }
        assert!(!m.can_request_rewrite());
    }

    #[test]
    fn rewrite_gate_stops_on_a_pending_attempt_here() {
        let (db, mut m, id) = rewrite_ready();
        let text = m.envelope.as_ref().unwrap().entry.text.clone();
        begin_rewrite(&db, &id, "clean", &text, "https://x.test").unwrap();
        m.reload_attempts(&db);
        assert!(!m.can_request_rewrite());
    }

    // parity: HIST-147 HIST-180
    #[test]
    fn rewrite_gate_stops_when_two_run_elsewhere() {
        let (db, mut m, id) = rewrite_ready();
        let others: Vec<String> = entries_page(&db, 5).into_iter().filter(|e| e != &id).take(2).collect();
        let a = begin_rewrite(&db, &others[0], "clean", "words", "https://x.test").unwrap();
        m.reload_attempts(&db);
        assert!(m.can_request_rewrite(), "one elsewhere still leaves room");
        begin_rewrite(&db, &others[1], "clean", "words", "https://x.test").unwrap();
        m.reload_attempts(&db);
        assert!(!m.can_request_rewrite());
        assert!(m.rewrite_notice.is_none(), "no reason is given, as in Swift");
        terminate_rewrite(&db, &a, Some("timeout"), None).unwrap();
        m.reload_attempts(&db);
        assert!(m.can_request_rewrite());
    }

    // parity: HIST-147 HIST-180
    #[test]
    fn rewrite_gate_needs_complete_quality() {
        let (db, mut m, id) = rewrite_ready();
        db.conn.execute("UPDATE transcriptions SET quality='incomplete' WHERE id=?", [&id]).unwrap();
        m.reload_attempts(&db);
        assert!(!m.can_request_rewrite());
        assert!(m.rewrite_notice.is_none(), "no reason is given, as in Swift");
    }

    fn entries_page(db: &Db, n: i64) -> Vec<String> {
        let mut s = db.conn.prepare("SELECT id FROM transcriptions ORDER BY created_at DESC LIMIT ?").unwrap();
        s.query_map([n], |r| r.get(0)).unwrap().map(Result::unwrap).collect()
    }

    fn remote(origin: &str, insecure: bool, credential: bool) -> crate::settings::RewriteSettings {
        crate::settings::RewriteSettings { origin: origin.into(), insecure_override: insecure, credential_present: credential }
    }

    // parity: HIST-149
    #[test]
    fn admission_checks_in_swifts_order() {
        let (db, _, id) = rewrite_ready();
        let ok = remote("https://x.test", false, true);
        // Rewriting off outranks every settings problem, and writes nothing.
        assert_eq!(admit_rewrite(&db, &id, "words", "clean", false, &remote("http://x.test", false, false)), Admission::NotEligible);
        assert_eq!(admit_rewrite(&db, &id, " \n", "clean", true, &ok), Admission::NotEligible);
        assert!(attempts(&db, &id).unwrap().is_empty());
        // Blocked plain HTTP, then the credential, then the endpoint.
        assert_eq!(admit_rewrite(&db, &id, "words", "clean", true, &remote("http://x.test", false, false)), Admission::Refused("insecure_endpoint_blocked"));
        assert_eq!(admit_rewrite(&db, &id, "words", "clean", true, &remote("https://x.test", false, false)), Admission::Refused("missing_credential"));
        assert_eq!(admit_rewrite(&db, &id, "words", "clean", true, &remote("", false, false)), Admission::Refused("invalid_settings"));
        // Settings outrank the input bound; the bound outranks the store.
        assert_eq!(admit_rewrite(&db, &id, &"x".repeat(20_001), "clean", true, &ok), Admission::Refused("input_too_large"));
        assert_eq!(admit_rewrite(&db, &id, &"é".repeat(32_769), "clean", true, &ok), Admission::Refused("input_too_large"));
        let Admission::Admitted(attempt) = admit_rewrite(&db, &id, "words", "clean", true, &ok) else { panic!("admitted") };
        assert_eq!(admit_rewrite(&db, &id, "words", "clean", true, &ok), Admission::Refused("concurrency_limit"));
        assert_eq!(attempts(&db, &id).unwrap().iter().find(|a| a.id == attempt).unwrap().state, "pending");
    }

    // parity: HIST-179
    #[test]
    fn rewrite_with_rewriting_off_clears_the_notice_and_writes_nothing() {
        let (db, mut m, id) = rewrite_ready();
        m.rewrite_notice = Some("old".into());
        assert!(m.can_request_rewrite(), "the button stays enabled with rewriting off");
        assert!(m.request_rewrite(&db, false, &remote("https://x.test", false, true)).is_none());
        assert!(m.rewrite_notice.is_none());
        assert!(attempts(&db, &id).unwrap().is_empty());
    }

    // parity: HIST-136
    #[test]
    fn a_refused_rewrite_shows_the_refusal_and_keeps_no_row() {
        let (db, mut m, id) = rewrite_ready();
        assert!(m.request_rewrite(&db, true, &remote("https://x.test", false, false)).is_none());
        assert_eq!(m.rewrite_notice.as_deref(), Some("Rewriting skipped: no credential for this server."));
        assert!(attempts(&db, &id).unwrap().is_empty());
    }

    /// One HTTP exchange on a loopback port: answers `status` and `body`, returns what it was sent.
    fn server(status: u16, body: String) -> (String, std::thread::JoinHandle<String>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let thread = std::thread::spawn(move || {
            let (mut c, _) = listener.accept().unwrap();
            let (mut got, mut buf) = (Vec::new(), [0; 4096]);
            loop {
                let n = c.read(&mut buf).unwrap();
                got.extend_from_slice(&buf[..n]);
                let text = String::from_utf8_lossy(&got).to_string();
                let Some(head) = text.find("\r\n\r\n") else { continue };
                let wanted = text.lines().find_map(|l| l.to_lowercase().strip_prefix("content-length: ").map(|v| v.trim().parse::<usize>().unwrap())).unwrap_or(0);
                if got.len() >= head + 4 + wanted {
                    write!(c, "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
                    return text;
                }
            }
        });
        (origin, thread)
    }

    fn result_line(id: &str, mode: &str, text: &str) -> String {
        serde_json::json!({"event":"result","schema_version":1,"request_id":id,"mode":mode,"text":text,"server":{"name":"s","version":"1"},"backend":{"kind":"k","model":"m"},"prompt_version":1,"shield":{"version":1,"placeholders":0,"restored":0},"timing":{}}).to_string() + "\n"
    }

    fn sample_request(origin: &str) -> RewriteRequest {
        RewriteRequest { dictation: "d".into(), attempt: "ABC".into(), mode: "clean", text: "some spoken words".into(), origin: origin.into() }
    }

    fn send(status: u16, body: String) -> Result<String, &'static str> {
        let (origin, thread) = server(status, body);
        let out = send_rewrite(&sample_request(&origin), Some("key"), std::time::Duration::from_secs(5));
        thread.join().unwrap();
        out
    }

    // parity: HIST-148
    #[test]
    fn an_answered_rewrite_is_stored_and_a_retry_sends_the_first_input() {
        let (db, mut m, id) = rewrite_ready();
        let saved = m.envelope.as_ref().unwrap().entry.text.clone();
        m.rewrite_mode = RewriteMode::Concise;
        let first = m.request_rewrite(&db, true, &remote("https://x.test", false, true)).unwrap();
        assert_eq!(m.pending_rewrite().map(|a| a.mode.as_str()), Some("concise"), "pending until answered");
        m.finish_rewrite(&db, &first, Ok("Short.".into()), 12);
        let a = attempts(&db, &id).unwrap();
        assert_eq!((a[0].state.as_str(), a[0].input_text.as_str()), ("succeeded", saved.as_str()));
        assert!(m.rewrite_notice.is_none());
        db.conn.execute("UPDATE transcriptions SET text='changed' WHERE id=?", [&id]).unwrap();
        m.reload_attempts(&db);
        assert_eq!(m.request_rewrite(&db, true, &remote("https://x.test", false, true)).unwrap().text, saved);
    }

    // parity: HIST-155
    #[test]
    fn an_answer_after_cancel_is_dropped() {
        let (db, mut m, id) = rewrite_ready();
        let request = m.request_rewrite(&db, true, &remote("https://x.test", false, true)).unwrap();
        m.cancel_rewrite(&db);
        m.finish_rewrite(&db, &request, Ok("Late.".into()), 1);
        assert_eq!(m.rewrite_notice.as_deref(), Some("Rewrite cancelled."));
        assert_eq!(attempts(&db, &id).unwrap()[0].state, "cancelled");
    }

    #[test]
    fn the_request_carries_protocol_v1_and_the_credential() {
        let (origin, thread) = server(200, result_line("abc", "clean", "Clean words."));
        assert_eq!(send_rewrite(&sample_request(&origin), Some("key"), std::time::Duration::from_secs(5)), Ok("Clean words.".into()));
        let got = thread.join().unwrap();
        assert!(got.starts_with("POST /v1/rewrite HTTP/1.1"), "{got}");
        assert!(got.to_lowercase().contains("authorization: bearer key"));
        let body: serde_json::Value = serde_json::from_str(got.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(body, serde_json::json!({"schema_version":1,"request_id":"ABC","mode":"clean","text":"some spoken words","language_hints":[],"stream_deltas":false}));
    }

    // parity: HIST-134
    #[test]
    fn connection_failures_map_to_their_notices() {
        let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", closed.local_addr().unwrap());
        drop(closed);
        assert_eq!(send_rewrite(&sample_request(&origin), None, std::time::Duration::from_secs(5)), Err("server_unreachable"));
        assert_eq!(send(500, String::new()), Err("transport_error"));
        assert_eq!(send(401, String::new()), Err("authentication_failed"));
        assert_eq!(send(503, String::new()), Err("backend_unavailable"));
        // Accepts and never answers.
        let silent = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", silent.local_addr().unwrap());
        assert_eq!(send_rewrite(&sample_request(&origin), None, std::time::Duration::from_millis(200)), Err("timeout"));
    }

    // parity: HIST-135
    #[test]
    fn unusable_replies_map_to_their_categories() {
        assert_eq!(send(200, "not json\n".into()), Err("malformed_response"));
        assert_eq!(send(200, String::new()), Err("malformed_response"), "no terminal event");
        assert_eq!(send(200, result_line("other", "clean", "Words.")), Err("request_mismatch"));
        assert_eq!(send(200, result_line("abc", "polished", "Words.")), Err("malformed_response"));
        assert_eq!(send(200, result_line("abc", "clean", "  ")), Err("empty_response"));
        assert_eq!(send(200, result_line("abc", "clean", &"x".repeat(69))), Err("oversized_response"));
        assert_eq!(send(200, result_line("abc", "clean", "⟦0⟧ words")), Err("server_validation_failed"));
        assert_eq!(send(200, result_line("abc", "clean", "Words.").replace("\"schema_version\":1", "\"schema_version\":9")), Err("unsupported_schema_version"));
        assert_eq!(send(200, format!("{{\"event\":\"error\",\"request_id\":\"abc\",\"code\":\"backend_error\"}}\n")), Err("server_validation_failed"));
        // Progress is checked and skipped; the first terminal event decides.
        let lines = format!("{{\"event\":\"accepted\",\"request_id\":\"abc\"}}\n{}{}", result_line("abc", "clean", "First."), result_line("abc", "clean", "Second."));
        assert_eq!(send(200, lines), Ok("First.".into()));
    }

    // parity: HIST-134
    #[test]
    fn connection_notice_copy() {
        for (category, text) in [
            ("server_unreachable", "Rewrite server unreachable."),
            ("transport_error", "Rewrite connection failed."),
            ("timeout", "Rewrite took too long."),
            ("authentication_failed", "Rewrite server rejected the credential. Check Settings."),
            ("backend_unavailable", "Rewrite model is not available on the server."),
        ] {
            assert_eq!(rewrite_notice(category), text);
        }
    }

    // parity: HIST-135
    #[test]
    fn result_notice_copy() {
        for category in ["malformed_response", "unsupported_schema_version", "request_mismatch"] {
            assert_eq!(rewrite_notice(category), "Rewrite server sent an unusable reply.");
        }
        for category in ["empty_response", "oversized_response", "server_validation_failed"] {
            assert_eq!(rewrite_notice(category), "Rewrite result was rejected.");
        }
    }

    // parity: HIST-136
    #[test]
    fn skipped_notice_copy() {
        for (category, text) in [
            ("missing_credential", "Rewriting skipped: no credential for this server."),
            ("insecure_endpoint_blocked", "Rewriting skipped: unencrypted connection blocked."),
            ("invalid_settings", "Rewriting skipped: the endpoint is invalid."),
            ("input_too_large", "Rewriting skipped: the text is too long."),
            ("capacity_exceeded", "Rewriting skipped: history is full."),
        ] {
            assert_eq!(rewrite_notice(category), text);
        }
    }

    // parity: HIST-137
    #[test]
    fn limit_notice_copy() {
        for (category, text) in [
            ("attempt_limit", "This dictation already has ten rewrite attempts."),
            ("concurrency_limit", "Two rewrites are still running."),
            ("interrupted", "Rewrite was interrupted by a restart."),
            ("context_copied", "Rewrite used on-screen text you did not say."),
        ] {
            assert_eq!(rewrite_notice(category), text);
        }
    }

    // parity: HIST-177 INS-107
    #[test]
    fn a_failed_insert_still_reads_as_delivered() {
        let (db, mut m, id) = rewrite_ready();
        let e = get(&db, &id).unwrap().unwrap();
        let a = begin_rewrite(&db, &id, "clean", &e.text, "https://x.test").unwrap();
        record_rewrite_result(&db, &a, "Short words.", Some(1)).unwrap();
        let (attempt, rev) = begin_attempt(&db, &id, e.revision).unwrap();
        record_outcome(&db, &id, rev, &attempt, Outcome::NotInserted, Some(&a)).unwrap();
        let delivered: i64 = db.conn.query_row("SELECT delivered FROM rewrite_attempts WHERE id=?", [&a], |r| r.get(0)).unwrap();
        assert_eq!(delivered, 1, "recorded as delivered although nothing was inserted");
        m.reload_attempts(&db);
        assert!(m.delivered_line().starts_with("Delivered: rewrite attempt 1"), "{}", m.delivered_line());
        assert!(crate::insights::load(&db).unwrap().words_corrected > 0);
    }

    // parity: HIST-064
    #[test]
    fn room_for_a_recording_follows_rows_bytes_and_disk() {
        let (db, _, _) = rewrite_ready();
        let set = |rows: i64, bytes: i64| db.conn.execute("UPDATE history_usage SET row_count=?,payload_bytes=?", [rows, bytes]).unwrap();
        set(1, 0);
        assert!(has_room(&db, None));
        assert!(!has_room(&db, Some(RESERVE_FREE_BYTES - 1)));
        assert!(has_room(&db, Some(RESERVE_FREE_BYTES)));
        set(MAX_ROWS, 0);
        assert!(!has_room(&db, None));
        set(MAX_ROWS - 1, MAX_PAYLOAD_BYTES - RESERVATION_BYTES);
        assert!(has_room(&db, None));
        set(1, MAX_PAYLOAD_BYTES - RESERVATION_BYTES + 1);
        assert!(!has_room(&db, None));
    }

    // parity: HIST-070 HIST-073 HIST-074 HIST-080 HIST-083 HIST-084 HIST-085 HIST-189
    #[test]
    fn waiting_dictations() {
        let db = seeded();
        let dir = std::env::temp_dir().join(format!("flow-pending-{}", std::process::id()));
        seed_pending(&db, &dir);
        let mut m = Model::default();
        m.refresh_pending(&db);
        assert_eq!(m.pending_items.len(), 2);
        let (old, new) = (m.pending_items[0].clone(), m.pending_items[1].clone());
        assert!(old.created_at < new.created_at);
        assert_eq!(old.status(now_ms()), "Retries stopped after 24 hours");
        assert_eq!(new.status(now_ms()), "Waiting for server");
        assert_eq!(new.length_label(), "3 s of audio");
        assert_eq!(PendingItem { sample_count: 15_999, ..new.clone() }.length_label(), "0 s of audio");
        let out = dir.join("out.wav");
        m.export_pending(&db, &dir, &new.id, &out);
        let bytes = std::fs::read(&out).unwrap();
        assert_eq!(&bytes[..4], b"RIFF");
        assert_eq!(u16::from_le_bytes([bytes[20], bytes[21]]), 3);
        assert_eq!(bytes.len(), 44 + 48_000 * 4);
        assert_eq!(m.pending_items.len(), 2, "export keeps the row");
        m.export_pending(&db, &dir, "missing", &out);
        assert_eq!(m.pending_error.as_deref(), Some(PENDING_ERROR));
        m.discard_pending(&db, &dir, &new.id);
        assert_eq!(m.pending_error, None);
        assert_eq!(m.pending_items.len(), 1);
        assert!(!dir.join(&new.audio_file).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
