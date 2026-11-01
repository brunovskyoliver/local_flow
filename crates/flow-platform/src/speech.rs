//! Finds and spawns the speech worker for `flow_core::dictation::lifecycle`. stdin and stdout only.
//! Its stderr goes nowhere in `serve`: the contract keeps it content-free, but nothing here needs it.
use flow_core::dictation::lifecycle::{Launcher, Process, Spawned};
use std::io;
use std::path::{Path, PathBuf};
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
pub fn spawn_provision(path: &Path, models: &Path, booster: bool) -> io::Result<Child> {
    let mut command = command(path);
    command.arg("provision").arg("--models").arg(models);
    if booster {
        command.arg("--booster");
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
}

#[cfg(test)]
mod tests {
    use super::*;

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
