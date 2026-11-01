//! The speech worker on Windows: the same messages as `flowd-speech`
//! (`specs/014-remote-dictation-server/contracts/speech-worker-ipc.md`), over Parakeet TDT v3 in
//! sherpa-onnx. Logs carry job IDs, sample counts, durations and codes only.
use flow_core::dictation::worker::{
    CODE_FAILED, CODE_INVALID_AUDIO, CODE_MODEL_UNAVAILABLE, Frame, Header, ModelIdentity,
    decode_samples, encode_frame, read_frame,
};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::Instant;

pub mod provision;
pub mod sherpa;

pub const WORKER_BUILD: &str = "flow-speech-win 1";
/// What the contract's frames carry: mono 16 kHz.
pub const SAMPLE_RATE: i32 = 16_000;
const WARMUP_SAMPLES: usize = 239_360;

#[derive(Clone, Debug, PartialEq)]
pub struct Token {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Recognition {
    pub text: String,
    pub tokens: Vec<Token>,
}

/// Every engine failure is one of the contract's codes; nothing else leaves the worker.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineError {
    InvalidAudio,
    ModelUnavailable,
    Failed,
}

impl EngineError {
    pub fn code(self) -> &'static str {
        match self {
            EngineError::InvalidAudio => CODE_INVALID_AUDIO,
            EngineError::ModelUnavailable => CODE_MODEL_UNAVAILABLE,
            EngineError::Failed => CODE_FAILED,
        }
    }
}

pub trait Engine {
    fn identity(&self) -> ModelIdentity;
    fn recognize(&mut self, samples: &[f32]) -> Result<Recognition, EngineError>;
}

/// `window_result` without op, index and sample_start. There's no term boosting here (spec), so
/// `boost_hints` is always empty and a job's `boost` is ignored.
pub fn window(recognition: &Recognition, sample_count: usize) -> Value {
    let tokens: Vec<Value> = recognition
        .tokens
        .iter()
        .map(|t| json!({"text": t.text, "start": t.start, "end": t.end}))
        .collect();
    let evidence: Vec<Value> = recognition
        .tokens
        .iter()
        .map(|t| json!({"text": t.text, "start": {"value": t.start}, "end": {"value": t.end}}))
        .collect();
    json!({
        "sample_count": sample_count,
        "text": recognition.text,
        "tokens": tokens,
        "boost_hints": [],
        "evidence": {
            "text": recognition.text,
            "samples": sample_count,
            "padded_samples": sample_count,
            "timings_available": !recognition.tokens.is_empty(),
            "tokens": evidence,
        },
    })
}

fn send(output: &mut impl Write, header: &Header) -> bool {
    match encode_frame(header, &[]) {
        Ok(data) => output
            .write_all(&data)
            .and_then(|()| output.flush())
            .is_ok(),
        Err(_) => false,
    }
}

fn job(engine: &mut dyn Engine, frame: &Frame, output: &mut impl Write) -> bool {
    let id = frame.header.job.unwrap_or(0);
    let samples = decode_samples(&frame.payload);
    let started = Instant::now();
    let answer = if samples.iter().all(|s| s.is_finite()) {
        // A panic in the binding is this job's failure, not a crash that takes the next job too.
        catch_unwind(AssertUnwindSafe(|| engine.recognize(&samples)))
            .unwrap_or(Err(EngineError::Failed))
    } else {
        Err(EngineError::InvalidAudio)
    };
    let ms = started.elapsed().as_millis() as i64;
    match answer {
        Ok(recognition) => {
            let result = Header::result(id, window(&recognition, samples.len()), ms);
            if encode_frame(&result, &[]).is_ok() {
                eprintln!("job={id} samples={} ms={ms}", samples.len());
                return send(output, &result);
            }
            // Over the header limit.
            eprintln!("job={id} samples={} code={CODE_FAILED}", samples.len());
            send(output, &Header::error(id, CODE_FAILED))
        }
        Err(e) => {
            eprintln!("job={id} samples={} code={}", samples.len(), e.code());
            send(output, &Header::error(id, e.code()))
        }
    }
}

/// `ready`, one silent window so the first dictation doesn't pay for it (as `flowd-speech` does),
/// then jobs until `shutdown` or end of input. Returns the exit status. One thread: a blocked read
/// is the job queue, and stdin holds back the client.
// ponytail: no `state` frames. The contract makes them optional, for measurements only.
pub fn serve(engine: &mut dyn Engine, input: &mut impl Read, output: &mut impl Write) -> i32 {
    if !send(output, &Header::ready(engine.identity())) {
        return 1;
    }
    eprintln!("state=ready");
    let warmup = catch_unwind(AssertUnwindSafe(|| {
        engine.recognize(&vec![0.0; WARMUP_SAMPLES])
    }));
    eprintln!("state=warm ok={}", matches!(warmup, Ok(Ok(_))));
    loop {
        let frame = match read_frame(input) {
            Ok(Some(frame)) => frame,
            Ok(None) => return 0,
            Err(_) => {
                eprintln!("frame_malformed");
                return 1;
            }
        };
        match frame.header.kind.as_str() {
            "recognize" => {
                if !job(engine, &frame, output) {
                    eprintln!("write_failed");
                    return 1;
                }
            }
            "shutdown" => {
                eprintln!("state=shutdown");
                return 0;
            }
            _ => {
                eprintln!("frame_unknown_type");
                return 1;
            }
        }
    }
}

/// `unavailable`, then the caller exits 0.
pub fn send_unavailable(output: &mut impl Write, reason: &str) -> i32 {
    eprintln!("state=unavailable reason={reason}");
    if send(output, &Header::unavailable(reason)) {
        0
    } else {
        1
    }
}

/// Scripted by the first sample of a job, for the conformance test.
#[cfg(feature = "fake-engine")]
pub struct FakeEngine;

#[cfg(feature = "fake-engine")]
impl Engine for FakeEngine {
    fn identity(&self) -> ModelIdentity {
        ModelIdentity {
            engine: "fake".into(),
            model_id: "fake-model".into(),
            model_revision: "1".into(),
            manifest_hash: "fake".into(),
            sdk: "0".into(),
            booster: None,
            worker_build: WORKER_BUILD.into(),
        }
    }
    fn recognize(&mut self, samples: &[f32]) -> Result<Recognition, EngineError> {
        match samples[0] {
            -2.0 => return Err(EngineError::Failed),
            -3.0 => return Err(EngineError::ModelUnavailable),
            -4.0 => panic!("scripted"),
            -5.0 => std::process::exit(9),
            -6.0 => std::thread::sleep(std::time::Duration::from_secs(600)),
            -7.0 => {
                return Ok(Recognition {
                    text: "x".repeat(70_000),
                    tokens: vec![],
                });
            }
            _ => {}
        }
        Ok(Recognition {
            text: format!("heard {}", samples.len()),
            tokens: vec![Token {
                text: "heard".into(),
                start: 0.0,
                end: 0.5,
            }],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flow_core::dictation::worker::encode_samples;
    use std::io::Cursor;

    struct Scripted(Vec<Result<Recognition, EngineError>>);
    impl Engine for Scripted {
        fn identity(&self) -> ModelIdentity {
            ModelIdentity {
                engine: "e".into(),
                model_id: "m".into(),
                model_revision: "r".into(),
                manifest_hash: "h".into(),
                sdk: "s".into(),
                booster: None,
                worker_build: "b".into(),
            }
        }
        fn recognize(&mut self, samples: &[f32]) -> Result<Recognition, EngineError> {
            // The warmup, and anything unscripted.
            if samples.len() == WARMUP_SAMPLES || self.0.is_empty() {
                return Ok(Recognition::default());
            }
            self.0.remove(0)
        }
    }

    fn run(engine: &mut dyn Engine, frames: &[Vec<u8>]) -> (i32, Vec<Header>) {
        let mut output = vec![];
        let status = serve(engine, &mut Cursor::new(frames.concat()), &mut output);
        let mut reader = Cursor::new(output);
        let mut headers = vec![];
        while let Ok(Some(frame)) = read_frame(&mut reader) {
            headers.push(frame.header);
        }
        (status, headers)
    }

    fn recognize(job: u64, samples: &[f32]) -> Vec<u8> {
        encode_frame(
            &Header::recognize(job, samples.len(), None),
            &encode_samples(samples),
        )
        .unwrap()
    }

    #[test]
    fn engine_failures_map_to_contract_codes_and_the_worker_lives() {
        let mut engine = Scripted(vec![
            Err(EngineError::InvalidAudio),
            Err(EngineError::ModelUnavailable),
            Err(EngineError::Failed),
            Ok(Recognition {
                text: "ok".into(),
                tokens: vec![],
            }),
        ]);
        let frames = [
            recognize(1, &[0.0]),
            recognize(2, &[0.0]),
            recognize(3, &[0.0]),
            recognize(4, &[f32::NAN]),
            recognize(5, &[0.0]),
        ];
        let (status, headers) = run(&mut engine, &frames);
        assert_eq!(status, 0, "a clean end of input");
        assert_eq!(headers[0].kind, "ready");
        let codes: Vec<_> = headers[1..4]
            .iter()
            .map(|h| h.code.as_deref().unwrap())
            .collect();
        assert_eq!(codes, ["invalid_audio", "model_unavailable", "failed"]);
        assert_eq!(
            (headers[4].job, headers[4].code.as_deref()),
            (Some(4), Some("invalid_audio")),
            "non-finite samples never reach the engine"
        );
        assert_eq!(headers[5].window.as_ref().unwrap()["text"], "ok");
    }

    #[test]
    fn a_panicking_engine_is_a_failed_job() {
        struct Panics;
        impl Engine for Panics {
            fn identity(&self) -> ModelIdentity {
                Scripted(vec![]).identity()
            }
            fn recognize(&mut self, samples: &[f32]) -> Result<Recognition, EngineError> {
                assert_eq!(samples.len(), WARMUP_SAMPLES, "scripted");
                Ok(Recognition::default())
            }
        }
        let (status, headers) = run(&mut Panics, &[recognize(1, &[0.0])]);
        assert_eq!(status, 0);
        assert_eq!(headers[1].code.as_deref(), Some("failed"));
    }

    #[test]
    fn a_result_over_the_header_limit_is_failed() {
        let mut engine = Scripted(vec![Ok(Recognition {
            text: "x".repeat(70_000),
            tokens: vec![],
        })]);
        let (_, headers) = run(&mut engine, &[recognize(1, &[0.0])]);
        assert_eq!(headers[1].code.as_deref(), Some("failed"));
    }

    #[test]
    fn a_malformed_frame_ends_the_worker_and_shutdown_exits_clean() {
        let bad = vec![0, 0, 0, 2, b'{', b'}', 0, 0, 0, 0];
        assert_eq!(run(&mut Scripted(vec![]), &[bad]).0, 1);
        let shutdown = encode_frame(&Header::of("shutdown"), &[]).unwrap();
        let (status, headers) = run(&mut Scripted(vec![]), &[shutdown, recognize(1, &[0.0])]);
        assert_eq!(status, 0);
        assert_eq!(headers.len(), 1, "nothing after shutdown");
    }

    #[test]
    fn window_has_the_channel_fields() {
        let value = window(
            &Recognition {
                text: "a b".into(),
                tokens: vec![Token {
                    text: " a".into(),
                    start: 0.25,
                    end: 0.5,
                }],
            },
            100,
        );
        assert_eq!(value["sample_count"], 100);
        assert_eq!(value["tokens"][0]["start"], 0.25);
        assert_eq!(value["evidence"]["tokens"][0]["end"]["value"], 0.5);
        assert_eq!(value["evidence"]["timings_available"], true);
        assert_eq!(value["boost_hints"], json!([]));
        assert_eq!(
            window(&Recognition::default(), 1)["evidence"]["timings_available"],
            false
        );
    }
}
