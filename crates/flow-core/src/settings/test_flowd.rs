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
/// A processor's output, the same SQL the Swift cross-check applies. No backticks: it's a Go raw string.
pub const PROCESSED: &str = include_str!("../../../../fixtures/handoff/processed.sql");
pub const MODEL: &str = "stub-model";

/// Added to `package main` at build time only. `test-seed` goes through the real account store.
const OVERLAY: &str = r#"package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"

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

// The fake meeting processor: flowd's `--meeting-processor` runs this same binary. It checks the
// uploaded audio against the bundle, reports progress, then writes the shared fixture's results.
func fakeProcessor() {
	var dir, meeting string
	for i := 1; i+1 < len(os.Args); i++ {
		switch os.Args[i] {
		case "--bundle":
			dir = os.Args[i+1]
		case "--meeting":
			meeting = os.Args[i+1]
		}
	}
	db, err := sql.Open("sqlite", filepath.Join(dir, "bundle.sqlite"))
	must(err)
	rows, err := db.Query("SELECT s.relative_path, s.byte_size FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id WHERE t.meeting_id=? AND s.state='finalized'", meeting)
	must(err)
	for rows.Next() {
		var path string
		var size int64
		must(rows.Scan(&path, &size))
		info, err := os.Stat(filepath.Join(dir, meeting, filepath.Base(path)))
		must(err)
		if info.Size() != size {
			must(fmt.Errorf("%s has %d bytes, the bundle says %d", path, info.Size(), size))
		}
	}
	must(rows.Err())
	var title string
	must(db.QueryRow("SELECT title FROM meetings WHERE id=?", meeting).Scan(&title))
	if title == "worker fails" {
		os.Exit(9)
	}
	must(os.WriteFile(filepath.Join(dir, "progress"), []byte("40"), 0o600))
	time.Sleep(700 * time.Millisecond)
	_, err = db.Exec(strings.ReplaceAll(`__PROCESSED__`, "{ID}", meeting))
	must(err)
	must(db.Close())
	os.Exit(0)
}

// The fake speech worker: flowd's `--speech-worker` runs this same binary as
// `serve --models <dir>`. Files in that directory steer it from the test.
func fakeWorker(dir string) {
	send := func(header map[string]any) {
		body, err := json.Marshal(header)
		must(err)
		frame := binary.BigEndian.AppendUint32(nil, uint32(len(body)))
		frame = append(append(frame, body...), 0, 0, 0, 0)
		_, err = os.Stdout.Write(frame)
		must(err)
	}
	send(map[string]any{"type": "ready", "protocol": 1, "model": map[string]any{"engine": "fake", "model_id": "fake-model", "model_revision": "1", "manifest_hash": "fake", "sdk": "0", "worker_build": "test"}})
	for {
		var length uint32
		if binary.Read(os.Stdin, binary.BigEndian, &length) != nil {
			os.Exit(0)
		}
		body := make([]byte, length)
		_, err := io.ReadFull(os.Stdin, body)
		must(err)
		must(binary.Read(os.Stdin, binary.BigEndian, &length))
		_, err = io.CopyN(io.Discard, os.Stdin, int64(length))
		must(err)
		var header struct {
			Type        string
			Job         uint64
			SampleCount int `json:"sample_count"`
		}
		must(json.Unmarshal(body, &header))
		if header.Type != "recognize" {
			os.Exit(0)
		}
		if delay, err := os.ReadFile(filepath.Join(dir, "delay_ms")); err == nil {
			var ms int
			fmt.Sscan(string(delay), &ms)
			time.Sleep(time.Duration(ms) * time.Millisecond)
		}
		if _, err := os.Stat(filepath.Join(dir, "fail")); err == nil {
			send(map[string]any{"type": "error", "job": header.Job, "code": "model_unavailable"})
			continue
		}
		send(map[string]any{"type": "result", "job": header.Job, "recognition_ms": 3, "window": map[string]any{"sample_count": header.SampleCount, "text": "hello world", "tokens": []any{}, "boost_hints": []any{}}})
	}
}

func init() {
	if len(os.Args) > 1 && os.Args[1] == "--bundle" {
		fakeProcessor()
	}
	if len(os.Args) == 4 && os.Args[1] == "serve" && os.Args[2] == "--models" {
		fakeWorker(os.Args[3])
	}
	if os.Getenv("FLOWD_TEST_IDENTITY") == "" {
		panic("test overlay without FLOWD_TEST_IDENTITY")
	}
	keychainRunner = fileKey{}
	if len(os.Args) == 2 && os.Args[1] == "test-keygen" {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		must(err)
		fmt.Printf("%x %x\n", key.D.FillBytes(make([]byte, 32)), elliptic.Marshal(elliptic.P256(), key.X, key.Y))
		os.Exit(0)
	}
	if len(os.Args) == 4 && os.Args[1] == "test-sign" {
		scalar, err := hex.DecodeString(os.Args[2])
		must(err)
		message, err := hex.DecodeString(os.Args[3])
		must(err)
		key := &ecdsa.PrivateKey{D: new(big.Int).SetBytes(scalar)}
		key.Curve = elliptic.P256()
		key.X, key.Y = elliptic.P256().ScalarBaseMult(scalar)
		digest := sha256.Sum256(message)
		der, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
		must(err)
		fmt.Printf("%x\n", der)
		os.Exit(0)
	}
	if len(os.Args) == 4 && os.Args[1] == "test-issuer-keys" {
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		must(err)
		must(os.WriteFile(os.Args[2], x509.MarshalPKCS1PrivateKey(key), 0o600))
		jwks, err := json.Marshal(map[string]any{"keys": []map[string]string{{"kty": "RSA", "alg": "RS256", "use": "sig", "kid": "test", "n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()), "e": "AQAB"}}})
		must(err)
		must(os.WriteFile(os.Args[3], jwks, 0o600))
		os.Exit(0)
	}
	if len(os.Args) == 6 && os.Args[1] == "test-mint" {
		der, err := os.ReadFile(os.Args[2])
		must(err)
		key, err := x509.ParsePKCS1PrivateKey(der)
		must(err)
		now := time.Now().Unix()
		claims, err := json.Marshal(map[string]any{"iss": os.Args[3], "aud": os.Args[4], "sub": "google-subject", "email_verified": true, "nonce": os.Args[5], "iat": now, "exp": now + 600})
		must(err)
		enc := base64.RawURLEncoding.EncodeToString
		signed := enc([]byte(`{"alg":"RS256","kid":"test"}`)) + "." + enc(claims)
		digest := sha256.Sum256([]byte(signed))
		signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
		must(err)
		fmt.Println(signed + "." + enc(signature))
		os.Exit(0)
	}
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
    bin: PathBuf,
    identity: PathBuf,
    data: PathBuf,
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
    pub const GOOGLE_CLIENT_ID: &str = "test-client.apps.googleusercontent.com";
    const TEST_ISSUER: &str = "https://issuer.test";

    pub fn start() -> Flowd {
        Flowd::launch(false)
    }

    /// A debug-tagged flowd that takes ID tokens from a local RS256 issuer as Google's.
    pub fn start_with_test_issuer() -> Flowd {
        Flowd::launch(true)
    }

    /// An ID token flowd accepts, for `nonce`.
    pub fn mint_id_token(&self, nonce: &str) -> String {
        let key = self.dir.join("issuer.der").display().to_string();
        self.tool(&["test-mint", &key, Flowd::TEST_ISSUER, Flowd::GOOGLE_CLIENT_ID, nonce]).trim().to_string()
    }

    fn launch(test_issuer: bool) -> Flowd {
        let server = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().map(|a| a.join("server")).find(|s| s.join("go.mod").exists()).expect("server/go.mod");
        // The clock alone collides: parallel tests start within its microsecond resolution.
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = (SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos(), NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        let dir = std::env::temp_dir().join(format!("flowd-test-{}-{}-{}", std::process::id(), unique.0, unique.1));
        let data = dir.join("data");
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&data).unwrap();
        let (overlay_go, overlay_json, bin, identity) = (dir.join("overlay.go"), dir.join("overlay.json"), dir.join("flowd"), dir.join("identity"));
        std::fs::write(&overlay_go, OVERLAY.replace("__PROCESSED__", PROCESSED)).unwrap();
        let replace = serde_json_escape(&server.join("cmd/flowd/zz_test_overlay.go"), &overlay_go);
        std::fs::write(&overlay_json, replace).unwrap();
        let tags = if test_issuer { "localflow_debug" } else { "" };
        output(Command::new("go").current_dir(&server).arg("build").arg("-tags").arg(tags).arg("-overlay").arg(&overlay_json).arg("-o").arg(&bin).arg("./cmd/flowd"), "go build flowd");

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
            bin: bin.clone(),
            identity: identity.clone(),
            data: data.clone(),
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
        main_args.extend(["--meeting-processor".to_string(), bin.display().to_string()]);
        std::fs::create_dir_all(flowd.dir.join("models")).unwrap();
        main_args.extend(["--speech-worker".to_string(), bin.display().to_string(), "--speech-models".to_string(), flowd.dir.join("models").display().to_string()]);
        if test_issuer {
            let (key, jwks) = (flowd.dir.join("issuer.der"), flowd.dir.join("jwks.json"));
            output(&mut tool(&["test-issuer-keys".as_ref(), key.as_ref(), jwks.as_ref()]), "issuer keys");
            main_args.extend(["--google-client-id".to_string(), Flowd::GOOGLE_CLIENT_ID.into(), "--test-issuer".into(), Flowd::TEST_ISSUER.into(), "--test-jwks".into(), jwks.display().to_string()]);
        }
        flowd.children.push(serve(main_args));
        flowd.children.push(serve(["--listen", &addr(&flowd.no_backend), "--backend", &format!("http://{dead}/v1"), "--analysis=false"].map(String::from).to_vec()));
        flowd.children.push(serve(["--listen", &addr(&flowd.wrong_version), "--backend", &format!("http://127.0.0.1:{backend}/v1"), "--rewrite-protocol-versions", "2"].map(String::from).to_vec()));
        for url in [flowd.remote.clone(), flowd.rewrite.clone(), flowd.no_backend.clone(), flowd.wrong_version.clone()] {
            flowd.wait(&addr(&url));
        }
        flowd
    }

    fn tool(&self, args: &[&str]) -> String {
        output(Command::new(&self.bin).args(args).env("FLOWD_TEST_IDENTITY", &self.identity), "flowd test tool")
    }

    /// `flowd admin --data-dir <data> --dev <args>`.
    pub fn admin(&self, args: &[&str]) -> String {
        let data = self.data.display().to_string();
        self.tool(&[&["admin", "--data-dir", &data, "--dev"], args].concat())
    }

    /// A new pairing token from the admin tool.
    /// Steers the fake speech worker: each window takes this long.
    pub fn worker_delay(&self, ms: u64) {
        std::fs::write(self.dir.join("models/delay_ms"), ms.to_string()).unwrap();
    }

    /// Steers the fake speech worker: every window answers `model_unavailable`.
    pub fn worker_fails(&self, fails: bool) {
        let path = self.dir.join("models/fail");
        if fails {
            std::fs::write(path, "").unwrap();
        } else {
            let _ = std::fs::remove_file(path);
        }
    }

    pub fn pair_token(&self, label: &str) -> String {
        let json = self.admin(&["token", "create", "--label", label, "--json"]);
        json_text(&json, "token").unwrap_or_else(|| panic!("no token field in the admin tool's answer"))
    }

    /// Makes a handoff meeting another device's. Each token redeems as a new user, so a test can't
    /// have two devices of one user without a sign-in; `<meeting dir>/device` is all `mine` reads.
    pub fn hand_to_another_device(&self, meeting: &str) {
        fn find(dir: &Path, meeting: &str) -> Option<PathBuf> {
            std::fs::read_dir(dir).ok()?.flatten().find_map(|e| if e.file_name() == meeting && e.path().join("device").exists() { Some(e.path().join("device")) } else if e.path().is_dir() { find(&e.path(), meeting) } else { None })
        }
        std::fs::write(find(&self.data, meeting).expect("the meeting's handoff directory"), "999999").unwrap();
    }

    /// Revokes the device that redeemed the most recent token.
    pub fn revoke_newest_device(&self) {
        let list = self.admin(&["token", "list", "--json"]);
        let id = list.rsplit("\"device_id\":").next().and_then(|tail| tail.split(|c: char| !c.is_ascii_digit() && c != ' ').find(|s| !s.trim().is_empty())).unwrap_or_else(|| panic!("no device in {list}")).trim().to_string();
        self.admin(&["revoke", "device", &id]);
    }

    /// A software P-256 key: scalar hex and X9.63 public key.
    pub fn keygen(&self) -> (String, Vec<u8>) {
        let out = self.tool(&["test-keygen"]);
        let (scalar, public) = out.trim().split_once(' ').unwrap();
        (scalar.to_string(), unhex(public))
    }

    /// DER ECDSA over the SHA-256 of `message`.
    pub fn sign(&self, scalar: &str, message: &[u8]) -> Vec<u8> {
        let hex: String = message.iter().map(|b| format!("{b:02x}")).collect();
        unhex(self.tool(&["test-sign", scalar, &hex]).trim())
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

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

/// A string field of a flat JSON answer: this file stays std only.
fn json_text(json: &str, key: &str) -> Option<String> {
    let tail = json.split(&format!("\"{key}\"")).nth(1)?.trim_start().strip_prefix(':')?.trim_start().strip_prefix('"')?;
    Some(tail.split('"').next()?.to_string())
}

fn serde_json_escape(from: &Path, to: &Path) -> String {
    format!("{{\"Replace\":{{{:?}:{:?}}}}}", from.display().to_string(), to.display().to_string())
}

/// The one thing flowd's probe asks a model server. The thread ends with the test process.
fn stub_backend() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        // A thread each: a connection left open by something probing loopback can't hold up flowd's.
        for mut stream in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let mut request = Vec::new();
                let mut buf = [0u8; 8192];
                let complete = |r: &[u8]| {
                    let text = String::from_utf8_lossy(r);
                    let Some(end) = text.find("\r\n\r\n") else { return false };
                    let length = text.lines().find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").and_then(|n| n.trim().parse::<usize>().ok())).unwrap_or(0);
                    r.len() >= end + 4 + length
                };
                while !complete(&request) {
                    match stream.read(&mut buf) {
                        Ok(n) if n > 0 => request.extend_from_slice(&buf[..n]),
                        _ => break,
                    }
                }
                // A completion: the schema-guided answer is one JSON string.
                if request.starts_with(b"POST") {
                    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"\\\"Hello world.\\\"\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
                    let _ = write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    return;
                }
                let body = format!("{{\"data\":[{{\"id\":\"{MODEL}\",\"capabilities\":{{\"json_schema\":true}}}}]}}");
                let _ = write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            });
        }
    });
    port
}
