//! Finds and spawns the speech worker for `flow_core::dictation::lifecycle`. stdin and stdout only.
//! Its stderr goes nowhere in `serve`: the contract keeps it content-free, but nothing here needs it.
use flow_core::dictation::lifecycle::{Launcher, Process, Spawned};
use std::io;
use crate::{InstallState, ModelPack, Unavailable};
use flow_core::dictation::provision::{Line, parse};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex, OnceLock};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub const WORKER_ENV: &str = "LOCALFLOW_SPEECH_WORKER";

/// Where the worker can be, in order. Mac: the override, beside the executable, then the app's
/// `Helpers` (where `scripts/bundle-server-helpers.sh` puts it). Windows: beside the exe, only.
pub fn worker_candidates(exe_dir: &Path, windows: bool, env: Option<PathBuf>) -> Vec<PathBuf> {
    if windows {
        return vec![exe_dir.join("flow-speech-win.exe")];
    }
    let mut out: Vec<PathBuf> = env.into_iter().collect();
    out.push(exe_dir.join("flowd-speech"));
    out.push(exe_dir.join("../Helpers/flowd-speech"));
    out
}

/// The installed worker for this process, if there is one.
pub fn find_worker() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let windows = cfg!(windows);
    let env = std::env::var_os(WORKER_ENV)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);
    worker_candidates(exe.parent()?, windows, env)
        .into_iter()
        .find(|path| path.is_file())
}

#[cfg(not(windows))]
fn command(path: &Path) -> Command {
    Command::new(path)
}

#[cfg(windows)]
fn command(path: &Path) -> Command {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut command = Command::new(path);
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

struct ChildProcess(Child);
impl Process for ChildProcess {
    fn kill(&mut self) {
        let _ = self.0.kill();
    }
    fn wait(&mut self, timeout: Duration) -> bool {
        let until = Instant::now() + timeout;
        loop {
            match self.0.try_wait() {
                Ok(Some(_)) | Err(_) => return true,
                Ok(None) if Instant::now() >= until => return false,
                Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            }
        }
    }
}

/// Starts `<worker> serve --models <dir>` plus any extra arguments.
pub struct WorkerLauncher {
    pub path: PathBuf,
    pub args: Vec<String>,
}

impl WorkerLauncher {
    pub fn serve(path: PathBuf, models: &Path) -> WorkerLauncher {
        WorkerLauncher {
            path,
            args: vec![
                "serve".into(),
                "--models".into(),
                models.to_string_lossy().into_owned(),
            ],
        }
    }
}

impl Launcher for WorkerLauncher {
    fn launch(&mut self) -> io::Result<Spawned> {
        let mut child = command(&self.path)
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let missing = || io::Error::from(io::ErrorKind::BrokenPipe);
        let writer = child.stdin.take().ok_or_else(missing)?;
        let reader = child.stdout.take().ok_or_else(missing)?;
        Ok(Spawned {
            reader: Box::new(reader),
            writer: Box::new(writer),
            process: Box::new(ChildProcess(child)),
        })
    }
}

/// `<worker> provision --models <dir> [--booster]`. The caller reads the piped stderr's
/// `provision model=… state=…` lines for progress and the exit status for the outcome.
pub fn spawn_provision(path: &Path, models: &Path, args: &[&str]) -> io::Result<Child> {
    let mut command = command(path);
    command.arg("provision").arg("--models").arg(models).args(args);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
}

/// One pack's install: its progress comes from the worker's stderr, its result from the exit status.
#[derive(Clone, Default)]
pub struct Job(Arc<Mutex<Option<InstallState>>>);

impl Job {
    pub fn state(&self) -> Option<InstallState> {
        self.0.lock().unwrap().clone()
    }

    /// Starts unless one is running. A verified install leaves `marker` beside the models.
    // ponytail: launch trusts the marker instead of Swift's size-and-date fingerprint; Test rehashes. A fingerprint if files are seen to change.
    pub fn start(&self, worker: &Path, models: &Path, args: &[&str], marker: &'static str) -> io::Result<()> {
        let mut state = self.0.lock().unwrap();
        if matches!(*state, Some(InstallState::Running(..))) {
            return Ok(());
        }
        std::fs::create_dir_all(models)?;
        let path = models.join(marker);
        let _ = std::fs::remove_file(&path);
        let mut child = spawn_provision(worker, models, args)?;
        *state = Some(InstallState::Running(0, 0, false));
        let (job, stderr) = (self.0.clone(), child.stderr.take());
        std::thread::spawn(move || {
            let mut failure = None;
            for line in stderr.into_iter().flat_map(|e| BufReader::new(e).lines()).map_while(Result::ok) {
                match parse(&line) {
                    Some(Line::Progress { completed, total, verifying }) => *job.lock().unwrap() = Some(InstallState::Running(completed, total, verifying)),
                    Some(Line::Failed(reason)) => failure = Some(reason),
                    _ => {}
                }
            }
            let succeeded = child.wait().is_ok_and(|status| status.success());
            let end = match failure {
                None if succeeded && std::fs::write(&path, "").is_ok() => InstallState::Verified,
                failure => InstallState::Failed(failure.unwrap_or_else(|| "worker_failed".into())),
            };
            *job.lock().unwrap() = Some(end);
        });
        Ok(())
    }
}

struct Jobs {
    speech: Job,
    meeting: Job,
    booster: Job,
}
static JOBS: LazyLock<Jobs> = LazyLock::new(|| Jobs { speech: Job::default(), meeting: Job::default(), booster: Job::default() });
static MODELS: OnceLock<PathBuf> = OnceLock::new();

/// Where installs go: `Paths::models`, set once at launch.
pub fn set_models_dir(models: PathBuf) {
    let _ = MODELS.set(models);
}

fn pack(which: ModelPack) -> (&'static Job, &'static [&'static str], &'static str) {
    match which {
        ModelPack::Speech => (&JOBS.speech, &[], ".speech-verified"),
        ModelPack::Meeting => (&JOBS.meeting, &["--meeting", "--booster"], ".meeting-verified"),
        ModelPack::Booster => (&JOBS.booster, &["--booster"], ".booster-verified"),
    }
}

/// `Services::install_*` on the real platforms.
pub fn install(which: ModelPack) -> Result<(), Unavailable> {
    let (job, args, marker) = pack(which);
    let worker = find_worker().ok_or(Unavailable("the speech worker"))?;
    let models = MODELS.get().ok_or(Unavailable("the models folder"))?;
    job.start(&worker, models, args, marker).map_err(|_| Unavailable("the speech worker"))
}

/// `Services::install_state` on the real platforms: this run's job, or the marker of an earlier one.
pub fn install_state(which: ModelPack) -> InstallState {
    let (job, _, marker) = pack(which);
    job.state().unwrap_or_else(|| if MODELS.get().is_some_and(|m| m.join(marker).exists()) { InstallState::Verified } else { InstallState::Idle })
}

/// SET-243's full-hash check: provisioning rehashes whatever is on disk. Blocks.
pub fn verify_speech_model() -> Result<(), String> {
    let worker = find_worker().ok_or("worker_missing")?;
    let models = MODELS.get().ok_or("models_missing")?;
    let status = spawn_provision(&worker, models, &[]).and_then(|mut child| {
        // Read to the end: a closed pipe would end the worker on its next log line.
        if let Some(mut stderr) = child.stderr.take() {
            let _ = io::copy(&mut stderr, &mut io::sink());
        }
        child.wait()
    });
    if status.is_ok_and(|s| s.success()) { Ok(()) } else { Err("verify_failed".into()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A scripted provision process in a temp dir.
    #[cfg(unix)]
    fn outcome(name: &str, script: &str) -> (Vec<InstallState>, InstallState, PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("flow-provision-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let worker = dir.join("worker");
        std::fs::write(&worker, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o755)).unwrap();
        let (job, models) = (Job::default(), dir.join("models"));
        job.start(&worker, &models, &["--booster"], ".m").unwrap();
        let mut seen = vec![];
        let began = std::time::Instant::now();
        loop {
            let state = job.state().unwrap();
            if seen.last() != Some(&state) {
                seen.push(state.clone());
            }
            if !matches!(state, InstallState::Running(..)) {
                return (seen, state, models);
            }
            assert!(began.elapsed() < Duration::from_secs(20));
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    // parity: SET-255
    #[cfg(unix)]
    #[test]
    fn a_scripted_install_reaches_each_outcome() {
        let progress = r#"echo "provision model=m state=downloading completed=4 total=9" >&2; sleep 0.2; echo "provision model=m state=verifying completed=9 total=9" >&2; sleep 0.2"#;
        let (seen, end, models) = outcome("ok", &format!(r#"[ "$1 $2 $4" = "provision --models --booster" ] || exit 9; {progress}; echo "provision model=m state=verified completed=9 total=9" >&2"#));
        assert_eq!(end, InstallState::Verified);
        assert!(seen.contains(&InstallState::Running(4, 9, false)) && seen.contains(&InstallState::Running(9, 9, true)), "{seen:?}");
        assert!(models.join(".m").exists(), "launch will know");

        let (_, end, models) = outcome("failed", r#"echo "provision model=m state=failed reason=hash_mismatch" >&2; exit 1"#);
        assert_eq!(end, InstallState::Failed("hash_mismatch".into()));
        assert!(!models.join(".m").exists());
        let (_, end, _) = outcome("died", "exit 3");
        assert_eq!(end, InstallState::Failed("worker_failed".into()), "no reason, still a failure");
        let (_, end, models) = outcome("said_fail_exit_0", r#"echo "provision state=failed reason=x" >&2"#);
        assert_eq!(end, InstallState::Failed("x".into()));
        assert!(!models.join(".m").exists());
    }

    #[test]
    fn a_worker_that_cannot_start_leaves_nothing_running() {
        let job = Job::default();
        assert!(job.start(Path::new("/nonexistent/worker"), &std::env::temp_dir(), &[], ".never").is_err());
        assert_eq!(job.state(), None);
    }

    #[test]
    fn candidates_per_platform() {
        let exe = Path::new("/app/MacOS");
        assert_eq!(
            worker_candidates(exe, false, None),
            [
                exe.join("flowd-speech"),
                exe.join("../Helpers/flowd-speech")
            ]
        );
        assert_eq!(
            worker_candidates(exe, false, Some("/dev/worker".into()))[0],
            Path::new("/dev/worker"),
            "the override wins on the Mac"
        );
        assert_eq!(
            worker_candidates(exe, true, Some("/dev/worker".into())),
            [exe.join("flow-speech-win.exe")],
            "Windows: beside the exe, only"
        );
    }
}
