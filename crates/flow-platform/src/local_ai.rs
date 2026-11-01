//! `LocalAIInstaller`: the MTPLX runtime and a chosen model under `LocalFlow/LocalAI`, served by the
//! `org.localflow.LocalFlow` login services (ADR 0026). Those paths, labels and ports are Swift's on
//! purpose: where the Swift app already set this up, its runtime, model and services are reused.
use flow_core::onboarding::*;
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const PYTHON_URL: &str = "https://github.com/astral-sh/python-build-standalone/releases/download/20260924/cpython-3.13.15%2B20260924-aarch64-apple-darwin-install_only_stripped.tar.gz";
const PYTHON_SHA256: &str = "064afb7c2fc0bbf511d886288adf98696af5105e36c138cdf2c199c0146fcf68";
const START_DEADLINE: Duration = Duration::from_secs(300);
pub const MTPLX_LABEL: &str = "org.localflow.LocalFlow.mtplx";
pub const FLOWD_LABEL: &str = "org.localflow.LocalFlow.flowd";

static PHASE: Mutex<Option<AiPhase>> = Mutex::new(None);

pub fn phase() -> Option<AiPhase> {
    PHASE.lock().unwrap().clone()
}
fn report(phase: AiPhase) {
    *PHASE.lock().unwrap() = Some(phase);
}

/// The system's answers, so the sequence can run in a test without touching launchd.
pub trait Agents: Send + 'static {
    fn loaded(&self, label: &str) -> bool;
    /// Registers a service that isn't loaded. `Err` holds the message to show.
    fn register(&self, label: &str) -> Result<(), String>;
    /// `launchctl kickstart`, with `-k` when `restart`.
    fn kickstart(&self, label: &str, restart: bool) -> bool;
}

pub struct Install {
    pub root: PathBuf,
    pub resources: PathBuf,
    pub log: PathBuf,
    pub model: LocalAiModel,
}

pub fn start(install: Install, agents: impl Agents) {
    report(AiPhase::PreparingRuntime);
    std::thread::spawn(move || {
        report(match run(&install, &agents) {
            Ok(()) => AiPhase::Ready,
            Err(message) => AiPhase::Failed(message),
        });
    });
}

fn run(i: &Install, agents: &impl Agents) -> Result<(), String> {
    let requirements = i.resources.join("mtplx-requirements.txt");
    if !requirements.is_file() {
        return Err(AI_ERROR_MISSING.into());
    }
    prepare_folders(i).map_err(|_| AI_ERROR_PACKAGES.to_string())?;
    // Our services own the ports once loaded; anything else there is a conflict.
    let taken = |port| std::net::TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), Duration::from_secs(1)).is_ok();
    if (!agents.loaded(MTPLX_LABEL) && taken(MTPLX_PORT)) || (!agents.loaded(FLOWD_LABEL) && taken(FLOWD_PORT)) {
        return Err(ai_error_port());
    }
    report(AiPhase::PreparingRuntime);
    install_python(i)?;
    install_packages(i, &requirements)?;
    report(AiPhase::DownloadingModel(0, i.model.download_bytes));
    let path = pull(i)?;
    let model_path = i.root.join("model-path");
    let changed = std::fs::read_to_string(&model_path).ok().as_deref() != Some(path.as_str());
    if changed {
        write_atomic(&model_path, path.as_bytes()).map_err(|_| AI_ERROR_DOWNLOAD.to_string())?;
    }
    write_key_if_missing(&i.root).map_err(|_| AI_ERROR_REGISTRATION.to_string())?;
    report(AiPhase::Starting);
    let was_loaded = agents.loaded(MTPLX_LABEL);
    for label in [MTPLX_LABEL, FLOWD_LABEL] {
        if !agents.loaded(label) {
            agents.register(label)?;
        }
    }
    write_atomic(&i.root.join("app-pid"), std::process::id().to_string().as_bytes()).map_err(|_| AI_ERROR_REGISTRATION.to_string())?;
    // A changed model needs a fresh mtplx; an unchanged one that's up stays up. Swift always restarts.
    if !agents.kickstart(FLOWD_LABEL, false) || !agents.kickstart(MTPLX_LABEL, was_loaded && changed) {
        return Err(AI_ERROR_REGISTRATION.into());
    }
    wait_until_serving()
}

fn prepare_folders(i: &Install) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    if let Some(logs) = i.log.parent() {
        std::fs::create_dir_all(logs)?;
    }
    std::fs::write(&i.log, b"")?; // One setup's log at a time keeps it bounded.
    std::fs::create_dir_all(&i.root)?;
    std::fs::set_permissions(&i.root, std::fs::Permissions::from_mode(0o700))
}

fn tool(i: &Install, program: &Path, args: &[&str]) -> Result<Command, ()> {
    let log = std::fs::OpenOptions::new().append(true).create(true).open(&i.log).map_err(|_| ())?;
    let mut c = Command::new(program);
    c.args(args).env("HF_HUB_DISABLE_TELEMETRY", "1").env("DO_NOT_TRACK", "1").env("PYTHONUNBUFFERED", "1").stdin(Stdio::null()).stdout(log.try_clone().map_err(|_| ())?).stderr(log);
    Ok(c)
}
fn ran(i: &Install, program: impl AsRef<Path>, args: &[&str]) -> bool {
    tool(i, program.as_ref(), args).is_ok_and(|mut c| c.status().is_ok_and(|s| s.success()))
}

fn install_python(i: &Install) -> Result<(), String> {
    let python = i.root.join("python/bin/python3");
    if python.is_file() {
        return Ok(());
    }
    let archive = i.root.join(".python.tar.gz");
    let archive_text = archive.to_string_lossy().into_owned();
    let result = (|| {
        if !ran(i, "/usr/bin/curl", &["-fsSL", "--retry", "2", "-o", &archive_text, PYTHON_URL]) {
            return Err(AI_ERROR_DOWNLOAD.to_string());
        }
        if !sha256(&archive).is_some_and(|h| h == PYTHON_SHA256) {
            return Err(AI_ERROR_INTEGRITY.to_string());
        }
        let staging = i.root.join(".python.staging");
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging).map_err(|_| AI_ERROR_PACKAGES.to_string())?;
        if !ran(i, "/usr/bin/tar", &["-xzf", &archive_text, "-C", &staging.to_string_lossy()]) {
            return Err(AI_ERROR_INTEGRITY.to_string());
        }
        let _ = std::fs::remove_dir_all(i.root.join("python"));
        std::fs::rename(staging.join("python"), i.root.join("python")).map_err(|_| AI_ERROR_PACKAGES.to_string())?;
        let _ = std::fs::remove_dir_all(&staging);
        Ok(())
    })();
    let _ = std::fs::remove_file(&archive);
    result
}

fn sha256(file: &Path) -> Option<String> {
    let out = Command::new("/usr/bin/shasum").args(["-a", "256"]).arg(file).stderr(Stdio::null()).output().ok().filter(|o| o.status.success())?;
    String::from_utf8(out.stdout).ok()?.split_whitespace().next().map(str::to_string)
}

/// The venv is rebuilt when the bundled lock changes, so an update that moves MTPLX reinstalls it.
fn install_packages(i: &Install, requirements: &Path) -> Result<(), String> {
    let venv = i.root.join("venv");
    let marker = venv.join(".localflow-requirements");
    let lock = sha256(requirements).ok_or(AI_ERROR_PACKAGES)?;
    if std::fs::read_to_string(&marker).is_ok_and(|m| m == lock) {
        return Ok(());
    }
    let _ = std::fs::remove_dir_all(&venv);
    let ok = ran(i, i.root.join("python/bin/python3"), &["-m", "venv", &venv.to_string_lossy()])
        && ran(i, venv.join("bin/python"), &["-m", "pip", "install", "--disable-pip-version-check", "--no-input", "--no-cache-dir", "--require-hashes", "--no-deps", "--only-binary", ":all:", "-r", &requirements.to_string_lossy()]);
    if !ok {
        return Err(AI_ERROR_PACKAGES.into());
    }
    std::fs::write(marker, lock).map_err(|_| AI_ERROR_PACKAGES.to_string())
}

/// `mtplx pull` reuses a model already in `~/.mtplx/models`, including one MTPLX.app downloaded.
fn pull(i: &Install) -> Result<String, String> {
    let mtplx = i.root.join("venv/bin/mtplx");
    let failed = || AI_ERROR_DOWNLOAD.to_string();
    let mut command = tool(i, &mtplx, &["pull", i.model.id, "--revision", i.model.revision, "--progress-json"]).map_err(|_| failed())?;
    let mut child = command.stdout(Stdio::piped()).spawn().map_err(|_| failed())?;
    let mut path = None;
    for line in BufReader::new(child.stdout.take().ok_or_else(failed)?).lines().map_while(Result::ok) {
        match pull_event(&line) {
            Some(PullEvent::Progress(done, total)) => report(AiPhase::DownloadingModel(done, total.unwrap_or(i.model.download_bytes))),
            Some(PullEvent::Result(p)) => path = Some(p),
            None => {}
        }
    }
    let ok = child.wait().is_ok_and(|s| s.success());
    path.filter(|p| ok && Path::new(p).exists()).ok_or_else(failed)
}

#[derive(PartialEq, Debug)]
pub enum PullEvent {
    Progress(i64, Option<i64>),
    Result(String),
}

/// One `mtplx pull --progress-json` line; other events and noise are ignored.
pub fn pull_event(line: &str) -> Option<PullEvent> {
    if line.len() > 65_536 {
        return None;
    }
    let v: Value = serde_json::from_str(line).ok()?;
    match v["event"].as_str()? {
        "progress" => Some(PullEvent::Progress(v["size_bytes"].as_i64()?, v["total_bytes"].as_i64().filter(|t| *t > 0))),
        "result" => Some(PullEvent::Result(v["path"].as_str()?.to_string())),
        _ => None,
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let staging = path.with_extension("staging");
    std::fs::write(&staging, bytes)?;
    std::fs::rename(staging, path)
}

fn write_key_if_missing(root: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    use std::io::Read;
    let key = root.join("api-key");
    if key.exists() {
        return Ok(());
    }
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(key)?.write_all(hex.as_bytes())
}

/// flowd reports the backend ready once MTPLX has loaded the weights.
fn wait_until_serving() -> Result<(), String> {
    let origin = flow_core::settings::loopback_endpoint();
    let end = Instant::now() + START_DEADLINE;
    while Instant::now() < end {
        if flow_core::settings::rewrite_health(&origin, None).is_ok_and(|h| h.backend.is_some_and(|b| b.state == "ready")) {
            return Ok(());
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    Err(AI_ERROR_TIMEOUT.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pull_lines() {
        assert_eq!(pull_event(r#"{"event":"progress","size_bytes":5,"total_bytes":9}"#), Some(PullEvent::Progress(5, Some(9))));
        assert_eq!(pull_event(r#"{"event":"progress","size_bytes":5,"total_bytes":0}"#), Some(PullEvent::Progress(5, None)));
        assert_eq!(pull_event(r#"{"event":"result","path":"/m"}"#), Some(PullEvent::Result("/m".into())));
        assert_eq!(pull_event(r#"{"event":"other"}"#), None);
        assert_eq!(pull_event("noise"), None);
    }

    #[test]
    fn a_new_key_is_private_and_an_existing_one_stays() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("flow-key-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        write_key_if_missing(&dir).unwrap();
        let key = std::fs::read(dir.join("api-key")).unwrap();
        assert_eq!(key.len(), 64);
        assert_eq!(std::fs::metadata(dir.join("api-key")).unwrap().permissions().mode() & 0o777, 0o600);
        write_key_if_missing(&dir).unwrap();
        assert_eq!(std::fs::read(dir.join("api-key")).unwrap(), key);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Downloads Python and the locked packages for real, into `LOCALFLOW_AI_TEST_ROOT`, and pulls the
    /// smallest pack through the shared `~/.mtplx/models`. Touches no service.
    #[test]
    #[ignore]
    fn real_runtime_and_pull() {
        let root = PathBuf::from(std::env::var("LOCALFLOW_AI_TEST_ROOT").unwrap());
        let resources = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../apps/macos/LocalFlow/Resources/LocalAI");
        let install = Install { log: root.join("setup.log"), root, resources: resources.clone(), model: CATALOG[0] };
        prepare_folders(&install).unwrap();
        install_python(&install).unwrap();
        install_packages(&install, &resources.join("mtplx-requirements.txt")).unwrap();
        let path = pull(&install).unwrap();
        assert!(path.ends_with(&CATALOG[0].id.replace('/', "--")), "{path}");
    }

    struct NoAgents;
    impl Agents for NoAgents {
        fn loaded(&self, _: &str) -> bool {
            true
        }
        fn register(&self, _: &str) -> Result<(), String> {
            Ok(())
        }
        fn kickstart(&self, _: &str, _: bool) -> bool {
            true
        }
    }

    #[test]
    fn a_bundle_without_the_lock_stops_before_touching_anything() {
        let dir = std::env::temp_dir().join(format!("flow-noai-{}", std::process::id()));
        let install = Install { root: dir.join("r"), resources: dir.join("none"), log: dir.join("l"), model: CATALOG[0] };
        assert_eq!(run(&install, &NoAgents), Err(AI_ERROR_MISSING.to_string()));
        assert!(!dir.exists());
    }
}
