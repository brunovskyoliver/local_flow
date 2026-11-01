//! The speech worker contract, `specs/014-remote-dictation-server/contracts/speech-worker-ipc.md`:
//! framing and a client over any Read and Write. Nothing here keeps or logs text or samples.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{self, Read, Write};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError, sync_channel};
use std::time::{Duration, Instant};

pub const PROTOCOL: i64 = 1;
pub const MAX_HEADER_BYTES: usize = 65_536;
pub const MAX_SAMPLE_COUNT: usize = 239_360;
pub const JOB_DEADLINE: Duration = Duration::from_secs(30);
/// flowd's `DefaultReadyTimeout`: a first load can be slow.
pub const READY_TIMEOUT: Duration = Duration::from_secs(300);
pub const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);
pub const UNAVAILABLE_RETRY: Duration = Duration::from_secs(60);
pub const BACKOFF_INITIAL: Duration = Duration::from_secs(1);
pub const BACKOFF_MAX: Duration = Duration::from_secs(60);

pub const CODE_INVALID_AUDIO: &str = "invalid_audio";
pub const CODE_MODEL_UNAVAILABLE: &str = "model_unavailable";
pub const CODE_FAILED: &str = "failed";

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelIdentity {
    pub engine: String,
    pub model_id: String,
    pub model_revision: String,
    pub manifest_hash: String,
    pub sdk: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub booster: Option<String>,
    pub worker_build: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoostTerm {
    pub entry_id: String,
    pub canonical: String,
}

/// One job's term boosting; it applies to that job only.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Boost {
    pub terms: Vec<BoostTerm>,
    pub governed: Vec<String>,
}

/// The JSON header of every message. Which fields are set depends on `kind`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Header {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub protocol: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<ModelIdentity>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sample_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub boost: Option<Boost>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recognition_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
}

impl Header {
    pub fn of(kind: &str) -> Header {
        Header {
            kind: kind.into(),
            ..Default::default()
        }
    }
    pub fn ready(model: ModelIdentity) -> Header {
        Header {
            protocol: Some(PROTOCOL),
            model: Some(model),
            ..Header::of("ready")
        }
    }
    pub fn unavailable(reason: &str) -> Header {
        Header {
            reason: Some(reason.into()),
            ..Header::of("unavailable")
        }
    }
    pub fn recognize(job: u64, sample_count: usize, boost: Option<Boost>) -> Header {
        Header {
            job: Some(job),
            sample_count: Some(sample_count as i64),
            boost,
            ..Header::of("recognize")
        }
    }
    pub fn result(job: u64, window: Value, recognition_ms: i64) -> Header {
        Header {
            job: Some(job),
            window: Some(window),
            recognition_ms: Some(recognition_ms),
            ..Header::of("result")
        }
    }
    pub fn error(job: u64, code: &str) -> Header {
        Header {
            job: Some(job),
            code: Some(code.into()),
            ..Header::of("error")
        }
    }

    /// The fields each type requires; `payload` is what the frame declares.
    fn validate(&self, payload: u32) -> Result<(), FrameError> {
        let mut want = 0u32;
        let job = self.job.is_some_and(|j| j != 0);
        match self.kind.as_str() {
            "ready" => {
                let complete = self.model.as_ref().is_some_and(|m| {
                    ![
                        &m.engine,
                        &m.model_id,
                        &m.model_revision,
                        &m.manifest_hash,
                        &m.sdk,
                        &m.worker_build,
                    ]
                    .iter()
                    .any(|v| v.is_empty())
                });
                if self.protocol != Some(PROTOCOL) || !complete {
                    return Err(FrameError::Malformed("ready"));
                }
            }
            "unavailable" => {
                if self.reason.as_deref().unwrap_or_default().is_empty() {
                    return Err(FrameError::Malformed("unavailable"));
                }
            }
            "recognize" => {
                let count = self.sample_count.unwrap_or(0);
                if !job || count < 1 || count > MAX_SAMPLE_COUNT as i64 {
                    return Err(FrameError::Malformed("recognize"));
                }
                want = count as u32 * 4;
            }
            "shutdown" => {}
            "result" => {
                if !job
                    || !self.recognition_ms.is_some_and(|ms| ms >= 0)
                    || !self.window.as_ref().is_some_and(Value::is_object)
                {
                    return Err(FrameError::Malformed("result"));
                }
            }
            "error" => {
                if !job
                    || !matches!(
                        self.code.as_deref(),
                        Some(CODE_INVALID_AUDIO | CODE_MODEL_UNAVAILABLE | CODE_FAILED)
                    )
                {
                    return Err(FrameError::Malformed("error"));
                }
            }
            "state" => {
                if !matches!(self.state.as_deref(), Some("active" | "releasing")) {
                    return Err(FrameError::Malformed("state"));
                }
            }
            _ => return Err(FrameError::Malformed("type")),
        }
        if payload != want {
            return Err(FrameError::Malformed("payload_length"));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameError {
    /// Fatal on read. On write nothing was sent. The text is a fixed label, never content.
    Malformed(&'static str),
    /// A header that doesn't fit one frame. On write nothing was sent, so the worker is unaffected.
    HeaderTooLarge,
}

#[derive(Debug, PartialEq)]
pub struct Frame {
    pub header: Header,
    pub payload: Vec<u8>,
}

/// Compact JSON with keys sorted by byte order at every level. Sorting is by hand because a
/// dependency turns on serde_json's `preserve_order` across the workspace.
fn canonical(value: &Value, out: &mut String) {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<_> = map.iter().collect();
            entries.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
            out.push('{');
            for (i, (key, item)) in entries.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::from(key.as_str()).to_string());
                out.push(':');
                canonical(item, out);
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical(item, out);
            }
            out.push(']');
        }
        leaf => out.push_str(&leaf.to_string()),
    }
}

/// One complete frame. Refuses anything `read_frame` would reject.
pub fn encode_frame(header: &Header, payload: &[u8]) -> Result<Vec<u8>, FrameError> {
    let length =
        u32::try_from(payload.len()).map_err(|_| FrameError::Malformed("payload_length"))?;
    header.validate(length)?;
    let value = serde_json::to_value(header).map_err(|_| FrameError::Malformed("header"))?;
    let mut json = String::new();
    canonical(&value, &mut json);
    if json.len() > MAX_HEADER_BYTES {
        return Err(FrameError::HeaderTooLarge);
    }
    let mut out = Vec::with_capacity(8 + json.len() + payload.len());
    out.extend_from_slice(&(json.len() as u32).to_be_bytes());
    out.extend_from_slice(json.as_bytes());
    out.extend_from_slice(&length.to_be_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

/// One frame, or `None` at end of input on a frame boundary. Every other failure is malformed and
/// fatal. Lengths are checked before anything is allocated for them.
pub fn read_frame(r: &mut impl Read) -> Result<Option<Frame>, FrameError> {
    let mut n = [0u8; 4];
    let mut got = 0;
    while got < 4 {
        match r.read(&mut n[got..]) {
            Ok(0) if got == 0 => return Ok(None),
            Ok(0) => return Err(FrameError::Malformed("short header_length")),
            Ok(count) => got += count,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return Err(FrameError::Malformed("read")),
        }
    }
    let length = u32::from_be_bytes(n) as usize;
    if length == 0 || length > MAX_HEADER_BYTES {
        return Err(FrameError::Malformed("header_length"));
    }
    let mut raw = vec![0u8; length];
    r.read_exact(&mut raw)
        .map_err(|_| FrameError::Malformed("short header"))?;
    let text = std::str::from_utf8(&raw).map_err(|_| FrameError::Malformed("header not UTF-8"))?;
    if !text.trim_start().starts_with('{') {
        return Err(FrameError::Malformed("header not an object"));
    }
    let header: Header =
        serde_json::from_str(text).map_err(|_| FrameError::Malformed("header JSON"))?;
    r.read_exact(&mut n)
        .map_err(|_| FrameError::Malformed("short payload_length"))?;
    let payload_length = u32::from_be_bytes(n);
    header.validate(payload_length)?;
    let mut payload = vec![0u8; payload_length as usize];
    r.read_exact(&mut payload)
        .map_err(|_| FrameError::Malformed("short payload"))?;
    Ok(Some(Frame { header, payload }))
}

/// Float32 little-endian.
pub fn encode_samples(samples: &[f32]) -> Vec<u8> {
    samples.iter().flat_map(|s| s.to_le_bytes()).collect()
}

/// The whole payload of a valid `recognize`; its length is a multiple of 4.
pub fn decode_samples(payload: &[u8]) -> Vec<f32> {
    payload
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

/// 1 s, 2 s, 4 s … capped at 60 s. Back to the start after a job succeeds, as in flowd.
#[derive(Clone, Copy, Debug)]
pub struct Backoff(Duration);
impl Default for Backoff {
    fn default() -> Self {
        Backoff(BACKOFF_INITIAL)
    }
}
impl Backoff {
    pub fn next_delay(&mut self) -> Duration {
        let delay = self.0;
        self.0 = (self.0 * 2).min(BACKOFF_MAX);
        delay
    }
    pub fn reset(&mut self) {
        *self = Backoff::default();
    }
}

/// Why the worker has to go: the caller kills it and restarts with backoff.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fatal {
    Malformed(&'static str),
    /// End of input where an answer was due: an exit or a crash.
    Exited,
    Deadline,
    /// An answer for a job other than the one running.
    OutOfOrder,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Started {
    Ready(ModelIdentity),
    /// The worker has no verified model and exits 0. Retry after `UNAVAILABLE_RETRY`.
    Unavailable(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Recognized {
    pub job: u64,
    /// `window_result` without op, index and sample_start.
    pub window: Value,
    pub recognition_ms: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JobError {
    /// The worker's `error` frame: the job failed and the worker lives.
    Code(String),
    /// Refused before sending: too many samples, or a boost list over the header limit.
    Refused(FrameError),
    Fatal(Fatal),
}

/// One worker's stdin and stdout. Reading and writing run on their own threads, so the job deadline
/// holds even if the worker stops draining its input or stops answering. Killing the process ends
/// both threads; dropping the client closes stdin, which also makes a worker exit.
pub struct Client {
    frames: Receiver<Result<Option<Frame>, FrameError>>,
    writes: SyncSender<Vec<u8>>,
    next_job: u64,
    dead: Option<Fatal>,
}

impl Client {
    pub fn new(
        mut reader: impl Read + Send + 'static,
        mut writer: impl Write + Send + 'static,
    ) -> Client {
        // Bounded: at most this many frames sit read but not taken.
        let (frame_tx, frames) = sync_channel(2);
        std::thread::spawn(move || {
            loop {
                let frame = read_frame(&mut reader);
                let done = !matches!(frame, Ok(Some(_)));
                if frame_tx.send(frame).is_err() || done {
                    break;
                }
            }
        });
        // One job at a time, so one queued write (a shutdown behind a job) is all it ever holds.
        let (writes, write_rx) = sync_channel::<Vec<u8>>(1);
        std::thread::spawn(move || {
            for data in write_rx {
                if writer
                    .write_all(&data)
                    .and_then(|()| writer.flush())
                    .is_err()
                {
                    // The reader sees the end of the worker.
                    break;
                }
            }
        });
        Client {
            frames,
            writes,
            next_job: 1,
            dead: None,
        }
    }

    fn fail(&mut self, fatal: Fatal) -> Fatal {
        self.dead = Some(fatal);
        fatal
    }

    fn next_frame(&mut self, until: Instant) -> Result<Frame, Fatal> {
        if let Some(fatal) = self.dead {
            return Err(fatal);
        }
        let fatal = match self
            .frames
            .recv_timeout(until.saturating_duration_since(Instant::now()))
        {
            Ok(Ok(Some(frame))) => return Ok(frame),
            Ok(Ok(None)) | Err(RecvTimeoutError::Disconnected) => Fatal::Exited,
            Ok(Err(FrameError::Malformed(what))) => Fatal::Malformed(what),
            Ok(Err(FrameError::HeaderTooLarge)) => Fatal::Malformed("header_length"),
            Err(RecvTimeoutError::Timeout) => Fatal::Deadline,
        };
        Err(self.fail(fatal))
    }

    /// The contract's first frame: `ready`, or `unavailable` and an exit.
    pub fn wait_ready(&mut self, timeout: Duration) -> Result<Started, Fatal> {
        let frame = self.next_frame(Instant::now() + timeout)?;
        match frame.header.kind.as_str() {
            "ready" => Ok(Started::Ready(frame.header.model.unwrap_or_default())),
            "unavailable" => Ok(Started::Unavailable(
                frame.header.reason.unwrap_or_default(),
            )),
            _ => Err(self.fail(Fatal::Malformed("first frame"))),
        }
    }

    /// One job. The caller holds the worker exclusively, so answers can only come in this order.
    pub fn recognize(
        &mut self,
        samples: &[f32],
        boost: Option<Boost>,
        deadline: Duration,
    ) -> Result<Recognized, JobError> {
        if let Some(fatal) = self.dead {
            return Err(JobError::Fatal(fatal));
        }
        let job = self.next_job;
        let data = encode_frame(
            &Header::recognize(job, samples.len(), boost),
            &encode_samples(samples),
        )
        .map_err(JobError::Refused)?;
        let until = Instant::now() + deadline;
        match self.writes.try_send(data) {
            Ok(()) => self.next_job += 1,
            Err(TrySendError::Full(_)) => return Err(JobError::Fatal(self.fail(Fatal::Deadline))),
            Err(TrySendError::Disconnected(_)) => {
                return Err(JobError::Fatal(self.fail(Fatal::Exited)));
            }
        }
        loop {
            let header = self.next_frame(until).map_err(JobError::Fatal)?.header;
            match header.kind.as_str() {
                "state" => continue,
                "result" | "error" if header.job != Some(job) => {
                    return Err(JobError::Fatal(self.fail(Fatal::OutOfOrder)));
                }
                "result" => {
                    return Ok(Recognized {
                        job,
                        window: header.window.unwrap_or_default(),
                        recognition_ms: header.recognition_ms.unwrap_or(0),
                    });
                }
                "error" => return Err(JobError::Code(header.code.unwrap_or_default())),
                _ => {
                    return Err(JobError::Fatal(
                        self.fail(Fatal::Malformed("unexpected frame")),
                    ));
                }
            }
        }
    }

    /// Asks the worker to release its runtime and exit. The caller waits for the exit.
    pub fn shutdown(&mut self) {
        if let Ok(data) = encode_frame(&Header::of("shutdown"), &[]) {
            let _ = self.writes.try_send(data);
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::Cursor;

    fn fixture(name: &str) -> Vec<u8> {
        std::fs::read(format!(
            "{}/../../fixtures/remote/worker-frames/{name}",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap()
    }

    fn unhex(text: &str) -> Vec<u8> {
        (0..text.len() / 2)
            .map(|i| u8::from_str_radix(&text[2 * i..2 * i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn golden_frames_decode_and_encode_to_the_same_bytes() {
        let manifest: Value = serde_json::from_slice(&fixture("manifest.json")).unwrap();
        let frames = manifest["frames"].as_array().unwrap();
        assert_eq!(frames.len(), 13);
        for entry in frames {
            let name = entry["file"].as_str().unwrap();
            let bytes = fixture(name);
            let decoded = read_frame(&mut Cursor::new(&bytes));
            if entry["valid"] == false {
                assert!(
                    matches!(decoded, Err(FrameError::Malformed(_))),
                    "{name}: {decoded:?}"
                );
                continue;
            }
            let frame = decoded.unwrap().unwrap();
            assert_eq!(
                frame.payload,
                unhex(entry["payload_hex"].as_str().unwrap()),
                "{name}"
            );
            assert_eq!(
                encode_frame(&frame.header, &frame.payload).unwrap(),
                bytes,
                "{name}"
            );
            let start = 4 + entry["header_json"].as_str().unwrap().len();
            assert_eq!(
                std::str::from_utf8(&bytes[4..start]).unwrap(),
                entry["header_json"].as_str().unwrap(),
                "{name}"
            );
        }
    }

    pub(crate) fn raw(header: &str, payload: &[u8]) -> Vec<u8> {
        let mut out = (header.len() as u32).to_be_bytes().to_vec();
        out.extend_from_slice(header.as_bytes());
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        out.extend_from_slice(payload);
        out
    }

    #[test]
    fn malformed_frames_are_refused() {
        let cases: Vec<(&str, Vec<u8>)> = vec![
            ("empty header", raw("", &[])),
            ("truncated length", vec![0, 0]),
            (
                "truncated header",
                raw(r#"{"type":"shutdown"}"#, &[])[..10].to_vec(),
            ),
            (
                "truncated payload length",
                raw(r#"{"type":"shutdown"}"#, &[])[..25].to_vec(),
            ),
            ("not json", raw(r#"{"type":"#, &[])),
            ("not an object", raw(r#"["shutdown"]"#, &[])),
            ("trailing data", raw(r#"{"type":"shutdown"} {}"#, &[])),
            (
                "invalid utf8",
                raw("{\"type\":\"state\",\"state\":\"\u{1}\"}", &[])
                    .iter()
                    .map(|b| if *b == 1 { 0xff } else { *b })
                    .collect(),
            ),
            ("unknown type", raw(r#"{"type":"hello"}"#, &[])),
            (
                "wrong field type",
                raw(
                    r#"{"type":"recognize","job":"1","sample_count":1}"#,
                    &[0; 4],
                ),
            ),
            (
                "zero samples",
                raw(r#"{"job":1,"sample_count":0,"type":"recognize"}"#, &[]),
            ),
            (
                "no job",
                raw(r#"{"sample_count":1,"type":"recognize"}"#, &[0; 4]),
            ),
            ("payload on shutdown", raw(r#"{"type":"shutdown"}"#, &[1])),
            (
                "ready wrong protocol",
                raw(
                    r#"{"model":{"engine":"e","manifest_hash":"h","model_id":"m","model_revision":"r","sdk":"s","worker_build":"b"},"protocol":2,"type":"ready"}"#,
                    &[],
                ),
            ),
            (
                "ready no model",
                raw(r#"{"protocol":1,"type":"ready"}"#, &[]),
            ),
            (
                "ready empty engine",
                raw(
                    r#"{"model":{"engine":"","manifest_hash":"h","model_id":"m","model_revision":"r","sdk":"s","worker_build":"b"},"protocol":1,"type":"ready"}"#,
                    &[],
                ),
            ),
            (
                "unavailable no reason",
                raw(r#"{"type":"unavailable"}"#, &[]),
            ),
            (
                "result no window",
                raw(r#"{"job":1,"recognition_ms":1,"type":"result"}"#, &[]),
            ),
            (
                "result window not object",
                raw(
                    r#"{"job":1,"recognition_ms":1,"type":"result","window":3}"#,
                    &[],
                ),
            ),
            (
                "result no ms",
                raw(r#"{"job":1,"type":"result","window":{}}"#, &[]),
            ),
            (
                "error unknown code",
                raw(r#"{"code":"boom","job":1,"type":"error"}"#, &[]),
            ),
            (
                "state unknown",
                raw(r#"{"state":"idle","type":"state"}"#, &[]),
            ),
        ];
        for (name, data) in cases {
            assert!(
                matches!(
                    read_frame(&mut Cursor::new(&data)),
                    Err(FrameError::Malformed(_))
                ),
                "{name}"
            );
        }
        assert_eq!(
            read_frame(&mut Cursor::new(&[] as &[u8])),
            Ok(None),
            "a clean end"
        );
    }

    #[test]
    fn encoder_refuses_what_a_reader_would_reject() {
        assert!(
            encode_frame(&Header::recognize(1, 2, None), &[0; 4]).is_err(),
            "payload mismatch"
        );
        assert!(
            encode_frame(
                &Header::recognize(1, MAX_SAMPLE_COUNT + 1, None),
                &vec![0; 4 * (MAX_SAMPLE_COUNT + 1)]
            )
            .is_err()
        );
        assert!(encode_frame(&Header::of("hello"), &[]).is_err());
        let terms = vec![BoostTerm {
            entry_id: "e".repeat(40_000),
            canonical: "c".repeat(40_000),
        }];
        let big = Header::recognize(
            1,
            1,
            Some(Boost {
                terms,
                governed: vec![],
            }),
        );
        assert_eq!(encode_frame(&big, &[0; 4]), Err(FrameError::HeaderTooLarge));
    }

    #[test]
    fn samples_round_trip() {
        let samples = [0.0, 0.5, -0.25, 1.0];
        assert_eq!(
            encode_samples(&samples),
            [0, 0, 0, 0, 0, 0, 0, 63, 0, 0, 128, 190, 0, 0, 128, 63]
        );
        assert_eq!(decode_samples(&encode_samples(&samples)), samples);
    }

    #[test]
    fn backoff_doubles_to_the_cap_and_resets() {
        let mut b = Backoff::default();
        let seconds: Vec<u64> = (0..8).map(|_| b.next_delay().as_secs()).collect();
        assert_eq!(seconds, [1, 2, 4, 8, 16, 32, 60, 60]);
        b.reset();
        assert_eq!(b.next_delay().as_secs(), 1);
    }

    /// An in-process worker over real pipes, answering per `script` for each frame it reads.
    pub(crate) fn pipes(
        script: impl FnOnce(&mut io::PipeReader, &mut io::PipeWriter) + Send + 'static,
    ) -> Client {
        let (mut to_worker_rx, to_worker) = io::pipe().unwrap();
        let (from_worker, mut from_worker_tx) = io::pipe().unwrap();
        std::thread::spawn(move || script(&mut to_worker_rx, &mut from_worker_tx));
        Client::new(from_worker, to_worker)
    }

    fn write(w: &mut impl Write, header: Header) {
        w.write_all(&encode_frame(&header, &[]).unwrap()).unwrap();
    }

    pub(crate) fn identity() -> ModelIdentity {
        ModelIdentity {
            engine: "fake".into(),
            model_id: "m".into(),
            model_revision: "r".into(),
            manifest_hash: "h".into(),
            sdk: "0".into(),
            booster: None,
            worker_build: "b".into(),
        }
    }

    #[test]
    fn jobs_run_in_order_and_state_frames_are_skipped() {
        let mut client = pipes(|r, w| {
            write(w, Header::ready(identity()));
            let first = read_frame(r).unwrap().unwrap();
            assert_eq!(first.header.job, Some(1));
            assert_eq!(decode_samples(&first.payload), [0.5, 0.25]);
            write(
                w,
                Header {
                    state: Some("active".into()),
                    ..Header::of("state")
                },
            );
            write(w, Header::result(1, serde_json::json!({"text": "a"}), 7));
            let second = read_frame(r).unwrap().unwrap();
            assert_eq!(second.header.job, Some(2));
            write(w, Header::error(2, CODE_INVALID_AUDIO));
            assert_eq!(read_frame(r).unwrap().unwrap().header.kind, "shutdown");
        });
        assert_eq!(
            client.wait_ready(JOB_DEADLINE),
            Ok(Started::Ready(identity()))
        );
        let result = client.recognize(&[0.5, 0.25], None, JOB_DEADLINE).unwrap();
        assert_eq!(
            (
                result.job,
                result.recognition_ms,
                result.window["text"].as_str()
            ),
            (1, 7, Some("a"))
        );
        assert_eq!(
            client.recognize(&[0.0], None, JOB_DEADLINE),
            Err(JobError::Code(CODE_INVALID_AUDIO.into()))
        );
        client.shutdown();
    }

    #[test]
    fn unavailable_is_a_start_result() {
        let mut client = pipes(|_, w| write(w, Header::unavailable("model_missing")));
        assert_eq!(
            client.wait_ready(JOB_DEADLINE),
            Ok(Started::Unavailable("model_missing".into()))
        );
    }

    #[test]
    fn anything_before_ready_is_fatal() {
        let mut client = pipes(|_, w| {
            write(
                w,
                Header {
                    state: Some("active".into()),
                    ..Header::of("state")
                },
            )
        });
        assert_eq!(
            client.wait_ready(JOB_DEADLINE),
            Err(Fatal::Malformed("first frame"))
        );
    }

    #[test]
    fn an_answer_for_another_job_is_fatal() {
        let mut client = pipes(|r, w| {
            read_frame(r).unwrap();
            write(w, Header::result(9, serde_json::json!({}), 1));
        });
        assert_eq!(
            client.recognize(&[0.0], None, JOB_DEADLINE),
            Err(JobError::Fatal(Fatal::OutOfOrder))
        );
        assert_eq!(
            client.recognize(&[0.0], None, JOB_DEADLINE),
            Err(JobError::Fatal(Fatal::OutOfOrder)),
            "stays dead"
        );
    }

    #[test]
    fn a_malformed_answer_is_fatal() {
        let mut client = pipes(|r, w| {
            read_frame(r).unwrap();
            w.write_all(&raw(r#"{"type":"hello"}"#, &[])).unwrap();
        });
        assert_eq!(
            client.recognize(&[0.0], None, JOB_DEADLINE),
            Err(JobError::Fatal(Fatal::Malformed("type")))
        );
    }

    #[test]
    fn end_of_input_is_an_exit() {
        let mut client = pipes(|r, _| {
            read_frame(r).unwrap();
        });
        assert_eq!(
            client.recognize(&[0.0], None, JOB_DEADLINE),
            Err(JobError::Fatal(Fatal::Exited))
        );
    }

    #[test]
    fn a_silent_worker_misses_the_deadline() {
        let (release, wait) = sync_channel::<()>(0);
        let mut client = pipes(move |r, _| {
            read_frame(r).unwrap();
            let _ = wait.recv();
        });
        let started = Instant::now();
        assert_eq!(
            client.recognize(&[0.0], None, Duration::from_millis(50)),
            Err(JobError::Fatal(Fatal::Deadline))
        );
        assert!(started.elapsed() < Duration::from_secs(5));
        drop(release);
    }

    #[test]
    fn a_worker_that_stops_reading_still_misses_the_deadline() {
        let (release, wait) = sync_channel::<()>(0);
        // Nothing reads, and a full window is more than a pipe buffer holds.
        let mut client = pipes(move |_, _| {
            let _ = wait.recv();
        });
        let samples = vec![0.0; MAX_SAMPLE_COUNT];
        assert_eq!(
            client.recognize(&samples, None, Duration::from_millis(50)),
            Err(JobError::Fatal(Fatal::Deadline))
        );
        drop(release);
    }

    #[test]
    fn an_oversized_boost_is_refused_and_the_worker_lives() {
        let mut client = pipes(|r, w| {
            let frame = read_frame(r).unwrap().unwrap();
            write(
                w,
                Header::result(frame.header.job.unwrap(), serde_json::json!({}), 1),
            );
        });
        let terms = vec![BoostTerm {
            entry_id: "e".repeat(70_000),
            canonical: "c".into(),
        }];
        assert_eq!(
            client.recognize(
                &[0.0],
                Some(Boost {
                    terms,
                    governed: vec![]
                }),
                JOB_DEADLINE
            ),
            Err(JobError::Refused(FrameError::HeaderTooLarge))
        );
        assert_eq!(
            client.recognize(&[0.0], None, JOB_DEADLINE).unwrap().job,
            1,
            "the refused job used no number"
        );
    }
}
