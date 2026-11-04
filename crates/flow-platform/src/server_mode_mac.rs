//! Server mode's processes (Feature 028, research R6). Every `launchctl`, `flowd admin`,
//! `flowd-speech` and loopback admin call goes through `ServerProcessRunner`, so tests never start
//! one; the paths and argument lists come from `flow_core::server_mode`.
use flow_core::server_mode::ServerModePaths;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
    fn get(&self, url: &str, bearer: &str) -> HttpAnswer {
        let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(ADMIN_TIMEOUT)).max_redirects(0).http_status_as_error(false).proxy(None).build().into();
        let mut response = agent.get(url).header("Authorization", format!("Bearer {bearer}")).call().map_err(|_| "unreachable".to_string())?;
        let status = response.status().as_u16();
        let body = response.body_mut().with_config().limit(MAX_ADMIN_BODY).read_to_vec().map_err(|_| "unreadable".to_string())?;
        Ok((status, body))
    }
}

/// One call a `RecordingRunner` saw.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecordedCall {
    Run { program: PathBuf, args: Vec<String> },
    Get { url: String, bearer: String },
}

type RunAnswer = Box<dyn FnMut(&Path, &[String]) -> ProcessResult + Send>;
type GetAnswer = Box<dyn FnMut(&str) -> HttpAnswer + Send>;

/// A runner for tests: records every call and answers with scripted closures. By default every
/// run succeeds with no output and nothing answers HTTP.
pub struct RecordingRunner {
    calls: Mutex<Vec<RecordedCall>>,
    run_answer: Mutex<RunAnswer>,
    get_answer: Mutex<GetAnswer>,
}

impl Default for RecordingRunner {
    fn default() -> Self {
        RecordingRunner { calls: Mutex::default(), run_answer: Mutex::new(Box::new(|_, _| ProcessResult::ok(""))), get_answer: Mutex::new(Box::new(|_| Err("unreachable".into()))) }
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

    #[test]
    fn the_system_runner_reports_what_it_could_not_start() {
        let result = SystemRunner.run(Path::new("/nonexistent/flowd"), &[]);
        assert_eq!((result.status, result.reason()), (-1, "could not start /nonexistent/flowd".to_string()));
        let echoed = SystemRunner.run(Path::new("/bin/sh"), &["-c".into(), "printf out; printf err >&2; exit 4".into()]);
        assert_eq!(echoed, ProcessResult { status: 4, output: "out".into(), error: "err".into() });
    }
}
