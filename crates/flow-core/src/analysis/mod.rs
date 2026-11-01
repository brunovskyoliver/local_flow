//! Meeting summary generation, ported from the Swift `Intelligence` sources: the policy and chunk
//! planner, the evidence snapshot and its version, the language policy and the request. `wire` decodes
//! answers, `validate` checks them, `store` owns the rows, `run` is `MeetingAnalyzer` and its transports,
//! `queue` is `MeetingIntelligenceCoordinator`.
use crate::db::Db;
use crate::meetings::{self, LabelKind, Res, TRANSCRIPT_PAGE};
use rusqlite::{OptionalExtension, params};
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet};

pub mod queue;
pub mod run;
pub mod store;
pub mod validate;
pub mod wire;
#[cfg(test)]
mod tests;

pub const PIPELINE_VERSION: &str = "chunking_v2/overlay_match_v1/policy_v1";
pub const UNAVAILABLE_MESSAGE: &str = "This server does not offer meeting analysis";

/// `AnalysisFailure`. Categories are the `failure_category` values, details are bounded on write.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub category: &'static str,
    pub detail: Option<String>,
}
impl Failure {
    pub fn new(category: &'static str) -> Self {
        Failure { category, detail: None }
    }
    pub fn with(category: &'static str, detail: impl Into<String>) -> Self {
        Failure { category, detail: Some(detail.into()) }
    }
}
/// `AnalysisFailureCategory.forServerCode`.
pub fn category_for_code(code: &str) -> &'static str {
    match code {
        "unauthorized" => "authentication_failed",
        "unsupported_version" => "unsupported_version",
        "invalid_request" | "output_invalid" => "malformed_response",
        "too_large" => "too_long",
        "output_too_large" => "oversized_response",
        "server_busy" => "server_unavailable",
        "queue_timeout" | "preempted" => "backend_busy",
        "backend_unavailable" | "backend_error" => "backend_unavailable",
        "backend_timeout" | "backend_first_token_timeout" => "backend_timeout",
        "source_validation" => "source_validation",
        _ => "malformed_response",
    }
}
/// `AnalysisFailureCategory.forHTTPStatus`: the body's code decides when there is one.
pub fn category_for_status(status: u16, code: Option<&str>) -> &'static str {
    if let Some(code) = code {
        return category_for_code(code);
    }
    match status {
        401 | 403 => "authentication_failed",
        404 | 429 => "server_unavailable",
        413 => "too_long",
        503 => "backend_unavailable",
        _ => "server_unreachable",
    }
}

// MARK: policy

/// `AnalysisPolicy`: the values health can lower. What never changes is below as constants.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Policy {
    pub full_budget: usize,
    pub chunk_budget: usize,
    pub context_tokens: i64,
    pub sources_per_item: usize,
    pub topic_cap: usize,
    pub decision_cap: usize,
    pub action_cap: usize,
    pub next_step_cap: usize,
    pub question_cap: usize,
    pub risk_cap: usize,
}
impl Default for Policy {
    fn default() -> Self {
        Policy { full_budget: 12_288, chunk_budget: 16_384, context_tokens: 32_768, sources_per_item: 10, topic_cap: 20, decision_cap: 40, action_cap: 60, next_step_cap: 40, question_cap: 40, risk_cap: 40 }
    }
}
pub const MAX_CHUNKS: usize = 64;
pub const PARTIALS_PER_SYNTHESIS: usize = 16;
pub const REDUCE_DEPTH: usize = 2;
pub const PREEMPTION_RETRIES: u32 = 3;
pub const PER_REQUEST_SECONDS: u64 = 300;
pub const LANGUAGE_SAMPLE_BYTES: usize = 32 * 1024;
pub const MAX_NOTE_PARAGRAPHS: usize = 256;
pub const MAX_NOTE_PARAGRAPH_BYTES: usize = 8192;
pub const RUN_ROWS_PER_MEETING: i64 = 20;
const MAX_REQUEST_CONFIG_BYTES: usize = 2048;

impl Policy {
    /// `runDeadline`: 60 s plus 300 s per request, between 2 and 30 minutes.
    pub fn deadline_seconds(request_count: usize) -> u64 {
        (60 + PER_REQUEST_SECONDS * request_count.max(1) as u64).clamp(120, 1800)
    }
    /// `lowered(by:)`: health can only make the budget and the caps smaller.
    pub fn lowered(&self, health: &wire::Health) -> Policy {
        let mut p = self.clone();
        if let Some(l) = &health.limits {
            p.chunk_budget = p.chunk_budget.min(l.input_bytes);
            p.full_budget = p.full_budget.min(l.input_bytes);
            p.context_tokens = p.context_tokens.min(l.context_tokens);
        }
        if let Some(c) = &health.caps {
            p.sources_per_item = p.sources_per_item.min(c.sources_per_item);
            p.topic_cap = p.topic_cap.min(c.topics);
            p.decision_cap = p.decision_cap.min(c.decisions);
            p.action_cap = p.action_cap.min(c.action_items);
            p.next_step_cap = p.next_step_cap.min(c.next_steps);
            p.question_cap = p.question_cap.min(c.open_questions);
            p.risk_cap = p.risk_cap.min(c.risks);
        }
        p
    }
    /// `requestConfigJSON`, written on the run row, in Swift's key order.
    pub fn config_json(&self) -> String {
        let text = format!(
            "{{\"policy\":\"policy_v1\",\"chunking\":\"chunking_v2\",\"overlay\":\"overlay_match_v1\",\"full_budget_bytes\":{},\"chunk_budget_bytes\":{},\"max_chunks\":{MAX_CHUNKS},\"partials_per_synthesis\":{PARTIALS_PER_SYNTHESIS},\"reduce_depth\":{REDUCE_DEPTH},\"requests_in_flight\":1,\"preemption_retries\":{PREEMPTION_RETRIES},\"sources_per_item\":{},\"topic_cap\":{},\"decision_cap\":{},\"action_item_cap\":{},\"next_step_cap\":{},\"open_question_cap\":{},\"risk_cap\":{},\"evidence_page\":{TRANSCRIPT_PAGE},\"language_sample_bytes\":{LANGUAGE_SAMPLE_BYTES},\"bytes_per_token\":3,\"context_tokens\":{}}}",
            self.full_budget, self.chunk_budget, self.sources_per_item, self.topic_cap, self.decision_cap, self.action_cap, self.next_step_cap, self.question_cap, self.risk_cap, self.context_tokens
        );
        prefix_bytes(&text, MAX_REQUEST_CONFIG_BYTES).to_string()
    }
}
/// The longest prefix of at most `max` bytes that ends on a character boundary.
pub(crate) fn prefix_bytes(text: &str, max: usize) -> &str {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

// MARK: evidence

#[derive(Clone, Debug, PartialEq)]
pub enum Speaker {
    Root(String),
    Unknown,
    Ambiguous,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub id: String,
    pub ordinal: i64,
    pub start_ms: i64,
    pub end_ms: i64,
    pub speaker: Speaker,
    pub text: String,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Participant {
    pub speaker_id: String,
    pub certainty: &'static str,
    pub origin: String,
    pub known_id: Option<String>,
    pub name: Option<String>,
    pub label: Option<String>,
}
impl Participant {
    fn may_be_named(&self) -> bool {
        matches!(self.certainty, "confirmed" | "recognized" | "local_name" | "local_user")
    }
    fn may_carry_known(&self) -> bool {
        matches!(self.certainty, "confirmed" | "recognized")
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Note {
    pub ordinal: i64,
    pub text: String,
    pub hash: String,
}
/// `MeetingAnalyzer.Snapshot`. The candidate names stay local: they never enter a request.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    pub segments: Vec<Segment>,
    pub participants: Vec<Participant>,
    pub candidates: HashSet<String>,
    pub notes: Vec<Note>,
}

/// `MeetingEvidenceReader.segmentPage`, one window of the pass: ordinals in `first..last`.
pub fn segment_window(db: &Db, meeting: &str, pass: &str, first: i64, last: i64) -> Res<Vec<Segment>> {
    let mut s = db.conn.prepare_cached("SELECT id, end_ms FROM transcript_segments WHERE meeting_id=?1 AND finality='final' AND pass_id=?2 AND ordinal>=?3 AND ordinal<?4")?;
    let ends: HashMap<String, i64> = s.query_map(params![meeting, pass, first, last], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
    let mut out = vec![];
    let mut after = (first > 0).then_some(first - 1);
    loop {
        let rows = meetings::labeled_page(db, meeting, "final", after, TRANSCRIPT_PAGE)?;
        for row in rows.iter().filter(|r| r.ordinal >= first && r.ordinal < last) {
            let Some(end) = ends.get(&row.id) else { continue };
            let speaker = match row.label.as_ref().map(|l| &l.kind) {
                Some(LabelKind::Speaker(root)) => Speaker::Root(root.clone()),
                Some(LabelKind::Overlapping) => Speaker::Ambiguous,
                _ => Speaker::Unknown,
            };
            out.push(Segment { id: row.id.clone(), ordinal: row.ordinal, start_ms: row.start_ms, end_ms: *end, speaker, text: row.text.clone() });
        }
        match rows.last() {
            Some(l) if rows.len() >= TRANSCRIPT_PAGE && l.ordinal + 1 < last => after = Some(l.ordinal),
            _ => return Ok(out),
        }
    }
}

/// `MeetingEvidenceReader.participants`: the research R9 table. A Possible match's candidate name and
/// id never appear here.
pub fn participants(db: &Db, meeting: &str) -> Res<Vec<Participant>> {
    let Some((run, _)) = meetings::accepted_speakers(db, meeting)? else { return Ok(vec![]) };
    let in_room: bool = db.conn.query_row("SELECT in_room FROM diarization_runs WHERE id=?1", [&run], |r| r.get(0))?;
    let profile: Option<(String, String)> = db.conn.query_row("SELECT id, display_name FROM known_speakers WHERE is_local_user=1 LIMIT 1", [], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
    let identities = meetings::identities(db, meeting)?;
    let mut s = db.conn.prepare("SELECT id, source, label_ordinal, display_name FROM meeting_speakers WHERE (run_id=?1 OR (run_id IS NULL AND meeting_id=?2)) AND merged_into IS NULL ORDER BY color_index, run_id IS NULL, label_ordinal LIMIT 512")?;
    let roots: Vec<(String, String, i64, Option<String>)> = s.query_map(params![run, meeting], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?.collect::<Result<_, _>>()?;
    Ok(roots
        .into_iter()
        .map(|(id, source, ordinal, display)| {
            let label = Some(meetings::speaker_label(&source, ordinal, None, in_room));
            let identity = identities.get(&id);
            let origin = identity.map_or("none", |i| i.origin.as_str()).to_string();
            let mut p = Participant { speaker_id: id, certainty: "unknown", origin, known_id: None, name: None, label };
            if source == "local" {
                p.certainty = "local_user";
                p.origin = "none".into();
                if let Some((known, name)) = &profile {
                    (p.known_id, p.name) = (Some(known.clone()), Some(name.clone()));
                }
                return p;
            }
            match identity.map(|i| i.state.as_str()) {
                Some(state @ ("confirmed" | "recognized")) => {
                    p.certainty = if state == "confirmed" { "confirmed" } else { "recognized" };
                    (p.known_id, p.name) = (identity.and_then(|i| i.known_id.clone()), identity.and_then(|i| i.known_name.clone()));
                }
                state => {
                    if display.is_some() {
                        (p.certainty, p.origin, p.name) = ("local_name", "none".into(), display);
                    } else if state == Some("possible") {
                        p.certainty = "possible";
                    }
                }
            }
            p
        })
        .collect())
}

/// `MeetingAnalyzer.loadEvidence`.
pub fn load_evidence(db: &Db, meeting: &str, pass: &str) -> Res<Snapshot> {
    let candidates = meetings::identities(db, meeting)?.into_values().filter(|i| i.state == "possible").filter_map(|i| i.known_name).filter(|n| !n.is_empty()).collect();
    let text = meetings::notes(db, meeting)?.map(|n| n.0).unwrap_or_default();
    let notes = meetings::note_paragraphs(&text).into_iter().map(|(ordinal, text, ..)| Note { ordinal, hash: crate::history::sha256_hex(text.as_bytes()), text }).collect();
    Ok(Snapshot { segments: segment_window(db, meeting, pass, 0, i64::MAX)?, participants: participants(db, meeting)?, candidates, notes })
}

/// The stored ids may be any case; Swift always writes `uuidString`, which is upper.
pub(crate) fn upper(id: &str) -> String {
    id.to_uppercase()
}

/// `EvidenceVersion.compute`. Names are out, identity state is in; the length prefixes make field
/// boundaries unambiguous. `chunk_budget` is fixed, as `AnalysisPolicy()` is in Swift: health must not
/// change a version.
pub fn evidence_version(meeting: &str, pass: &str, snapshot: &Snapshot, language: &str) -> String {
    let mut out: Vec<u8> = vec![];
    let mut line = |fields: &[&str]| {
        for f in fields {
            out.extend_from_slice(format!("{}:", f.len()).as_bytes());
            out.extend_from_slice(f.as_bytes());
            out.push(0x1f);
        }
        out.push(0x0a);
    };
    line(&["evidence_v1"]);
    line(&["meeting", &upper(meeting)]);
    line(&["pass", &upper(pass)]);
    let mut segments: Vec<&Segment> = snapshot.segments.iter().collect();
    segments.sort_by_key(|s| s.ordinal);
    for s in segments {
        let speaker = match &s.speaker {
            Speaker::Root(id) => upper(id),
            Speaker::Unknown => "unknown".into(),
            Speaker::Ambiguous => "ambiguous".into(),
        };
        line(&["segment", &upper(&s.id), &s.ordinal.to_string(), &s.start_ms.to_string(), &s.end_ms.to_string(), &speaker, &s.text]);
    }
    let mut roots: Vec<(String, &Participant)> = snapshot.participants.iter().map(|p| (upper(&p.speaker_id), p)).collect();
    roots.sort_by(|a, b| a.0.cmp(&b.0));
    for (id, p) in roots {
        if p.certainty == "local_user" {
            line(&["local", &id, if p.known_id.is_some() { "1" } else { "0" }]);
        } else {
            line(&["root", &id, p.certainty, &p.origin, &p.known_id.as_deref().map(upper).unwrap_or_else(|| "none".into())]);
        }
    }
    let mut notes: Vec<&Note> = snapshot.notes.iter().collect();
    notes.sort_by_key(|n| n.ordinal);
    for n in notes {
        line(&["note", &n.ordinal.to_string(), &n.text]);
    }
    line(&["language", language, "1"]);
    line(&["versions", "1", "chunking_v2", "16384", "caps_v1"]);
    crate::history::sha256_hex(&out)
}

/// `currentEvidenceVersion`: None without a final transcript.
pub fn current_version(db: &Db, meeting: &str) -> Res<Option<String>> {
    let Some(pass) = meetings::transcription(db, meeting)?.filter(|t| t.state == "final").and_then(|t| t.pass_id) else { return Ok(None) };
    let snapshot = load_evidence(db, meeting, &pass)?;
    let language = resolve_language(db, meeting, &snapshot)?;
    Ok(Some(evidence_version(meeting, &pass, &snapshot, language)))
}

// MARK: chunk plan

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chunk {
    pub index: usize,
    pub first: i64,
    /// Exclusive.
    pub last: i64,
    pub bytes: usize,
    pub oversized: bool,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plan {
    /// Empty for one `full` request.
    pub chunks: Vec<Chunk>,
    /// Synthesis requests per reduce level.
    pub synthesis: Vec<usize>,
}
impl Plan {
    pub fn request_count(&self) -> usize {
        self.chunks.len().max(1) + self.synthesis.iter().sum::<usize>()
    }
}
/// `AnalysisChunkPlanner.plan` (`chunking_v2`).
pub fn plan(segments: &[Segment], notes: &[Note], policy: &Policy) -> Result<Plan, Failure> {
    if notes.len() > MAX_NOTE_PARAGRAPHS || notes.iter().any(|n| n.text.len() > MAX_NOTE_PARAGRAPH_BYTES) {
        return Err(Failure::with("too_long", "notes_too_large"));
    }
    let total: usize = segments.iter().map(|s| s.text.len()).sum();
    if total <= policy.full_budget {
        return Ok(Plan::default());
    }
    // A chunk never holds the whole text, so a staged plan always has partials to combine.
    let budget = policy.chunk_budget.min(total - 1).max(1);
    let (mut chunks, mut start, mut bytes, mut remaining): (Vec<Chunk>, usize, usize, usize) = (vec![], 0, 0, total);
    let retarget = |empty: bool, remaining: usize| {
        let count = (if empty { 2 } else { 1 }).max((remaining + budget - 1) / budget);
        (remaining + count - 1) / count
    };
    let mut target = retarget(true, remaining);
    let mut close = |end: usize, oversized: bool, start: &mut usize, bytes: &mut usize, target: &mut usize| {
        chunks.push(Chunk { index: chunks.len(), first: segments[*start].ordinal, last: segments[end - 1].ordinal + 1, bytes: *bytes, oversized });
        remaining -= *bytes;
        *start = end;
        *bytes = 0;
        *target = retarget(false, remaining);
    };
    for (i, s) in segments.iter().enumerate() {
        let size = s.text.len();
        if size > budget {
            if i > start {
                close(i, false, &mut start, &mut bytes, &mut target);
            }
            bytes = size;
            close(i + 1, true, &mut start, &mut bytes, &mut target);
            continue;
        }
        if bytes + size > budget {
            close(i, false, &mut start, &mut bytes, &mut target);
        }
        bytes += size;
        if bytes >= target {
            close(i + 1, false, &mut start, &mut bytes, &mut target);
        }
    }
    if start < segments.len() {
        close(segments.len(), false, &mut start, &mut bytes, &mut target);
    }
    if chunks.len() > MAX_CHUNKS {
        return Err(Failure::with("too_long", "too_many_chunks"));
    }
    let (mut synthesis, mut partials) = (vec![], chunks.len());
    while partials > 1 {
        partials = partials.div_ceil(PARTIALS_PER_SYNTHESIS);
        synthesis.push(partials);
    }
    if synthesis.len() > REDUCE_DEPTH {
        return Err(Failure::with("too_long", "reduce_too_deep"));
    }
    Ok(Plan { chunks, synthesis })
}

// MARK: language

/// `LanguagePolicy.recordedLanguage`: a single `lang_<sk|en>_prompt_v<1|2>` tag in the pass identity.
pub fn recorded_language(pipeline: Option<&str>) -> Option<&'static str> {
    let tags: Vec<&str> = pipeline.unwrap_or_default().split('+').filter(|t| t.starts_with("lang_")).collect();
    let [tag] = tags[..] else { return None };
    let parts: Vec<&str> = tag.split('_').collect();
    match parts[..] {
        ["lang", "sk", "prompt", "v1" | "v2"] => Some("sk"),
        ["lang", "en", "prompt", "v1" | "v2"] => Some("en"),
        _ => None,
    }
}
/// `LanguagePolicy.resolve`.
pub fn resolve_language(db: &Db, meeting: &str, snapshot: &Snapshot) -> Res<&'static str> {
    let pipeline: Option<String> = db.conn.query_row("SELECT pipeline_version FROM meeting_transcriptions WHERE meeting_id=?1", [meeting], |r| r.get(0)).optional()?.flatten();
    if let Some(recorded) = recorded_language(pipeline.as_deref()) {
        return Ok(recorded);
    }
    let chosen: Option<String> = db.conn.query_row("SELECT language FROM meetings WHERE id=?1", [meeting], |r| r.get(0)).optional()?.flatten();
    Ok(match chosen.as_deref() {
        Some("slovak") => "sk",
        Some("english") => "en",
        _ => detect_language(&snapshot.segments),
    })
}
// Words that appear in only one of the two languages. Words both share, such as "a", "to", "no" and
// "do", say nothing and are left out.
const ENGLISH: &[&str] = &[
    "the", "and", "of", "is", "are", "was", "were", "with", "that", "this", "these", "those", "have", "has", "had", "will", "would", "should", "could", "can", "not", "for", "from", "they", "their", "there", "what", "when", "which", "who", "how", "we", "you", "our", "your", "it", "be", "been", "but", "if", "at", "an", "in", "or", "as", "about", "next", "need", "needs", "want", "think", "know", "just", "because", "after", "before", "all",
];
const SLOVAK: &[&str] = &[
    "je", "som", "sme", "ste", "sú", "aby", "ale", "aj", "ak", "že", "sa", "si", "ako", "tak", "takže", "už", "ešte", "len", "veľmi", "tu", "tam", "kde", "kedy", "čo", "kto", "prečo", "lebo", "pretože", "keď", "potom", "teraz", "dnes", "včera", "treba", "bude", "budeme", "budú", "bol", "bola", "bolo", "boli", "byť", "mám", "máme", "máte", "majú", "môže", "môžeme", "musíme", "chceme", "nie", "pre", "pri", "alebo", "ktorý", "ktorá", "ktoré", "toto", "tento", "táto", "teda", "tiež", "všetko",
];
/// (English hits, Slovak hits, letters that aren't Latin, letters).
fn tally(text: &str) -> (usize, usize, usize, usize) {
    let (mut english, mut slovak) = (0, 0);
    let lower = text.to_lowercase();
    for word in lower.split(|c: char| !c.is_alphabetic()).filter(|w| !w.is_empty()) {
        if ENGLISH.contains(&word) {
            english += 1;
        } else if SLOVAK.contains(&word) || word.chars().any(|c| "áäčďéíĺľňóôŕšťúýž".contains(c)) {
            slovak += 1;
        }
    }
    let letters = lower.chars().filter(|c| c.is_alphabetic()).count();
    let foreign = lower.chars().filter(|c| c.is_alphabetic() && (*c as u32) > 0x24F).count();
    (english, slovak, foreign, letters)
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dominant {
    English,
    Slovak,
    /// Another script, which Swift's recognizer has no English or Slovak hypothesis for.
    Other,
    /// Latin text without one telling word, such as "OK." It counts for neither side.
    NoSignal,
}
/// `SupportedTextLanguage.dominant`.
// ponytail: function words and Slovak diacritics in place of NLLanguageRecognizer, which only Apple has.
// Ceiling: other Latin languages (Czech reads as Slovak, Spanish often as neither) and text that is mostly
// names or jargon. Replace with a statistical model if a real meeting resolves wrongly.
pub fn dominant(text: &str) -> Dominant {
    let (english, slovak, foreign, letters) = tally(text);
    if letters > 0 && foreign * 2 > letters {
        return Dominant::Other;
    }
    match english.cmp(&slovak) {
        _ if english + slovak == 0 => Dominant::NoSignal,
        std::cmp::Ordering::Less => Dominant::Slovak,
        std::cmp::Ordering::Greater => Dominant::English,
        std::cmp::Ordering::Equal => Dominant::NoSignal,
    }
}
/// `SupportedTextLanguage.confident`: only substantial prose that is plainly one language decides.
pub fn confident(text: &str, min_letters: usize, min_words: usize) -> Option<Dominant> {
    let words: Vec<&str> = text.split(|c: char| !c.is_alphabetic()).filter(|w| !w.is_empty()).collect();
    if words.len() < min_words || words.iter().map(|w| w.chars().count()).sum::<usize>() < min_letters {
        return None;
    }
    let (english, slovak, ..) = tally(text);
    // Swift asks for a 0.99 share; with word counts that means none of the other language at all.
    match (english, slovak) {
        (e, 0) if e >= 5 => Some(Dominant::English),
        (0, s) if s >= 5 => Some(Dominant::Slovak),
        _ => None,
    }
}
/// `LanguagePolicy.detect`.
pub fn detect_language(segments: &[Segment]) -> &'static str {
    let (mut english, mut slovak, mut other) = (0usize, 0usize, 0usize);
    for text in sampled_texts(segments, LANGUAGE_SAMPLE_BYTES) {
        let count = text.chars().count();
        match dominant(text) {
            Dominant::English => english += count,
            Dominant::Slovak => slovak += count,
            Dominant::Other => other += count,
            Dominant::NoSignal => {}
        }
    }
    let total = english + slovak + other;
    let top = english.max(slovak);
    if total == 0 || other >= top {
        return "mixed";
    }
    if top as f64 / total as f64 >= 0.8 {
        return if english >= slovak { "en" } else { "sk" };
    }
    if english >= 2 * slovak { "en" } else { "mixed" }
}
/// `LanguagePolicy.sampledTexts`: all of it within the budget, else up to 64 evenly spaced prefixes.
fn sampled_texts(segments: &[Segment], budget: usize) -> Vec<&str> {
    if segments.is_empty() {
        return vec![];
    }
    let mut ordered: Vec<&Segment> = segments.iter().collect();
    ordered.sort_by_key(|s| s.ordinal);
    if ordered.iter().map(|s| s.text.len()).sum::<usize>() <= budget {
        return ordered.iter().map(|s| s.text.as_str()).collect();
    }
    let positions = ordered.len().min(64).min(budget);
    let share = budget / positions;
    (0..positions).map(|i| prefix_bytes(&ordered[i * ordered.len() / positions].text, share)).filter(|t| !t.is_empty()).collect()
}

// MARK: request

/// Everything a request carries for its whole run.
pub struct RequestBase<'a> {
    pub meeting: &'a str,
    pub run: &'a str,
    pub title: &'a str,
    pub started_at: &'a str,
    pub duration_ms: i64,
    pub time_zone: &'a str,
    pub language: &'a str,
    pub participants: &'a [Participant],
}
/// `AnalysisRequest`, with the optional keys absent as Swift encodes them.
pub fn request_json(base: &RequestBase, stage: &str, chunk: Option<(usize, usize)>, segments: Option<&[Segment]>, notes: Option<&[Note]>, partials: Option<&[Value]>) -> Value {
    let participants: Vec<Value> = base
        .participants
        .iter()
        .map(|p| {
            let mut o = Map::new();
            o.insert("speaker_id".into(), upper(&p.speaker_id).into());
            o.insert("certainty".into(), p.certainty.into());
            o.insert("origin".into(), prefix_bytes(&p.origin, 32).into());
            if let Some(known) = p.known_id.as_deref().filter(|_| p.may_carry_known()) {
                o.insert("known_speaker_id".into(), upper(known).into());
            }
            if let Some(name) = p.name.as_deref().filter(|_| p.may_be_named()) {
                o.insert("name".into(), prefix_bytes(name, 80).into());
            }
            if let Some(label) = &p.label {
                o.insert("label".into(), prefix_bytes(label, 80).into());
            }
            Value::Object(o)
        })
        .collect();
    let mut body = json!({
        "schema_version": 1,
        "request_id": meetings::new_id(),
        "run_id": upper(base.run),
        "priority": "background",
        "stage": stage,
        "meeting": {
            "id": upper(base.meeting),
            "title": prefix_bytes(base.title, 256),
            "started_at": base.started_at,
            "duration_ms": base.duration_ms,
            "time_zone": prefix_bytes(base.time_zone, 64),
            "language_policy": {"output": base.language, "preserve_terms": true},
        },
        "participants": participants,
    });
    if let Some((index, count)) = chunk {
        body["chunk"] = json!({"index": index, "count": count});
    }
    if let Some(segments) = segments {
        body["segments"] = segments
            .iter()
            .map(|s| {
                let speaker = match &s.speaker {
                    Speaker::Root(id) => Value::String(upper(id)),
                    _ => Value::Null,
                };
                json!({"id": upper(&s.id), "start_ms": s.start_ms, "end_ms": s.end_ms, "speaker_id": speaker, "text": s.text})
            })
            .collect();
    }
    if let Some(notes) = notes {
        body["notes"] = notes.iter().map(|n| json!({"id": format!("note:{}", n.ordinal), "text": n.text})).collect();
    }
    if let Some(partials) = partials {
        body["partials"] = Value::Array(partials.to_vec());
    }
    body
}
