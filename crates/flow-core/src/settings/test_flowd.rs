//! A throwaway flowd for tests: built from `server/` with a Go overlay, on a temp directory, with
//! loopback listeners and a stub model backend. The overlay keeps its identity key in a temp file,
//! so neither the owner's Keychain nor the owner's server is touched. `server/` isn't modified.
//! Panics when flowd can't start: a test using this never skips. Dropping it stops every process.
#![cfg(unix)]

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const TOKEN: &str = "throwaway-rewrite-token";
pub const MODEL: &str = "stub-model";

/// Added to `package main` at build time only. `test-seed` goes through the real account store.
const OVERLAY: &str = r#"package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"localflow/server/internal/accounts"
)

type fileKey struct{}
type missing struct{}

func (missing) Error() string { return "no key" }
func (missing) ExitCode() int { return 44 }

func (fileKey) Run(_ context.Context, stdin []byte, args ...string) ([]byte, error) {
	path := os.Getenv("FLOWD_TEST_IDENTITY")
	if args[0] == "add-generic-password" {
		key, _, _ := strings.Cut(string(stdin), "\n")
		return nil, os.WriteFile(path, []byte(key), 0o600)
	}
	key, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, missing{}
	}
	return key, err
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func init() {
	if os.Getenv("FLOWD_TEST_IDENTITY") == "" {
		panic("test overlay without FLOWD_TEST_IDENTITY")
	}
	keychainRunner = fileKey{}
	if len(os.Args) == 3 && os.Args[1] == "test-seed" {
		ctx := context.Background()
		store, err := accounts.Open(os.Args[2], time.Now)
		must(err)
		user, _, err := store.EnsureUser(ctx, "apple", "test-subject", "Test")
		must(err)
		device, err := store.AddDevice(ctx, user.ID, "Test Mac", bytes.Repeat([]byte{4}, 65))
		must(err)
		must(store.SetUserState(ctx, user.ID, accounts.UserApproved, "admin:test"))
		must(store.SetDeviceState(ctx, device.ID, accounts.DeviceApproved, "admin:test"))
		token, _, err := store.IssueAccess(ctx, device.ID)
		must(err)
		fmt.Println(token)
		os.Exit(0)
	}
}
"#;

pub struct Flowd {
    /// `--remote-listen`: identity and the sealed channel.
    pub remote: String,
    /// `--listen`: rewrite and analysis health. Its backend answers and offers `MODEL`.
    pub rewrite: String,
    /// A second server: backend down, `--analysis=false`.
    pub no_backend: String,
    /// A third server: rewrite protocol 2 only.
    pub wrong_version: String,
    /// A closed port.
    pub down: String,
    pub token: String,
    /// From `flowd admin init`, not from the identity endpoint.
    pub fingerprint: String,
    /// An approved device's token, issued by the server's own store.
    pub access_token: String,
    children: Vec<Child>,
    dir: PathBuf,
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn output(command: &mut Command, what: &str) -> String {
    let out = command.output().unwrap_or_else(|e| panic!("{what}: {e}"));
    assert!(out.status.success(), "{what}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

impl Flowd {
    pub fn start() -> Flowd {
        let server = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().map(|a| a.join("server")).find(|s| s.join("go.mod").exists()).expect("server/go.mod");
        let unique = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("flowd-test-{}-{unique}", std::process::id()));
        let data = dir.join("data");
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&data).unwrap();
        let (overlay_go, overlay_json, bin, identity) = (dir.join("overlay.go"), dir.join("overlay.json"), dir.join("flowd"), dir.join("identity"));
        std::fs::write(&overlay_go, OVERLAY).unwrap();
        let replace = serde_json_escape(&server.join("cmd/flowd/zz_test_overlay.go"), &overlay_go);
        std::fs::write(&overlay_json, replace).unwrap();
        output(Command::new("go").current_dir(&server).arg("build").arg("-overlay").arg(&overlay_json).arg("-o").arg(&bin).arg("./cmd/flowd"), "go build flowd");

        let mut flowd = Flowd {
            remote: format!("http://127.0.0.1:{}", free_port()),
            rewrite: format!("http://127.0.0.1:{}", free_port()),
            no_backend: format!("http://127.0.0.1:{}", free_port()),
            wrong_version: format!("http://127.0.0.1:{}", free_port()),
            down: format!("http://127.0.0.1:{}", free_port()),
            token: TOKEN.into(),
            fingerprint: String::new(),
            access_token: String::new(),
            children: vec![],
            dir,
        };
        let tool = |args: &[&std::ffi::OsStr]| {
            let mut c = Command::new(&bin);
            c.args(args).env("FLOWD_TEST_IDENTITY", &identity).env("LOCALFLOW_REWRITE_TOKEN", TOKEN).env("LOCALFLOW_BACKEND_TOKEN", "");
            c
        };
        let init = output(&mut tool(&["admin".as_ref(), "--data-dir".as_ref(), data.as_ref(), "--dev".as_ref(), "init".as_ref()]), "flowd admin init");
        flowd.fingerprint = init.split_whitespace().skip_while(|w| *w != "fingerprint").nth(1).unwrap_or_else(|| panic!("no fingerprint in {init}")).to_string();
        flowd.access_token = output(&mut tool(&["test-seed".as_ref(), data.as_ref()]), "seed").trim().to_string();

        let backend = stub_backend();
        let addr = |url: &str| url.trim_start_matches("http://").to_string();
        let log = flowd.dir.join("log");
        let serve = |args: Vec<String>| {
            let file = std::fs::OpenOptions::new().create(true).append(true).open(&log).unwrap();
            tool(&[]).arg("serve").args(args).arg("--model").arg(MODEL).stdout(Stdio::null()).stderr(file).spawn().expect("spawn flowd")
        };
        let dead = addr(&flowd.down);
        let mut main_args: Vec<String> = ["--listen", &addr(&flowd.rewrite), "--backend", &format!("http://127.0.0.1:{backend}/v1"), "--remote-listen", &addr(&flowd.remote), "--dev", "--data-dir"].map(String::from).to_vec();
        main_args.push(data.display().to_string());
        flowd.children.push(serve(main_args));
        flowd.children.push(serve(["--listen", &addr(&flowd.no_backend), "--backend", &format!("http://{dead}/v1"), "--analysis=false"].map(String::from).to_vec()));
        flowd.children.push(serve(["--listen", &addr(&flowd.wrong_version), "--backend", &format!("http://127.0.0.1:{backend}/v1"), "--rewrite-protocol-versions", "2"].map(String::from).to_vec()));
        for url in [flowd.remote.clone(), flowd.rewrite.clone(), flowd.no_backend.clone(), flowd.wrong_version.clone()] {
            flowd.wait(&addr(&url));
        }
        flowd
    }

    fn wait(&mut self, addr: &str) {
        let deadline = Instant::now() + Duration::from_secs(20);
        while TcpStream::connect(addr).is_err() {
            let exited = self.children.iter_mut().any(|c| matches!(c.try_wait(), Ok(Some(_))));
            if exited || Instant::now() > deadline {
                panic!("flowd didn't listen on {addr}: {}", std::fs::read_to_string(self.dir.join("log")).unwrap_or_default());
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Flowd {
    fn drop(&mut self) {
        for child in &mut self.children {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn serde_json_escape(from: &Path, to: &Path) -> String {
    format!("{{\"Replace\":{{{:?}:{:?}}}}}", from.display().to_string(), to.display().to_string())
}

/// The one thing flowd's probe asks a model server. The thread ends with the test process.
fn stub_backend() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let mut buf = [0u8; 2048];
            let _ = stream.read(&mut buf);
            let body = format!("{{\"data\":[{{\"id\":\"{MODEL}\",\"capabilities\":{{\"json_schema\":true}}}}]}}");
            let _ = write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        }
    });
    port
}
