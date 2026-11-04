//! Server mode (Feature 028, research R6 and R7): the pure half of Swift's `ServerModeController`.
//! Labels, ports, folders, argument lists, plist bytes, ownership, addresses and the model plan.
//! The platform crate's `server_mode_mac` runs launchctl, copies files and starts processes with these.
use crate::onboarding::{CATALOG, bytes, default_model};
use crate::prefs::Prefs;
use crate::remote::address::{ServerAddressKind, origin, server_address_kind};
use std::path::{Path, PathBuf};

/// `setup.role`: `client` or `server`; absent means `client`.
pub const ROLE_KEY: &str = "setup.role";
pub const ENABLED_KEY: &str = "serverMode.enabled";
pub const CUSTOM_ADDRESS_KEY: &str = "serverMode.customAddress";
/// The hash of the plist this app wrote. Swift's value lives in its own defaults and is never read.
pub const PLIST_HASH_KEY: &str = "serverMode.plistSHA256";
pub const OPEN_PENDING_KEY: &str = "serverMode.openPending";
pub const HELPERS_STAMP_KEY: &str = "serverMode.helpersStamp";

/// Helpers a server can't run without, from the app's `Contents/Helpers`.
pub const REQUIRED_HELPERS: [&str; 3] = ["flowd", "flowd-speech", "localflow-whisper-engine"];
/// The meeting handoff processor; without it flowd leaves the handoff op off (research R8).
pub const MEETING_PROCESSOR: &str = "flowd-meeting";
pub const RESOURCE_BUNDLE: &str = "FluidAudio_FluidAudio.bundle";
/// Pinned descriptors the worker reads next to itself.
pub const DESCRIPTORS: [&str; 4] = ["parakeet-v3.json", "parakeet-ctc-110m.json", "whisper-large-v3-turbo.json", "speaker-diarization-offline.json"];
/// The models the server needs, as `flowd-speech provision --meeting` fetches them: (descriptor,
/// folder under `<data>/Models`, service it serves).
pub const SERVER_MODELS: [(&str, &str, &str); 3] = [
    ("parakeet-v3.json", "parakeet-v3", "Dictation"),
    ("whisper-large-v3-turbo.json", "whisper-large-v3-turbo", "Meetings"),
    ("speaker-diarization-offline.json", "speaker-diarization-offline/speaker-diarization", "Meetings"),
];

pub const HELPERS_MISSING: &str = "This build of LocalFlow doesn't include the server helpers.";
pub const NO_PLIST: &str = "The server's launch agent has no plist to start from.";
pub const NO_REMOTE_LISTEN: &str = "This server's plist has no --remote-listen to change.";
pub const REWRITING_MISSING: &str = "Rewriting and summaries: set up local AI in LocalFlow, then turn server mode off and on.";
pub const HANDOFF_MISSING: &str = "Meetings sent from a phone: this server has no flowd-meeting.";

/// `"<service>: models not downloaded."`
pub fn models_missing(service: &str) -> String {
    format!("{service}: models not downloaded.")
}

/// Starts flowd with the server MTPLX key from the file named by `$1`, so the key never sits in a plist.
pub const WRAPPER_SCRIPT: &str = "#!/bin/sh\n# Starts flowd with the server MTPLX key from the file named by $1.\nset -eu\nkey_file=\"$1\"\nshift\nLOCALFLOW_BACKEND_TOKEN=\"$(cat \"$key_file\")\"\n[ -n \"$LOCALFLOW_BACKEND_TOKEN\" ]\nexport LOCALFLOW_BACKEND_TOKEN\nexec \"$@\"\n";

/// The MTPLX agent's environment: memory caps, and warmup only for the 512-token class rewrites use.
const MTPLX_ENV: [&str; 8] = [
    "MTPLX_CLEAR_CACHE_AFTER_REQUEST=always",
    "MTPLX_MLX_CACHE_LIMIT=268435456",
    "MTPLX_SESSION_BANK_MAX_ENTRIES=1",
    "MTPLX_SESSION_BANK_MAX_BYTES=512M",
    "MTPLX_SESSION_BANK_PER_SESSION_BYTES=512M",
    "MTPLX_WARMUP_LADDER=512",
    "HF_HUB_DISABLE_TELEMETRY=1",
    "DO_NOT_TRACK=1",
];
const MTPLX_FLAGS: [&str; 17] = [
    "--scheduler-mode",
    "serial",
    "--batching-preset",
    "latency",
    "--ssd-session-cache",
    "off",
    "--context-window",
    "32768",
    "--fan-mode",
    "default",
    "--reasoning",
    "off",
    "--adaptive-policy",
    "expected_value",
    "--no-stats-footer",
    "--unsafe-force-unverified",
    "--yes",
];

/// The server's labels, ports and folders, the same ones `scripts/install-remote-server.sh` uses.
/// Separate from the client's own agents; a development build has only its own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerModePaths {
    pub dev: bool,
    pub home: PathBuf,
}

impl ServerModePaths {
    pub fn new(home: impl Into<PathBuf>, dev: bool) -> Self {
        ServerModePaths { dev, home: home.into() }
    }
    pub fn label(&self) -> &'static str {
        if self.dev { "org.localflow.LocalFlow.dev.remote" } else { "org.localflow.LocalFlow.remote" }
    }
    pub fn mtplx_label(&self) -> &'static str {
        if self.dev { "org.localflow.LocalFlow.dev.remote.mtplx" } else { "org.localflow.LocalFlow.remote.mtplx" }
    }
    fn port(&self, production: u16) -> u16 {
        if self.dev { production + 10_000 } else { production }
    }
    pub fn remote_port(&self) -> u16 {
        self.port(8090)
    }
    pub fn local_port(&self) -> u16 {
        self.port(8091)
    }
    pub fn mtplx_port(&self) -> u16 {
        self.port(8092)
    }
    pub fn admin_port(&self) -> u16 {
        self.port(8093)
    }
    fn directory_name(&self) -> &'static str {
        if self.dev { "LocalFlow Server Dev" } else { "LocalFlow Server" }
    }
    pub fn data_dir(&self) -> PathBuf {
        self.home.join("Library/Application Support").join(self.directory_name())
    }
    pub fn bin_dir(&self) -> PathBuf {
        self.data_dir().join("bin")
    }
    /// The data directory's own flowd, the one `flowd admin` must always run.
    pub fn flowd(&self) -> PathBuf {
        self.bin_dir().join("flowd")
    }
    pub fn log_dir(&self) -> PathBuf {
        self.home.join("Library/Logs").join(self.directory_name())
    }
    pub fn plist(&self) -> PathBuf {
        self.home.join("Library/LaunchAgents").join(format!("{}.plist", self.label()))
    }
    pub fn mtplx_plist(&self) -> PathBuf {
        self.home.join("Library/LaunchAgents").join(format!("{}.plist", self.mtplx_label()))
    }
    /// flowd refuses to serve without the identity key; `flowd admin init` creates both.
    pub fn database(&self) -> PathBuf {
        self.data_dir().join("flowd-remote.sqlite")
    }
    pub fn models_dir(&self) -> PathBuf {
        self.data_dir().join("Models")
    }
    /// flowd's bearer token for the loopback admin API (0600).
    pub fn admin_token(&self) -> PathBuf {
        self.data_dir().join("admin-token")
    }
    /// The server MTPLX key (0600), read by the wrapper.
    pub fn mtplx_key(&self) -> PathBuf {
        self.data_dir().join("mtplx-api-key")
    }
    pub fn wrapper(&self) -> PathBuf {
        self.bin_dir().join("localflow-remote-flowd")
    }
    pub fn meeting_processor(&self) -> PathBuf {
        self.bin_dir().join(MEETING_PROCESSOR)
    }
    /// Where an open to the network keeps the previous plist: `ServerMode` in this app's data folder.
    pub fn backup_plist(&self, app_data: &Path) -> PathBuf {
        app_data.join("ServerMode").join(format!("{}.plist", self.label()))
    }

    /// The installer's flowd flags. `rewriting` starts it through the key wrapper; `meeting_processor`
    /// is whether `bin/flowd-meeting` is executable.
    pub fn flowd_arguments(&self, listen: &str, rewriting: bool, meeting_processor: bool) -> Vec<String> {
        let bin = self.bin_dir();
        let mut args: Vec<String> = Vec::new();
        if rewriting {
            args.extend([text(&self.wrapper()), text(&self.mtplx_key())]);
        }
        args.extend([
            text(&self.flowd()),
            "serve".into(),
            "--listen".into(),
            format!("127.0.0.1:{}", self.local_port()),
            "--remote-listen".into(),
            listen.into(),
            "--data-dir".into(),
            text(&self.data_dir()),
            "--backend".into(),
            format!("http://127.0.0.1:{}/v1", self.mtplx_port()),
            "--model".into(),
            "localflow".into(),
            "--speech-worker".into(),
            text(&bin.join("flowd-speech")),
            "--meeting-helper".into(),
            text(&bin.join("localflow-whisper-engine")),
        ]);
        if meeting_processor {
            args.extend(["--meeting-processor".into(), text(&self.meeting_processor())]);
        }
        args.extend(["--log-file".into(), text(&self.log_dir().join("flowd.log")), "--admin-listen".into(), format!("127.0.0.1:{}", self.admin_port())]);
        if self.dev {
            args.push("--dev".into());
        }
        args
    }

    /// The serving flags and memory caps of the installer's MTPLX agent, key from `mtplx_key()`.
    pub fn mtplx_arguments(&self, mtplx: &Path, model: &Path) -> Vec<String> {
        let mut args = vec!["/usr/bin/env".to_string()];
        args.extend(MTPLX_ENV.iter().map(|e| e.to_string()));
        args.extend([
            text(mtplx),
            "serve".into(),
            "--host".into(),
            "127.0.0.1".into(),
            "--port".into(),
            self.mtplx_port().to_string(),
            "--model".into(),
            text(model),
            "--model-id".into(),
            "localflow".into(),
            "--api-key-file".into(),
            text(&self.mtplx_key()),
        ]);
        args.extend(MTPLX_FLAGS.iter().map(|f| f.to_string()));
        args
    }

    /// flowd's plist, logs beside `flowd.log`.
    pub fn flowd_plist(&self, listen: &str, rewriting: bool, meeting_processor: bool) -> Vec<u8> {
        let logs = self.log_dir();
        agent_plist(self.label(), &self.flowd_arguments(listen, rewriting, meeting_processor), &text(&logs.join("flowd.stdout.log")), &text(&logs.join("flowd.stderr.log")))
    }

    /// The server's own MTPLX plist; its stdout is discarded.
    pub fn mtplx_plist_bytes(&self, mtplx: &Path, model: &Path) -> Vec<u8> {
        agent_plist(self.mtplx_label(), &self.mtplx_arguments(mtplx, model), "/dev/null", &text(&self.log_dir().join("mtplx.stderr.log")))
    }

    /// `admin --data-dir <dir> [--dev] …`, to run with `flowd()` and never the app's own copy: a
    /// newer flowd would migrate an adopted server's database past what that server can open.
    pub fn admin_arguments(&self, args: &[&str]) -> Vec<String> {
        let mut out = vec!["admin".to_string(), "--data-dir".into(), text(&self.data_dir())];
        if self.dev {
            out.push("--dev".into());
        }
        out.extend(args.iter().map(|a| a.to_string()));
        out
    }
}

fn text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn string_array(values: &[String]) -> plist::Value {
    plist::Value::Array(values.iter().map(|a| a.as_str().into()).collect())
}

/// A launch agent's plist in XML, keys sorted as `PropertyListSerialization` writes them.
pub fn agent_plist(label: &str, arguments: &[String], stdout: &str, stderr: &str) -> Vec<u8> {
    let mut d = plist::Dictionary::new();
    d.insert("KeepAlive".into(), true.into());
    d.insert("Label".into(), label.into());
    d.insert("LimitLoadToSessionType".into(), "Aqua".into());
    d.insert("ProcessType".into(), "Standard".into());
    d.insert("ProgramArguments".into(), string_array(arguments));
    d.insert("RunAtLoad".into(), true.into());
    d.insert("StandardErrorPath".into(), stderr.into());
    d.insert("StandardOutPath".into(), stdout.into());
    d.insert("ThrottleInterval".into(), plist::Value::Integer(30.into()));
    xml(&plist::Value::Dictionary(d))
}

fn xml(value: &plist::Value) -> Vec<u8> {
    let mut out = Vec::new();
    value.to_writer_xml(&mut out).expect("writing to memory");
    out
}

fn dictionary(bytes: &[u8]) -> Option<plist::Dictionary> {
    plist::Value::from_reader(std::io::Cursor::new(bytes)).ok()?.into_dictionary()
}

/// `ProgramArguments` of a plist in XML or binary form.
pub fn program_arguments(bytes: &[u8]) -> Option<Vec<String>> {
    dictionary(bytes)?.get("ProgramArguments")?.as_array()?.iter().map(|v| v.as_string().map(String::from)).collect()
}

/// The plist with only `ProgramArguments` replaced, every other key kept. `None` if it isn't a plist.
pub fn replace_arguments(bytes: &[u8], arguments: &[String]) -> Option<Vec<u8>> {
    let mut d = dictionary(bytes)?;
    d.insert("ProgramArguments".into(), string_array(arguments));
    Some(xml(&plist::Value::Dictionary(d)))
}

/// The value after `flag`, as `--remote-listen 0.0.0.0:8090` gives it.
pub fn value_after<'a>(arguments: &'a [String], flag: &str) -> Option<&'a str> {
    let i = arguments.iter().position(|a| a == flag)?;
    arguments.get(i + 1).map(String::as_str)
}

/// Who owns the agent at the server's label. Only an agent this app wrote may be rewritten.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Ownership {
    #[default]
    None,
    Managed,
    Adopted,
}

pub fn plist_hash(bytes: &[u8]) -> String {
    crate::history::sha256_hex(bytes)
}

/// A plist whose hash isn't the one this app recorded, a loaded agent with no plist or lost
/// preferences all mean someone else made this server (the Swift app, the install script), so it
/// is adopted: started, stopped and administered, never rewritten. Failing towards adoption can
/// only cost a resync.
pub fn ownership(plist: Option<&[u8]>, prefs: &Prefs, loaded: bool) -> Ownership {
    match plist {
        None if loaded => Ownership::Adopted,
        None => Ownership::None,
        Some(bytes) if prefs.string(PLIST_HASH_KEY).as_deref() == Some(plist_hash(bytes).as_str()) => Ownership::Managed,
        Some(_) => Ownership::Adopted,
    }
}

/// After writing `bytes` to the server's plist: this app now owns it.
pub fn record_plist(prefs: &mut Prefs, bytes: &[u8]) {
    prefs.set(PLIST_HASH_KEY, plist_hash(bytes));
}

// Listen addresses.

/// The host of a `host:port` bind, without IPv6 brackets.
pub fn listen_host(listen: &str) -> &str {
    match listen.rfind(':') {
        Some(colon) => listen[..colon].trim_matches(|c| c == '[' || c == ']'),
        None => listen,
    }
}

pub fn listen_port(listen: &str) -> Option<u16> {
    listen.rsplit(':').next()?.parse().ok()
}

/// A loopback bind is reachable only through a local proxy or tunnel.
pub fn is_loopback(listen: &str) -> bool {
    listen.starts_with("127.") || listen.starts_with("[::1]") || listen.starts_with("localhost")
}

fn is_wildcard(host: &str) -> bool {
    host == "0.0.0.0" || host == "::"
}

/// Where the server answers on this Mac; a wildcard bind answers on loopback.
pub fn health_origin(listen: &str) -> Option<String> {
    let port = listen_port(listen)?;
    let host = listen_host(listen);
    let local = if is_wildcard(host) { "127.0.0.1" } else { host };
    Some(if local.contains(':') { format!("http://[{local}]:{port}") } else { format!("http://{local}:{port}") })
}

/// `launchctl print`'s top-level `state` and `pid`; nested blocks are indented deeper.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct AgentJob {
    pub running: bool,
    pub pid: Option<i32>,
}

impl AgentJob {
    pub fn parse(text: &str) -> AgentJob {
        let mut job = AgentJob::default();
        for line in text.lines().filter(|l| l.starts_with('\t') && !l.starts_with("\t\t")) {
            let Some((key, value)) = line.trim().split_once(" = ") else { continue };
            match key {
                "state" => job.running = value == "running",
                "pid" => job.pid = value.parse().ok(),
                _ => {}
            }
        }
        job
    }
}

/// What the Settings group and onboarding show about the server.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct ServerModeStatus {
    pub ownership: Ownership,
    pub loaded: bool,
    pub running: bool,
    /// `--remote-listen` from the plist.
    pub listen: Option<String>,
    /// The running server's own answer, from its public identity route.
    pub fingerprint: Option<String>,
    /// Services that can't work yet, and why.
    pub missing: Vec<String>,
    /// Bytes left to download for the speech and meeting models.
    pub missing_model_bytes: u64,
    pub client_connected: bool,
}

impl ServerModeStatus {
    /// Only a loopback bind has anything to open.
    pub fn can_open_to_network(&self) -> bool {
        self.listen.as_deref().is_some_and(is_loopback)
    }
}

/// `flowd admin list` shows a device that has connected at least once.
pub fn client_seen(list_output: &str) -> bool {
    list_output.match_indices("last seen ").any(|(i, m)| list_output[i + m.len()..].starts_with(|c: char| c.is_ascii_digit()))
}

/// Bytes a model still needs: the descriptor's files whose size on disk under `root` differs.
/// `provision` does the full hash check when it runs. `None` when the descriptor doesn't parse.
pub fn missing_model_bytes(descriptor: &[u8], root: &Path) -> Option<u64> {
    let value: serde_json::Value = serde_json::from_slice(descriptor).ok()?;
    let mut sum = 0;
    for file in value["files"].as_array()? {
        let (path, size) = (file["path"].as_str()?, file["size"].as_u64()?);
        if std::fs::metadata(root.join(path)).map(|m| m.len()).ok() != Some(size) {
            sum += size;
        }
    }
    Some(sum)
}

// Addresses (FR-012a).

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerAddress {
    pub title: String,
    pub origin: String,
}

/// Tailscale first, then the local network, and only what `origin` accepts, each address once.
pub fn address_list(ips: &[String], port: u16) -> Vec<ServerAddress> {
    let mut seen: Vec<&str> = Vec::new();
    let mut found: Vec<(ServerAddressKind, ServerAddress)> = Vec::new();
    for ip in ips {
        let Some(kind) = server_address_kind(ip) else { continue };
        if seen.contains(&ip.as_str()) {
            continue;
        }
        seen.push(ip);
        let host = if ip.contains(':') { format!("[{ip}]") } else { ip.clone() };
        let Some(origin) = origin(&format!("http://{host}:{port}")) else { continue };
        let title = if kind == ServerAddressKind::Tailscale { "Tailscale" } else { "Local network" };
        found.push((kind, ServerAddress { title: format!("{title}: {origin}"), origin }));
    }
    let (tailscale, lan): (Vec<_>, Vec<_>) = found.into_iter().partition(|(k, _)| *k == ServerAddressKind::Tailscale);
    tailscale.into_iter().chain(lan).map(|(_, a)| a).collect()
}

/// Reachable addresses for a token's link: none while the server binds only to loopback, the
/// interfaces' for a wildcard bind, then the owner's custom address.
pub fn addresses(listen: Option<&str>, interfaces: &[String], prefs: &Prefs) -> Vec<ServerAddress> {
    let mut found = Vec::new();
    if let Some(listen) = listen.filter(|l| !is_loopback(l))
        && let Some(port) = listen_port(listen)
    {
        let host = listen_host(listen);
        found = if is_wildcard(host) { address_list(interfaces, port) } else { address_list(&[host.to_string()], port) };
    }
    if let Some(custom) = prefs.string(CUSTOM_ADDRESS_KEY).as_deref().and_then(origin) {
        found.push(ServerAddress { title: format!("Custom: {custom}"), origin: custom });
    }
    found
}

/// False if the text is not a usable address; empty clears it.
pub fn set_custom_address(prefs: &mut Prefs, text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        prefs.remove(CUSTOM_ADDRESS_KEY);
        return true;
    }
    match origin(trimmed) {
        Some(o) => {
            prefs.set(CUSTOM_ADDRESS_KEY, o);
            true
        }
        None => false,
    }
}

pub fn custom_address(prefs: &Prefs) -> String {
    prefs.string(CUSTOM_ADDRESS_KEY).unwrap_or_default()
}

// Open to the network.

/// How long a changed bind has to report healthy before the previous plist comes back.
pub const OPEN_DEADLINE: std::time::Duration = std::time::Duration::from_secs(60);
/// Consecutive healthy checks of the new process that count as opened.
pub const OPEN_HEALTHY_CHECKS: u32 = 2;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpenOutcome {
    Opened,
    RolledBack(String),
    Failed(String),
}

pub fn not_healthy(deadline: std::time::Duration) -> String {
    format!("The server did not report healthy within {} s.", deadline.as_secs())
}

/// The arguments with only `--remote-listen` changed to every network, and the port. `None` when
/// the plist has no `--remote-listen` with a port.
pub fn opened_arguments(arguments: &[String]) -> Option<(Vec<String>, u16)> {
    let i = arguments.iter().position(|a| a == "--remote-listen")?;
    let port = listen_port(arguments.get(i + 1)?)?;
    let mut changed = arguments.to_vec();
    changed[i + 1] = format!("0.0.0.0:{port}");
    Some((changed, port))
}

/// The health window after an open: a new process (another PID than before) that answers twice in
/// a row is healthy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OpenCheck {
    previous_pid: Option<i32>,
    healthy_checks: u32,
}

impl OpenCheck {
    pub fn new(previous_pid: Option<i32>) -> Self {
        OpenCheck { previous_pid, healthy_checks: 0 }
    }
    /// One poll: the job as `launchctl print` saw it (`None` when not loaded), and whether its
    /// health route answered. True once the open stands.
    pub fn observe(&mut self, job: Option<AgentJob>, answered: bool) -> bool {
        let healthy = answered && job.is_some_and(|j| j.running && j.pid != self.previous_pid);
        self.healthy_checks = if healthy { self.healthy_checks + 1 } else { 0 };
        self.healthy_checks >= OPEN_HEALTHY_CHECKS
    }
}

/// Set while an open awaits its health check, so a quit in that window is undone at launch (FR-010).
pub fn begin_open(prefs: &mut Prefs) {
    prefs.set(OPEN_PENDING_KEY, true);
}

pub fn end_open(prefs: &mut Prefs) {
    prefs.remove(OPEN_PENDING_KEY);
}

/// At launch: true when an open was interrupted and the previous plist must come back. Clears the mark.
pub fn take_interrupted_open(prefs: &mut Prefs) -> bool {
    let pending = prefs.bool_or(OPEN_PENDING_KEY, false);
    end_open(prefs);
    pending
}

// The server's models (research R7).

/// The sums of the file sizes in `apps/macos/LocalFlow/Resources/Models/<name>.json`.
pub const PARAKEET_V3_BYTES: u64 = 483_105_645;
pub const WHISPER_TURBO_BYTES: u64 = 1_625_440_373;
pub const DIARIZATION_OFFLINE_BYTES: u64 = 21_599_417;
/// Python and the MTPLX packages.
pub const MTPLX_RUNTIME_BYTES: u64 = 540_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlanPart {
    Dictation,
    Meetings,
    Speakers,
    Runtime,
    /// A `CATALOG` index.
    LanguageModel(usize),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlanItem {
    pub part: PlanPart,
    pub name: &'static str,
    pub bytes: u64,
    /// Already on disk: nothing to download.
    pub installed: bool,
}

/// What this Mac has, for the plan.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct PlanInput {
    pub physical_memory: u64,
    /// `None` when it can't be read; then the disk isn't checked.
    pub free_disk: Option<u64>,
    /// Per `CATALOG` entry, as `default_model` takes it.
    pub downloaded: [bool; 5],
    /// Parakeet v3, Whisper and diarization, in `SERVER_MODELS` order.
    pub speech_installed: [bool; 3],
    pub runtime_installed: bool,
}

/// What the step offers when the plan doesn't fit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlanOffer {
    /// It fits; start as planned.
    Fits,
    /// A smaller language model (`CATALOG` index) that fits.
    Smaller(usize),
    /// No language model fits: start without rewriting, reported as unavailable.
    WithoutRewriting,
    /// Even the speech and meeting models don't fit the free disk.
    FreeSpace,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerModelPlan {
    pub items: Vec<PlanItem>,
    /// The language model (`CATALOG` index); `None` starts without rewriting.
    pub model: Option<usize>,
    /// Bytes still to download.
    pub download_bytes: u64,
    /// What doesn't fit, in words for the step.
    pub problems: Vec<String>,
    pub offer: PlanOffer,
}

impl ServerModelPlan {
    pub fn fits(&self) -> bool {
        self.problems.is_empty()
    }
    /// Every item's size, installed or not.
    pub fn total_bytes(&self) -> u64 {
        self.items.iter().map(|i| i.bytes).sum()
    }
}

fn plan_items(input: &PlanInput, model: Option<usize>) -> Vec<PlanItem> {
    let speech = [
        (PlanPart::Dictation, "Parakeet v3 (dictation)", PARAKEET_V3_BYTES),
        (PlanPart::Meetings, "Whisper large-v3-turbo (meetings)", WHISPER_TURBO_BYTES),
        (PlanPart::Speakers, "Speaker labels (meetings)", DIARIZATION_OFFLINE_BYTES),
    ];
    let mut items: Vec<PlanItem> = speech.iter().zip(input.speech_installed).map(|(&(part, name, bytes), installed)| PlanItem { part, name, bytes, installed }).collect();
    if let Some(i) = model {
        items.push(PlanItem { part: PlanPart::Runtime, name: "On-device AI runtime", bytes: MTPLX_RUNTIME_BYTES, installed: input.runtime_installed });
        items.push(PlanItem { part: PlanPart::LanguageModel(i), name: CATALOG[i].name, bytes: CATALOG[i].download_bytes as u64, installed: input.downloaded[i] });
    }
    items
}

fn to_download(items: &[PlanItem]) -> u64 {
    items.iter().filter(|i| !i.installed).map(|i| i.bytes).sum()
}

fn disk_fits(input: &PlanInput, model: Option<usize>) -> bool {
    input.free_disk.is_none_or(|free| to_download(&plan_items(input, model)) <= free)
}

/// The plan for one choice, with what doesn't fit named. `offer` stays `Fits`; `server_model_plan`
/// fills it in.
pub fn plan_for(input: &PlanInput, model: Option<usize>) -> ServerModelPlan {
    let items = plan_items(input, model);
    let download_bytes = to_download(&items);
    let mut problems = Vec::new();
    if let Some(i) = model
        && !CATALOG[i].fits(input.physical_memory)
    {
        problems.push(format!("{} needs a Mac with at least {} GB of memory.", CATALOG[i].name, CATALOG[i].minimum_gb));
    }
    if let Some(free) = input.free_disk
        && download_bytes > free
    {
        problems.push(format!("Needs {} of free disk space to download; {} is free.", bytes(download_bytes as i64), bytes(free as i64)));
    }
    ServerModelPlan { items, model, download_bytes, problems, offer: PlanOffer::Fits }
}

/// The default plan: the speech and meeting models, the runtime and `default_model` for this Mac's
/// memory, checked against free disk and memory. When it doesn't fit, `offer` names the next
/// smaller model that does, or starting without rewriting.
pub fn server_model_plan(input: &PlanInput) -> ServerModelPlan {
    let chosen = default_model(&input.downloaded, input.physical_memory);
    let mut plan = plan_for(input, Some(chosen));
    if !plan.fits() {
        plan.offer = match next_smaller(input, chosen) {
            Some(i) => PlanOffer::Smaller(i),
            None if disk_fits(input, None) => PlanOffer::WithoutRewriting,
            None => PlanOffer::FreeSpace,
        };
    }
    plan
}

/// The largest model below `model` in download size that fits this Mac's memory and disk.
pub fn next_smaller(input: &PlanInput, model: usize) -> Option<usize> {
    let limit = CATALOG[model].download_bytes;
    (0..CATALOG.len()).filter(|&i| CATALOG[i].download_bytes < limit && CATALOG[i].fits(input.physical_memory) && disk_fits(input, Some(i))).max_by_key(|&i| CATALOG[i].download_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("flow-server-mode-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Swift's `testExactLabelsPortsAndDirectories`, plus the files the controller names.
    #[test]
    fn exact_labels_ports_and_directories() {
        let home = PathBuf::from("/tmp/home");
        let production = ServerModePaths::new(&home, false);
        assert_eq!(production.label(), "org.localflow.LocalFlow.remote");
        assert_eq!(production.mtplx_label(), "org.localflow.LocalFlow.remote.mtplx");
        assert_eq!([production.remote_port(), production.local_port(), production.mtplx_port(), production.admin_port()], [8090, 8091, 8092, 8093]);
        assert_eq!(production.data_dir(), home.join("Library/Application Support/LocalFlow Server"));
        assert_eq!(production.log_dir(), home.join("Library/Logs/LocalFlow Server"));
        assert_eq!(production.flowd(), home.join("Library/Application Support/LocalFlow Server/bin/flowd"));
        assert_eq!(production.plist(), home.join("Library/LaunchAgents/org.localflow.LocalFlow.remote.plist"));
        assert_eq!(production.mtplx_plist(), home.join("Library/LaunchAgents/org.localflow.LocalFlow.remote.mtplx.plist"));
        let dev = ServerModePaths::new(&home, true);
        assert_eq!(dev.label(), "org.localflow.LocalFlow.dev.remote");
        assert_eq!(dev.mtplx_label(), "org.localflow.LocalFlow.dev.remote.mtplx");
        assert_eq!([dev.remote_port(), dev.local_port(), dev.mtplx_port(), dev.admin_port()], [18090, 18091, 18092, 18093]);
        assert_eq!(dev.data_dir(), home.join("Library/Application Support/LocalFlow Server Dev"));
        assert_eq!(dev.log_dir(), home.join("Library/Logs/LocalFlow Server Dev"));
        assert_eq!(dev.plist(), home.join("Library/LaunchAgents/org.localflow.LocalFlow.dev.remote.plist"));
        assert_eq!(dev.backup_plist(Path::new("/app")), PathBuf::from("/app/ServerMode/org.localflow.LocalFlow.dev.remote.plist"));
    }

    /// The same names as Swift's `ServerModeController` keys and data-model.md.
    #[test]
    fn preference_keys() {
        assert_eq!([ROLE_KEY, ENABLED_KEY, CUSTOM_ADDRESS_KEY, PLIST_HASH_KEY, OPEN_PENDING_KEY, HELPERS_STAMP_KEY], ["setup.role", "serverMode.enabled", "serverMode.customAddress", "serverMode.plistSHA256", "serverMode.openPending", "serverMode.helpersStamp"]);
    }

    /// Swift's `testNewInstallOpensToAllNetworksWithDevIsolation`, argument for argument.
    #[test]
    fn flowd_arguments_for_a_new_dev_install() {
        let p = ServerModePaths::new("/h", true);
        let data = "/h/Library/Application Support/LocalFlow Server Dev";
        let args = p.flowd_arguments("0.0.0.0:18090", false, false);
        let expected = [
            format!("{data}/bin/flowd"),
            "serve".into(),
            "--listen".into(),
            "127.0.0.1:18091".into(),
            "--remote-listen".into(),
            "0.0.0.0:18090".into(),
            "--data-dir".into(),
            data.into(),
            "--backend".into(),
            "http://127.0.0.1:18092/v1".into(),
            "--model".into(),
            "localflow".into(),
            "--speech-worker".into(),
            format!("{data}/bin/flowd-speech"),
            "--meeting-helper".into(),
            format!("{data}/bin/localflow-whisper-engine"),
            "--log-file".into(),
            "/h/Library/Logs/LocalFlow Server Dev/flowd.log".into(),
            "--admin-listen".into(),
            "127.0.0.1:18093".into(),
            "--dev".into(),
        ];
        assert_eq!(args, expected);
        assert_eq!(args[1], "serve", "no wrapper without local AI");
        assert!(!ServerModePaths::new("/h", false).flowd_arguments("0.0.0.0:8090", false, false).contains(&"--dev".to_string()));
    }

    /// Swift's `testWithLocalAITheKeyStaysOutOfThePlist`: the wrapper and key file come first.
    #[test]
    fn rewriting_runs_flowd_through_the_key_wrapper() {
        let p = ServerModePaths::new("/h", true);
        let args = p.flowd_arguments("0.0.0.0:18090", true, false);
        assert_eq!(args[..3], [p.wrapper().to_string_lossy().into_owned(), p.mtplx_key().to_string_lossy().into_owned(), p.flowd().to_string_lossy().into_owned()]);
        assert!(p.wrapper().ends_with("bin/localflow-remote-flowd"));
        assert!(p.mtplx_key().ends_with("LocalFlow Server Dev/mtplx-api-key"));
        assert!(WRAPPER_SCRIPT.starts_with("#!/bin/sh\n") && WRAPPER_SCRIPT.ends_with("exec \"$@\"\n"));
        assert!(WRAPPER_SCRIPT.contains("LOCALFLOW_BACKEND_TOKEN=\"$(cat \"$key_file\")\""));
    }

    #[test]
    fn meeting_processor_is_passed_when_present() {
        let p = ServerModePaths::new("/h", true);
        let args = p.flowd_arguments("0.0.0.0:18090", false, true);
        assert_eq!(value_after(&args, "--meeting-processor"), Some(p.meeting_processor().to_str().unwrap()));
        assert!(p.meeting_processor().ends_with("bin/flowd-meeting"));
        assert_eq!(value_after(&args, "--meeting-helper").map(|h| h.ends_with("localflow-whisper-engine")), Some(true));
        assert!(!p.flowd_arguments("0.0.0.0:18090", false, false).contains(&"--meeting-processor".to_string()));
    }

    #[test]
    fn mtplx_arguments_keep_the_caps_and_warm_only_512() {
        let p = ServerModePaths::new("/h", true);
        let args = p.mtplx_arguments(Path::new("/ai/venv/bin/mtplx"), Path::new("/models/m"));
        assert_eq!(args[0], "/usr/bin/env");
        for env in ["MTPLX_CLEAR_CACHE_AFTER_REQUEST=always", "MTPLX_MLX_CACHE_LIMIT=268435456", "MTPLX_SESSION_BANK_MAX_ENTRIES=1", "MTPLX_SESSION_BANK_MAX_BYTES=512M", "MTPLX_SESSION_BANK_PER_SESSION_BYTES=512M", "MTPLX_WARMUP_LADDER=512", "HF_HUB_DISABLE_TELEMETRY=1", "DO_NOT_TRACK=1"] {
            assert!(args.iter().position(|a| a == env).unwrap() < args.iter().position(|a| a == "/ai/venv/bin/mtplx").unwrap(), "{env}");
        }
        assert_eq!(value_after(&args, "--port"), Some("18092"));
        assert_eq!(value_after(&args, "--model"), Some("/models/m"));
        assert_eq!(value_after(&args, "--model-id"), Some("localflow"));
        assert_eq!(value_after(&args, "--api-key-file"), Some(p.mtplx_key().to_str().unwrap()));
        assert_eq!(value_after(&args, "--context-window"), Some("32768"));
        assert_eq!(value_after(&args, "--scheduler-mode"), Some("serial"));
        assert_eq!(args.last().map(String::as_str), Some("--yes"));
        assert_eq!(args.len(), 1 + 8 + 12 + 17);
    }

    #[test]
    fn plists_carry_the_agent_keys_and_no_key_value() {
        let p = ServerModePaths::new("/h", true);
        let bytes = p.flowd_plist("0.0.0.0:18090", true, false);
        let d = dictionary(&bytes).unwrap();
        assert_eq!(d.get("Label").and_then(|v| v.as_string()), Some("org.localflow.LocalFlow.dev.remote"));
        assert_eq!(d.get("KeepAlive").and_then(|v| v.as_boolean()), Some(true));
        assert_eq!(d.get("RunAtLoad").and_then(|v| v.as_boolean()), Some(true));
        assert_eq!(d.get("LimitLoadToSessionType").and_then(|v| v.as_string()), Some("Aqua"));
        assert_eq!(d.get("ProcessType").and_then(|v| v.as_string()), Some("Standard"));
        assert_eq!(d.get("ThrottleInterval").and_then(|v| v.as_signed_integer()), Some(30));
        assert_eq!(d.get("StandardOutPath").and_then(|v| v.as_string()), Some("/h/Library/Logs/LocalFlow Server Dev/flowd.stdout.log"));
        assert_eq!(d.get("StandardErrorPath").and_then(|v| v.as_string()), Some("/h/Library/Logs/LocalFlow Server Dev/flowd.stderr.log"));
        assert_eq!(program_arguments(&bytes).unwrap(), p.flowd_arguments("0.0.0.0:18090", true, false));
        assert!(String::from_utf8(bytes).unwrap().starts_with("<?xml"));
        let mtplx = p.mtplx_plist_bytes(Path::new("/ai/mtplx"), Path::new("/m"));
        let d = dictionary(&mtplx).unwrap();
        assert_eq!(d.get("Label").and_then(|v| v.as_string()), Some("org.localflow.LocalFlow.dev.remote.mtplx"));
        assert_eq!(d.get("StandardOutPath").and_then(|v| v.as_string()), Some("/dev/null"));
        assert_eq!(value_after(&program_arguments(&mtplx).unwrap(), "--port"), Some("18092"));
    }

    /// A plist as the install script writes it, with a sign-in flag the app doesn't know about.
    fn script_plist(p: &ServerModePaths) -> Vec<u8> {
        let mut d = plist::Dictionary::new();
        d.insert("Label".into(), p.label().into());
        d.insert("KeepAlive".into(), true.into());
        d.insert("ProgramArguments".into(), string_array(&s(&["/script/flowd", "serve", "--remote-listen", &format!("127.0.0.1:{}", p.remote_port()), "--google-client-id", "abc.apps.googleusercontent.com"])));
        xml(&plist::Value::Dictionary(d))
    }

    /// Swift's adoption tests: only the plist this app recorded is managed; Swift's and the script's are adopted.
    #[test]
    fn ownership_follows_the_recorded_hash() {
        let p = ServerModePaths::new("/h", true);
        let mut prefs = Prefs::memory();
        assert_eq!(ownership(None, &prefs, false), Ownership::None);
        assert_eq!(ownership(None, &prefs, true), Ownership::Adopted, "a loaded agent with no plist");
        let ours = p.flowd_plist("0.0.0.0:18090", false, false);
        assert_eq!(ownership(Some(&ours), &prefs, false), Ownership::Adopted, "lost preferences");
        record_plist(&mut prefs, &ours);
        assert_eq!(prefs.string(PLIST_HASH_KEY).unwrap(), plist_hash(&ours));
        assert_eq!(ownership(Some(&ours), &prefs, true), Ownership::Managed);
        assert_eq!(ownership(Some(&script_plist(&p)), &prefs, true), Ownership::Adopted, "changed behind the app");
    }

    /// Swift's `testOpenChangesOnlyTheListenAddressAndAdoptedStaysAdopted`.
    #[test]
    fn open_changes_only_the_listen_address() {
        let p = ServerModePaths::new("/h", false);
        let original = script_plist(&p);
        let before = program_arguments(&original).unwrap();
        let (changed, port) = opened_arguments(&before).unwrap();
        let mut expected = before.clone();
        expected[3] = "0.0.0.0:8090".into();
        assert_eq!((changed.clone(), port), (expected.clone(), 8090));
        let written = replace_arguments(&original, &changed).unwrap();
        assert_eq!(program_arguments(&written).unwrap(), expected);
        let d = dictionary(&written).unwrap();
        assert_eq!(d.get("KeepAlive").and_then(|v| v.as_boolean()), Some(true));
        assert_eq!(value_after(&program_arguments(&written).unwrap(), "--google-client-id"), Some("abc.apps.googleusercontent.com"));
        let prefs = Prefs::memory();
        assert_eq!(ownership(Some(&written), &prefs, true), Ownership::Adopted);
        assert_eq!(opened_arguments(&s(&["/flowd", "serve"])), None);
        assert_eq!(NO_REMOTE_LISTEN, "This server's plist has no --remote-listen to change.");
        assert!(replace_arguments(b"not a plist", &changed).is_none());
    }

    #[test]
    fn open_check_needs_a_new_process_healthy_twice() {
        let up = |pid| Some(AgentJob { running: true, pid: Some(pid) });
        let mut check = OpenCheck::new(Some(100));
        assert!(!check.observe(up(100), true), "the old process doesn't count");
        assert!(!check.observe(up(101), true));
        assert!(!check.observe(None, true), "gone resets");
        assert!(!check.observe(up(101), true));
        assert!(!check.observe(up(101), false), "no answer resets");
        assert!(!check.observe(up(101), true));
        assert!(check.observe(up(101), true));
        assert_eq!(not_healthy(OPEN_DEADLINE), "The server did not report healthy within 60 s.");
    }

    /// Swift's `testAnOpenInterruptedByQuittingIsUndoneAtLaunch`, the preference half.
    #[test]
    fn an_interrupted_open_is_taken_once() {
        let mut prefs = Prefs::memory();
        assert!(!take_interrupted_open(&mut prefs));
        begin_open(&mut prefs);
        end_open(&mut prefs);
        assert!(!take_interrupted_open(&mut prefs), "a finished open stands");
        begin_open(&mut prefs);
        assert!(take_interrupted_open(&mut prefs));
        assert!(!prefs.contains(OPEN_PENDING_KEY));
    }

    #[test]
    fn listen_parsing_and_health() {
        assert_eq!((listen_host("0.0.0.0:8090"), listen_port("0.0.0.0:8090")), ("0.0.0.0", Some(8090)));
        assert_eq!((listen_host("[::1]:8090"), listen_port("[::1]:8090")), ("::1", Some(8090)));
        assert_eq!(listen_port("0.0.0.0"), None);
        assert!(is_loopback("127.0.0.1:8090") && is_loopback("[::1]:8090") && is_loopback("localhost:8090"));
        assert!(!is_loopback("0.0.0.0:8090") && !is_loopback("10.0.0.7:8090"));
        assert_eq!(health_origin("0.0.0.0:18090").as_deref(), Some("http://127.0.0.1:18090"));
        assert_eq!(health_origin("[::]:18090").as_deref(), Some("http://127.0.0.1:18090"));
        assert_eq!(health_origin("[fd00::9]:18090").as_deref(), Some("http://[fd00::9]:18090"));
        let mut status = ServerModeStatus { listen: Some("127.0.0.1:8090".into()), ..Default::default() };
        assert!(status.can_open_to_network());
        status.listen = Some("0.0.0.0:8090".into());
        assert!(!status.can_open_to_network());
        status.listen = None;
        assert!(!status.can_open_to_network());
    }

    #[test]
    fn launchctl_print_reads_only_the_top_level() {
        assert_eq!(AgentJob::parse("\tstate = running\n\tpid = 101\n\t\tpid = 1\n"), AgentJob { running: true, pid: Some(101) });
        assert_eq!(AgentJob::parse("\tstate = not running\n\t\tstate = running\n"), AgentJob { running: false, pid: None });
    }

    /// Swift's `testNoClientYetIsReportedFromTheAdminList`.
    #[test]
    fn a_client_is_seen_from_the_admin_list() {
        assert!(!client_seen("user 1 token Ada approved created 2026-10-31 10:00\n  device 1 x approved enrolled 2026-10-31 10:01  last seen never\n"));
        assert!(client_seen("  device 1 x approved enrolled 2026-10-31 10:01  last seen 2026-10-31 11:00\n"));
    }

    /// Swift's `testAddressTable`.
    #[test]
    fn address_table() {
        let list = address_list(&s(&["127.0.0.1", "::1", "192.168.1.20", "100.100.1.2", "169.254.3.4", "fe80::1", "8.8.8.8", "fd7a:115c:a1e0::2", "192.168.1.20", "fd00::9"]), 8090);
        assert_eq!(list.iter().map(|a| a.title.as_str()).collect::<Vec<_>>(), ["Tailscale: http://100.100.1.2:8090", "Tailscale: http://[fd7a:115c:a1e0::2]:8090", "Local network: http://192.168.1.20:8090", "Local network: http://[fd00::9]:8090"]);
        assert_eq!(list[0].origin, "http://100.100.1.2:8090");
    }

    /// Swift's `testAddressesFollowTheBindAndTheCustomAddressIsValidated`.
    #[test]
    fn addresses_follow_the_bind_and_the_custom_address_is_validated() {
        let mut prefs = Prefs::memory();
        let ifaces = s(&["10.0.0.2"]);
        let origins = |listen: &str, ifaces: &[String], prefs: &Prefs| addresses(Some(listen), ifaces, prefs).into_iter().map(|a| a.origin).collect::<Vec<_>>();
        assert_eq!(origins("0.0.0.0:18090", &ifaces, &prefs), ["http://10.0.0.2:18090"]);
        assert!(origins("127.0.0.1:18090", &ifaces, &prefs).is_empty(), "a loopback bind isn't reachable on the machine's addresses");
        assert_eq!(origins("10.0.0.7:18090", &ifaces, &prefs), ["http://10.0.0.7:18090"], "a bind to one address lists only that one");
        assert!(!set_custom_address(&mut prefs, "http://example.com"), "public http is refused");
        assert!(!set_custom_address(&mut prefs, "https://example.com/path"));
        assert_eq!(custom_address(&prefs), "");
        assert!(set_custom_address(&mut prefs, "https://mini.example.com"));
        assert_eq!(origins("127.0.0.1:18090", &[], &prefs), ["https://mini.example.com"]);
        assert_eq!(addresses(None, &[], &prefs)[0].title, "Custom: https://mini.example.com");
        assert!(set_custom_address(&mut prefs, ""));
        assert_eq!(custom_address(&prefs), "");
    }

    #[test]
    fn admin_arguments_name_the_data_dir_and_dev() {
        assert_eq!(ServerModePaths::new("/h", true).admin_arguments(&["init"]), s(&["admin", "--data-dir", "/h/Library/Application Support/LocalFlow Server Dev", "--dev", "init"]));
        assert_eq!(ServerModePaths::new("/h", false).admin_arguments(&["list"]), s(&["admin", "--data-dir", "/h/Library/Application Support/LocalFlow Server", "list"]));
    }

    /// Swift's `missingModels`: sizes against the descriptor, as `testInstalledModelsAreNotListed`.
    #[test]
    fn missing_model_bytes_compares_sizes() {
        let root = temp("models");
        let descriptor = br#"{"files":[{"path":"a/model.bin","size":1000},{"path":"b.bin","size":5}]}"#;
        assert_eq!(missing_model_bytes(descriptor, &root), Some(1005));
        std::fs::create_dir_all(root.join("a")).unwrap();
        std::fs::write(root.join("a/model.bin"), vec![0; 1000]).unwrap();
        std::fs::write(root.join("b.bin"), b"1234").unwrap();
        assert_eq!(missing_model_bytes(descriptor, &root), Some(5), "a wrong size still counts");
        assert_eq!(missing_model_bytes(b"{}", &root), None);
        assert_eq!(models_missing("Dictation"), "Dictation: models not downloaded.");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn model_sizes_are_the_descriptors() {
        for (name, bytes) in [("parakeet-v3", PARAKEET_V3_BYTES), ("whisper-large-v3-turbo", WHISPER_TURBO_BYTES), ("speaker-diarization-offline", DIARIZATION_OFFLINE_BYTES)] {
            let path = format!("{}/../../apps/macos/LocalFlow/Resources/Models/{name}.json", env!("CARGO_MANIFEST_DIR"));
            let manifest: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
            let sum: u64 = manifest["files"].as_array().unwrap().iter().map(|f| f["size"].as_u64().unwrap()).sum();
            assert_eq!(bytes, sum, "{name}");
        }
        assert!(SERVER_MODELS.iter().all(|(file, ..)| DESCRIPTORS.contains(file)));
    }

    const GB: u64 = 1 << 30;
    const SPEECH: u64 = PARAKEET_V3_BYTES + WHISPER_TURBO_BYTES + DIARIZATION_OFFLINE_BYTES;

    fn mac(memory_gb: u64) -> PlanInput {
        PlanInput { physical_memory: memory_gb * GB, free_disk: Some(500 * GB), ..Default::default() }
    }

    #[test]
    fn plan_for_an_8_gb_mac() {
        let plan = server_model_plan(&mac(8));
        assert_eq!(plan.model, Some(0));
        assert_eq!(plan.items.iter().map(|i| i.part).collect::<Vec<_>>(), [PlanPart::Dictation, PlanPart::Meetings, PlanPart::Speakers, PlanPart::Runtime, PlanPart::LanguageModel(0)]);
        assert_eq!(plan.items[4].name, "Qwen 3.5 4B Speed");
        let total = SPEECH + MTPLX_RUNTIME_BYTES + CATALOG[0].download_bytes as u64;
        assert_eq!((plan.download_bytes, plan.total_bytes()), (total, total));
        assert!(plan.fits());
        assert_eq!(plan.offer, PlanOffer::Fits);
    }

    #[test]
    fn plan_for_a_16_gb_mac_reuses_a_downloaded_model_and_installed_parts() {
        let mut input = mac(16);
        input.downloaded[1] = true;
        input.speech_installed = [true, false, false];
        input.runtime_installed = true;
        let plan = server_model_plan(&input);
        assert_eq!(plan.model, Some(1));
        assert_eq!(plan.download_bytes, WHISPER_TURBO_BYTES + DIARIZATION_OFFLINE_BYTES);
        assert_eq!(plan.total_bytes(), SPEECH + MTPLX_RUNTIME_BYTES + CATALOG[1].download_bytes as u64);
        assert!(plan.fits());
        // The 27B model downloaded on a 16 GB Mac doesn't fit its memory, so it isn't the default.
        let mut input = mac(16);
        input.downloaded[4] = true;
        assert_eq!(server_model_plan(&input).model, Some(0));
        assert_eq!(plan_for(&input, Some(4)).problems, ["Qwen 3.8 27B Speed needs a Mac with at least 48 GB of memory."]);
    }

    #[test]
    fn plan_for_a_48_gb_mac_offers_the_next_smaller_model_when_the_disk_is_short() {
        let mut input = mac(48);
        input.downloaded[4] = true;
        let plan = server_model_plan(&input);
        assert_eq!((plan.model, plan.download_bytes), (Some(4), SPEECH + MTPLX_RUNTIME_BYTES));
        assert!(plan.fits());
        // Only the 4B Speed model fits next to the speech models.
        let input = PlanInput { free_disk: Some(SPEECH + MTPLX_RUNTIME_BYTES + 3 * GB), ..mac(48) };
        assert_eq!(next_smaller(&input, 4), Some(0));
        let mut big = plan_for(&input, Some(4));
        assert!(!big.fits());
        assert_eq!(big.problems.len(), 1);
        assert!(big.problems[0].starts_with("Needs "), "{}", big.problems[0]);
        big = plan_for(&input, Some(2));
        assert!(!big.fits());
        assert_eq!(next_smaller(&input, 2), Some(0));
    }

    #[test]
    fn plan_starts_without_rewriting_when_no_model_fits() {
        let input = PlanInput { free_disk: Some(SPEECH + GB), ..mac(8) };
        let plan = server_model_plan(&input);
        assert!(!plan.fits());
        assert_eq!(plan.offer, PlanOffer::WithoutRewriting);
        let without = plan_for(&input, None);
        assert!(without.fits());
        assert_eq!(without.download_bytes, SPEECH);
        assert!(without.items.iter().all(|i| !matches!(i.part, PlanPart::Runtime | PlanPart::LanguageModel(_))));
        // Under 8 GB nothing fits memory.
        let small = server_model_plan(&mac(4));
        assert_eq!(small.offer, PlanOffer::WithoutRewriting);
        assert_eq!(small.problems, ["Qwen 3.5 4B Speed needs a Mac with at least 8 GB of memory."]);
    }

    #[test]
    fn plan_on_a_full_disk_asks_for_space() {
        let input = PlanInput { free_disk: Some(GB), ..mac(16) };
        let plan = server_model_plan(&input);
        assert_eq!(plan.offer, PlanOffer::FreeSpace);
        assert_eq!(plan.problems.len(), 1);
        assert!(plan.problems[0].contains("free disk space"));
        assert!(!plan_for(&input, None).fits(), "not even the speech models");
        let unknown = PlanInput { free_disk: None, ..mac(16) };
        assert!(server_model_plan(&unknown).fits(), "an unreadable disk isn't a refusal");
    }
}
