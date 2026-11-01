//! The real binary over real pipes, with the worker client from `flow-core`. The fake engine is the
//! only fake; the real-engine test runs only when `FLOW_SPEECH_REAL_DIR` points at downloaded files.
use flow_core::dictation::worker::{
    Client, Fatal, Header, JOB_DEADLINE, JobError, MAX_SAMPLE_COUNT, READY_TIMEOUT, Started,
    encode_frame,
};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

fn spawn(args: &[&str]) -> (Child, Client) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_flow-speech-win"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let client = Client::new(child.stdout.take().unwrap(), child.stdin.take().unwrap());
    (child, client)
}

fn fake() -> (Child, Client) {
    let (child, mut client) = spawn(&["serve", "--models", "unused", "--fake-engine"]);
    let Ok(Started::Ready(model)) = client.wait_ready(READY_TIMEOUT) else {
        panic!("no ready")
    };
    assert_eq!(
        (model.engine.as_str(), model.worker_build.as_str()),
        ("fake", "flow-speech-win 1")
    );
    (child, client)
}

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "flow-speech-conformance-{name}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn jobs_answer_in_order_with_contract_codes() {
    let (mut child, mut client) = fake();
    let result = client.recognize(&[0.0; 1600], None, JOB_DEADLINE).unwrap();
    assert_eq!(
        (
            result.job,
            result.window["sample_count"].as_u64(),
            result.window["text"].as_str()
        ),
        (1, Some(1600), Some("heard 1600"))
    );
    let full = client
        .recognize(&vec![0.0; MAX_SAMPLE_COUNT], None, JOB_DEADLINE)
        .unwrap();
    assert_eq!(
        (full.job, full.window["sample_count"].as_u64()),
        (2, Some(MAX_SAMPLE_COUNT as u64))
    );
    for (first, code) in [
        (-2.0, "failed"),
        (-3.0, "model_unavailable"),
        (-4.0, "failed"),
        (f32::NAN, "invalid_audio"),
        (-7.0, "failed"),
    ] {
        assert_eq!(
            client.recognize(&[first], None, JOB_DEADLINE),
            Err(JobError::Code(code.into())),
            "{first}"
        );
    }
    assert!(
        client.recognize(&[0.0], None, JOB_DEADLINE).is_ok(),
        "the worker survived them all"
    );
    client.shutdown();
    drop(client);
    assert_eq!(
        child.wait().unwrap().code(),
        Some(0),
        "shutdown exits clean"
    );
}

/// The whole path the app takes: lifecycle, the platform's spawn, the real binary.
#[test]
fn lifecycle_starts_uses_and_restarts_the_real_binary() {
    use flow_core::dictation::lifecycle::{Lifecycle, RecognizeError, Refusal};
    let launcher = flow_platform::speech::WorkerLauncher {
        path: env!("CARGO_BIN_EXE_flow-speech-win").into(),
        args: ["serve", "--models", "unused", "--fake-engine"]
            .map(String::from)
            .to_vec(),
    };
    let mut lifecycle = Lifecycle::new(Box::new(launcher), Box::new(std::time::Instant::now));
    let lease = lifecycle.acquire().unwrap();
    assert_eq!(
        lifecycle
            .recognize(&lease, &[0.0; 16], None)
            .unwrap()
            .window["sample_count"],
        16
    );
    assert_eq!(
        lifecycle.recognize(&lease, &[-5.0], None),
        Err(RecognizeError::Lost(Fatal::Exited))
    );
    assert!(matches!(
        lifecycle.recognize(&lease, &[0.0], None),
        Err(RecognizeError::Refused(Refusal::Restarting(_)))
    ));
    std::thread::sleep(Duration::from_millis(1100));
    assert!(
        lifecycle.recognize(&lease, &[0.0], None).is_ok(),
        "restarted after the backoff"
    );
    lifecycle.finish(lease);
    assert!(lifecycle.shutdown_if_idle());
    assert_eq!(lifecycle.model(), None);
}

#[test]
fn closing_stdin_exits_clean() {
    let (mut child, client) = fake();
    drop(client);
    assert_eq!(child.wait().unwrap().code(), Some(0));
}

#[test]
fn a_crash_is_seen_as_an_exit() {
    let (mut child, mut client) = fake();
    assert_eq!(
        client.recognize(&[-5.0], None, JOB_DEADLINE),
        Err(JobError::Fatal(Fatal::Exited))
    );
    assert_eq!(child.wait().unwrap().code(), Some(9));
}

#[test]
fn a_hung_engine_misses_the_deadline_and_dies_when_killed() {
    let (mut child, mut client) = fake();
    assert_eq!(
        client.recognize(&[-6.0], None, Duration::from_millis(200)),
        Err(JobError::Fatal(Fatal::Deadline))
    );
    child.kill().unwrap();
    child.wait().unwrap();
}

#[test]
fn a_malformed_frame_exits_non_zero() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_flow-speech-win"))
        .args(["serve", "--models", "unused", "--fake-engine"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin
        .write_all(
            &std::fs::read(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../fixtures/remote/worker-frames/invalid-sample-count-over.bin"
            ))
            .unwrap(),
        )
        .unwrap();
    assert_eq!(child.wait().unwrap().code(), Some(1));
}

#[test]
fn no_model_is_unavailable_and_exit_zero() {
    let models = temp("nomodel");
    let (mut child, mut client) = spawn(&["serve", "--models", models.to_str().unwrap()]);
    assert_eq!(
        client.wait_ready(READY_TIMEOUT),
        Ok(Started::Unavailable("model_missing".into()))
    );
    assert_eq!(child.wait().unwrap().code(), Some(0));
    std::fs::remove_dir_all(models).unwrap();
}

#[test]
fn a_verified_model_without_a_verified_runtime_is_unavailable() {
    let (models, descriptors) = (temp("noruntime-models"), temp("noruntime-descriptors"));
    // A one-file model that's already in place, so provisioning needs no network.
    let dir = models.join("sherpa-parakeet-tdt-v3");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("a"), b"model").unwrap();
    let manifest = serde_json::json!({"engine": "e", "sdk": "s", "model_id": "m", "model_revision": "r", "source": "https://example.invalid",
        "files": [{"name": "a", "size": 5, "sha256": flow_speech_win::provision::hash_bytes(b"model")}],
        "runtime": {"windows-x86_64": {"library": "l", "files": [{"name": "l", "size": 1, "sha256": "0".repeat(64)}]}, "macos-aarch64": {"library": "l", "files": [{"name": "l", "size": 1, "sha256": "0".repeat(64)}]}}});
    std::fs::write(
        descriptors.join("sherpa-parakeet-v3.json"),
        manifest.to_string(),
    )
    .unwrap();
    let (m, d) = (models.to_str().unwrap(), descriptors.to_str().unwrap());
    let status = Command::new(env!("CARGO_BIN_EXE_flow-speech-win"))
        .args(["provision", "--models", m, "--descriptors", d, "--booster"])
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(0));
    let (mut child, mut client) =
        spawn(&["serve", "--models", m, "--descriptors", d, "--runtime", d]);
    assert_eq!(
        client.wait_ready(READY_TIMEOUT),
        Ok(Started::Unavailable("runtime_missing".into()))
    );
    assert_eq!(child.wait().unwrap().code(), Some(0));
    std::fs::remove_dir_all(models).unwrap();
    std::fs::remove_dir_all(descriptors).unwrap();
}

#[test]
fn provisioning_an_unpinned_manifest_refuses() {
    let (models, descriptors) = (temp("unpinned-models"), temp("unpinned-descriptors"));
    let manifest = serde_json::json!({"engine": "e", "sdk": "s", "model_id": "m", "model_revision": "r", "source": "https://example.invalid", "files": [{"name": "a", "size": 5, "sha256": ""}], "runtime": {}});
    std::fs::write(
        descriptors.join("sherpa-parakeet-v3.json"),
        manifest.to_string(),
    )
    .unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_flow-speech-win"))
        .args([
            "provision",
            "--models",
            models.to_str().unwrap(),
            "--descriptors",
            descriptors.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("state=failed reason=unpinned"));
    std::fs::remove_dir_all(models).unwrap();
    std::fs::remove_dir_all(descriptors).unwrap();
}

#[test]
fn bad_arguments_are_a_usage_error() {
    for args in [&[][..], &["serve"][..], &["nonsense", "--models", "x"][..]] {
        let status = Command::new(env!("CARGO_BIN_EXE_flow-speech-win"))
            .args(args)
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(64), "{args:?}");
    }
    // Frames the worker sends are encoded with the same rules the client reads.
    assert!(encode_frame(&Header::of("shutdown"), &[]).is_ok());
}

/// 24 kHz PCM16 from the model's own test file, resampled to the contract's 16 kHz.
fn read_wav_16k(path: &std::path::Path) -> Vec<f32> {
    let data = std::fs::read(path).unwrap();
    let start = data.windows(4).position(|w| w == b"data").unwrap() + 8;
    let source: Vec<f32> = data[start..]
        .chunks_exact(2)
        .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0)
        .collect();
    (0..source.len() * 2 / 3)
        .map(|i| {
            let position = i as f64 * 1.5;
            let (index, fraction) = (position as usize, position.fract() as f32);
            source[index] * (1.0 - fraction)
                + source.get(index + 1).copied().unwrap_or(0.0) * fraction
        })
        .collect()
}

/// Mac evidence only, never Windows evidence. `FLOW_SPEECH_REAL_DIR` holds `Models/` (provisioned),
/// `runtime/` and `en.wav`. Nothing is asserted about the words beyond a sane non-empty answer here;
/// the caller reads the transcript from a run with `--nocapture`.
#[test]
fn real_engine_when_files_are_given() {
    let Some(root) = std::env::var_os("FLOW_SPEECH_REAL_DIR").map(PathBuf::from) else {
        return;
    };
    let (models, runtime) = (root.join("Models"), root.join("runtime"));
    let (mut child, mut client) = spawn(&[
        "serve",
        "--models",
        models.to_str().unwrap(),
        "--runtime",
        runtime.to_str().unwrap(),
        "--descriptors",
        root.join("descriptors").to_str().unwrap(),
    ]);
    let started = client.wait_ready(READY_TIMEOUT).unwrap();
    println!("{started:?}");
    let Started::Ready(model) = started else {
        panic!("not ready")
    };
    assert_eq!(model.engine, "sherpa-onnx");
    let samples = read_wav_16k(&root.join("en.wav"));
    let result = client
        .recognize(
            &samples[..samples.len().min(MAX_SAMPLE_COUNT)],
            None,
            JOB_DEADLINE,
        )
        .unwrap();
    println!(
        "samples={} recognition_ms={} text={} first_tokens={}",
        samples.len(),
        result.recognition_ms,
        result.window["text"],
        result.window["tokens"].as_array().map_or(0, Vec::len)
    );
    assert!(!result.window["text"].as_str().unwrap().is_empty());
    assert!(
        result.window["evidence"]["timings_available"]
            .as_bool()
            .unwrap()
    );
    client.shutdown();
    drop(client);
    assert_eq!(child.wait().unwrap().code(), Some(0));
}
