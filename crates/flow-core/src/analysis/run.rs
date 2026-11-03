//! `MeetingAnalyzer`, `AnalysisClient`, `RemoteAnalysisTransport`, `RoutingAnalysisTransport` and the
//! endpoint choice from `AppServices`. Everything here blocks; call it off the UI thread.
use super::store::{self, Identity, RunRow, StoreError};
use super::validate::{self, Evidence};
use super::wire::{self, Event, Health, Payload};
use super::{Dominant, Failure, Policy, RequestBase, Snapshot, UNAVAILABLE_MESSAGE, category_for_code, category_for_status, confident, current_version, load_evidence, plan, request_json, resolve_language, upper};
use crate::db::Db;
use crate::history::{CancellableConnector, now_ms, sha256_hex};
use crate::meetings::{self, MeetingError};
use crate::prefs::Prefs;
use crate::remote::channel::{ChannelError, ServerMessage};
use crate::remote::pool::{Pool, Role};
use crate::settings::{self, Connection, Path, RewriteSettings, Service};
use serde_json::Value;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const WAITING_DETAIL: &str = "waiting_for_server";
const MAX_PART_BYTES: usize = 49_152;
const MAX_ESCAPED_PART_BYTES: usize = 64_000;

/// `RewriteEndpoint`. Not `Debug`: the headers can hold the summary server's key.
#[derive(Clone)]
pub struct Endpoint {
    pub origin: String,
    pub headers: Vec<(&'static str, String)>,
    pub via_channel: bool,
    pub channel_fallback: bool,
}
impl Endpoint {
    fn inference_path(&self) -> &'static str {
        if self.via_channel {
            "server"
        } else if self.headers.is_empty() {
            "local"
        } else {
            "custom"
        }
    }
    /// `summaryBackendKey`: origin, primary URL and model, never the key.
    fn backend_key(&self) -> String {
        let header = |name: &str| self.headers.iter().find(|h| h.0 == name).map_or("", |h| h.1.as_str());
        format!("{}|{}|{}", self.origin, header("X-LocalFlow-Primary-URL"), header("X-LocalFlow-Primary-Model"))
    }
}
/// What `summarySettings`, `summaryEndpoint` and `localSummaryEndpoint` answer now. Built on the UI
/// thread, where the preferences and the Keychain are.
#[derive(Clone)]
pub struct Route {
    pub settings: RewriteSettings,
    pub endpoint: Option<Endpoint>,
    pub local: Option<Endpoint>,
}
pub fn route(p: &Prefs, credential: impl Fn(&str) -> bool, summary_key: Option<&str>) -> Route {
    let routing = settings::routing(p);
    let server = settings::remote_server_url(p);
    let serves = routing.served(Service::Summaries) && !server.is_empty();
    let settings = if serves {
        RewriteSettings::routed_to_remote(server)
    } else if routing.switch_applies() {
        RewriteSettings { origin: settings::loopback_endpoint(), ..Default::default() }
    } else {
        RewriteSettings::capture(p, credential)
    };
    let endpoint = settings.valid().then(|| {
        let mut endpoint = Endpoint { origin: settings.origin.clone(), headers: vec![], via_channel: settings.via_channel, channel_fallback: false };
        if !settings.via_channel {
            if !routing.switch_applies() {
                endpoint.headers = settings::summary_headers(p, summary_key, false);
            } else if routing.path(Service::Summaries) == Path::Custom {
                endpoint.headers = settings::summary_headers(p, summary_key, true);
                endpoint.channel_fallback = routing.consent_current && routing.offered(Service::Summaries);
            }
        }
        endpoint
    });
    let local = routing.served(Service::Summaries).then(|| Endpoint { origin: settings::loopback_endpoint(), headers: vec![], via_channel: false, channel_fallback: false });
    Route { settings, endpoint, local }
}

/// `AnalysisPartialCache`: chunk results that passed, so a retry resumes where the run failed. Holds one
/// meeting, evidence version and backend at a time.
// ponytail: memory only, lost on relaunch, as Swift's. Persist it if retries across launches matter.
#[derive(Default)]
pub struct PartialCache {
    scope: Option<(String, String, String)>,
    results: HashMap<(i64, i64), wire::AnalysisResult>,
}
impl PartialCache {
    pub fn forget(&mut self, meeting: &str) {
        if self.scope.as_ref().is_some_and(|s| s.0 == meeting) {
            *self = PartialCache::default();
        }
    }
}
/// `secret` answers with the rewrite credential stored for an origin. `wait_unit` scales the delays
/// between attempts and `deadline_unit` the run and request limits; both are a second outside tests.
pub struct Deps {
    pub database: PathBuf,
    pub secret: Arc<dyn Fn(&str) -> Option<String> + Send + Sync>,
    pub pool: Option<Arc<Pool>>,
    pub wait_unit: Duration,
    pub deadline_unit: Duration,
    pub partials: Mutex<PartialCache>,
}

/// How a run stopped short of adopting.
#[derive(Debug)]
pub enum Stop {
    Cancelled,
    Failure(Failure),
    Late,
    Internal { full: bool },
}
impl From<Failure> for Stop {
    fn from(f: Failure) -> Self {
        Stop::Failure(f)
    }
}
impl From<rusqlite::Error> for Stop {
    fn from(e: rusqlite::Error) -> Self {
        Stop::Internal { full: matches!(&e, rusqlite::Error::SqliteFailure(f, _) if f.code == rusqlite::ErrorCode::DiskFull) }
    }
}
impl From<MeetingError> for Stop {
    fn from(e: MeetingError) -> Self {
        match e {
            MeetingError::Sql(e) => e.into(),
            _ => Stop::Internal { full: false },
        }
    }
}
impl From<StoreError> for Stop {
    fn from(e: StoreError) -> Self {
        match e {
            StoreError::Late => Stop::Late,
            StoreError::Sql(e) => e.into(),
            _ => Stop::Internal { full: false },
        }
    }
}

pub enum Item {
    FellBack,
    FirstByte,
    Event(Event),
    Completed { request_bytes: usize, response_bytes: usize },
}
type Sink<'a> = &'a mut dyn FnMut(Item) -> Result<(), Stop>;

// MARK: HTTP

fn http_agent(timeout: Duration, cancel: &Arc<AtomicBool>) -> ureq::Agent {
    // No redirects: a credential never follows one.
    let config = ureq::Agent::config_builder().timeout_global(Some(timeout)).max_redirects(0).http_status_as_error(false).proxy(None).build();
    let connector = CancellableConnector { inner: Default::default(), cancel: cancel.clone() };
    ureq::Agent::with_parts(config, connector, ureq::unversioned::resolver::DefaultResolver::default())
}
fn transport_failure(e: ureq::Error, cancel: &AtomicBool) -> Stop {
    if cancel.load(Ordering::SeqCst) {
        return Stop::Cancelled;
    }
    Stop::Failure(match e {
        ureq::Error::Timeout(_) => Failure::new("timeout"),
        ureq::Error::HostNotFound | ureq::Error::ConnectionFailed => Failure::new("server_unreachable"),
        ureq::Error::Io(e) if e.kind() == std::io::ErrorKind::TimedOut => Failure::new("timeout"),
        ureq::Error::Io(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => Failure::new("server_unreachable"),
        other if other.to_string().to_lowercase().contains("tls") => Failure::with("server_unreachable", "tls_failure"),
        _ => Failure::with("server_unreachable", "transport_error"),
    })
}
fn http_analyze(deps: &Deps, endpoint: &Endpoint, body: &[u8], timeout: Duration, cancel: &Arc<AtomicBool>, sink: Sink) -> Result<(), Stop> {
    let secret = (deps.secret)(&endpoint.origin);
    // `localModel?.ready(for:)`: flowd loads a model it unloaded; only this Mac's own flowd needs it.
    crate::local_model::wait_until_ready(&endpoint.origin, secret.as_deref(), timeout, cancel, &mut || {});
    if cancel.load(Ordering::SeqCst) {
        return Err(Stop::Cancelled);
    }
    let mut post = http_agent(timeout, cancel).post(format!("{}/v1/analysis/meeting", endpoint.origin.trim_end_matches('/'))).header("Content-Type", "application/json").header("Accept", "application/x-ndjson");
    if let Some(secret) = &secret {
        post = post.header("Authorization", format!("Bearer {secret}"));
    }
    for (name, value) in &endpoint.headers {
        post = post.header(*name, value);
    }
    let mut response = post.send(body).map_err(|e| transport_failure(e, cancel))?;
    sink(Item::FirstByte)?;
    let status = response.status().as_u16();
    if status != 200 {
        let raw = response.body_mut().with_config().limit(wire::MAX_ERROR_BODY_BYTES as u64).read_to_vec().unwrap_or_default();
        let parsed: Option<Value> = serde_json::from_slice(&raw).ok();
        let code = parsed.as_ref().and_then(|v| v.get("error")?.get("code")?.as_str());
        let detail = code.or((status == 429).then_some("server_busy"));
        return Err(Stop::Failure(Failure { category: category_for_status(status, code), detail: detail.map(String::from) }));
    }
    let mut total = 0;
    let reader = BufReader::new(response.into_body().into_reader().take(wire::MAX_STREAM_BYTES as u64 + 1));
    for line in reader.split(b'\n') {
        let line = line.map_err(|e| {
            if cancel.load(Ordering::SeqCst) {
                Stop::Cancelled
            } else if e.kind() == std::io::ErrorKind::TimedOut {
                Stop::Failure(Failure::new("timeout"))
            } else {
                Stop::Failure(Failure::with("server_unreachable", "transport_error"))
            }
        })?;
        total += line.len() + 1;
        if total > wire::MAX_STREAM_BYTES + 1 {
            return Err(Failure::with("oversized_response", "stream_bytes").into());
        }
        if line.len() >= wire::MAX_LINE_BYTES {
            return Err(Failure::new("oversized_response").into());
        }
        if !line.is_empty() {
            sink(Item::Event(wire::decode_event(&line)?))?;
        }
    }
    sink(Item::Completed { request_bytes: body.len(), response_bytes: total })
}
/// `AnalysisClient.health`.
fn http_health(deps: &Deps, endpoint: &Endpoint) -> Result<Health, Stop> {
    let cancel = Arc::new(AtomicBool::new(false));
    let mut get = http_agent(Duration::from_secs(10), &cancel).get(format!("{}/v1/analysis/health", endpoint.origin.trim_end_matches('/'))).header("Accept", "application/json");
    if let Some(secret) = (deps.secret)(&endpoint.origin) {
        get = get.header("Authorization", format!("Bearer {secret}"));
    }
    for (name, value) in &endpoint.headers {
        get = get.header(*name, value);
    }
    let mut response = get.call().map_err(|e| transport_failure(e, &cancel))?;
    let status = response.status().as_u16();
    if status == 404 {
        return Err(Failure::with("server_unavailable", UNAVAILABLE_MESSAGE).into());
    }
    if status != 200 {
        return Err(Failure::new(category_for_status(status, None)).into());
    }
    let raw = response.body_mut().with_config().limit(wire::MAX_ERROR_BODY_BYTES as u64 + 1).read_to_vec().map_err(|_| Failure::new("oversized_response"))?;
    if raw.len() > wire::MAX_ERROR_BODY_BYTES {
        return Err(Failure::new("oversized_response").into());
    }
    let health = wire::decode_health(&raw).filter(|h| h.service.as_deref() == Some("localflow-analysis")).ok_or_else(|| Failure::with("server_unavailable", UNAVAILABLE_MESSAGE))?;
    if health.result_schema_version.is_some_and(|v| v != 1) {
        return Err(Failure::new("unsupported_version").into());
    }
    Ok(health)
}

// MARK: channel

/// `RemoteAnalysisTransport.fragments`.
pub fn fragments(body: &str) -> Vec<&str> {
    let mut parts = vec![];
    let (mut start, mut raw, mut escaped) = (0, 0, 0);
    for (at, c) in body.char_indices() {
        let bytes = c.len_utf8();
        let cost = match c {
            '"' | '\\' | '/' => 2,
            c if (c as u32) < 0x20 => 6,
            _ => bytes,
        };
        if raw + bytes > MAX_PART_BYTES || escaped + cost > MAX_ESCAPED_PART_BYTES {
            parts.push(&body[start..at]);
            (start, raw, escaped) = (at, 0, 0);
        }
        raw += bytes;
        escaped += cost;
    }
    parts.push(&body[start..]);
    parts
}
fn channel_failure(e: ChannelError) -> Failure {
    let waiting = || Failure::with("server_unreachable", WAITING_DETAIL);
    match e {
        ChannelError::Unreachable | ChannelError::Closed | ChannelError::Timeout => waiting(),
        ChannelError::PinMismatch => Failure::new("authentication_failed"),
        ChannelError::Protocol => Failure::new("malformed_response"),
        ChannelError::Server(code) => match code.as_str() {
            "busy" | "worker_unavailable" => waiting(),
            "not_offered" => Failure::with("server_unavailable", "not_offered"),
            "unauthorized" | "token_expired" | "not_approved" | "revoked" | "pairing_token_invalid" => Failure::new("authentication_failed"),
            "limit_exceeded" => Failure::new("too_long"),
            "unsupported_version" => Failure::new("unsupported_version"),
            "invalid_message" | "internal" => Failure::new("malformed_response"),
            _ => waiting(),
        },
    }
}
/// One op on the background channel; the channel is kept only after a terminal event.
fn channel_analyze(deps: &Deps, body: &[u8], timeout: Duration, cancel: &AtomicBool, sink: Sink) -> Result<(), Stop> {
    if body.len() > wire::MAX_REQUEST_BODY_BYTES {
        return Err(Failure::new("too_long").into());
    }
    let waiting = Failure::with("server_unreachable", WAITING_DETAIL);
    let pool = deps.pool.as_ref().ok_or_else(|| waiting.clone())?;
    let text = std::str::from_utf8(body).map_err(|_| Failure::new("malformed_response"))?;
    let started = Instant::now();
    let (mut channel, op) = pool.lease(Role::Background).map_err(channel_failure)?;
    let mut finished = false;
    let mut exchange = || -> Result<(), Stop> {
        let parts = fragments(text);
        for (index, part) in parts.iter().enumerate() {
            let message = serde_json::json!({"schema_version": 1, "type": "analysis_part", "op": op, "index": index, "data": part});
            channel.send_json(&message.to_string()).map_err(channel_failure)?;
        }
        let closing = serde_json::json!({"schema_version": 1, "type": "analysis", "op": op, "parts": parts.len(), "bytes": body.len(), "sha256": sha256_hex(body)});
        channel.send_json(&closing.to_string()).map_err(channel_failure)?;
        let (mut first, mut total, mut pending, mut pending_parts) = (true, 0, Vec::<u8>::new(), 0);
        loop {
            if cancel.load(Ordering::SeqCst) {
                return Err(Stop::Cancelled);
            }
            if started.elapsed() >= timeout {
                return Err(Failure::new("timeout").into());
            }
            let Some(message) = channel.poll().map_err(channel_failure)? else {
                std::thread::sleep(Duration::from_millis(10));
                continue;
            };
            if first {
                sink(Item::FirstByte)?;
                first = false;
            }
            let m = match message {
                ServerMessage::Error { code } => return Err(channel_failure(ChannelError::Server(code)).into()),
                ServerMessage::Other(m) if m["op"] == op => m,
                _ => return Err(Failure::new("malformed_response").into()),
            };
            let line = match m["type"].as_str() {
                Some("progress") => continue,
                Some("analysis_event_part") => {
                    let data = m["data"].as_str().unwrap_or_default();
                    if m["index"].as_u64() != Some(pending_parts) || pending.len() + data.len() > wire::MAX_LINE_BYTES {
                        return Err(Failure::new("oversized_response").into());
                    }
                    pending.extend_from_slice(data.as_bytes());
                    pending_parts += 1;
                    continue;
                }
                Some("analysis_event") if !m["event"].is_null() => {
                    if pending_parts != 0 {
                        return Err(Failure::new("malformed_response").into());
                    }
                    serde_json::to_vec(&m["event"]).map_err(|_| Failure::new("malformed_response"))?
                }
                Some("analysis_event") => {
                    if m["parts"].as_u64() != Some(pending_parts) || m["sha256"].as_str() != Some(sha256_hex(&pending).as_str()) {
                        return Err(Failure::new("malformed_response").into());
                    }
                    pending_parts = 0;
                    std::mem::take(&mut pending)
                }
                _ => return Err(Failure::new("malformed_response").into()),
            };
            total += line.len() + 1;
            if total > wire::MAX_STREAM_BYTES {
                return Err(Failure::with("oversized_response", "stream_bytes").into());
            }
            let event = wire::decode_event(&line)?;
            let terminal = matches!(event, Event::Result(_) | Event::Error(_));
            sink(Item::Event(event))?;
            if terminal {
                finished = true;
                return sink(Item::Completed { request_bytes: body.len(), response_bytes: total });
            }
        }
    };
    let outcome = exchange();
    pool.release(Role::Background, channel, finished.then_some(op + 1));
    outcome
}

// MARK: routing

/// `RoutingAnalysisTransport.analyze`: a custom server first; before anything committed a failure
/// retries over the channel, without its headers.
fn analyze(deps: &Deps, endpoint: &Endpoint, body: &[u8], timeout: Duration, cancel: &Arc<AtomicBool>, sink: Sink) -> Result<(), Stop> {
    if endpoint.via_channel {
        return channel_analyze(deps, body, timeout, cancel, sink);
    }
    if !endpoint.channel_fallback {
        return http_analyze(deps, endpoint, body, timeout, cancel, sink);
    }
    let (mut held, mut committed) = (vec![], false);
    let outcome = http_analyze(deps, endpoint, body, timeout, cancel, &mut |item| {
        if committed {
            return sink(item);
        }
        match item {
            Item::Event(Event::Error(code)) => Err(Failure::with(category_for_code(&code), code).into()),
            Item::Event(Event::Progress { .. } | Event::Result(_)) => {
                committed = true;
                for earlier in held.drain(..) {
                    sink(earlier)?;
                }
                sink(item)
            }
            other => {
                held.push(other);
                Ok(())
            }
        }
    });
    match outcome {
        Err(Stop::Failure(_)) if !committed => {
            sink(Item::FellBack)?;
            channel_analyze(deps, body, timeout, cancel, sink)
        }
        Ok(()) => {
            for earlier in held {
                sink(earlier)?;
            }
            Ok(())
        }
        other => other,
    }
}
/// The channel has no health route; flowd answers on it with the client's default limits.
fn channel_health() -> Health {
    Health { service: Some("localflow-analysis".into()), server_version: None, backend_state: Some("ready".into()), result_schema_version: Some(1), ..Default::default() }
}
fn health(deps: &Deps, endpoint: &Endpoint) -> Result<Health, Stop> {
    if endpoint.via_channel {
        return Ok(channel_health());
    }
    let answer = http_health(deps, endpoint);
    if endpoint.channel_fallback && !answer.as_ref().is_ok_and(|h| h.backend_state.as_deref() == Some("ready")) {
        return Ok(channel_health());
    }
    answer
}
/// `MeetingAnalyzer.serverReachable`.
pub fn server_reachable(deps: &Deps, route: &Route) -> bool {
    route.endpoint.as_ref().is_some_and(|e| health(deps, e).is_ok())
}

// MARK: admission

pub struct Admission {
    pub run: String,
    pub meeting: String,
    pub version: String,
    pub pass: String,
    pub language: &'static str,
    pub endpoint: Endpoint,
    pub snapshot: Snapshot,
    title: String,
    started_ms: i64,
    duration_ms: i64,
    offset: i32,
}
/// The IANA name of this machine's zone, which the server's `time.LoadLocation` requires.
// ponytail: TZ, then the /etc/localtime link, then a whole-hour Etc/GMT zone from the offset, else UTC.
// Windows has only the last two, so a half-hour zone or a daylight change the summary mentions reads off
// by that much. A Windows-to-IANA table lifts this.
pub fn current_zone(offset_seconds: i32) -> String {
    let from_env = std::env::var("TZ").ok().map(|z| z.trim_start_matches(':').to_string()).filter(|z| !z.is_empty() && !z.contains(' ') && z.contains('/'));
    let from_link = || std::fs::read_link("/etc/localtime").ok().and_then(|p| p.to_str().and_then(|s| s.split("zoneinfo/").nth(1).map(String::from)));
    from_env.or_else(from_link).unwrap_or_else(|| {
        let hours = offset_seconds / 3600;
        if offset_seconds == 0 || offset_seconds % 3600 != 0 {
            "UTC".into()
        } else if hours > 0 {
            format!("Etc/GMT-{hours}")
        } else {
            format!("Etc/GMT+{}", -hours)
        }
    })
}
/// `yyyy-MM-dd'T'HH:mm:ssXXX`.
pub fn rfc3339(ms: i64, offset: i32) -> String {
    let local = ms.div_euclid(1000) + i64::from(offset);
    let (y, m, d) = meetings::civil(local.div_euclid(86_400));
    let s = local.rem_euclid(86_400);
    let zone = if offset == 0 { "Z".to_string() } else { format!("{}{:02}:{:02}", if offset < 0 { '-' } else { '+' }, offset.abs() / 3600, offset.abs() % 3600 / 60) };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}{zone}", s / 3600, s % 3600 / 60, s % 60)
}
/// `MeetingAnalyzer.admit`: eligibility, preflight, evidence and the `pending` row. A refusal leaves no row.
pub fn admit(deps: &Deps, db: &Db, route: &Route, meeting: &str, trigger: &str) -> Result<Admission, Stop> {
    let transcription = meetings::transcription(db, meeting)?.filter(|t| t.state == "final");
    let Some(pass) = transcription.and_then(|t| t.pass_id) else { return Err(Failure::new("not_eligible").into()) };
    if let Some(refusal) = route.settings.preflight() {
        return Err(Failure::new(if matches!(refusal, Connection::AuthenticationFailed | Connection::MissingCredential) { "authentication_failed" } else { "server_unavailable" }).into());
    }
    let run_locally: bool = db.conn.query_row("SELECT run_locally FROM meetings WHERE id=?1", [meeting], |r| r.get(0)).unwrap_or(false);
    let (chosen, ran_locally) = match (&route.local, run_locally) {
        (Some(local), true) => (Some(local.clone()), true),
        _ => (route.endpoint.clone(), false),
    };
    let Some(endpoint) = chosen else { return Err(Failure::with("server_unavailable", UNAVAILABLE_MESSAGE).into()) };
    let snapshot = load_evidence(db, meeting, &pass)?;
    if snapshot.notes.len() > super::MAX_NOTE_PARAGRAPHS || snapshot.notes.iter().any(|n| n.text.len() > super::MAX_NOTE_PARAGRAPH_BYTES) {
        return Err(Failure::with("too_long", "notes_too_large").into());
    }
    let language = resolve_language(db, meeting, &snapshot)?;
    let version = super::evidence_version(meeting, &pass, &snapshot, language);
    // A user-started run against a stopped model fails every request at once: say so now. An unreachable
    // server is left to the run's own health step.
    if trigger != "automatic"
        && trigger != "restart"
        && let Ok(Some(state)) = health(deps, &endpoint).map(|h| h.backend_state)
        && state != "ready"
    {
        return Err(Failure::with("backend_unavailable", state).into());
    }
    // One automatic run per finalized pass.
    if trigger == "automatic" && store::accepted_run(db, meeting).ok().flatten().is_some_and(|r| r.pass.as_deref().is_some_and(|p| p.eq_ignore_ascii_case(&pass))) {
        return Err(Failure::with("not_eligible", "automatic_already_accepted").into());
    }
    let row = meetings::meeting(db, meeting)?.ok_or(Stop::Internal { full: false })?;
    let started_ms = row.started_at.unwrap_or(row.created_at);
    let offset = meetings::local_offset(db, started_ms);
    let title = row.display_title(meetings::local_offset(db, row.created_at));
    let duration_ms: i64 = db.conn.query_row("SELECT wall_clock_ms FROM meetings WHERE id=?1", [meeting], |r| r.get(0))?;
    let now = now_ms();
    let run = store::admit(db, meeting, trigger, &version, &pass, &Policy::default(), now).map_err(|e| match e {
        // The same meeting's run is already active: nothing to add, and nothing to tell the user but this.
        StoreError::ActiveRun => Stop::Failure(Failure::with("not_eligible", "active_run")),
        other => other.into(),
    })?;
    store::record_path(db, &run, if ran_locally { "local_after_server_failure" } else { endpoint.inference_path() })?;
    Ok(Admission { run, meeting: meeting.to_string(), version, pass, language, endpoint, snapshot, title, started_ms, duration_ms, offset })
}

// MARK: run

pub type Progress<'a> = &'a (dyn Fn(Option<(String, f32)>) + Sync);
struct Context<'a> {
    deps: &'a Deps,
    db: &'a Db,
    a: &'a Admission,
    cancel: &'a Arc<AtomicBool>,
    progress: Progress<'a>,
    deadline: Instant,
    evidence: Evidence,
    policy: Policy,
    time_zone: String,
}
impl Context<'_> {
    fn check(&self) -> Result<(), Stop> {
        if self.cancel.load(Ordering::SeqCst) {
            return Err(Stop::Cancelled);
        }
        if Instant::now() >= self.deadline {
            return Err(Failure::new("timeout").into());
        }
        Ok(())
    }
    fn wait(&self, delay: Duration) -> Result<(), Stop> {
        let end = Instant::now() + delay;
        while Instant::now() < end {
            self.check()?;
            std::thread::sleep(Duration::from_millis(10).min(delay));
        }
        self.check()
    }
    fn request(&self, stage: &str, chunk: Option<(usize, usize)>, segments: Option<&[super::Segment]>, notes: Option<&[super::Note]>, partials: Option<&[Value]>) -> Value {
        let a = self.a;
        let started_at = rfc3339(a.started_ms, a.offset);
        let base = RequestBase { meeting: &a.meeting, run: &a.run, title: &a.title, started_at: &started_at, duration_ms: a.duration_ms, time_zone: &self.time_zone, language: a.language, participants: &a.snapshot.participants };
        request_json(&base, stage, chunk, segments, notes, partials)
    }
    /// `consumeWithPreemptionRetry`.
    fn consume_retrying(&self, request: &Value, chars: usize, label: &str) -> Result<Box<Payload>, Stop> {
        let mut attempt = 0;
        loop {
            match self.consume(request, chars, label, attempt > 0) {
                Err(Stop::Failure(f)) if f.category == "backend_busy" && f.detail.as_deref() == Some("preempted") => {
                    store::record_request(self.db, &self.a.run, 0, 0, attempt > 0, true)?;
                    attempt += 1;
                    if attempt > super::PREEMPTION_RETRIES {
                        return Err(f.into());
                    }
                    self.wait(self.deps.wait_unit * (2 * attempt))?;
                }
                other => return other,
            }
        }
    }
    fn consume(&self, request: &Value, chars: usize, label: &str, retried: bool) -> Result<Box<Payload>, Stop> {
        self.check()?;
        let (run, meeting_run) = (&self.a.run, upper(&self.a.run));
        let body = serde_json::to_vec(request).map_err(|_| Stop::Internal { full: false })?;
        let limit = (self.deps.deadline_unit * super::PER_REQUEST_SECONDS as u32).min(self.deadline.saturating_duration_since(Instant::now()));
        let (mut result, mut sizes) = (None, (0, 0));
        let total = chars.max(1) as f64;
        analyze(self.deps, &self.a.endpoint, &body, limit, self.cancel, &mut |item| {
            if self.cancel.load(Ordering::SeqCst) {
                return Err(Stop::Cancelled);
            }
            let at = |fraction: f64| (self.progress)(Some((label.to_string(), fraction as f32)));
            match item {
                Item::FellBack => store::record_path(self.db, run, "server")?,
                Item::FirstByte => at(0.05),
                Item::Event(Event::Accepted) => at(0.1),
                Item::Event(Event::Progress { chars }) => at((0.1 + 0.8 * chars as f64 / total).min(0.9)),
                Item::Event(Event::Result(payload)) => {
                    if payload.run_id.as_deref().is_some_and(|id| !id.eq_ignore_ascii_case(&meeting_run)) {
                        return Err(Failure::with("malformed_response", "run_id").into());
                    }
                    result = Some(payload);
                }
                Item::Event(Event::Error(code)) => return Err(Failure::with(category_for_code(&code), code).into()),
                Item::Completed { request_bytes, response_bytes } => sizes = (request_bytes, response_bytes),
            }
            Ok(())
        })?;
        if self.cancel.load(Ordering::SeqCst) {
            return Err(Stop::Cancelled);
        }
        store::record_request(self.db, run, sizes.0, sizes.1, retried, false)?;
        let Some(result) = result else { return Err(Failure::with("malformed_response", "no_result").into()) };
        if result.analysis.language != self.a.language {
            return Err(Failure::with("malformed_response", "language_policy").into());
        }
        if !prose_matches(&result.analysis, self.a.language) {
            return Err(Failure::with("malformed_response", "prose_language").into());
        }
        Ok(result)
    }
    fn evidence_holds(&self) -> Result<(), Stop> {
        if current_version(self.db, &self.a.meeting)?.as_deref() == Some(self.a.version.as_str()) { Ok(()) } else { Err(Failure::with("source_validation", "evidence_changed").into()) }
    }
    /// `checkPartial`: only the run-failing source rules apply to a result that is never adopted.
    fn check_partial(&self, result: &wire::AnalysisResult) -> Result<(), Stop> {
        match validate::validate(result, &self.evidence, &self.policy) {
            Err(f) if !matches!(f.category, "protected_literal" | "unsupported_content") => Err(f.into()),
            _ => Ok(()),
        }
    }
    fn perform(&self, plan: &super::Plan) -> Result<Box<Payload>, Stop> {
        let a = self.a;
        if plan.chunks.is_empty() {
            let chars = a.snapshot.segments.iter().map(|s| s.text.chars().count()).sum();
            let request = self.request("full", None, Some(&a.snapshot.segments), Some(&a.snapshot.notes), None);
            return self.consume_retrying(&request, chars, "Analyzing");
        }
        let backend = a.endpoint.backend_key();
        let scope = (a.meeting.clone(), a.version.clone(), backend);
        let (mut inputs, mut requested): (Vec<wire::AnalysisResult>, bool) = (vec![], false);
        for chunk in &plan.chunks {
            let cached = self.deps.partials.lock().ok().and_then(|c| if c.scope.as_ref() == Some(&scope) { c.results.get(&(chunk.first, chunk.last)).cloned() } else { None });
            if let Some(cached) = cached {
                inputs.push(cached);
                continue;
            }
            if requested {
                self.evidence_holds()?;
            }
            requested = true;
            let segments = super::segment_window(self.db, &a.meeting, &a.pass, chunk.first, chunk.last)?;
            let chars = segments.iter().map(|s| s.text.chars().count()).sum();
            let request = self.request("chunk", Some((chunk.index, plan.chunks.len())), Some(&segments), None, None);
            let label = format!("Analyzing part {} of {}", chunk.index + 1, plan.chunks.len());
            let outcome = self.consume_retrying(&request, chars, &label)?;
            self.check_partial(&outcome.analysis)?;
            if let Ok(mut cache) = self.deps.partials.lock() {
                if cache.scope.as_ref() != Some(&scope) {
                    *cache = PartialCache { scope: Some(scope.clone()), results: HashMap::new() };
                }
                cache.results.insert((chunk.first, chunk.last), outcome.analysis.clone());
            }
            inputs.push(outcome.analysis);
        }
        let mut last = None;
        for (level, count) in plan.synthesis.iter().enumerate() {
            let last_level = level == plan.synthesis.len() - 1;
            let mut outputs: Vec<wire::AnalysisResult> = vec![];
            for group in inputs.chunks(super::PARTIALS_PER_SYNTHESIS) {
                let is_final = last_level && outputs.len() == count - 1;
                let raws: Vec<Value> = group.iter().map(|r| r.raw.clone()).collect();
                let request = self.request("synthesis", None, None, is_final.then_some(&a.snapshot.notes[..]), Some(&raws));
                let outcome = self.consume_retrying(&request, 0, "Combining")?;
                if is_final {
                    outputs.push(outcome.analysis.clone());
                    last = Some(outcome);
                } else {
                    self.check_partial(&outcome.analysis)?;
                    outputs.push(outcome.analysis);
                }
            }
            inputs = outputs;
        }
        last.ok_or_else(|| Failure::with("malformed_response", "no_result").into())
    }
}
/// `proseMatches`: the summary and the topic summaries together must not be plainly the other language.
pub fn prose_matches(analysis: &wire::AnalysisResult, output: &str) -> bool {
    let expected = if output == "en" { Dominant::English } else { Dominant::Slovak };
    let topics = analysis.topics.iter().map(|t| t.summary.as_str()).filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n");
    [analysis.summary.text.as_str(), topics.as_str()].iter().all(|block| confident(block, 200, 30).is_none_or(|l| l == expected))
}
fn identity(health: &Health, payload: &Payload) -> Identity {
    let prompt_versions = health.prompt_versions.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join(",");
    Identity {
        server_version: payload.server_version.clone().or_else(|| health.server_version.clone()).unwrap_or_default(),
        backend_kind: payload.backend_kind.clone().or_else(|| health.backend_kind.clone()).unwrap_or_default(),
        backend_model: payload.backend_model.clone().or_else(|| health.backend_model.clone()).unwrap_or_default(),
        prompt_versions,
        pipeline_version: payload.pipeline_version.clone().unwrap_or_else(|| super::PIPELINE_VERSION.to_string()),
    }
}
fn evidence_of(a: &Admission) -> Evidence {
    Evidence {
        meeting: a.meeting.clone(),
        segments: a.snapshot.segments.iter().map(|s| (upper(&s.id), (s.id.clone(), s.text.clone()))).collect(),
        notes: a.snapshot.notes.clone(),
        participants: a.snapshot.participants.clone(),
        candidates: a.snapshot.candidates.clone(),
        started_ms: Some(a.started_ms),
        offset: a.offset,
    }
}
fn attempt(deps: &Deps, db: &Db, a: &Admission, cancel: &Arc<AtomicBool>, progress: Progress) -> Result<(), Stop> {
    store::start(db, &a.run, now_ms())?;
    progress(Some(("Analyzing".into(), 0.0)));
    let check = |c: &AtomicBool| if c.load(Ordering::SeqCst) { Err(Stop::Cancelled) } else { Ok(()) };
    check(cancel)?;
    if current_version(db, &a.meeting)?.as_deref() != Some(a.version.as_str()) {
        return Err(Failure::with("source_validation", "evidence_changed").into());
    }
    let health = health(deps, &a.endpoint)?;
    check(cancel)?;
    if health.result_schema_version.is_some_and(|v| v != 1) {
        return Err(Failure::with("unsupported_version", "result_schema_version").into());
    }
    let policy = Policy::default().lowered(&health);
    let plan = plan(&a.snapshot.segments, &a.snapshot.notes, &policy)?;
    store::record_plan(db, &a.run, plan.chunks.len())?;
    let deadline = Instant::now() + deps.deadline_unit * Policy::deadline_seconds(plan.request_count()) as u32;
    let time_zone = current_zone(a.offset);
    let context = Context { deps, db, a, cancel, progress, deadline, evidence: evidence_of(a), policy: policy.clone(), time_zone };
    let outcome = context.perform(&plan)?;
    let (validated, counts) = validate::validate(&outcome.analysis, &context.evidence, &policy)?;
    context.evidence_holds()?;
    store::adopt(db, &a.run, &validated, &counts, &identity(&health, &outcome), now_ms())?;
    if let Ok(mut cache) = deps.partials.lock() {
        cache.forget(&a.meeting);
    }
    Ok(())
}
/// `MeetingAnalyzer.execute`: `pending` to a terminal row. None when the run was cancelled or the row
/// is unreachable; otherwise the meeting's latest run.
pub fn execute(deps: &Deps, a: &Admission, cancel: &Arc<AtomicBool>, progress: Progress) -> Option<RunRow> {
    if !deps.database.exists() {
        return None;
    }
    let db = Db::open(&deps.database).ok()?;
    let outcome = attempt(deps, &db, a, cancel, progress);
    let now = now_ms();
    let terminal = match outcome {
        Ok(()) => true,
        Err(Stop::Cancelled) => {
            let _ = store::cancel(&db, &a.run, now);
            false
        }
        Err(Stop::Failure(f)) => {
            let _ = if f.category == "timeout" { store::time_out(&db, &a.run, now) } else { store::fail(&db, &a.run, f.category, f.detail.as_deref(), now) };
            true
        }
        Err(Stop::Late) => {
            let _ = store::supersede(&db, &a.run, now);
            true
        }
        Err(Stop::Internal { full }) => {
            let _ = store::fail(&db, &a.run, if full { "persistence_capacity" } else { "persistence_failure" }, Some("internal_error"), now);
            true
        }
    };
    progress(None);
    if terminal { store::latest_run(&db, &a.meeting).ok().flatten() } else { None }
}
