//! `HandoffFileTransfer` and the `handoff` op's messages. One file moves in bounded chunks, so memory
//! doesn't grow with it: uploads read and hash in pieces and resume at the server's size; downloads
//! append to a private `.part` beside the target, hash as they go and publish with one rename.
use super::channel::{ChannelError, ServerMessage};
use super::pool::{Pool, Role};
use crate::settings::{Sha256, base64url_decode, base64url_encode};
use serde_json::{Value, json};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const CHUNK_BYTES: usize = 48_000;
/// The largest file either side accepts, as the server's `MaxHandoffFileBytes`.
pub const MAX_FILE_BYTES: u64 = 1 << 30;
/// The largest chunk accepted from a server; it sends at most 48,000 bytes.
pub const MAX_CHUNK_BYTES: usize = 1 << 20;
/// Uploads of one file whose checksum the server rejected before giving up.
pub const MAX_MISMATCHES: u32 = 3;
const HASH_READ_BYTES: usize = 1 << 20;

/// Why a call or a transfer didn't finish, in the terms the step machine acts on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    /// `RemoteMeetingWaiting`: unreachable, busy or a stopped worker. The code is `server_failure`.
    Waiting(String),
    /// The server doesn't offer the op.
    NotOffered,
    /// `DictationFailure.invalidResult`: the same request gets the same answer.
    Refused,
    /// The server never accepted the file's checksum. Download: its partial file is dropped.
    ChecksumMismatch,
    /// A local file failed or changed. Never logged with content.
    Local,
}

impl From<std::io::Error> for Failure {
    fn from(_: std::io::Error) -> Failure {
        Failure::Local
    }
}

/// `RemoteMeetingJobs.mapped`. A revoked or expired device waits too; the next attempt routes by the new state.
pub fn mapped(error: ChannelError) -> Failure {
    match error {
        ChannelError::Protocol => Failure::Refused,
        ChannelError::Server(code) => match code.as_str() {
            "not_offered" => Failure::NotOffered,
            "busy" | "worker_unavailable" => Failure::Waiting(code),
            "invalid_message" | "internal" | "limit_exceeded" => Failure::Refused,
            _ => Failure::Waiting("unreachable".into()),
        },
        _ => Failure::Waiting("unreachable".into()),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Put,
    Start,
    List,
    Get,
    Delete,
    Release,
}

/// `RemoteHandoffRequest`, without Feature 020's partial runs: this client doesn't send them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub action: Action,
    pub meeting: Option<String>,
    pub name: Option<String>,
    pub offset: Option<u64>,
    pub data: Option<Vec<u8>>,
    pub sha256: Option<String>,
    /// `put` and `start`: keep the result for another device after `release`.
    pub copy: bool,
}

impl Request {
    pub fn new(action: Action, meeting: Option<&str>) -> Request {
        Request { action, meeting: meeting.map(str::to_string), name: None, offset: None, data: None, sha256: None, copy: false }
    }

    pub fn message(&self, op: i64) -> Value {
        let action = match self.action {
            Action::Put => "put",
            Action::Start => "start",
            Action::List => "list",
            Action::Get => "get",
            Action::Delete => "delete",
            Action::Release => "release",
        };
        let mut object = json!({"type": "handoff", "op": op, "action": action});
        if let Some(meeting) = &self.meeting {
            object["meeting"] = meeting.as_str().into();
        }
        if let Some(name) = &self.name {
            object["name"] = name.as_str().into();
        }
        if let Some(offset) = self.offset {
            object["offset"] = offset.into();
        }
        if let Some(data) = &self.data {
            object["data"] = base64url_encode(data).into();
        }
        if let Some(sha256) = &self.sha256 {
            object["sha256"] = sha256.as_str().into();
        }
        if self.copy {
            object["copy"] = true.into();
        }
        object
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Receiving,
    Queued,
    Processing,
    Done,
    Failed,
    Missing,
}

fn state(value: Option<&Value>) -> Result<Option<State>, ChannelError> {
    Ok(Some(match value {
        None => return Ok(None),
        Some(v) => match v.as_str() {
            Some("receiving") => State::Receiving,
            Some("queued") => State::Queued,
            Some("processing") => State::Processing,
            Some("done") => State::Done,
            Some("failed") => State::Failed,
            Some("missing") => State::Missing,
            _ => return Err(ChannelError::Protocol),
        },
    }))
}

fn uuid(value: Option<&Value>) -> Result<Option<String>, ChannelError> {
    let Some(value) = value else { return Ok(None) };
    let text = value.as_str().filter(|s| valid_id(s)).ok_or(ChannelError::Protocol)?;
    Ok(Some(text.to_string()))
}

/// `8-4-4-4-12` hex: it names a directory here.
pub fn valid_id(id: &str) -> bool {
    id.len() == 36 && id.char_indices().all(|(i, c)| if [8, 13, 18, 23].contains(&i) { c == '-' } else { c.is_ascii_hexdigit() })
}

fn count(object: &Value, key: &str) -> Result<Option<u64>, ChannelError> {
    object.get(key).map(|v| v.as_u64().ok_or(ChannelError::Protocol)).transpose()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub meeting: String,
    pub state: State,
    /// `processing`: percent done once the processor has reported.
    pub progress: Option<u8>,
    pub mine: bool,
    pub copy: bool,
    pub released: bool,
}

/// `handoff_reply`. `state` is absent only on a `list` reply, which has `meetings`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Reply {
    pub state: Option<State>,
    pub offset: Option<u64>,
    pub data: Option<Vec<u8>>,
    pub size: Option<u64>,
    pub sha256: Option<String>,
    pub meetings: Option<Vec<Entry>>,
}

impl Reply {
    pub fn parse(object: &Value) -> Result<Reply, ChannelError> {
        let detail_allowed = |state: Option<State>, detail: Option<&Value>| detail.is_none() || matches!(state, Some(State::Failed | State::Receiving));
        let reply_state = state(object.get("state"))?;
        uuid(object.get("meeting"))?;
        let data = match object.get("data") {
            None => None,
            Some(text) => Some(text.as_str().and_then(base64url_decode).ok_or(ChannelError::Protocol)?),
        };
        let meetings = match object.get("meetings") {
            None => None,
            Some(list) => {
                let list = list.as_array().ok_or(ChannelError::Protocol)?;
                let parsed = list.iter().map(|entry| {
                    let (Some(meeting), Some(entry_state)) = (uuid(entry.get("meeting"))?, state(entry.get("state"))?) else { return Err(ChannelError::Protocol) };
                    if !detail_allowed(Some(entry_state), entry.get("detail")) {
                        return Err(ChannelError::Protocol);
                    }
                    let flag = |key: &str| entry.get(key).and_then(Value::as_bool).unwrap_or(false);
                    // An out-of-range percent is dropped rather than failing the whole list.
                    let progress = entry.get("progress").and_then(Value::as_u64).filter(|p| *p <= 100).map(|p| p as u8);
                    Ok(Entry { meeting, state: entry_state, progress, mine: flag("mine"), copy: flag("copy"), released: flag("released") })
                });
                Some(parsed.collect::<Result<Vec<_>, _>>()?)
            }
        };
        if reply_state.is_none() != meetings.is_some() || !detail_allowed(reply_state, object.get("detail")) {
            return Err(ChannelError::Protocol);
        }
        Ok(Reply { state: reply_state, offset: count(object, "offset")?, data, size: count(object, "size")?, sha256: object.get("sha256").and_then(Value::as_str).map(str::to_string), meetings })
    }
}

/// One `handoff` request and its reply.
pub type Call<'a> = &'a (dyn Fn(&Request) -> Result<Reply, Failure> + Send + Sync);

/// One op on the background channel: the channel is kept only after a clean answer.
pub fn exchange(pool: &Pool, request: &Request) -> Result<Reply, Failure> {
    let (mut channel, op) = pool.lease(Role::Background).map_err(mapped)?;
    let answer = channel.send(request.message(op)).and_then(|()| match channel.receive()? {
        ServerMessage::Other(object) if object["type"] == "handoff_reply" && object["op"] == op => Reply::parse(&object),
        ServerMessage::Error { code } => Err(ChannelError::Server(code)),
        _ => Err(ChannelError::Protocol),
    });
    pool.release(Role::Background, channel, answer.is_ok().then_some(op + 1));
    answer.map_err(mapped)
}

fn hex(digest: [u8; 32]) -> String {
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn hash_into(hasher: &mut Sha256, file: &mut File, limit: u64) -> Result<(), Failure> {
    let mut buffer = vec![0; HASH_READ_BYTES];
    let mut remaining = limit;
    while remaining > 0 {
        let read = file.read(&mut buffer[..HASH_READ_BYTES.min(remaining as usize)])?;
        if read == 0 {
            return Err(Failure::Local);
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    Ok(())
}

/// The file's SHA-256 in lowercase hex, read in 1 MiB pieces.
pub fn sha256_of(path: &Path) -> Result<String, Failure> {
    let mut file = File::open(path)?;
    let size = file.metadata()?.len();
    let mut hasher = Sha256::default();
    hash_into(&mut hasher, &mut file, size)?;
    Ok(hex(hasher.finish()))
}

/// Sends `path` as `name` from the server's stored size; the last chunk carries the SHA-256. A
/// mismatch empties the server's file and the upload starts again, after `retry_delay`, doubled each
/// time, at most `MAX_MISMATCHES` times.
pub fn put(meeting: &str, name: &str, path: &Path, retry_delay: Duration, call: Call) -> Result<(), Failure> {
    let mut file = File::open(path)?;
    let size = file.metadata()?.len();
    if size > MAX_FILE_BYTES {
        return Err(Failure::Local);
    }
    let mut hasher = Sha256::default();
    hash_into(&mut hasher, &mut file, size)?;
    let hash = hex(hasher.finish());
    let request = |offset: u64, data: Option<Vec<u8>>, sha256: Option<String>| Request { name: Some(name.to_string()), offset: Some(offset), data, sha256, ..Request::new(Action::Put, Some(meeting)) };
    // An offset the server does not have yet writes nothing and returns its size.
    let mut offset = call(&request(0, None, None))?.offset.unwrap_or(0);
    if offset > size {
        return Err(Failure::Refused);
    }
    let mut mismatches = 0;
    let mut chunk = vec![0; CHUNK_BYTES];
    loop {
        let end = size.min(offset + CHUNK_BYTES as u64);
        let last = end == size;
        let mut data = None;
        if end > offset {
            let bytes = &mut chunk[..(end - offset) as usize];
            file.seek(SeekFrom::Start(offset))?;
            file.read_exact(bytes)?;
            data = Some(bytes.to_vec());
        }
        let reply = call(&request(offset, data, last.then(|| hash.clone())))?;
        let (Some(next), Some(State::Receiving)) = (reply.offset, reply.state) else { return Err(Failure::Refused) };
        if last && next == 0 && size > 0 {
            mismatches += 1;
            if mismatches >= MAX_MISMATCHES {
                return Err(Failure::ChecksumMismatch);
            }
            std::thread::sleep(retry_delay * (1 << (mismatches - 1)));
            offset = 0;
            continue;
        }
        if next != end {
            return Err(Failure::Refused);
        }
        if last {
            return Ok(());
        }
        offset = next;
    }
}

fn announced(reply: &Reply) -> Result<(u64, String), Failure> {
    match (reply.state, reply.size, &reply.sha256) {
        (Some(State::Done), Some(size), Some(sha256)) if size <= MAX_FILE_BYTES && sha256.len() == 64 && sha256.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) => Ok((size, sha256.clone())),
        _ => Err(Failure::Refused),
    }
}

/// `<file>.part`, created owner-only, never through a symlink.
fn open_part(path: &Path) -> Result<File, Failure> {
    if let Some(dir) = path.parent() {
        private_dir(dir)?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).read(true).write(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    Ok(options.open(path)?)
}

/// A directory only this user can enter.
pub(crate) fn private_dir(dir: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(dir)
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut text = path.as_os_str().to_os_string();
    text.push(suffix);
    text.into()
}

/// The `<file>.part.<sha256>` markers naming the version a partial holds.
fn remove_markers(part: &Path) {
    let (Some(dir), Some(name)) = (part.parent(), part.file_name().and_then(|n| n.to_str())) else { return };
    let prefix = format!("{name}.");
    for item in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        if item.file_name().to_str().is_some_and(|n| n.starts_with(&prefix)) {
            let _ = std::fs::remove_file(item.path());
        }
    }
}

/// Downloads a done meeting's bundle, or with `name` one of its files, to `target` once its size and
/// SHA-256 match what the server announced. A failed transfer resumes from `<file>.part` when the
/// server still announces the same file; a checksum failure deletes it.
pub fn get(meeting: &str, name: Option<&str>, target: &Path, call: Call) -> Result<(), Failure> {
    let request = |offset: u64| Request { name: name.map(str::to_string), offset: Some(offset), ..Request::new(Action::Get, Some(meeting)) };
    let part_path = with_suffix(target, ".part");
    // The first chunk names the file: a partial from another version starts over.
    let mut reply = call(&request(0))?;
    let (size, sha256) = announced(&reply)?;
    let mut part = open_part(&part_path)?;
    let mut hasher = Sha256::default();
    let mut written = part.metadata()?.len();
    let marker = with_suffix(&part_path, &format!(".{sha256}"));
    if written > size || !marker.exists() {
        part.set_len(0)?;
        written = 0;
        remove_markers(&part_path);
        File::create(&marker)?;
    } else if written > 0 {
        part.seek(SeekFrom::Start(0))?;
        hash_into(&mut hasher, &mut part, written)?;
    }
    part.seek(SeekFrom::Start(written))?;
    if written > 0 && written < size {
        reply = call(&request(written))?;
    }
    while written < size {
        let chunk = match (&reply.data, reply.offset == Some(written), announced(&reply)?) {
            (Some(chunk), true, (s, h)) if s == size && h == sha256 && !chunk.is_empty() && chunk.len() <= MAX_CHUNK_BYTES && chunk.len() as u64 <= size - written => chunk,
            _ => return Err(Failure::Refused),
        };
        part.write_all(chunk)?;
        hasher.update(chunk);
        written += chunk.len() as u64;
        if written < size {
            reply = call(&request(written))?;
        }
    }
    if hex(hasher.finish()) != sha256 {
        drop(part);
        let _ = std::fs::remove_file(&part_path);
        remove_markers(&part_path);
        return Err(Failure::ChecksumMismatch);
    }
    part.sync_all()?;
    drop(part);
    std::fs::rename(&part_path, target)?;
    remove_markers(&part_path);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn dir(tag: &str) -> PathBuf {
        let unique = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let d = std::env::temp_dir().join(format!("flow-transfer-{tag}-{}-{unique}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// The server's put and get in memory, as `server/internal/remote/handoff.go` does them.
    #[derive(Default)]
    struct Server {
        stored: Mutex<Vec<u8>>,
        reject: Mutex<u32>,
        puts: Mutex<Vec<(u64, usize, bool)>>,
        gets: Mutex<Vec<u64>>,
        fail_after: Mutex<Option<usize>>,
        lie: Mutex<bool>,
    }

    impl Server {
        fn call(&self, r: &Request) -> Result<Reply, Failure> {
            if let Some(left) = self.fail_after.lock().unwrap().as_mut() {
                if *left == 0 {
                    return Err(Failure::Waiting("unreachable".into()));
                }
                *left -= 1;
            }
            let mut stored = self.stored.lock().unwrap();
            match r.action {
                Action::Put => {
                    let offset = r.offset.unwrap();
                    self.puts.lock().unwrap().push((offset, r.data.as_ref().map_or(0, Vec::len), r.sha256.is_some()));
                    if offset == stored.len() as u64 {
                        stored.extend_from_slice(r.data.as_deref().unwrap_or_default());
                        if let Some(sum) = &r.sha256 {
                            let mut reject = self.reject.lock().unwrap();
                            if *reject > 0 || hex(crate::settings::sha256(&stored)) != *sum {
                                *reject = reject.saturating_sub(1);
                                stored.clear();
                            }
                        }
                    }
                    Ok(Reply { state: Some(State::Receiving), offset: Some(stored.len() as u64), ..Reply::default() })
                }
                Action::Get => {
                    let offset = r.offset.unwrap();
                    self.gets.lock().unwrap().push(offset);
                    let end = stored.len().min(offset as usize + CHUNK_BYTES);
                    let sha256 = if *self.lie.lock().unwrap() { "0".repeat(64) } else { hex(crate::settings::sha256(&stored)) };
                    Ok(Reply { state: Some(State::Done), offset: Some(offset), size: Some(stored.len() as u64), sha256: Some(sha256), data: (offset < stored.len() as u64).then(|| stored[offset as usize..end].to_vec()), ..Reply::default() })
                }
                _ => Err(Failure::Refused),
            }
        }
        fn run<T>(&self, f: impl FnOnce(Call) -> T) -> T {
            f(&|r: &Request| self.call(r))
        }
    }

    fn bytes(n: usize) -> Vec<u8> {
        (0..n).map(|i| (i * 31 % 251) as u8).collect()
    }

    #[test]
    fn streaming_hash_matches_one_shot_across_block_edges() {
        let data = bytes(1000);
        for split in [0, 1, 55, 63, 64, 65, 128, 999] {
            let mut h = Sha256::default();
            h.update(&data[..split]);
            h.update(&data[split..]);
            assert_eq!(h.finish(), crate::settings::sha256(&data), "split {split}");
        }
        assert_eq!(hex(crate::settings::sha256(b"abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    #[test]
    fn upload_is_bounded_resumes_at_the_servers_size_and_hashes_the_whole_file() {
        let d = dir("put");
        let path = d.join("a.aac");
        let data = bytes(CHUNK_BYTES * 2 + 10);
        std::fs::write(&path, &data).unwrap();
        let server = Server::default();
        *server.fail_after.lock().unwrap() = Some(2);
        assert_eq!(server.run(|c| put("M", "a.aac", &path, Duration::ZERO, c)), Err(Failure::Waiting("unreachable".into())));
        assert_eq!(server.stored.lock().unwrap().len(), CHUNK_BYTES, "one chunk landed");
        *server.fail_after.lock().unwrap() = None;
        server.puts.lock().unwrap().clear();
        server.run(|c| put("M", "a.aac", &path, Duration::ZERO, c)).unwrap();
        assert_eq!(*server.stored.lock().unwrap(), data);
        let puts = server.puts.lock().unwrap();
        assert_eq!(puts[0], (0, 0, false), "asks the size first");
        assert_eq!(puts[1], (CHUNK_BYTES as u64, CHUNK_BYTES, false), "resumes, not from zero");
        assert_eq!(puts[2], (2 * CHUNK_BYTES as u64, 10, true), "the last chunk carries the hash");
        assert!(puts.iter().all(|p| p.1 <= CHUNK_BYTES));
    }

    #[test]
    fn a_rejected_checksum_restarts_a_bounded_number_of_times() {
        let d = dir("reject");
        let path = d.join("a.aac");
        let data = bytes(100);
        std::fs::write(&path, &data).unwrap();
        let server = Server::default();
        *server.reject.lock().unwrap() = 1;
        server.run(|c| put("M", "a.aac", &path, Duration::ZERO, c)).unwrap();
        assert_eq!(*server.stored.lock().unwrap(), data);
        let server = Server::default();
        *server.reject.lock().unwrap() = 99;
        assert_eq!(server.run(|c| put("M", "a.aac", &path, Duration::ZERO, c)), Err(Failure::ChecksumMismatch));
        assert_eq!(server.puts.lock().unwrap().iter().filter(|p| p.2).count(), MAX_MISMATCHES as usize);
        assert_eq!(std::fs::read(&path).unwrap(), data, "the original stays");
    }

    #[test]
    fn an_empty_file_and_a_finished_server_copy_still_send_the_hash() {
        let d = dir("empty");
        let path = d.join("a");
        std::fs::write(&path, b"").unwrap();
        let server = Server::default();
        server.run(|c| put("M", "a", &path, Duration::ZERO, c)).unwrap();
        assert_eq!(*server.puts.lock().unwrap().last().unwrap(), (0, 0, true));
        std::fs::write(&path, b"xyz").unwrap();
        *server.stored.lock().unwrap() = b"xyz".to_vec();
        server.run(|c| put("M", "a", &path, Duration::ZERO, c)).unwrap();
        assert_eq!(*server.puts.lock().unwrap().last().unwrap(), (3, 0, true));
    }

    #[test]
    fn download_resumes_from_its_partial_and_publishes_once_verified() {
        let d = dir("get");
        let target = d.join("result.sqlite");
        let data = bytes(CHUNK_BYTES * 3 + 7);
        let server = Server::default();
        *server.stored.lock().unwrap() = data.clone();
        *server.fail_after.lock().unwrap() = Some(2);
        assert!(server.run(|c| get("M", None, &target, c)).is_err());
        assert!(!target.exists());
        assert_eq!(std::fs::metadata(d.join("result.sqlite.part")).unwrap().len(), 2 * CHUNK_BYTES as u64);
        *server.fail_after.lock().unwrap() = None;
        server.gets.lock().unwrap().clear();
        server.run(|c| get("M", None, &target, c)).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), data);
        assert_eq!(server.gets.lock().unwrap()[1], 2 * CHUNK_BYTES as u64, "continues from the partial");
        assert_eq!(std::fs::read_dir(&d).unwrap().count(), 1, "no part or marker left");
    }

    #[test]
    fn a_partial_of_another_version_starts_over_and_a_bad_sum_drops_it() {
        let d = dir("version");
        let target = d.join("f");
        let (data, other) = (bytes(CHUNK_BYTES + 5), vec![9; CHUNK_BYTES + 5]);
        let server = Server::default();
        *server.stored.lock().unwrap() = other;
        *server.fail_after.lock().unwrap() = Some(1);
        assert!(server.run(|c| get("M", None, &target, c)).is_err());
        *server.fail_after.lock().unwrap() = None;
        *server.stored.lock().unwrap() = data.clone();
        server.run(|c| get("M", None, &target, c)).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), data);

        let (d, server) = (dir("lie"), Server::default());
        let target = d.join("f");
        *server.stored.lock().unwrap() = data;
        *server.lie.lock().unwrap() = true;
        assert_eq!(server.run(|c| get("M", None, &target, c)), Err(Failure::ChecksumMismatch));
        assert_eq!(std::fs::read_dir(&d).unwrap().count(), 0);
    }

    #[test]
    fn replies_are_validated_like_swifts() {
        let id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
        let ok = json!({"meetings": [{"meeting": id, "state": "processing", "progress": 140, "mine": true}, {"meeting": id, "state": "failed", "detail": "exit_1"}]});
        let list = Reply::parse(&ok).unwrap().meetings.unwrap();
        assert_eq!((list[0].progress, list[0].mine, list[1].state), (None, true, State::Failed));
        for bad in [json!({}), json!({"state": "odd"}), json!({"state": "done", "meetings": []}), json!({"state": "done", "detail": "x"}), json!({"state": "done", "offset": -1}), json!({"state": "done", "data": "*"}), json!({"state": "done", "meeting": "../x"}), json!({"meetings": [{"meeting": id, "state": "queued", "detail": "x"}]})] {
            assert_eq!(Reply::parse(&bad), Err(ChannelError::Protocol), "{bad}");
        }
    }

    /// A turn off during a chunk: the channel it used closes, and no next chunk leaves.
    #[test]
    fn turning_off_mid_chunk_stops_the_upload() {
        use super::super::channel::{Channel, Purpose, Transports};
        use super::super::scripted::{Reply as Script_, Script};
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
        let d = dir("off");
        let file = d.join("f");
        std::fs::write(&file, vec![7; CHUNK_BYTES * 4]).unwrap();
        let script = Script::new(vec![Script_::ready(); 3]);
        let off = Arc::new(AtomicBool::new(false));
        let gone = off.clone();
        let opener: super::super::pool::Opener = Box::new(move || {
            if gone.load(Ordering::SeqCst) {
                return Err(ChannelError::Closed);
            }
            let mut channel = Channel::new(script.open("ws://x").map_err(|_| ChannelError::Unreachable)?, &script.public_key())?;
            channel.open(Purpose::Session, Some("token"))?;
            Ok(channel)
        });
        let pool = Pool::new(opener, Box::new(|| Duration::ZERO));
        let calls = AtomicU32::new(0);
        let call = |r: &Request| {
            let (channel, op) = pool.lease(Role::Background).map_err(mapped)?;
            if calls.fetch_add(1, Ordering::SeqCst) == 1 {
                off.store(true, Ordering::SeqCst);
                pool.close_parked();
            }
            pool.release(Role::Background, channel, Some(op + 1));
            Ok(Reply { state: Some(State::Receiving), offset: Some(r.offset.unwrap() + r.data.as_ref().map_or(0, |b| b.len() as u64)), ..Reply::default() })
        };
        assert_eq!(put("6F3A1C52-8D47-4E19-9B21-0C7E5A2D4F10", "f", &file, Duration::ZERO, &call), Err(Failure::Waiting("unreachable".into())));
        assert_eq!(calls.load(Ordering::SeqCst), 2, "the size question and one chunk");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn errors_map_like_remote_meeting_jobs() {
        let s = |c: &str| mapped(ChannelError::Server(c.into()));
        assert_eq!(s("not_offered"), Failure::NotOffered);
        assert_eq!(s("busy"), Failure::Waiting("busy".into()));
        assert_eq!(s("worker_unavailable"), Failure::Waiting("worker_unavailable".into()));
        for refused in ["invalid_message", "internal", "limit_exceeded"] {
            assert_eq!(s(refused), Failure::Refused);
        }
        for waits in ["revoked", "not_approved", "token_expired", "unauthorized"] {
            assert_eq!(s(waits), Failure::Waiting("unreachable".into()));
        }
        assert_eq!(mapped(ChannelError::Protocol), Failure::Refused);
        assert_eq!(mapped(ChannelError::Closed), Failure::Waiting("unreachable".into()));
    }
}
