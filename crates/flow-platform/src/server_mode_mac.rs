//! Server mode's processes (Feature 028, research R6). Every `launchctl`, `flowd admin`,
//! `flowd-speech` and loopback admin call goes through `ServerProcessRunner`, so tests never start
//! one; the paths and argument lists come from `flow_core::server_mode`.
use flow_core::prefs::Prefs;
use flow_core::server_mode::*;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A finished child process. Token values reach the app only through `output`, on stdout.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProcessResult {
    pub status: i32,
    pub output: String,
    pub error: String,
}

impl ProcessResult {
    pub fn ok(output: impl Into<String>) -> Self {
        ProcessResult { status: 0, output: output.into(), error: String::new() }
    }
    pub fn failed(status: i32, error: impl Into<String>) -> Self {
        ProcessResult { status, output: String::new(), error: error.into() }
    }
    pub fn succeeded(&self) -> bool {
        self.status == 0
    }
    /// The first line of stderr, for showing to the owner.
    pub fn reason(&self) -> String {
        self.error.lines().next().map(String::from).unwrap_or_else(|| format!("exit {}", self.status))
    }
}

/// An HTTP answer: status and body.
pub type HttpAnswer = Result<(u16, Vec<u8>), String>;

pub trait ServerProcessRunner: Send + Sync {
    /// Runs an executable by absolute path, never through a shell, with stdin closed.
    fn run(&self, program: &Path, args: &[String]) -> ProcessResult;
    /// `GET url` with `Authorization: Bearer <bearer>`, loopback only. `Err` when nothing answered.
    fn get(&self, url: &str, bearer: &str) -> HttpAnswer;
    /// `PUT url` with a JSON `body`, otherwise as `get`.
    fn put(&self, url: &str, bearer: &str, body: &[u8]) -> HttpAnswer;
    /// `run`, handing each stderr line to `line` as it comes (`flowd-speech provision`'s progress).
    fn run_streaming(&self, program: &Path, args: &[String], line: &mut dyn FnMut(&str)) -> ProcessResult {
        let result = self.run(program, args);
        result.error.lines().for_each(&mut *line);
        result
    }
}

pub struct SystemRunner;

const ADMIN_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_ADMIN_BODY: u64 = 1 << 20;

impl ServerProcessRunner for SystemRunner {
    fn run(&self, program: &Path, args: &[String]) -> ProcessResult {
        // `output` reads stdout and stderr together, so a child filling one can't block on the other.
        match std::process::Command::new(program).args(args).stdin(std::process::Stdio::null()).output() {
            Ok(out) => ProcessResult { status: out.status.code().unwrap_or(-1), output: String::from_utf8_lossy(&out.stdout).into_owned(), error: String::from_utf8_lossy(&out.stderr).into_owned() },
            Err(_) => ProcessResult::failed(-1, format!("could not start {}", program.display())),
        }
    }
    fn run_streaming(&self, program: &Path, args: &[String], line: &mut dyn FnMut(&str)) -> ProcessResult {
        use std::io::{BufRead, Read};
        use std::process::Stdio;
        let spawned = std::process::Command::new(program).args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn();
        let Ok(mut child) = spawned else { return ProcessResult::failed(-1, format!("could not start {}", program.display())) };
        // stdout on its own thread: a child that fills it while stderr is read must not block.
        let mut stdout = child.stdout.take();
        let output = std::thread::spawn(move || {
            let mut text = String::new();
            if let Some(out) = stdout.as_mut() {
                let _ = out.read_to_string(&mut text);
            }
            text
        });
        let mut error = String::new();
        for l in child.stderr.take().map(std::io::BufReader::new).into_iter().flat_map(|r| r.lines()).map_while(Result::ok) {
            line(&l);
            error.push_str(&l);
            error.push('\n');
        }
        let status = child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);
        ProcessResult { status, output: output.join().unwrap_or_default(), error }
    }
    fn get(&self, url: &str, bearer: &str) -> HttpAnswer {
        let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(ADMIN_TIMEOUT)).max_redirects(0).http_status_as_error(false).proxy(None).build().into();
        let response = agent.get(url).header("Authorization", format!("Bearer {bearer}")).call();
        read_answer(response)
    }
    fn put(&self, url: &str, bearer: &str, body: &[u8]) -> HttpAnswer {
        let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(ADMIN_TIMEOUT)).max_redirects(0).http_status_as_error(false).proxy(None).build().into();
        let response = agent.put(url).header("Authorization", format!("Bearer {bearer}")).header("Content-Type", "application/json").send(body);
        read_answer(response)
    }
}

fn read_answer(response: Result<ureq::http::Response<ureq::Body>, ureq::Error>) -> HttpAnswer {
    let mut response = response.map_err(|_| "unreachable".to_string())?;
    let status = response.status().as_u16();
    let body = response.body_mut().with_config().limit(MAX_ADMIN_BODY).read_to_vec().map_err(|_| "unreadable".to_string())?;
    Ok((status, body))
}

/// One call a `RecordingRunner` saw.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecordedCall {
    Run { program: PathBuf, args: Vec<String> },
    Get { url: String, bearer: String },
    Put { url: String, bearer: String, body: String },
}

type RunAnswer = Box<dyn FnMut(&Path, &[String]) -> ProcessResult + Send>;
type GetAnswer = Box<dyn FnMut(&str) -> HttpAnswer + Send>;
type PutAnswer = Box<dyn FnMut(&str, &[u8]) -> HttpAnswer + Send>;

/// A runner for tests: records every call and answers with scripted closures. By default every
/// run succeeds with no output and nothing answers HTTP.
pub struct RecordingRunner {
    calls: Mutex<Vec<RecordedCall>>,
    run_answer: Mutex<RunAnswer>,
    get_answer: Mutex<GetAnswer>,
    put_answer: Mutex<PutAnswer>,
}

impl Default for RecordingRunner {
    fn default() -> Self {
        RecordingRunner {
            calls: Mutex::default(),
            run_answer: Mutex::new(Box::new(|_, _| ProcessResult::ok(""))),
            get_answer: Mutex::new(Box::new(|_| Err("unreachable".into()))),
            put_answer: Mutex::new(Box::new(|_, _| Err("unreachable".into()))),
        }
    }
}

impl RecordingRunner {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
    pub fn answer_runs(&self, f: impl FnMut(&Path, &[String]) -> ProcessResult + Send + 'static) {
        *self.run_answer.lock().unwrap() = Box::new(f);
    }
    pub fn answer_gets(&self, f: impl FnMut(&str) -> HttpAnswer + Send + 'static) {
        *self.get_answer.lock().unwrap() = Box::new(f);
    }
    pub fn answer_puts(&self, f: impl FnMut(&str, &[u8]) -> HttpAnswer + Send + 'static) {
        *self.put_answer.lock().unwrap() = Box::new(f);
    }
    pub fn calls(&self) -> Vec<RecordedCall> {
        self.calls.lock().unwrap().clone()
    }
    /// The runs as (program, args), in order.
    pub fn runs(&self) -> Vec<(PathBuf, Vec<String>)> {
        self.calls().into_iter().filter_map(|c| if let RecordedCall::Run { program, args } = c { Some((program, args)) } else { None }).collect()
    }
}

impl ServerProcessRunner for RecordingRunner {
    fn run(&self, program: &Path, args: &[String]) -> ProcessResult {
        self.calls.lock().unwrap().push(RecordedCall::Run { program: program.into(), args: args.to_vec() });
        (self.run_answer.lock().unwrap())(program, args)
    }
    fn get(&self, url: &str, bearer: &str) -> HttpAnswer {
        self.calls.lock().unwrap().push(RecordedCall::Get { url: url.into(), bearer: bearer.into() });
        (self.get_answer.lock().unwrap())(url)
    }
    fn put(&self, url: &str, bearer: &str, body: &[u8]) -> HttpAnswer {
        self.calls.lock().unwrap().push(RecordedCall::Put { url: url.into(), bearer: bearer.into(), body: String::from_utf8_lossy(body).into_owned() });
        (self.put_answer.lock().unwrap())(url, body)
    }
}

/// Why `admin_status` has no answer. Never holds the token.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdminError {
    /// No readable `admin-token`: flowd hasn't run with `--admin-listen` yet.
    NoToken,
    /// Other users can read the token file, so it isn't used.
    TokenNotPrivate,
    Unreachable,
    /// flowd answered with this HTTP status.
    Refused(u16),
    Invalid,
}

/// `flowd admin` for this server. It always runs the data directory's own flowd: a newer one from
/// the app would migrate an adopted server's database past what that server can open.
#[derive(Clone)]
pub struct ServerAdmin {
    pub paths: ServerModePaths,
    pub runner: Arc<dyn ServerProcessRunner>,
}

impl ServerAdmin {
    pub fn new(paths: ServerModePaths, runner: Arc<dyn ServerProcessRunner>) -> Self {
        ServerAdmin { paths, runner }
    }

    /// `<data>/bin/flowd admin --data-dir <data> [--dev] <args…>`.
    pub fn run(&self, args: &[&str]) -> ProcessResult {
        self.runner.run(&self.paths.flowd(), &self.paths.admin_arguments(args))
    }

    /// The token from `<data-dir>/admin-token`, refused when the file isn't private to this user,
    /// as flowd itself refuses it.
    fn admin_token(&self) -> Result<String, AdminError> {
        use std::os::unix::fs::PermissionsExt;
        let path = self.paths.admin_token();
        let meta = std::fs::metadata(&path).map_err(|_| AdminError::NoToken)?;
        if meta.permissions().mode() & 0o077 != 0 {
            return Err(AdminError::TokenNotPrivate);
        }
        let token = std::fs::read_to_string(&path).map_err(|_| AdminError::NoToken)?.trim().to_string();
        if token.len() < 32 { Err(AdminError::NoToken) } else { Ok(token) }
    }

    /// `GET http://127.0.0.1:<admin port>/v1/admin/status`: version, start time, counters, the
    /// summaries backend and, from US3, live channels.
    pub fn admin_status(&self) -> Result<serde_json::Value, AdminError> {
        let token = self.admin_token()?;
        let url = format!("http://127.0.0.1:{}/v1/admin/status", self.paths.admin_port());
        let (status, body) = self.runner.get(&url, &token).map_err(|_| AdminError::Unreachable)?;
        if status != 200 {
            return Err(AdminError::Refused(status));
        }
        serde_json::from_slice::<serde_json::Value>(&body).ok().filter(|v| v.is_object()).ok_or(AdminError::Invalid)
    }

    /// `PUT /v1/admin/analysis`: switches the running flowd's summaries backend, `None` back to the
    /// rewrite model. flowd reads `analysis-api-key` itself.
    pub fn put_analysis(&self, backend: Option<(&str, &str)>) -> Result<(), AdminError> {
        let token = self.admin_token()?;
        let url = format!("http://127.0.0.1:{}/v1/admin/analysis", self.paths.admin_port());
        let (url_value, model) = backend.unwrap_or(("", ""));
        let body = serde_json::json!({"backend": url_value, "model": model}).to_string();
        let (status, _) = self.runner.put(&url, &token, body.as_bytes()).map_err(|_| AdminError::Unreachable)?;
        if status == 200 { Ok(()) } else { Err(AdminError::Refused(status)) }
    }

    // The Users page (T044, T045)

    /// `list --json`, `token list --json`, `audit --limit 50 --json` and the status's channels,
    /// merged. Without the loopback status nobody shows as connected; the list still loads.
    pub fn users_page(&self, now_ms: i64) -> Result<flow_core::server_admin::Model, flow_core::server_admin::ReadError> {
        use flow_core::server_admin::*;
        let read = |args: &[&str]| self.run(args);
        let list = read(&["list", "--json"]);
        let list = decode_list(list.status, &list.output, &list.error)?;
        let tokens = read(&["token", "list", "--json"]);
        let tokens = decode_tokens(tokens.status, &tokens.output, &tokens.error)?;
        let audit = read(&["audit", "--limit", "50", "--json"]);
        let audit = decode_audit(audit.status, &audit.output, &audit.error)?;
        let live = self.admin_status().map(|s| connected(&s)).unwrap_or_default();
        Ok(merge(list, &live, tokens, audit, now_ms))
    }

    /// Approve, reject, revoke, rename, `user create` or `token revoke`. A failure reports stderr.
    pub fn act(&self, action: &flow_core::server_admin::Action) -> Result<(), String> {
        use flow_core::server_admin::Action::*;
        let id = |n: &i64| n.to_string();
        let args: Vec<String> = match action {
            Approve(kind, n) => vec!["approve".into(), kind.word().into(), id(n)],
            Reject(n) => vec!["reject".into(), "user".into(), id(n)],
            Revoke(kind, n) => vec!["revoke".into(), kind.word().into(), id(n)],
            Rename(kind, n, name) => vec!["rename".into(), kind.word().into(), id(n), "--name".into(), name.clone()],
            CreateUser(name) => vec!["user".into(), "create".into(), "--name".into(), name.clone(), "--json".into()],
            RevokeToken(n) => vec!["token".into(), "revoke".into(), id(n)],
        };
        let result = self.run(&args.iter().map(String::as_str).collect::<Vec<_>>());
        if result.succeeded() { Ok(()) } else { Err(result.reason()) }
    }

    /// `token create --label <label> [--user <id>] --ttl 24h --address <origin>… --json`. `user` is
    /// `None` only when the owner asked for a new person. The token reaches only the returned value.
    pub fn create_token(&self, label: &str, user: Option<i64>, addresses: &[String]) -> Result<OwnerToken, String> {
        let user = user.map(|u| u.to_string());
        let mut args = vec!["token", "create", "--label", label];
        if let Some(user) = &user {
            args.extend(["--user", user.as_str()]);
        }
        args.extend(["--ttl", "24h"]);
        for address in addresses {
            args.extend(["--address", address.as_str()]);
        }
        args.push("--json");
        let result = self.run(&args);
        if !result.succeeded() {
            return Err(format!("flowd admin token create failed: {}", result.reason()));
        }
        OwnerToken::parse(&result.output).ok_or_else(|| "flowd admin token create gave no token.".into())
    }
}

// The controller (T025): Swift's `ServerModeController`, with the pure parts in flow_core.

/// Time for the 60-second open and the waits around launchctl, so tests run them instantly.
pub trait Clock: Send + Sync {
    fn now(&self) -> Instant;
    fn sleep(&self, duration: Duration);
}

pub struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// A clock that moves only when something sleeps on it.
pub struct FakeClock(Mutex<Instant>);
impl Default for FakeClock {
    fn default() -> Self {
        FakeClock(Mutex::new(Instant::now()))
    }
}
impl Clock for FakeClock {
    fn now(&self) -> Instant {
        *self.0.lock().unwrap()
    }
    fn sleep(&self, duration: Duration) {
        *self.0.lock().unwrap() += duration;
    }
}

/// `origin` → the fingerprint its `GET /v1/remote/identity` reports, `None` when it doesn't answer.
pub type IdentityProbe = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;
/// The numeric addresses of this Mac's interfaces that are up, without loopback.
pub type Interfaces = Arc<dyn Fn() -> Vec<String> + Send + Sync>;

const LAUNCHCTL: &str = "/bin/launchctl";
const DOWNLOAD_FAILED: &str = "A model could not be downloaded or verified. Try again.";
const ADOPTED_OPEN: &str = "This server was set up outside LocalFlow, so its settings stay as they are. Change its address where it was set up.";
const HANDOFF_STALE: &str = "Meetings sent from a phone: turn server mode off and on.";
const ADOPTED_ANALYSIS: &str = "This server was set up outside LocalFlow, so its settings stay as they are. Change its analysis backend where it was set up.";

/// Server mode for one Mac. Nothing here touches the client's own agents or preferences: its
/// state is `server-mode.json` beside them, with Swift's key names.
pub struct ServerMode {
    pub paths: ServerModePaths,
    pub admin: ServerAdmin,
    runner: Arc<dyn ServerProcessRunner>,
    /// The app's `Contents` folder: `Helpers` and `Resources`.
    contents: PathBuf,
    /// This app's data folder: `server-mode.json` and `ServerMode/` for the open's backup.
    app_root: PathBuf,
    /// The MTPLX runtime and `model-path`, shared with the Swift app (`LocalFlow/LocalAI`).
    local_ai: PathBuf,
    uid: u32,
    prefs: Mutex<Prefs>,
    pub clock: Arc<dyn Clock>,
    pub probe: IdentityProbe,
    pub interfaces: Interfaces,
    /// Between health checks during an open; Swift's is 3 s.
    pub poll: Duration,
}

impl ServerMode {
    pub fn new(paths: ServerModePaths, runner: Arc<dyn ServerProcessRunner>, contents: PathBuf, app_root: PathBuf, local_ai: PathBuf, uid: u32) -> Self {
        let prefs = Mutex::new(Prefs::open(app_root.join("server-mode.json")));
        ServerMode {
            admin: ServerAdmin::new(paths.clone(), runner.clone()),
            paths,
            runner,
            contents,
            app_root,
            local_ai,
            uid,
            prefs,
            clock: Arc::new(SystemClock),
            probe: Arc::new(|origin: &str| flow_core::settings::fetch_identity(origin).ok().map(|i| i.fingerprint)),
            interfaces: Arc::new(interface_ips),
            poll: Duration::from_secs(3),
        }
    }

    fn prefs(&self) -> std::sync::MutexGuard<'_, Prefs> {
        self.prefs.lock().unwrap()
    }

    // launchctl

    fn domain(&self) -> String {
        format!("gui/{}", self.uid)
    }
    fn target(&self, label: &str) -> String {
        format!("{}/{label}", self.domain())
    }
    fn launchctl(&self, args: &[String]) -> ProcessResult {
        self.runner.run(Path::new(LAUNCHCTL), args)
    }
    fn job(&self, label: &str) -> Option<AgentJob> {
        let result = self.launchctl(&["print".into(), self.target(label)]);
        result.succeeded().then(|| AgentJob::parse(&result.output))
    }
    fn bootout(&self, label: &str) -> ProcessResult {
        self.launchctl(&["bootout".into(), self.target(label)])
    }
    fn bootstrap(&self, plist: &Path) -> ProcessResult {
        self.launchctl(&["bootstrap".into(), self.domain(), text(plist)])
    }
    /// bootstrap fails with error 5 while the old job is still being torn down.
    fn wait_until_gone(&self, label: &str) {
        for _ in 0..50 {
            if self.job(label).is_none() {
                return;
            }
            self.clock.sleep(Duration::from_millis(200));
        }
    }

    // Status

    fn plist_bytes(&self) -> Option<Vec<u8>> {
        std::fs::read(self.paths.plist()).ok()
    }
    fn plist_arguments(&self) -> Option<Vec<String>> {
        program_arguments(&self.plist_bytes()?)
    }
    pub fn ownership(&self, loaded: bool) -> Ownership {
        ownership(self.plist_bytes().as_deref(), &self.prefs(), loaded)
    }

    fn helpers(&self) -> PathBuf {
        self.contents.join("Helpers")
    }
    fn helpers_present(&self) -> bool {
        REQUIRED_HELPERS.iter().all(|h| executable(&self.helpers().join(h))) && self.helpers().join(RESOURCE_BUNDLE).exists()
    }
    /// Changes when an update or a rebuild replaces the helpers.
    fn helpers_stamp(&self) -> String {
        ["flowd", "flowd-speech", MEETING_PROCESSOR]
            .iter()
            .map(|name| {
                let meta = std::fs::metadata(self.helpers().join(name)).ok();
                let size = meta.as_ref().map_or(0, |m| m.len());
                let date = meta.and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs());
                format!("{name}:{size}:{date}")
            })
            .collect::<Vec<_>>()
            .join(",")
    }

    /// A pinned descriptor: the one installed with the server, else the app's.
    fn descriptor(&self, name: &str) -> Option<Vec<u8>> {
        std::fs::read(self.paths.bin_dir().join(name)).or_else(|_| std::fs::read(self.resource(name))).ok()
    }
    fn resource(&self, name: &str) -> PathBuf {
        let models = self.contents.join("Resources/Models").join(name);
        if models.exists() { models } else { self.contents.join("Resources").join(name) }
    }
    /// Bytes still missing per `SERVER_MODELS` entry; `None` without a readable descriptor.
    fn model_gaps(&self) -> [Option<u64>; 3] {
        SERVER_MODELS.map(|(file, root, _)| missing_model_bytes(&self.descriptor(file)?, &self.paths.models_dir().join(root)))
    }

    pub fn status(&self) -> ServerModeStatus {
        let job = self.job(self.paths.label());
        let mut status = ServerModeStatus { loaded: job.is_some(), running: job.is_some_and(|j| j.running), ..Default::default() };
        status.ownership = self.ownership(status.loaded);
        let arguments = self.plist_arguments();
        status.listen = arguments.as_deref().and_then(|a| value_after(a, "--remote-listen")).map(String::from);
        if status.ownership == Ownership::None {
            status.listen = None;
            if !self.helpers_present() {
                status.missing.push(HELPERS_MISSING.into());
            }
        }
        if status.running
            && let Some(origin) = status.listen.as_deref().and_then(health_origin)
        {
            status.fingerprint = (self.probe)(&origin);
            let people = self.admin.run(&["list"]);
            status.client_connected = people.succeeded() && client_seen(&people.output);
        }
        for ((_, _, service), gap) in SERVER_MODELS.iter().zip(self.model_gaps()) {
            let Some(bytes) = gap else { continue };
            status.missing_model_bytes += bytes;
            let line = models_missing(service);
            if bytes > 0 && !status.missing.contains(&line) {
                status.missing.push(line);
            }
        }
        if status.ownership != Ownership::None {
            if !self.paths.mtplx_plist().exists() {
                status.missing.push(REWRITING_MISSING.into());
            }
            if !executable(&self.paths.meeting_processor()) {
                status.missing.push(HANDOFF_MISSING.into());
            } else if status.ownership == Ownership::Managed && arguments.is_some_and(|a| !a.iter().any(|x| x == "--meeting-processor")) {
                // Set up before flowd-meeting was bundled: the next plist this app writes has the flag.
                status.missing.push(HANDOFF_STALE.into());
            }
        }
        status
    }

    pub fn enabled(&self) -> bool {
        self.prefs().bool_or(ENABLED_KEY, false)
    }

    pub fn addresses(&self, listen: Option<&str>) -> Vec<ServerAddress> {
        addresses(listen, &(self.interfaces)(), &self.prefs())
    }

    pub fn plan_input(&self, physical_memory: u64, free_disk: Option<u64>, downloaded: [bool; 5]) -> PlanInput {
        let speech_installed = self.model_gaps().map(|g| g == Some(0));
        let runtime_installed = self.local_ai.join("python/bin/python3").is_file() && self.local_ai.join("venv/.localflow-requirements").is_file();
        PlanInput { physical_memory, free_disk, downloaded, speech_installed, runtime_installed }
    }

    // On and off

    /// A new server listens on loopback only: nothing is reachable from other devices until the
    /// owner confirms `open_to_network` (FR-009). An adopted server is started as it is (FR-011).
    pub fn turn_on(&self) -> Result<(), String> {
        if self.job(self.paths.label()).is_none() {
            match self.ownership(false) {
                Ownership::Adopted => {}
                Ownership::None => self.install(&format!("127.0.0.1:{}", self.paths.remote_port()))?,
                Ownership::Managed => {
                    if !self.helpers_present() {
                        return Err(HELPERS_MISSING.into());
                    }
                    if self.prefs().string(HELPERS_STAMP_KEY) != Some(self.helpers_stamp()) {
                        self.sync_helpers()?;
                    }
                    let listen = self.plist_arguments().and_then(|a| value_after(&a, "--remote-listen").map(String::from));
                    self.install(&listen.unwrap_or_else(|| format!("127.0.0.1:{}", self.paths.remote_port())))?;
                }
            }
            self.start()?;
        }
        self.prefs().set(ENABLED_KEY, true);
        Ok(())
    }

    /// Stops both agents and keeps them from coming back at login: their connections close. Deletes
    /// nothing, so the users and devices are there when it's turned on again.
    pub fn turn_off(&self) -> Result<(), String> {
        for label in [self.paths.label(), self.paths.mtplx_label()] {
            if self.job(label).is_some() {
                let result = self.bootout(label);
                if !result.succeeded() {
                    return Err(format!("launchctl bootout failed: {}", result.reason()));
                }
                self.wait_until_gone(label);
            }
            self.launchctl(&["disable".into(), self.target(label)]);
        }
        self.prefs().set(ENABLED_KEY, false);
        Ok(())
    }

    /// After an app update: new helpers for a server this app installed. An adopted one is left alone.
    pub fn resync_if_updated(&self) {
        let loaded = self.job(self.paths.label()).is_some();
        if self.ownership(loaded) != Ownership::Managed || !self.helpers_present() || self.prefs().string(HELPERS_STAMP_KEY) == Some(self.helpers_stamp()) {
            return;
        }
        if loaded {
            self.bootout(self.paths.label());
            self.wait_until_gone(self.paths.label());
        }
        let _ = self.sync_helpers();
        if loaded {
            self.bootstrap(&self.paths.plist());
        }
    }

    /// The speech and meeting models. The worker's model locks need flowd stopped, and flowd comes
    /// back whatever the result. Before the first install the helpers are copied so the worker exists.
    pub fn download_models(&self, progress: &(dyn Fn(u64, u64) + Sync)) -> Result<(), String> {
        let worker = self.paths.bin_dir().join("flowd-speech");
        if !executable(&worker) {
            if self.ownership(false) == Ownership::Adopted || !self.helpers_present() {
                return Err(HELPERS_MISSING.into());
            }
            self.sync_helpers()?;
        }
        let loaded = self.job(self.paths.label()).is_some();
        if loaded {
            self.bootout(self.paths.label());
            self.wait_until_gone(self.paths.label());
        }
        let args = ["provision".to_string(), "--models".into(), text(&self.paths.models_dir()), "--meeting".into()];
        let result = self.runner.run_streaming(&worker, &args, &mut |line| {
            if let Some(flow_core::dictation::provision::Line::Progress { completed, total, .. }) = flow_core::dictation::provision::parse(line) {
                progress(completed, total);
            }
        });
        if loaded {
            self.bootstrap(&self.paths.plist());
        }
        if result.succeeded() { Ok(()) } else { Err(DOWNLOAD_FAILED.into()) }
    }

    // Open to the network

    /// Changes only `--remote-listen`, keeps the previous plist and restores it unless the server
    /// is healthy within 60 s. A server set up elsewhere is never rewritten (FR-011).
    pub fn open_to_network(&self) -> OpenOutcome {
        let Some(bytes) = self.plist_bytes() else { return OpenOutcome::Failed(NO_REMOTE_LISTEN.into()) };
        let Some((changed, port)) = program_arguments(&bytes).and_then(|a| opened_arguments(&a)) else { return OpenOutcome::Failed(NO_REMOTE_LISTEN.into()) };
        if self.ownership(true) != Ownership::Managed {
            return OpenOutcome::Failed(ADOPTED_OPEN.into());
        }
        let previous_pid = self.job(self.paths.label()).and_then(|j| j.pid);
        let backup = self.paths.backup_plist(&self.app_root);
        let plist = self.paths.plist();
        let written = (|| {
            std::fs::create_dir_all(backup.parent().unwrap_or(&self.app_root))?;
            std::fs::copy(&plist, &backup)?;
            let new = replace_arguments(&bytes, &changed).ok_or_else(|| std::io::Error::other("not a plist"))?;
            write_atomic(&plist, &new, 0o644)
        })();
        if let Err(e) = written {
            return OpenOutcome::Failed(format!("Could not write {}: {e}", file_name(&plist)));
        }
        begin_open(&mut self.prefs());
        let outcome = self.await_open(previous_pid, port, &backup);
        end_open(&mut self.prefs());
        outcome
    }

    fn await_open(&self, previous_pid: Option<i32>, port: u16, backup: &Path) -> OpenOutcome {
        if let Some(failure) = self.reload() {
            return self.rolled_back(failure, backup);
        }
        let origin = format!("http://127.0.0.1:{port}");
        let end = self.clock.now() + OPEN_DEADLINE;
        let mut check = OpenCheck::new(previous_pid);
        while self.clock.now() < end {
            self.clock.sleep(self.poll);
            let job = self.job(self.paths.label());
            let answered = job.is_some_and(|j| j.running && j.pid != previous_pid) && (self.probe)(&origin).is_some();
            if check.observe(job, answered) {
                if let Some(bytes) = self.plist_bytes() {
                    record_plist(&mut self.prefs(), &bytes);
                }
                return OpenOutcome::Opened;
            }
        }
        self.rolled_back(not_healthy(OPEN_DEADLINE), backup)
    }

    fn rolled_back(&self, reason: String, backup: &Path) -> OpenOutcome {
        match self.restore(backup) {
            Some(failure) => OpenOutcome::Failed(format!("{reason} The previous settings were restored, but: {failure}")),
            None => OpenOutcome::RolledBack(reason),
        }
    }

    /// `None` once the previous plist is back and loaded.
    fn restore(&self, backup: &Path) -> Option<String> {
        if let Err(e) = std::fs::rename(backup, self.paths.plist()) {
            return Some(format!("could not restore the plist: {e}"));
        }
        self.reload()
    }

    /// The app quit during an open's health window: nothing proved the new bind healthy, so the
    /// previous settings come back. Runs at launch.
    pub fn recover_interrupted_open(&self) {
        if take_interrupted_open(&mut self.prefs()) {
            let _ = self.restore(&self.paths.backup_plist(&self.app_root));
        }
    }

    /// bootout, wait for the job to go, bootstrap from the plist. `None` on success.
    fn reload(&self) -> Option<String> {
        let label = self.paths.label();
        if self.job(label).is_some() {
            self.bootout(label);
            self.wait_until_gone(label);
        }
        let result = self.bootstrap(&self.paths.plist());
        (!result.succeeded()).then(|| format!("launchctl bootstrap failed: {}", result.reason()))
    }

    // Install

    /// A new install, or a managed one whose plist is rendered again with its own bind.
    fn install(&self, listen: &str) -> Result<(), String> {
        if !self.helpers_present() {
            return Err(HELPERS_MISSING.into());
        }
        self.prepare_folders()?;
        if !self.paths.flowd().exists() {
            self.sync_helpers()?;
        }
        // flowd refuses to serve without the identity key; `init` refuses a second run.
        if !self.paths.database().exists() {
            let result = self.admin.run(&["init"]);
            if !result.succeeded() {
                return Err(format!("flowd admin init failed: {}", result.reason()));
            }
        }
        let rewriting = self.prepare_mtplx()?;
        let bytes = self.paths.flowd_plist(listen, rewriting, executable(&self.paths.meeting_processor()), self.analysis().as_ref());
        let plist = self.paths.plist();
        std::fs::create_dir_all(plist.parent().unwrap_or(Path::new("/"))).and_then(|_| write_atomic(&plist, &bytes, 0o644)).map_err(|e| format!("Could not write {}: {e}", file_name(&plist)))?;
        record_plist(&mut self.prefs(), &bytes);
        Ok(())
    }

    fn prepare_folders(&self) -> Result<(), String> {
        use std::os::unix::fs::PermissionsExt;
        for dir in [self.paths.bin_dir(), self.paths.log_dir()] {
            std::fs::create_dir_all(&dir).map_err(|e| format!("Could not create {}: {e}", dir.display()))?;
        }
        for dir in [self.paths.data_dir(), self.paths.log_dir()] {
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).map_err(|e| format!("Could not protect {}: {e}", dir.display()))?;
        }
        Ok(())
    }

    fn sync_helpers(&self) -> Result<(), String> {
        self.prepare_folders()?;
        let bin = self.paths.bin_dir();
        let failed = |name: &str| format!("Could not install {name}.");
        let optional = executable(&self.helpers().join(MEETING_PROCESSOR)).then_some(MEETING_PROCESSOR);
        for name in REQUIRED_HELPERS.into_iter().chain(optional) {
            copy_file(&self.helpers().join(name), &bin.join(name), 0o755).map_err(|_| failed(name))?;
        }
        copy_dir(&self.helpers().join(RESOURCE_BUNDLE), &bin.join(RESOURCE_BUNDLE)).map_err(|_| failed(RESOURCE_BUNDLE))?;
        // The worker reads the pinned descriptors next to itself.
        for name in DESCRIPTORS {
            copy_file(&self.resource(name), &bin.join(name), 0o644).map_err(|_| failed(name))?;
        }
        // The helper and model licences travel with the install (ADR 0019).
        let licenses = self.contents.join("Resources/WhisperLicenses");
        if licenses.is_dir() {
            copy_dir(&licenses, &bin.join("WhisperLicenses")).map_err(|_| failed("WhisperLicenses"))?;
        }
        self.prefs().set(HELPERS_STAMP_KEY, self.helpers_stamp());
        Ok(())
    }

    /// With the local AI runtime and a model the server gets its own MTPLX agent, key and wrapper,
    /// so the key never appears in a plist. An MTPLX plist already there is kept. False without one.
    fn prepare_mtplx(&self) -> Result<bool, String> {
        let mtplx = self.local_ai.join("venv/bin/mtplx");
        let model = std::fs::read_to_string(self.local_ai.join("model-path")).ok().map(|m| PathBuf::from(m.trim()));
        let Some(model) = model.filter(|m| executable(&mtplx) && m.exists()) else { return Ok(self.paths.mtplx_plist().exists()) };
        let key = self.paths.mtplx_key();
        if !key.exists() {
            write_new_key(&key).map_err(|_| format!("Could not write {}.", file_name(&key)))?;
        }
        let wrapper = self.paths.wrapper();
        write_atomic(&wrapper, WRAPPER_SCRIPT.as_bytes(), 0o755).map_err(|_| format!("Could not write {}.", file_name(&wrapper)))?;
        let plist = self.paths.mtplx_plist();
        if !plist.exists() {
            let bytes = self.paths.mtplx_plist_bytes(&mtplx, &model);
            std::fs::create_dir_all(plist.parent().unwrap_or(Path::new("/"))).and_then(|_| write_atomic(&plist, &bytes, 0o644)).map_err(|_| format!("Could not write {}.", file_name(&plist)))?;
        }
        Ok(true)
    }

    /// MTPLX first, so flowd's backend probe finds it. `disable` from an earlier turn-off also blocks
    /// bootstrap, so `enable` comes first.
    fn start(&self) -> Result<(), String> {
        if !self.paths.plist().exists() {
            return Err(NO_PLIST.into());
        }
        for (label, plist) in [(self.paths.mtplx_label(), self.paths.mtplx_plist()), (self.paths.label(), self.paths.plist())] {
            if !plist.exists() {
                continue;
            }
            self.launchctl(&["enable".into(), self.target(label)]);
            if self.job(label).is_none() {
                let result = self.bootstrap(&plist);
                if !result.succeeded() {
                    return Err(format!("launchctl bootstrap failed: {}", result.reason()));
                }
            }
        }
        Ok(())
    }

    // The analysis backend

    /// The stored backend as flowd starts with it, the key file passed only when it's private.
    fn analysis(&self) -> Option<Analysis> {
        let (url, model) = analysis_backend(&self.prefs())?;
        Some(Analysis { url, model, key_file: private_file(&self.paths.analysis_key()) })
    }

    pub fn analysis_backend(&self) -> Option<(String, String)> {
        analysis_backend(&self.prefs())
    }

    /// Stores the summaries backend in `server-mode.json` so flowd keeps it across restarts. A
    /// managed plist gets the flags (its new hash recorded, so it stays managed); a running flowd
    /// switches through the admin API, or is reloaded when that doesn't answer. An adopted server is
    /// refused and nothing changes.
    // ponytail: after a switch over the admin API launchd still holds the old arguments, so a crash
    // restart runs without the backend until the next reload or login.
    pub fn set_analysis_backend(&self, backend: Option<(&str, &str)>) -> Result<(), String> {
        check_analysis_backend(backend)?;
        let key = self.paths.analysis_key();
        if backend.is_some() && key.exists() && !private_file(&key) {
            return Err(ANALYSIS_KEY_NOT_PRIVATE.into());
        }
        let job = self.job(self.paths.label());
        match self.ownership(job.is_some()) {
            Ownership::Adopted => return Err(ADOPTED_ANALYSIS.into()),
            // The install writes it into the plist.
            Ownership::None => return store_analysis_backend(&mut self.prefs(), backend).map_err(String::from),
            Ownership::Managed => {}
        }
        let plist = self.paths.plist();
        let bytes = self.plist_bytes().ok_or(NO_PLIST)?;
        let analysis = backend.map(|(url, model)| Analysis { url: url.into(), model: model.into(), key_file: private_file(&key) });
        let arguments = program_arguments(&bytes).ok_or(NO_PLIST)?;
        let new = replace_arguments(&bytes, &self.paths.with_analysis(&arguments, analysis.as_ref())).ok_or(NO_PLIST)?;
        write_atomic(&plist, &new, 0o644).map_err(|e| format!("Could not write {}: {e}", file_name(&plist)))?;
        {
            let mut prefs = self.prefs();
            record_plist(&mut prefs, &new);
            store_analysis_backend(&mut prefs, backend)?;
        }
        match job {
            None => Ok(()),
            Some(j) if j.running && self.admin.put_analysis(backend).is_ok() => Ok(()),
            Some(_) => self.reload().map_or(Ok(()), Err),
        }
    }

    /// A summaries backend stored in `server-mode.json` that the managed plist doesn't carry yet
    /// (written there by hand, or by a build before the flags existed) goes into the plist.
    pub fn apply_stored_analysis(&self) {
        let Some((url, model)) = self.analysis_backend() else { return };
        if self.ownership(self.job(self.paths.label()).is_some()) != Ownership::Managed {
            return;
        }
        let Some(arguments) = self.plist_bytes().and_then(|b| program_arguments(&b)) else { return };
        if value_after(&arguments, "--analysis-backend") == Some(url.as_str()) && value_after(&arguments, "--analysis-model") == Some(model.as_str()) {
            return;
        }
        let _ = self.set_analysis_backend(Some((&url, &model)));
    }

    // The owner's first token (T031)

    pub fn owner_name(&self) -> String {
        let full = self.runner.run(Path::new("/usr/bin/id"), &["-F".into()]);
        Some(full.output.trim().to_string()).filter(|n| full.succeeded() && !n.is_empty()).unwrap_or_else(|| "Owner".into())
    }

    /// The token reaches only the returned value: the runner's arguments carry the label and
    /// addresses, and a failure reports stderr, which has no token.
    pub fn create_owner_token(&self, label: &str, addresses: &[String]) -> Result<OwnerToken, String> {
        self.admin.create_token(label, None, addresses)
    }
}

impl crate::ServerHost for ServerMode {
    fn status(&self) -> ServerModeStatus {
        ServerMode::status(self)
    }
    fn enabled(&self) -> bool {
        ServerMode::enabled(self)
    }
    fn addresses(&self, listen: Option<&str>) -> Vec<ServerAddress> {
        ServerMode::addresses(self, listen)
    }
    fn custom_address(&self) -> String {
        custom_address(&self.prefs())
    }
    fn set_custom_address(&self, text: &str) -> bool {
        set_custom_address(&mut self.prefs(), text)
    }
    fn plan_input(&self, physical_memory: u64, free_disk: Option<u64>, downloaded: [bool; 5]) -> PlanInput {
        ServerMode::plan_input(self, physical_memory, free_disk, downloaded)
    }
    fn install_language_model(&self, model_id: &str) -> Result<(), crate::Unavailable> {
        let model = *flow_core::onboarding::CATALOG.iter().find(|m| m.id == model_id).ok_or(crate::Unavailable("this model"))?;
        let log = self.paths.home.join("Library/Logs/LocalFlow/local-ai-setup.log");
        let install = crate::local_ai::Install { root: self.local_ai.clone(), resources: self.contents.join("Resources/LocalAI"), log, model, register_client_agents: false };
        crate::local_ai::start(install, NoClientAgents);
        Ok(())
    }
    fn language_model_phase(&self) -> Option<flow_core::onboarding::AiPhase> {
        crate::local_ai::phase()
    }
    fn download_models(&self, progress: &(dyn Fn(u64, u64) + Sync)) -> Result<(), String> {
        ServerMode::download_models(self, progress)
    }
    fn turn_on(&self) -> Result<(), String> {
        ServerMode::turn_on(self)
    }
    fn turn_off(&self) -> Result<(), String> {
        ServerMode::turn_off(self)
    }
    fn open_to_network(&self) -> OpenOutcome {
        ServerMode::open_to_network(self)
    }
    fn owner_name(&self) -> String {
        ServerMode::owner_name(self)
    }
    fn create_owner_token(&self, label: &str, addresses: &[String]) -> Result<OwnerToken, String> {
        ServerMode::create_owner_token(self, label, addresses)
    }
    fn launch(&self) {
        self.recover_interrupted_open();
        self.resync_if_updated();
        self.apply_stored_analysis();
    }
    fn users_page(&self) -> Result<flow_core::server_admin::Model, flow_core::server_admin::ReadError> {
        self.admin.users_page(flow_core::history::now_ms())
    }
    fn admin_act(&self, action: &flow_core::server_admin::Action) -> Result<(), String> {
        self.admin.act(action)
    }
    fn create_device_token(&self, label: &str, user: Option<i64>, addresses: &[String]) -> Result<OwnerToken, String> {
        self.admin.create_token(label, user, addresses)
    }
    fn analysis_backend(&self) -> Option<(String, String)> {
        ServerMode::analysis_backend(self)
    }
    fn set_analysis_backend(&self, backend: Option<(&str, &str)>) -> Result<(), String> {
        ServerMode::set_analysis_backend(self, backend)
    }
}

/// The server path never touches the client's agents (T024): `install` doesn't call these.
struct NoClientAgents;
impl crate::local_ai::Agents for NoClientAgents {
    fn loaded(&self, _: &str) -> bool {
        false
    }
    fn register(&self, _: &str) -> Result<(), String> {
        Err(flow_core::onboarding::AI_ERROR_REGISTRATION.into())
    }
    fn kickstart(&self, _: &str, _: bool) -> bool {
        false
    }
}

/// Development builds run only the `.dev` server, on 18090-18093 (T033).
pub fn dev_identity() -> bool {
    cfg!(debug_assertions)
}

fn text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// A regular file only this user can read or write, as flowd wants its key files.
fn private_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o077 == 0)
}

fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Through a staging file and a rename: a running helper keeps its old file, the next start gets the new one.
fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let stage = path.with_extension("new");
    std::fs::write(&stage, bytes)?;
    std::fs::set_permissions(&stage, std::fs::Permissions::from_mode(mode))?;
    std::fs::rename(stage, path)
}

fn copy_file(source: &Path, destination: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let stage = destination.with_extension("new");
    let _ = std::fs::remove_file(&stage);
    std::fs::copy(source, &stage)?;
    std::fs::set_permissions(&stage, std::fs::Permissions::from_mode(mode))?;
    std::fs::rename(stage, destination)
}

/// Replaces `destination` with a copy of the folder, symlinks kept as links.
fn copy_dir(source: &Path, destination: &Path) -> std::io::Result<()> {
    let _ = std::fs::remove_dir_all(destination);
    std::fs::create_dir_all(destination)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let (from, to) = (entry.path(), destination.join(entry.file_name()));
        let kind = entry.file_type()?;
        if kind.is_symlink() {
            std::os::unix::fs::symlink(std::fs::read_link(&from)?, &to)?;
        } else if kind.is_dir() {
            copy_dir(&from, &to)?;
        } else {
            std::fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

/// 32 random bytes as hex, created 0600 and never replaced.
fn write_new_key(path: &Path) -> std::io::Result<()> {
    use std::io::{Read, Write};
    use std::os::unix::fs::OpenOptionsExt;
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?.write_all(hex.as_bytes())
}

/// IPv4 and IPv6 addresses of interfaces that are up and running, without loopback.
pub fn interface_ips() -> Vec<String> {
    let mut ips = Vec::new();
    unsafe {
        let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut head) != 0 {
            return ips;
        }
        let mut cursor = head;
        while !cursor.is_null() {
            let entry = &*cursor;
            cursor = entry.ifa_next;
            let flags = entry.ifa_flags as i32;
            let address = entry.ifa_addr;
            if flags & libc::IFF_UP == 0 || flags & libc::IFF_RUNNING == 0 || flags & libc::IFF_LOOPBACK != 0 || address.is_null() {
                continue;
            }
            let family = (*address).sa_family as i32;
            if family != libc::AF_INET && family != libc::AF_INET6 {
                continue;
            }
            let mut host = [0 as libc::c_char; libc::NI_MAXHOST as usize];
            if libc::getnameinfo(address, (*address).sa_len as libc::socklen_t, host.as_mut_ptr(), host.len() as libc::socklen_t, std::ptr::null_mut(), 0, libc::NI_NUMERICHOST) == 0 {
                let ip = std::ffi::CStr::from_ptr(host.as_ptr()).to_string_lossy();
                ips.push(ip.split('%').next().unwrap_or_default().to_string());
            }
        }
        libc::freeifaddrs(head);
    }
    // The Tailscale name first: clients on the tailnet reach it however the IP changes.
    let names: Vec<String> = ips.iter().filter_map(|ip| tailscale_name(ip)).collect();
    names.into_iter().chain(ips).collect()
}

/// The MagicDNS name of a Tailscale IPv4 address (100.64.0.0/10), from reverse lookup.
fn tailscale_name(ip: &str) -> Option<String> {
    let v4: std::net::Ipv4Addr = ip.parse().ok()?;
    let b = v4.octets();
    if b[0] != 100 || b[1] & 0xc0 != 64 {
        return None;
    }
    let name = dns_lookup_name(v4)?;
    let name = name.trim_end_matches('.').to_ascii_lowercase();
    name.ends_with(".ts.net").then_some(name)
}

fn dns_lookup_name(v4: std::net::Ipv4Addr) -> Option<String> {
    unsafe {
        let mut addr: libc::sockaddr_in = std::mem::zeroed();
        addr.sin_len = std::mem::size_of::<libc::sockaddr_in>() as u8;
        addr.sin_family = libc::AF_INET as libc::sa_family_t;
        addr.sin_addr = libc::in_addr { s_addr: u32::from(v4).to_be() };
        let mut host = [0 as libc::c_char; libc::NI_MAXHOST as usize];
        let found = libc::getnameinfo(
            &addr as *const libc::sockaddr_in as *const libc::sockaddr,
            addr.sin_len as libc::socklen_t,
            host.as_mut_ptr(),
            host.len() as libc::socklen_t,
            std::ptr::null_mut(),
            0,
            libc::NI_NAMEREQD,
        );
        (found == 0).then(|| std::ffi::CStr::from_ptr(host.as_ptr()).to_string_lossy().into_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// A temp home with a development identity, so nothing here names the production agent or ports.
    fn dev_home(name: &str) -> (PathBuf, ServerModePaths) {
        let home = std::env::temp_dir().join(format!("flow-server-admin-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let paths = ServerModePaths::new(&home, true);
        std::fs::create_dir_all(paths.data_dir()).unwrap();
        (home, paths)
    }

    fn write_token(paths: &ServerModePaths, mode: u32) {
        std::fs::write(paths.admin_token(), "ab".repeat(32) + "\n").unwrap();
        std::fs::set_permissions(paths.admin_token(), std::fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn admin_runs_the_data_directorys_own_flowd() {
        let (home, paths) = dev_home("run");
        let runner = RecordingRunner::new();
        runner.answer_runs(|_, args| if args.last().is_some_and(|a| a == "list") { ProcessResult::ok("user 1\n") } else { ProcessResult::failed(1, "locked\nmore") });
        let admin = ServerAdmin::new(paths.clone(), runner.clone());
        assert_eq!(admin.run(&["list"]).output, "user 1\n");
        let failed = admin.run(&["init"]);
        assert!(!failed.succeeded());
        assert_eq!(failed.reason(), "locked");
        let data = paths.data_dir().to_string_lossy().into_owned();
        assert_eq!(runner.runs(), [(paths.flowd(), vec!["admin".to_string(), "--data-dir".into(), data.clone(), "--dev".into(), "list".into()]), (paths.flowd(), vec!["admin".into(), "--data-dir".into(), data, "--dev".into(), "init".into()])]);
        assert!(paths.flowd().starts_with(paths.data_dir().join("bin")), "never the app's copy");
        assert_eq!(ProcessResult::failed(3, "").reason(), "exit 3");
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn admin_status_reads_the_private_token_and_asks_loopback() {
        let (home, paths) = dev_home("status");
        let runner = RecordingRunner::new();
        runner.answer_gets(|_| Ok((200, br#"{"version":"1","counters":{}}"#.to_vec())));
        let admin = ServerAdmin::new(paths.clone(), runner.clone());
        assert_eq!(admin.admin_status(), Err(AdminError::NoToken));
        assert!(runner.calls().is_empty(), "no token, no request");
        write_token(&paths, 0o600);
        assert_eq!(admin.admin_status().unwrap()["version"], "1");
        let url = format!("http://127.0.0.1:{}/v1/admin/status", paths.admin_port());
        assert_eq!(runner.calls(), [RecordedCall::Get { url, bearer: "ab".repeat(32) }]);
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn a_token_other_users_can_read_is_refused() {
        let (home, paths) = dev_home("mode");
        let runner = RecordingRunner::new();
        let admin = ServerAdmin::new(paths.clone(), runner.clone());
        for mode in [0o644, 0o640, 0o604] {
            write_token(&paths, mode);
            assert_eq!(admin.admin_status(), Err(AdminError::TokenNotPrivate), "{mode:o}");
        }
        assert!(runner.calls().is_empty());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn admin_status_failures() {
        let (home, paths) = dev_home("fail");
        write_token(&paths, 0o600);
        let runner = RecordingRunner::new();
        let admin = ServerAdmin::new(paths, runner.clone());
        assert_eq!(admin.admin_status(), Err(AdminError::Unreachable), "the default fake answers nothing");
        runner.answer_gets(|_| Ok((403, b"forbidden".to_vec())));
        assert_eq!(admin.admin_status(), Err(AdminError::Refused(403)));
        runner.answer_gets(|_| Ok((200, b"[1]".to_vec())));
        assert_eq!(admin.admin_status(), Err(AdminError::Invalid));
        std::fs::remove_dir_all(home).unwrap();
    }

    /// T045: each owner action runs the data directory's flowd with exactly these arguments.
    #[test]
    fn admin_actions_pass_exact_arguments() {
        use flow_core::server_admin::{Action::*, Kind};
        let (home, paths) = dev_home("actions");
        let runner = RecordingRunner::new();
        runner.answer_runs(|_, args| match args.iter().position(|a| a == "create") {
            Some(_) if args.contains(&"token".to_string()) => ProcessResult::ok(r#"{"id":4,"label":"x","expires_at":"2026-11-05T10:00:00Z","token":"lfp_secret","link":"localflow://pair#token=lfp_secret"}"#),
            _ if args.last().is_some_and(|a| a == "9") => ProcessResult::failed(2, "device 9 not found"),
            _ => ProcessResult::ok(""),
        });
        let admin = ServerAdmin::new(paths.clone(), runner.clone());
        for action in [Approve(Kind::User, 1), Approve(Kind::Device, 2), Reject(3), Revoke(Kind::User, 4), Revoke(Kind::Device, 5), Rename(Kind::Device, 6, "Ana's Mac; rm -rf".into()), Rename(Kind::User, 7, "Ana".into()), CreateUser("Ben".into()), RevokeToken(8)] {
            assert_eq!(admin.act(&action), Ok(()), "{action:?}");
        }
        assert_eq!(admin.act(&Approve(Kind::Device, 9)), Err("device 9 not found".into()));
        let token = admin.create_token("Ana's iPhone", Some(7), &["https://m.example".into()]).unwrap();
        assert_eq!(token.token, "lfp_secret");
        admin.create_token("New person", None, &[]).unwrap();
        let prefix = ["admin".to_string(), "--data-dir".into(), paths.data_dir().to_string_lossy().into_owned(), "--dev".into()];
        let tails: Vec<Vec<String>> = runner.runs().into_iter().map(|(program, args)| {
            assert_eq!(program, paths.flowd());
            assert_eq!(args[..4], prefix);
            args[4..].to_vec()
        }).collect();
        let want: Vec<Vec<&str>> = vec![
            vec!["approve", "user", "1"],
            vec!["approve", "device", "2"],
            vec!["reject", "user", "3"],
            vec!["revoke", "user", "4"],
            vec!["revoke", "device", "5"],
            vec!["rename", "device", "6", "--name", "Ana's Mac; rm -rf"],
            vec!["rename", "user", "7", "--name", "Ana"],
            vec!["user", "create", "--name", "Ben", "--json"],
            vec!["token", "revoke", "8"],
            vec!["approve", "device", "9"],
            vec!["token", "create", "--label", "Ana's iPhone", "--user", "7", "--ttl", "24h", "--address", "https://m.example", "--json"],
            vec!["token", "create", "--label", "New person", "--ttl", "24h", "--json"],
        ];
        assert_eq!(tails, want);
        std::fs::remove_dir_all(home).unwrap();
    }

    /// T044: the page reads the three `--json` outputs and the live channels; an old flowd is
    /// "needs updating", and a missing admin token still shows the list.
    #[test]
    fn the_users_page_reads_json_and_channels() {
        use flow_core::server_admin::ReadError;
        let (home, paths) = dev_home("users");
        let runner = RecordingRunner::new();
        runner.answer_runs(|_, args| match args[4].as_str() {
            "list" => ProcessResult::ok(include_str!("../../../fixtures/server-admin/list.json")),
            "token" => ProcessResult::ok(include_str!("../../../fixtures/server-admin/tokens.json")),
            _ => ProcessResult::ok(include_str!("../../../fixtures/server-admin/audit.json")),
        });
        runner.answer_gets(|_| Ok((200, br#"{"channels":{"open":1,"devices":[{"device_id":2,"channels":1}]}}"#.to_vec())));
        let admin = ServerAdmin::new(paths.clone(), runner.clone());
        let page = admin.users_page(0).unwrap();
        assert!(!page.users[0].devices[1].connected, "no admin token yet, so nobody shows as connected");
        write_token(&paths, 0o600);
        let page = admin.users_page(0).unwrap();
        assert!(page.users[0].devices[1].connected && !page.users[0].devices[0].connected);
        assert_eq!(page.tokens.len(), 2);
        let args: Vec<Vec<String>> = runner.runs().into_iter().take(3).map(|(_, a)| a[4..].to_vec()).collect();
        assert_eq!(args, [vec!["list", "--json"], vec!["token", "list", "--json"], vec!["audit", "--limit", "50", "--json"]]);
        runner.answer_runs(|_, _| ProcessResult::failed(1, "flowd: usage: flowd admin …"));
        assert_eq!(admin.users_page(0), Err(ReadError::NeedsUpdate));
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn the_system_runner_reports_what_it_could_not_start() {
        let result = SystemRunner.run(Path::new("/nonexistent/flowd"), &[]);
        assert_eq!((result.status, result.reason()), (-1, "could not start /nonexistent/flowd".to_string()));
        let echoed = SystemRunner.run(Path::new("/bin/sh"), &["-c".into(), "printf out; printf err >&2; exit 4".into()]);
        assert_eq!(echoed, ProcessResult { status: 4, output: "out".into(), error: "err".into() });
    }

    // ServerMode (T025, T031, T033)

    use std::collections::HashMap;

    struct Rig {
        home: PathBuf,
        mode: ServerMode,
        runner: Arc<RecordingRunner>,
        answers: Arc<Mutex<bool>>,
        client_prefs: PathBuf,
    }

    fn executable_file(path: &Path, body: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// An app bundle with fake helpers, a launchd that keeps loaded jobs in a map, and a flowd that
    /// answers `admin init`, `list` and `token create`. Development identity only.
    fn rig(name: &str) -> Rig {
        let (home, paths) = dev_home(&format!("mode-{name}"));
        let contents = home.join("LocalFlow.app/Contents");
        for helper in REQUIRED_HELPERS {
            executable_file(&contents.join("Helpers").join(helper), "#!/bin/sh\n");
        }
        std::fs::create_dir_all(contents.join("Helpers").join(RESOURCE_BUNDLE).join("Inner")).unwrap();
        std::fs::write(contents.join("Helpers").join(RESOURCE_BUNDLE).join("Inner/x"), "x").unwrap();
        for name in DESCRIPTORS {
            let file = format!(r#"{{"files":[{{"path":"{name}.bin","size":4}}]}}"#);
            std::fs::create_dir_all(contents.join("Resources/Models")).unwrap();
            std::fs::write(contents.join("Resources/Models").join(name), file).unwrap();
        }
        let app_root = home.join("app");
        std::fs::create_dir_all(&app_root).unwrap();
        // The client's own settings, which server mode must never change.
        let client_prefs = app_root.join("preferences.json");
        std::fs::write(&client_prefs, r#"{"dictation.model":"parakeet-v3","rewrite.enabled":true}"#).unwrap();

        let runner = RecordingRunner::new();
        let jobs: Arc<Mutex<HashMap<String, i32>>> = Arc::default();
        let database = paths.database();
        let mut next_pid = 100;
        runner.answer_runs(move |program, args| {
            let mut jobs = jobs.lock().unwrap();
            let label = |target: &str| target.rsplit('/').next().unwrap().to_string();
            match (program.to_str().unwrap(), args.first().map(String::as_str).unwrap_or("")) {
                (LAUNCHCTL, "print") => match jobs.get(&label(&args[1])) {
                    Some(pid) => ProcessResult::ok(format!("\tstate = running\n\tpid = {pid}\n")),
                    None => ProcessResult::failed(113, "Could not find service"),
                },
                (LAUNCHCTL, "bootstrap") => {
                    next_pid += 1;
                    jobs.insert(Path::new(&args[2]).file_stem().unwrap().to_string_lossy().into_owned(), next_pid);
                    ProcessResult::ok("")
                }
                (LAUNCHCTL, "bootout") => {
                    jobs.remove(&label(&args[1]));
                    ProcessResult::ok("")
                }
                (LAUNCHCTL, _) => ProcessResult::ok(""),
                ("/usr/bin/id", _) => ProcessResult::ok("Oliver Owner\n"),
                (p, "provision") if p.ends_with("flowd-speech") => ProcessResult { status: 0, output: String::new(), error: "provision model=m state=downloading completed=4 total=9\nprovision model=m state=verified\n".into() },
                (p, "admin") if p.ends_with("flowd") => match args.last().unwrap().as_str() {
                    "init" => {
                        std::fs::write(&database, "").unwrap();
                        ProcessResult::ok("")
                    }
                    "list" => ProcessResult::ok("user 1 owner\n  device 2 last seen 2026-11-04\n"),
                    "--json" => ProcessResult::ok(r#"{"id":"t1","label":"Owner","expires_at":"2026-11-05T10:00:00Z","token":"lfp_secret","link":"localflow://pair?token=lfp_secret"}"#),
                    _ => ProcessResult::failed(2, "unknown"),
                },
                _ => ProcessResult::failed(-1, "unexpected"),
            }
        });
        let mut mode = ServerMode::new(paths, runner.clone(), contents, app_root, home.join("LocalAI"), 501);
        let answers = Arc::new(Mutex::new(true));
        let answering = answers.clone();
        mode.clock = Arc::new(FakeClock::default());
        mode.probe = Arc::new(move |_| answering.lock().unwrap().then(|| "fp-1".to_string()));
        mode.interfaces = Arc::new(|| vec!["192.168.1.20".into()]);
        Rig { home, mode, runner, answers, client_prefs }
    }

    fn listen(mode: &ServerMode) -> Option<String> {
        value_after(&mode.plist_arguments()?, "--remote-listen").map(String::from)
    }

    fn launchctl_args(runner: &RecordingRunner) -> Vec<Vec<String>> {
        runner.runs().into_iter().filter(|(p, _)| p == Path::new(LAUNCHCTL)).map(|(_, a)| a).collect()
    }

    /// T033: every launchctl call names the development agents, never `org.localflow.LocalFlow.remote[.mtplx]`.
    fn assert_dev_labels_only(runner: &RecordingRunner) {
        for args in launchctl_args(runner) {
            assert!(args.iter().all(|a| !a.contains("org.localflow.LocalFlow.remote")), "production label in {args:?}");
        }
    }

    #[test]
    fn turning_on_installs_a_loopback_server_and_off_keeps_its_data() {
        let r = rig("on-off");
        let before = std::fs::read(&r.client_prefs).unwrap();
        assert_eq!(r.mode.status().ownership, Ownership::None);
        r.mode.turn_on().unwrap();
        assert!(r.mode.enabled());
        assert_eq!(listen(&r.mode), Some(format!("127.0.0.1:{}", r.mode.paths.remote_port())), "nothing reachable before the owner opens it");
        let status = r.mode.status();
        assert_eq!((status.ownership, status.loaded, status.running), (Ownership::Managed, true, true));
        assert_eq!(status.fingerprint.as_deref(), Some("fp-1"));
        assert!(status.client_connected);
        assert_eq!(status.missing_model_bytes, 12, "three models of 4 bytes each");
        assert!(status.missing.contains(&models_missing("Dictation")));
        assert!(r.mode.addresses(status.listen.as_deref()).is_empty(), "loopback has no address to show");
        for helper in REQUIRED_HELPERS {
            assert!(executable(&r.mode.paths.bin_dir().join(helper)), "{helper}");
        }
        assert!(r.mode.paths.bin_dir().join(RESOURCE_BUNDLE).join("Inner/x").exists());
        assert!(r.mode.paths.bin_dir().join("parakeet-v3.json").exists());
        assert!(r.mode.paths.database().exists());
        let data_mode = std::fs::metadata(r.mode.paths.data_dir()).unwrap().permissions().mode() & 0o777;
        assert_eq!(data_mode, 0o700);

        r.mode.turn_off().unwrap();
        assert!(!r.mode.enabled());
        assert!(!r.mode.status().loaded);
        assert!(r.mode.paths.database().exists() && r.mode.paths.plist().exists(), "off deletes nothing");
        let args = launchctl_args(&r.runner);
        assert!(args.contains(&vec!["bootout".into(), format!("gui/501/{}", r.mode.paths.label())]));
        assert!(args.contains(&vec!["disable".into(), format!("gui/501/{}", r.mode.paths.label())]));

        r.mode.turn_on().unwrap();
        assert!(r.mode.status().running, "on again after off: enable comes before bootstrap");
        assert_eq!(std::fs::read(&r.client_prefs).unwrap(), before, "the client's dictation and rewrite settings are untouched");
        assert!(r.mode.app_root.join("server-mode.json").exists());
        assert_dev_labels_only(&r.runner);
        std::fs::remove_dir_all(r.home).unwrap();
    }

    #[test]
    fn opening_to_the_network_rewrites_only_the_bind_once_healthy() {
        let r = rig("open");
        r.mode.turn_on().unwrap();
        let before = program_arguments(&std::fs::read(r.mode.paths.plist()).unwrap()).unwrap();
        assert_eq!(r.mode.open_to_network(), OpenOutcome::Opened);
        let after = r.mode.plist_arguments().unwrap();
        let port = r.mode.paths.remote_port();
        assert_eq!(after, opened_arguments(&before).unwrap().0);
        assert_eq!(listen(&r.mode), Some(format!("0.0.0.0:{port}")));
        assert_eq!(r.mode.status().ownership, Ownership::Managed, "the new plist is recorded as this app's");
        assert_eq!(r.mode.addresses(Some(&format!("0.0.0.0:{port}")))[0].origin, format!("http://192.168.1.20:{port}"));
        assert!(!take_interrupted_open(&mut r.mode.prefs()), "the pending marker is cleared");
        assert_dev_labels_only(&r.runner);
        std::fs::remove_dir_all(r.home).unwrap();
    }

    #[test]
    fn an_open_that_never_answers_is_rolled_back_after_sixty_seconds() {
        let r = rig("rollback");
        r.mode.turn_on().unwrap();
        let before = std::fs::read(r.mode.paths.plist()).unwrap();
        *r.answers.lock().unwrap() = false;
        let start = r.mode.clock.now();
        let OpenOutcome::RolledBack(reason) = r.mode.open_to_network() else { panic!("expected a rollback") };
        assert_eq!(reason, not_healthy(OPEN_DEADLINE));
        assert!(r.mode.clock.now() - start >= OPEN_DEADLINE);
        assert_eq!(std::fs::read(r.mode.paths.plist()).unwrap(), before, "the previous plist is back");
        assert_eq!(r.mode.status().ownership, Ownership::Managed);
        assert!(r.mode.status().loaded, "and loaded again");
        std::fs::remove_dir_all(r.home).unwrap();
    }

    #[test]
    fn an_open_cut_short_by_quitting_is_restored_at_launch() {
        let r = rig("interrupted");
        r.mode.turn_on().unwrap();
        let before = std::fs::read(r.mode.paths.plist()).unwrap();
        let backup = r.mode.paths.backup_plist(&r.mode.app_root);
        std::fs::create_dir_all(backup.parent().unwrap()).unwrap();
        std::fs::copy(r.mode.paths.plist(), &backup).unwrap();
        std::fs::write(r.mode.paths.plist(), b"half-written").unwrap();
        begin_open(&mut r.mode.prefs());
        crate::ServerHost::launch(&r.mode);
        assert_eq!(std::fs::read(r.mode.paths.plist()).unwrap(), before);
        std::fs::remove_dir_all(r.home).unwrap();
    }

    #[test]
    fn a_server_set_up_elsewhere_is_started_but_never_rewritten() {
        let r = rig("adopted");
        let foreign = r.mode.paths.flowd_plist("0.0.0.0:9999", false, false, None);
        std::fs::create_dir_all(r.mode.paths.plist().parent().unwrap()).unwrap();
        std::fs::write(r.mode.paths.plist(), &foreign).unwrap();
        std::fs::create_dir_all(r.mode.paths.bin_dir()).unwrap();
        assert_eq!(r.mode.status().ownership, Ownership::Adopted);
        r.mode.turn_on().unwrap();
        assert!(r.mode.status().running);
        assert_eq!(r.mode.open_to_network(), OpenOutcome::Failed(ADOPTED_OPEN.into()));
        assert_eq!(std::fs::read(r.mode.paths.plist()).unwrap(), foreign);
        assert!(!r.mode.paths.database().exists(), "no admin init on someone else's server");
        assert_eq!(r.mode.download_models(&|_, _| {}), Err(HELPERS_MISSING.into()), "no flowd-speech of its own to run");
        r.mode.turn_off().unwrap();
        assert_eq!(std::fs::read(r.mode.paths.plist()).unwrap(), foreign);
        std::fs::remove_dir_all(r.home).unwrap();
    }

    const BACKEND: (&str, &str) = ("http://127.0.0.1:8443/v1", "smart");

    fn write_analysis_key(paths: &ServerModePaths, mode: u32) {
        std::fs::write(paths.analysis_key(), "sk-local\n").unwrap();
        std::fs::set_permissions(paths.analysis_key(), std::fs::Permissions::from_mode(mode)).unwrap();
    }

    fn calls_after(runner: &RecordingRunner, before: usize) -> Vec<RecordedCall> {
        runner.calls()[before..].to_vec()
    }

    fn stored(mode: &ServerMode) -> serde_json::Value {
        serde_json::from_slice(&std::fs::read(mode.app_root.join("server-mode.json")).unwrap()).unwrap()
    }

    #[test]
    fn the_analysis_backend_goes_into_the_managed_plist_and_the_running_flowd() {
        let r = rig("analysis");
        let client_before = std::fs::read(&r.client_prefs).unwrap();
        r.mode.turn_on().unwrap();
        write_token(&r.mode.paths, 0o600);
        write_analysis_key(&r.mode.paths, 0o600);
        r.runner.answer_puts(|_, _| Ok((200, b"{}".to_vec())));
        let before = r.runner.calls().len();
        r.mode.set_analysis_backend(Some(BACKEND)).unwrap();

        let args = r.mode.plist_arguments().unwrap();
        assert_eq!(value_after(&args, "--analysis-backend"), Some(BACKEND.0));
        assert_eq!(value_after(&args, "--analysis-model"), Some(BACKEND.1));
        assert_eq!(value_after(&args, "--analysis-backend-key-file"), Some(r.mode.paths.analysis_key().to_str().unwrap()));
        assert_eq!(r.mode.status().ownership, Ownership::Managed, "the new hash is recorded");
        assert_eq!(r.mode.analysis_backend(), Some((BACKEND.0.into(), BACKEND.1.into())));
        assert_eq!((stored(&r.mode)["serverMode.analysisBackend"].as_str(), stored(&r.mode)["serverMode.analysisModel"].as_str()), (Some(BACKEND.0), Some(BACKEND.1)));
        let calls = calls_after(&r.runner, before);
        let url = format!("http://127.0.0.1:{}/v1/admin/analysis", r.mode.paths.admin_port());
        assert!(calls.contains(&RecordedCall::Put { url, bearer: "ab".repeat(32), body: r#"{"backend":"http://127.0.0.1:8443/v1","model":"smart"}"#.into() }));
        assert!(!calls.iter().any(|c| matches!(c, RecordedCall::Run { args, .. } if args[0] == "bootout")), "switched live, no restart");
        assert!(!std::fs::read_to_string(r.mode.paths.plist()).unwrap().contains("sk-local"), "the key stays in its file");

        // A restart renders the plist again with the same flags.
        r.mode.turn_off().unwrap();
        r.mode.turn_on().unwrap();
        assert_eq!(value_after(&r.mode.plist_arguments().unwrap(), "--analysis-backend"), Some(BACKEND.0));

        // Cleared: the flags go and flowd is told to use the rewrite model.
        let before = r.runner.calls().len();
        r.mode.set_analysis_backend(None).unwrap();
        assert!(r.mode.plist_arguments().unwrap().iter().all(|a| !a.starts_with("--analysis")));
        assert_eq!(r.mode.analysis_backend(), None);
        assert!(calls_after(&r.runner, before).iter().any(|c| matches!(c, RecordedCall::Put { body, .. } if body == r#"{"backend":"","model":""}"#)));
        assert_eq!(std::fs::read(&r.client_prefs).unwrap(), client_before, "the client's preferences are untouched");
        assert_dev_labels_only(&r.runner);
        std::fs::remove_dir_all(r.home).unwrap();
    }

    #[test]
    fn a_stored_analysis_backend_reaches_the_plist_at_launch_once() {
        let r = rig("analysis-launch");
        r.mode.turn_on().unwrap();
        write_token(&r.mode.paths, 0o600);
        write_analysis_key(&r.mode.paths, 0o600);
        r.runner.answer_puts(|_, _| Ok((200, b"{}".to_vec())));
        store_analysis_backend(&mut r.mode.prefs(), Some(BACKEND)).unwrap();
        r.mode.apply_stored_analysis();
        let args = r.mode.plist_arguments().unwrap();
        assert_eq!((value_after(&args, "--analysis-backend"), value_after(&args, "--analysis-model")), (Some(BACKEND.0), Some(BACKEND.1)));
        assert_eq!(r.mode.status().ownership, Ownership::Managed);
        let before = r.runner.calls().len();
        r.mode.apply_stored_analysis();
        assert!(!calls_after(&r.runner, before).iter().any(|c| matches!(c, RecordedCall::Put { .. })), "already applied");
        assert_dev_labels_only(&r.runner);
        std::fs::remove_dir_all(r.home).unwrap();
    }

    #[test]
    fn without_the_admin_api_flowd_is_reloaded_and_without_a_key_file_no_key_flag() {
        let r = rig("analysis-reload");
        r.mode.turn_on().unwrap();
        let before = r.runner.calls().len();
        r.mode.set_analysis_backend(Some(BACKEND)).unwrap();
        let args = r.mode.plist_arguments().unwrap();
        assert_eq!(value_after(&args, "--analysis-backend"), Some(BACKEND.0));
        assert!(!args.contains(&"--analysis-backend-key-file".to_string()), "no key file, no flag");
        let runs: Vec<String> = calls_after(&r.runner, before).into_iter().filter_map(|c| if let RecordedCall::Run { args, .. } = c { Some(args[0].clone()) } else { None }).collect();
        let bootout = runs.iter().position(|a| a == "bootout").expect("no admin token: reloaded");
        assert!(runs[bootout..].contains(&"bootstrap".to_string()));
        assert!(r.mode.status().running);
        assert_eq!(r.mode.status().ownership, Ownership::Managed);
        std::fs::remove_dir_all(r.home).unwrap();
    }

    #[test]
    fn a_backend_set_before_the_install_is_in_its_first_plist() {
        let r = rig("analysis-first");
        write_analysis_key(&r.mode.paths, 0o600);
        r.mode.set_analysis_backend(Some(BACKEND)).unwrap();
        assert!(!r.mode.paths.plist().exists(), "nothing written before the owner turns it on");
        r.mode.turn_on().unwrap();
        let args = r.mode.plist_arguments().unwrap();
        assert_eq!(value_after(&args, "--analysis-model"), Some(BACKEND.1));
        assert!(args.contains(&"--analysis-backend-key-file".to_string()));
        std::fs::remove_dir_all(r.home).unwrap();
    }

    #[test]
    fn an_analysis_backend_is_refused_for_an_adopted_server_a_remote_url_or_a_shared_key() {
        let r = rig("analysis-refused");
        let client_before = std::fs::read(&r.client_prefs).unwrap();
        let foreign = r.mode.paths.flowd_plist("0.0.0.0:9999", false, false, None);
        std::fs::create_dir_all(r.mode.paths.plist().parent().unwrap()).unwrap();
        std::fs::write(r.mode.paths.plist(), &foreign).unwrap();
        r.mode.turn_on().unwrap();
        assert_eq!(r.mode.set_analysis_backend(Some(BACKEND)), Err(ADOPTED_ANALYSIS.into()));
        assert_eq!(r.mode.set_analysis_backend(None), Err(ADOPTED_ANALYSIS.into()));
        assert_eq!(std::fs::read(r.mode.paths.plist()).unwrap(), foreign, "never rewritten");
        assert_eq!(r.mode.analysis_backend(), None);
        assert!(stored(&r.mode).get("serverMode.analysisBackend").is_none());
        assert!(!r.runner.calls().iter().any(|c| matches!(c, RecordedCall::Put { .. })), "nor switched live");

        let r2 = rig("analysis-invalid");
        r2.mode.turn_on().unwrap();
        let plist = std::fs::read(r2.mode.paths.plist()).unwrap();
        let before = r2.runner.calls().len();
        for (url, model, why) in [("http://192.168.1.20:8443/v1", "smart", ANALYSIS_NOT_LOOPBACK), ("http://example.com/v1", "smart", ANALYSIS_NOT_LOOPBACK), ("http://u:p@127.0.0.1/v1", "smart", ANALYSIS_NOT_LOOPBACK), ("http://127.0.0.1:8443/v1", "", ANALYSIS_BAD_MODEL)] {
            assert_eq!(r2.mode.set_analysis_backend(Some((url, model))), Err(why.into()), "{url}");
        }
        let long = "m".repeat(129);
        assert_eq!(r2.mode.set_analysis_backend(Some((BACKEND.0, &long))), Err(ANALYSIS_BAD_MODEL.into()));
        write_analysis_key(&r2.mode.paths, 0o644);
        assert_eq!(r2.mode.set_analysis_backend(Some(BACKEND)), Err(ANALYSIS_KEY_NOT_PRIVATE.into()));
        assert_eq!(std::fs::read(r2.mode.paths.plist()).unwrap(), plist);
        assert_eq!(r2.mode.analysis_backend(), None);
        assert!(calls_after(&r2.runner, before).is_empty(), "refused before touching launchd or flowd");
        assert_eq!(std::fs::read(&r.client_prefs).unwrap(), client_before);
        std::fs::remove_dir_all(r.home).unwrap();
        std::fs::remove_dir_all(r2.home).unwrap();
    }

    #[test]
    fn models_download_with_flowd_stopped_and_report_progress() {
        let r = rig("models");
        r.mode.turn_on().unwrap();
        let seen = Mutex::new(Vec::new());
        r.mode.download_models(&|done, total| seen.lock().unwrap().push((done, total))).unwrap();
        assert_eq!(*seen.lock().unwrap(), [(4, 9)]);
        let runs = r.runner.runs();
        let provision = runs.iter().position(|(p, _)| p.ends_with("flowd-speech")).unwrap();
        let worker_args = &runs[provision].1;
        assert_eq!(worker_args[..2], ["provision".to_string(), "--models".into()]);
        assert_eq!(runs[provision - 1].1, vec!["print".to_string(), format!("gui/501/{}", r.mode.paths.label())], "waited for flowd to go");
        assert_eq!(runs[provision + 1].1[0], "bootstrap", "and brought it back");
        assert_dev_labels_only(&r.runner);
        std::fs::remove_dir_all(r.home).unwrap();
    }

    #[test]
    fn the_owner_token_stays_in_memory() {
        let r = rig("token");
        r.mode.turn_on().unwrap();
        assert_eq!(r.mode.owner_name(), "Oliver Owner");
        let token = r.mode.create_owner_token("Oliver Owner", &["http://192.168.1.20:18090".into()]).unwrap();
        assert_eq!((token.token.as_str(), token.expires_at.as_str()), ("lfp_secret", "2026-11-05T10:00:00Z"));
        assert!(!format!("{token:?}").contains("lfp_"));
        let create = r.runner.runs().into_iter().find(|(_, a)| a.contains(&"create".to_string())).unwrap().1;
        assert!(create.ends_with(&["token".into(), "create".into(), "--label".into(), "Oliver Owner".into(), "--ttl".into(), "24h".into(), "--address".into(), "http://192.168.1.20:18090".into(), "--json".into()]));
        fn files(dir: &Path, out: &mut Vec<PathBuf>) {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let path = entry.path();
                if entry.file_type().unwrap().is_dir() { files(&path, out) } else { out.push(path) }
            }
        }
        let mut written = Vec::new();
        files(&r.home, &mut written);
        assert!(written.len() > 5);
        for file in written {
            assert!(!String::from_utf8_lossy(&std::fs::read(&file).unwrap()).contains("lfp_"), "{}", file.display());
        }
        std::fs::remove_dir_all(r.home).unwrap();
    }
}
