//! `AnalysisEvent`, `AnalysisResult` and `AnalysisHealth` decoding. Strict as Swift's is: unknown keys,
//! wrong types and closed enums all fail, and the caps of an unlowered policy apply.
use super::{Failure, Policy};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashSet};

pub const MAX_LINE_BYTES: usize = 98_304;
pub const MAX_STREAM_BYTES: usize = 524_288;
pub const MAX_ERROR_BODY_BYTES: usize = 8192;
pub const MAX_REQUEST_BODY_BYTES: usize = 262_144;
const MAX_IDENTITY_BYTES: usize = 128;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WireSource {
    pub note: bool,
    pub id: String,
}
#[derive(Clone, Debug, PartialEq)]
pub struct WireSummary {
    pub text: String,
    pub sources: Vec<WireSource>,
    pub whole_meeting: bool,
}
#[derive(Clone, Debug, PartialEq)]
pub struct WireTopic {
    pub title: String,
    pub summary: String,
    pub bullets: Vec<String>,
    pub sources: Vec<WireSource>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct WireItem {
    pub text: String,
    pub evidence_class: Option<String>,
    pub sources: Vec<WireSource>,
}
#[derive(Clone, Debug, PartialEq)]
pub enum WireOwner {
    Participant(String),
    Mentioned(String),
    None,
}
#[derive(Clone, Debug, PartialEq)]
pub struct WireDue {
    pub state: String,
    pub date: Option<String>,
    pub original: Option<String>,
    pub source: Option<WireSource>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct WireAction {
    pub text: String,
    pub owner: WireOwner,
    pub ownership_state: String,
    pub due: WireDue,
    pub sources: Vec<WireSource>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct AnalysisResult {
    /// As it arrived: a partial goes back to the server inside a synthesis request unchanged.
    pub raw: Value,
    pub meeting_id: String,
    pub language: String,
    pub summary: WireSummary,
    pub topics: Vec<WireTopic>,
    pub decisions: Vec<WireItem>,
    pub action_items: Vec<WireAction>,
    pub next_steps: Vec<WireItem>,
    pub open_questions: Vec<WireItem>,
    pub risks: Vec<WireItem>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Payload {
    pub run_id: Option<String>,
    pub server_version: Option<String>,
    pub backend_kind: Option<String>,
    pub backend_model: Option<String>,
    pub pipeline_version: Option<String>,
    pub analysis: AnalysisResult,
}
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Accepted,
    Progress { chars: i64 },
    Result(Box<Payload>),
    Error(String),
}

fn malformed() -> Failure {
    Failure::new("malformed_response")
}
pub(crate) fn is_uuid(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() == 36 && b.iter().enumerate().all(|(i, c)| if matches!(i, 8 | 13 | 18 | 23) { *c == b'-' } else { c.is_ascii_hexdigit() })
}
fn object<'a>(value: Option<&'a Value>, allowed: &[&str]) -> Result<&'a Map<String, Value>, Failure> {
    let object = value.and_then(Value::as_object).ok_or_else(malformed)?;
    if object.keys().any(|k| !allowed.contains(&k.as_str())) {
        return Err(malformed());
    }
    Ok(object)
}
fn string<'a>(o: &'a Map<String, Value>, key: &str) -> Result<&'a str, Failure> {
    o.get(key).and_then(Value::as_str).ok_or_else(malformed)
}
fn bounded(o: &Map<String, Value>, key: &str, min: usize, max: usize) -> Result<String, Failure> {
    let value = string(o, key)?;
    if value.len() < min || value.len() > max {
        return Err(malformed());
    }
    Ok(value.to_string())
}
fn array<T>(o: &Map<String, Value>, key: &str, cap: usize, decode: impl Fn(&Value) -> Result<T, Failure>) -> Result<Vec<T>, Failure> {
    let list = o.get(key).and_then(Value::as_array).ok_or_else(malformed)?;
    if list.len() > cap {
        return Err(Failure::new("over_cap"));
    }
    list.iter().map(decode).collect()
}
fn source(value: &Value) -> Result<WireSource, Failure> {
    let o = object(Some(value), &["kind", "id"])?;
    let id = string(o, "id")?.to_string();
    match string(o, "kind")? {
        "segment" if is_uuid(&id) => Ok(WireSource { note: false, id }),
        "note" if id.strip_prefix("note:").is_some_and(|n| n.parse::<i64>().is_ok()) => Ok(WireSource { note: true, id }),
        _ => Err(malformed()),
    }
}
fn sources(o: &Map<String, Value>, min: usize) -> Result<Vec<WireSource>, Failure> {
    let list = o.get("sources").and_then(Value::as_array).ok_or_else(malformed)?;
    if list.len() < min || list.len() > 10 {
        return Err(malformed());
    }
    let refs: Vec<WireSource> = list.iter().map(source).collect::<Result<_, _>>()?;
    if refs.iter().map(|r| (r.note, r.id.as_str())).collect::<HashSet<_>>().len() != refs.len() {
        return Err(malformed());
    }
    Ok(refs)
}
fn summary(value: Option<&Value>) -> Result<WireSummary, Failure> {
    let o = object(value, &["text", "sources", "whole_meeting"])?;
    Ok(WireSummary { text: bounded(o, "text", 1, 4000)?, sources: sources(o, 0)?, whole_meeting: o.get("whole_meeting").and_then(Value::as_bool).ok_or_else(malformed)? })
}
fn topic(value: &Value) -> Result<WireTopic, Failure> {
    let o = object(Some(value), &["title", "summary", "bullets", "sources"])?;
    let title = bounded(o, "title", 1, 200)?;
    let summary = bounded(o, "summary", 0, 2000)?;
    let list = o.get("bullets").and_then(Value::as_array).filter(|b| b.len() <= 12).ok_or_else(malformed)?;
    let bullets = list.iter().map(|b| b.as_str().filter(|t| t.len() <= 500).map(String::from).ok_or_else(malformed)).collect::<Result<_, _>>()?;
    Ok(WireTopic { title, summary, bullets, sources: sources(o, 0)? })
}
fn item(value: &Value, evidence_allowed: bool) -> Result<WireItem, Failure> {
    let allowed: &[&str] = if evidence_allowed { &["text", "sources", "evidence_class"] } else { &["text", "sources"] };
    let o = object(Some(value), allowed)?;
    let text = bounded(o, "text", 1, 1000)?;
    let evidence_class = match o.get("evidence_class") {
        None => None,
        Some(raw) => Some(raw.as_str().filter(|c| matches!(*c, "explicit" | "implied")).ok_or_else(malformed)?.to_string()),
    };
    Ok(WireItem { text, evidence_class, sources: sources(o, 1)? })
}
fn owner(value: Option<&Value>) -> Result<WireOwner, Failure> {
    let o = object(value, &["kind", "speaker_id", "name"])?;
    let (speaker, name) = (o.get("speaker_id"), o.get("name"));
    match string(o, "kind")? {
        "participant" if name.is_none() => speaker.and_then(Value::as_str).filter(|s| is_uuid(s)).map(|s| WireOwner::Participant(s.to_string())).ok_or_else(malformed),
        "mentioned" if speaker.is_none() => Ok(WireOwner::Mentioned(bounded(o, "name", 1, 80)?)),
        "none" if speaker.is_none() && name.is_none() => Ok(WireOwner::None),
        _ => Err(malformed()),
    }
}
fn date_shape(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() == 10 && b.iter().enumerate().all(|(i, c)| if matches!(i, 4 | 7) { *c == b'-' } else { c.is_ascii_digit() })
}
fn due(value: Option<&Value>) -> Result<WireDue, Failure> {
    let o = object(value, &["state", "date", "original", "source"])?;
    let state = string(o, "state")?.to_string();
    let date = o.get("date").and_then(Value::as_str).map(String::from);
    if date.as_deref().is_some_and(|d| !date_shape(d)) {
        return Err(malformed());
    }
    let original = o.get("original").and_then(Value::as_str).map(String::from);
    if original.as_deref().is_some_and(|t| t.is_empty() || t.len() > 80) {
        return Err(malformed());
    }
    let source = o.get("source").map(source).transpose()?;
    let fits = match state.as_str() {
        "explicit_absolute" | "explicit_relative_resolved" => date.is_some() && original.is_some() && source.is_some(),
        "unresolved" => date.is_none() && original.is_some() && source.is_some(),
        "absent" => date.is_none() && original.is_none() && source.is_none(),
        _ => false,
    };
    if !fits {
        return Err(malformed());
    }
    Ok(WireDue { state, date, original, source })
}
fn action(value: &Value) -> Result<WireAction, Failure> {
    let o = object(Some(value), &["text", "owner", "ownership_state", "due", "sources"])?;
    let text = bounded(o, "text", 1, 1000)?;
    let ownership_state = string(o, "ownership_state")?;
    if !matches!(ownership_state, "explicit" | "supported" | "unresolved") {
        return Err(malformed());
    }
    Ok(WireAction { text, owner: owner(o.get("owner"))?, ownership_state: ownership_state.to_string(), due: due(o.get("due"))?, sources: sources(o, 1)? })
}
/// `AnalysisResult.decode`. A `chunk` stage's partial gets half the caps.
pub fn decode_result(value: Option<&Value>, partial: bool) -> Result<AnalysisResult, Failure> {
    let o = object(value, &["schema_version", "meeting_id", "partial", "language", "summary", "topics", "decisions", "action_items", "next_steps", "open_questions", "risks"])?;
    if o.get("schema_version").and_then(Value::as_i64).ok_or_else(malformed)? != 1 {
        return Err(Failure::new("unsupported_version"));
    }
    let meeting_id = string(o, "meeting_id")?;
    if !is_uuid(meeting_id) || o.get("partial").and_then(Value::as_bool).is_none() {
        return Err(malformed());
    }
    let language = string(o, "language")?;
    if !matches!(language, "sk" | "en" | "mixed") {
        return Err(malformed());
    }
    let p = Policy::default();
    let cap = |full: usize| if partial { full / 2 } else { full };
    let summary = summary(o.get("summary"))?;
    Ok(AnalysisResult {
        meeting_id: meeting_id.to_string(),
        language: language.to_string(),
        summary,
        topics: array(o, "topics", cap(p.topic_cap), topic)?,
        decisions: array(o, "decisions", cap(p.decision_cap), |v| item(v, true))?,
        action_items: array(o, "action_items", cap(p.action_cap), action)?,
        next_steps: array(o, "next_steps", cap(p.next_step_cap), |v| item(v, false))?,
        open_questions: array(o, "open_questions", cap(p.question_cap), |v| item(v, true))?,
        risks: array(o, "risks", cap(p.risk_cap), |v| item(v, true))?,
        raw: value.cloned().unwrap_or(Value::Null),
    })
}
/// `AnalysisEvent.decode`.
pub fn decode_event(line: &[u8]) -> Result<Event, Failure> {
    if line.len() > MAX_LINE_BYTES {
        return Err(Failure::new("oversized_response"));
    }
    let object: Value = serde_json::from_slice(line).map_err(|_| malformed())?;
    let kind = object.get("type").and_then(Value::as_str).ok_or_else(malformed)?;
    if object.get("schema_version").and_then(Value::as_i64) != Some(1) {
        return Err(Failure::new("unsupported_version"));
    }
    match kind {
        "accepted" => Ok(Event::Accepted),
        "progress" => Ok(Event::Progress { chars: object.get("chars").and_then(Value::as_i64).unwrap_or(0) }),
        "result" => {
            let stage = object.get("stage").and_then(Value::as_str).ok_or_else(malformed)?;
            if !matches!(stage, "full" | "chunk" | "synthesis") {
                return Err(malformed());
            }
            let analysis = decode_result(object.get("analysis"), stage == "chunk")?;
            let text = |parent: &str, key: &str| object.get(parent).and_then(|p| p.get(key)).and_then(Value::as_str);
            let backend = text("backend", "kind").zip(text("backend", "model"));
            let server = text("server", "name").zip(text("server", "version")).filter(|(n, v)| n.len() <= MAX_IDENTITY_BYTES && v.len() <= MAX_IDENTITY_BYTES);
            Ok(Event::Result(Box::new(Payload {
                run_id: object.get("run_id").and_then(Value::as_str).map(String::from),
                server_version: server.map(|s| s.1.to_string()),
                backend_kind: backend.map(|b| b.0.to_string()),
                backend_model: backend.map(|b| b.1.to_string()),
                pipeline_version: object.get("pipeline_version").and_then(Value::as_str).map(String::from),
                analysis,
            })))
        }
        "error" => Ok(Event::Error(object.get("code").and_then(Value::as_str).ok_or_else(malformed)?.to_string())),
        _ => Err(malformed()),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Limits {
    pub input_bytes: usize,
    pub context_tokens: i64,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caps {
    pub sources_per_item: usize,
    pub topics: usize,
    pub decisions: usize,
    pub action_items: usize,
    pub next_steps: usize,
    pub open_questions: usize,
    pub risks: usize,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Health {
    pub service: Option<String>,
    pub server_version: Option<String>,
    pub backend_state: Option<String>,
    pub backend_kind: Option<String>,
    pub backend_model: Option<String>,
    pub prompt_versions: BTreeMap<String, i64>,
    pub result_schema_version: Option<i64>,
    pub limits: Option<Limits>,
    pub caps: Option<Caps>,
}
/// `AnalysisHealth.decode`. None when the body isn't a JSON object.
pub fn decode_health(body: &[u8]) -> Option<Health> {
    let o: Value = serde_json::from_slice(body).ok()?;
    o.as_object()?;
    let text = |parent: &str, key: &str| o.get(parent).and_then(|p| p.get(key)).and_then(Value::as_str).map(String::from);
    let int = |parent: &str, key: &str| o.get(parent).and_then(|p| p.get(key)).and_then(Value::as_i64);
    let size = |parent: &str, key: &str| int(parent, key).map(|v| v.max(0) as usize);
    let limits = (|| {
        int("limits", "output_bytes")?;
        int("limits", "concurrency")?;
        Some(Limits { input_bytes: size("limits", "input_bytes")?, context_tokens: int("limits", "context_tokens")? })
    })();
    let caps = (|| Some(Caps { sources_per_item: size("caps", "sources_per_item")?, topics: size("caps", "topics")?, decisions: size("caps", "decisions")?, action_items: size("caps", "action_items")?, next_steps: size("caps", "next_steps")?, open_questions: size("caps", "open_questions")?, risks: size("caps", "risks")? }))();
    let backend_state = text("backend", "state");
    Some(Health {
        service: o.get("service").and_then(Value::as_str).map(String::from),
        server_version: text("server", "version"),
        backend_kind: backend_state.as_ref().and_then(|_| text("backend", "kind")),
        backend_model: backend_state.as_ref().and_then(|_| text("backend", "model")),
        backend_state,
        prompt_versions: o.get("prompt_versions").and_then(Value::as_object).map(|m| m.iter().filter_map(|(k, v)| Some((k.clone(), v.as_i64()?))).collect()).unwrap_or_default(),
        result_schema_version: o.get("result_schema_version").and_then(Value::as_i64),
        limits,
        caps,
    })
}
