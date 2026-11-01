//! The pinned manifest, verification and model download. Hashes come from files really downloaded;
//! see `specs/026-dictation-both-platforms/research.md` R2. No pin means a refusal, never a skip.
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

pub const EMBEDDED: &str = include_str!("../manifest.json");
pub const MODEL_DIR: &str = "sherpa-parakeet-tdt-v3";
const MARKER: &str = ".verified";
const DOWNLOAD_LIMIT: Duration = Duration::from_secs(2 * 60 * 60);

#[derive(Clone, Debug, Deserialize)]
pub struct PinnedFile {
    pub name: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Runtime {
    pub library: String,
    pub files: Vec<PinnedFile>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Manifest {
    pub engine: String,
    pub sdk: String,
    pub model_id: String,
    pub model_revision: String,
    pub source: String,
    pub files: Vec<PinnedFile>,
    pub runtime: BTreeMap<String, Runtime>,
    #[serde(skip)]
    pub hash: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    /// No hash for something it would have to trust.
    Unpinned,
    /// A plain address anywhere but loopback.
    BadSource,
    Download,
    /// The bytes don't match the pin.
    Mismatch,
    Disk,
}

impl Failure {
    pub fn label(self) -> &'static str {
        match self {
            Failure::Unpinned => "unpinned",
            Failure::BadSource => "bad_source",
            Failure::Download => "download",
            Failure::Mismatch => "mismatch",
            Failure::Disk => "disk",
        }
    }
}

fn pinned(file: &PinnedFile) -> bool {
    file.sha256.len() == 64
        && file
            .sha256
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        && file.size > 0
        // `:` would name an alternate data stream on NTFS.
        && !file.name.contains(['/', '\\', ':'])
        && !file.name.starts_with('.')
}

impl Manifest {
    pub fn parse(text: &str) -> Option<Manifest> {
        let mut manifest: Manifest = serde_json::from_str(text).ok()?;
        manifest.hash = hash_bytes(text.as_bytes());
        Some(manifest)
    }
    pub fn embedded() -> Manifest {
        Manifest::parse(EMBEDDED).expect("the embedded manifest parses")
    }
    /// This build's runtime, only if every file of it is pinned, the library it loads included.
    pub fn runtime_here(&self) -> Option<&Runtime> {
        self.runtime
            .get(&format!(
                "{}-{}",
                std::env::consts::OS,
                std::env::consts::ARCH
            ))
            .filter(|r| r.files.iter().all(pinned) && r.files.iter().any(|f| f.name == r.library))
    }
    fn model_pinned(&self) -> bool {
        !self.files.is_empty() && self.files.iter().all(pinned)
    }
}

pub fn hash_bytes(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Streams, since the encoder is 652 MB.
pub fn hash_file(path: &Path) -> io::Result<String> {
    let mut hasher = Sha256::new();
    io::copy(&mut File::open(path)?, &mut hasher)?;
    Ok(hex(&hasher.finalize()))
}

fn file_ok(dir: &Path, file: &PinnedFile) -> bool {
    let path = dir.join(&file.name);
    fs::metadata(&path).is_ok_and(|m| m.is_file() && m.len() == file.size)
        && hash_file(&path).is_ok_and(|hash| hash == file.sha256)
}

/// Every runtime file against its pin, before anything loads it. Only about 20 MB, so on each start.
pub fn runtime_verified(dir: &Path, runtime: &Runtime) -> bool {
    runtime.files.iter().all(|file| file_ok(dir, file))
}

/// Each file's size and modified time, under the manifest's hash.
fn stamp(dir: &Path, manifest: &Manifest) -> Option<String> {
    let mut out = format!("{}\n", manifest.hash);
    for file in &manifest.files {
        let meta = fs::metadata(dir.join(&file.name)).ok()?;
        let modified = meta
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_nanos();
        if meta.len() != file.size {
            return None;
        }
        out.push_str(&format!("{} {} {modified}\n", file.name, meta.len()));
    }
    Some(out)
}

/// What `serve` checks at each start: provision hashed these same files. Hashing 670 MB per start
/// would slow the first dictation after every release.
// ponytail: flipped bits behind an unchanged size and time aren't seen here; then the load or the
// recognition fails. Re-running provision hashes everything again.
pub fn model_ready(models: &Path, manifest: &Manifest) -> Option<PathBuf> {
    let dir = models.join(MODEL_DIR);
    if !manifest.model_pinned() {
        return None;
    }
    (fs::read_to_string(dir.join(MARKER)).ok()? == stamp(&dir, manifest)?).then_some(dir)
}

fn valid_source(source: &str) -> bool {
    source.starts_with("https://") || source.starts_with("http://127.0.0.1:")
}

fn download(
    url: &str,
    part: &Path,
    file: &PinnedFile,
    progress: &mut dyn FnMut(u64),
) -> Result<(), Failure> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_connect(Some(Duration::from_secs(30)))
        .timeout_global(Some(DOWNLOAD_LIMIT))
        .build()
        .into();
    let response = agent.get(url).call().map_err(|_| Failure::Download)?;
    let mut body = response.into_body().into_reader();
    let mut out = File::create(part).map_err(|_| Failure::Disk)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    let mut total = 0u64;
    loop {
        let count = match body.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return Err(Failure::Download),
        };
        total += count as u64;
        // Bounded by the pin, whatever the server sends.
        if total > file.size {
            return Err(Failure::Mismatch);
        }
        hasher.update(&buffer[..count]);
        out.write_all(&buffer[..count]).map_err(|_| Failure::Disk)?;
        progress(count as u64);
    }
    out.sync_all().map_err(|_| Failure::Disk)?;
    if total != file.size || hex(&hasher.finalize()) != file.sha256 {
        return Err(Failure::Mismatch);
    }
    Ok(())
}

/// Downloads what's missing or wrong and verifies every file. A file takes its final name only
/// after its hash matches. Progress goes to stderr as content-free lines:
/// `provision model=<id> state=downloading|verifying|verified|failed [completed=<bytes> total=<bytes>] [reason=<label>]`.
// ponytail: a failed download restarts its file. Add Range if interrupted installs become a problem.
pub fn provision(models: &Path, manifest: &Manifest) -> Result<PathBuf, Failure> {
    let id = &manifest.model_id;
    if !manifest.model_pinned() {
        return Err(Failure::Unpinned);
    }
    if !valid_source(&manifest.source) {
        return Err(Failure::BadSource);
    }
    let dir = models.join(MODEL_DIR);
    fs::create_dir_all(&dir).map_err(|_| Failure::Disk)?;
    let _ = fs::remove_file(dir.join(MARKER));
    let total: u64 = manifest.files.iter().map(|f| f.size).sum();
    let mut completed = 0u64;
    let mut reported = 0u64;
    for file in &manifest.files {
        eprintln!("provision model={id} state=verifying completed={completed} total={total}");
        if !file_ok(&dir, file) {
            let part = dir.join(format!("{}.part", file.name));
            let url = format!("{}/{}", manifest.source, file.name);
            let mut report = |count: u64| {
                completed += count;
                if completed - reported >= 8 << 20 {
                    reported = completed;
                    eprintln!(
                        "provision model={id} state=downloading completed={completed} total={total}"
                    );
                }
            };
            if let Err(failure) = download(&url, &part, file, &mut report) {
                let _ = fs::remove_file(&part);
                return Err(failure);
            }
            fs::rename(&part, dir.join(&file.name)).map_err(|_| Failure::Disk)?;
        } else {
            completed += file.size;
        }
    }
    let stamped = stamp(&dir, manifest).ok_or(Failure::Disk)?;
    fs::write(dir.join(MARKER), stamped).map_err(|_| Failure::Disk)?;
    eprintln!("provision model={id} state=verified completed={total} total={total}");
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("flow-speech-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Serves `bodies` by path on loopback; anything else is a 404. Returns the base address.
    fn server(bodies: Vec<(String, Vec<u8>)>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                let mut request = [0u8; 2048];
                let count = stream.read(&mut request).unwrap_or(0);
                let line = String::from_utf8_lossy(&request[..count])
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .to_string();
                let path = line.split(' ').nth(1).unwrap_or_default().to_string();
                match bodies.iter().find(|(p, _)| *p == path) {
                    Some((_, body)) => {
                        let _ = write!(
                            stream,
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = stream.write_all(body);
                    }
                    None => {
                        let _ = write!(
                            stream,
                            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        );
                    }
                }
            }
        });
        format!("http://{address}")
    }

    fn manifest(source: &str, files: &[(&str, &[u8])]) -> Manifest {
        let files: Vec<_> = files.iter().map(|(name, body)| serde_json::json!({"name": name, "size": body.len(), "sha256": hash_bytes(body)})).collect();
        let text = serde_json::json!({"engine": "e", "sdk": "s", "model_id": "m", "model_revision": "r", "source": source, "files": files, "runtime": {}}).to_string();
        Manifest::parse(&text).unwrap()
    }

    #[test]
    fn the_embedded_manifest_pins_everything_it_names() {
        let manifest = Manifest::embedded();
        assert!(manifest.model_pinned());
        assert!(
            manifest.source.starts_with("https://")
                && manifest.source.ends_with(&manifest.model_revision),
            "a pinned revision"
        );
        assert!(manifest.runtime["windows-x86_64"].files.iter().all(pinned));
        assert!(manifest.runtime["macos-aarch64"].files.iter().all(pinned));
        assert_eq!(manifest.hash, hash_bytes(EMBEDDED.as_bytes()));
        for runtime in manifest.runtime.values() {
            assert!(runtime.files.iter().any(|f| f.name == runtime.library), "{}", runtime.library);
        }
    }

    #[test]
    fn a_runtime_library_outside_its_pinned_files_is_no_runtime() {
        let here = format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH);
        let file = |name: &str| PinnedFile { name: name.into(), size: 1, sha256: hash_bytes(b"x") };
        let with = |library: &str, name: &str| {
            let mut m = manifest("https://example.invalid", &[("a", b"x")]);
            m.runtime.insert(here.clone(), Runtime { library: library.into(), files: vec![file(name)] });
            m
        };
        assert!(with("lib", "lib").runtime_here().is_some());
        assert!(with("../evil", "lib").runtime_here().is_none(), "a library nothing pins");
        assert!(with("lib", "lib:stream").runtime_here().is_none(), "an alternate data stream");
        assert!(with("lib:stream", "lib:stream").runtime_here().is_none());
        let models = temp("colon");
        assert_eq!(provision(&models, &manifest("https://example.invalid", &[("a:b", b"x")])), Err(Failure::Unpinned));
        fs::remove_dir_all(models).unwrap();
    }

    #[test]
    fn provisioning_refuses_rather_than_skips_a_missing_pin() {
        let models = temp("unpinned");
        for sha in ["", "abc", &"Z".repeat(64)] {
            let mut bad = manifest("https://example.invalid", &[("a", b"x")]);
            bad.files[0].sha256 = sha.to_string();
            assert_eq!(provision(&models, &bad), Err(Failure::Unpinned), "{sha}");
        }
        let mut none = manifest("https://example.invalid", &[("a", b"x")]);
        none.files.clear();
        assert_eq!(
            provision(&models, &none),
            Err(Failure::Unpinned),
            "no files"
        );
        assert!(!models.join(MODEL_DIR).exists(), "nothing touched");
        fs::remove_dir_all(models).unwrap();
    }

    #[test]
    fn provisioning_refuses_a_plain_address_and_a_path_in_a_name() {
        let models = temp("source");
        assert_eq!(
            provision(&models, &manifest("http://example.invalid", &[("a", b"x")])),
            Err(Failure::BadSource)
        );
        assert_eq!(
            provision(
                &models,
                &manifest("https://example.invalid", &[("../a", b"x")])
            ),
            Err(Failure::Unpinned)
        );
        fs::remove_dir_all(models).unwrap();
    }

    #[test]
    fn downloads_verifies_and_marks_then_serve_finds_it() {
        let models = temp("download");
        let base = server(vec![
            ("/a.onnx".into(), b"aaaa".to_vec()),
            ("/b.txt".into(), b"bb".to_vec()),
        ]);
        let good = manifest(&base, &[("a.onnx", b"aaaa"), ("b.txt", b"bb")]);
        assert_eq!(model_ready(&models, &good), None);
        let dir = provision(&models, &good).unwrap();
        assert_eq!(fs::read(dir.join("a.onnx")).unwrap(), b"aaaa");
        assert!(!dir.join("a.onnx.part").exists());
        assert_eq!(model_ready(&models, &good), Some(dir.clone()));

        // A changed size or a changed manifest is no longer ready.
        fs::write(dir.join("b.txt"), b"bbb").unwrap();
        assert_eq!(model_ready(&models, &good), None);
        // Same size, wrong bytes: provisioning hashes everything and replaces it.
        fs::write(dir.join("b.txt"), b"zz").unwrap();
        provision(&models, &good).unwrap();
        assert_eq!(fs::read(dir.join("b.txt")).unwrap(), b"bb");
        let other = manifest(&base, &[("a.onnx", b"aaaa")]);
        assert_eq!(model_ready(&models, &other), None);
        fs::remove_dir_all(models).unwrap();
    }

    #[test]
    fn a_wrong_or_oversized_download_never_takes_the_final_name() {
        let models = temp("mismatch");
        let base = server(vec![
            ("/a".into(), b"evil".to_vec()),
            ("/big".into(), b"far too long".to_vec()),
        ]);
        assert_eq!(
            provision(&models, &manifest(&base, &[("a", b"good")])),
            Err(Failure::Mismatch)
        );
        assert_eq!(
            provision(&models, &manifest(&base, &[("big", b"short")])),
            Err(Failure::Mismatch)
        );
        assert_eq!(
            provision(&models, &manifest(&base, &[("missing", b"x")])),
            Err(Failure::Download)
        );
        let dir = models.join(MODEL_DIR);
        for name in ["a", "a.part", "big", "big.part", "missing", MARKER] {
            assert!(!dir.join(name).exists(), "{name}");
        }
        fs::remove_dir_all(models).unwrap();
    }

    #[test]
    fn runtime_is_checked_against_its_pin() {
        let dir = temp("runtime");
        fs::write(dir.join("lib"), b"code").unwrap();
        let file = |body: &[u8]| PinnedFile {
            name: "lib".into(),
            size: body.len() as u64,
            sha256: hash_bytes(body),
        };
        assert!(runtime_verified(
            &dir,
            &Runtime {
                library: "lib".into(),
                files: vec![file(b"code")]
            }
        ));
        assert!(!runtime_verified(
            &dir,
            &Runtime {
                library: "lib".into(),
                files: vec![file(b"Code")]
            }
        ));
        fs::remove_file(dir.join("lib")).unwrap();
        assert!(!runtime_verified(
            &dir,
            &Runtime {
                library: "lib".into(),
                files: vec![file(b"code")]
            }
        ));
        fs::remove_dir_all(dir).unwrap();
    }
}
