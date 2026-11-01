//! sherpa-onnx's C API (v2.0.1, the pinned runtime), loaded at run time so nothing links it and
//! cross-builds need no ONNX Runtime. Call `load` only with files that passed `runtime_verified`:
//! the layouts below match that exact version.
use crate::provision::{Manifest, Runtime};
use crate::{Engine, EngineError, Recognition, SAMPLE_RATE, Token, WORKER_BUILD};
use flow_core::dictation::worker::ModelIdentity;
use std::ffi::{CStr, CString, c_char, c_void};
use std::path::Path;

#[cfg(unix)]
mod dl {
    use std::ffi::{CString, c_char, c_int, c_void};
    use std::path::Path;
    unsafe extern "C" {
        fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
        fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    }
    const RTLD_NOW: c_int = 2;
    pub fn open(path: &Path) -> Option<*mut c_void> {
        let path = CString::new(path.to_str()?).ok()?;
        // SAFETY: a valid C string; the caller verified the file. ONNX Runtime resolves next to it
        // through the library's own @loader_path.
        Some(unsafe { dlopen(path.as_ptr(), RTLD_NOW) }).filter(|h| !h.is_null())
    }
    pub fn symbol(handle: *mut c_void, name: &std::ffi::CStr) -> Option<*mut c_void> {
        // SAFETY: a live handle and a valid C string.
        Some(unsafe { dlsym(handle, name.as_ptr()) }).filter(|s| !s.is_null())
    }
}

#[cfg(windows)]
mod dl {
    use std::ffi::{c_char, c_void};
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LoadLibraryExW(path: *const u16, file: *mut c_void, flags: u32) -> *mut c_void;
        fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    }
    /// `onnxruntime.dll` resolves from the library's own folder, not the current directory.
    const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x8;
    pub fn open(path: &Path) -> Option<*mut c_void> {
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain([0]).collect();
        // SAFETY: a NUL-terminated absolute path; the caller verified the file.
        Some(unsafe {
            LoadLibraryExW(
                wide.as_ptr(),
                std::ptr::null_mut(),
                LOAD_WITH_ALTERED_SEARCH_PATH,
            )
        })
        .filter(|h| !h.is_null())
    }
    pub fn symbol(handle: *mut c_void, name: &std::ffi::CStr) -> Option<*mut c_void> {
        // SAFETY: a live module and a valid C string.
        Some(unsafe { GetProcAddress(handle, name.as_ptr()) }).filter(|s| !s.is_null())
    }
}

type Text = *const c_char;

/// `SherpaOnnxOfflineModelConfig`. Unused members are blanks of the C size, all zero, which the
/// library reads as unset. 64-bit layouts, the same on macOS and Windows; sizes in `layout_matches`.
#[repr(C)]
struct ModelConfig {
    encoder: Text,
    decoder: Text,
    joiner: Text,
    /// paraformer 8, nemo_ctc 8, whisper 48, tdnn 8.
    _other_models: [u64; 9],
    tokens: Text,
    num_threads: i32,
    debug: i32,
    provider: Text,
    model_type: Text,
    /// modeling_unit through cohere_transcribe.
    _rest: [u64; 47],
}

#[repr(C)]
struct RecognizerConfig {
    sample_rate: i32,
    feature_dim: i32,
    model: ModelConfig,
    /// lm_config.
    _lm: [u64; 2],
    decoding_method: Text,
    /// max_active_paths through ctc_fst_decoder_config.
    _rest: [u64; 11],
}

#[repr(C)]
struct RawResult {
    text: Text,
    timestamps: *const f32,
    count: i32,
    tokens: Text,
    tokens_arr: *const Text,
    _json_lang_emotion_event: [u64; 4],
    durations: *const f32,
    _rest: [u64; 6],
}

struct Api {
    create: unsafe extern "C" fn(*const RecognizerConfig) -> *const c_void,
    create_stream: unsafe extern "C" fn(*const c_void) -> *const c_void,
    destroy_stream: unsafe extern "C" fn(*const c_void),
    accept: unsafe extern "C" fn(*const c_void, i32, *const f32, i32),
    decode: unsafe extern "C" fn(*const c_void, *const c_void),
    result: unsafe extern "C" fn(*const c_void) -> *const RawResult,
    destroy_result: unsafe extern "C" fn(*const RawResult),
}

/// The engine. Loaded once per process; the process's exit releases it (contract: release by exit).
pub struct Sherpa {
    api: Api,
    recognizer: *const c_void,
    identity: ModelIdentity,
}

macro_rules! bind {
    ($handle:expr, $name:literal) => {{
        let symbol = dl::symbol($handle, $name)?;
        // SAFETY: the file passed its pin, so this symbol has the v2.0.1 signature of the field.
        unsafe { std::mem::transmute::<*mut c_void, _>(symbol) }
    }};
}

impl Sherpa {
    /// `None` when the library or model won't load. The caller exits 1, as `flowd-speech` does.
    pub fn load(
        runtime_dir: &Path,
        runtime: &Runtime,
        model_dir: &Path,
        manifest: &Manifest,
    ) -> Option<Sherpa> {
        // An absolute path: the loader must not search for it.
        let library = std::path::absolute(runtime_dir.join(&runtime.library)).ok()?;
        let handle = dl::open(&library)?;
        let api = Api {
            create: bind!(handle, c"SherpaOnnxCreateOfflineRecognizer"),
            create_stream: bind!(handle, c"SherpaOnnxCreateOfflineStream"),
            destroy_stream: bind!(handle, c"SherpaOnnxDestroyOfflineStream"),
            accept: bind!(handle, c"SherpaOnnxAcceptWaveformOffline"),
            decode: bind!(handle, c"SherpaOnnxDecodeOfflineStream"),
            result: bind!(handle, c"SherpaOnnxGetOfflineStreamResult"),
            destroy_result: bind!(handle, c"SherpaOnnxDestroyOfflineRecognizerResult"),
        };
        let path = |name: &str| CString::new(model_dir.join(name).to_str()?).ok();
        let (encoder, decoder, joiner, tokens) = (
            path("encoder.int8.onnx")?,
            path("decoder.int8.onnx")?,
            path("joiner.int8.onnx")?,
            path("tokens.txt")?,
        );
        // SAFETY: all-zero is a valid value of these plain C structs: null pointers and zero numbers.
        let mut config: RecognizerConfig = unsafe { std::mem::zeroed() };
        config.sample_rate = SAMPLE_RATE;
        config.feature_dim = 80;
        config.model.encoder = encoder.as_ptr();
        config.model.decoder = decoder.as_ptr();
        config.model.joiner = joiner.as_ptr();
        config.model.tokens = tokens.as_ptr();
        // ponytail: fixed at four threads at most; measure on real x64 hardware before tuning (SC-003).
        config.model.num_threads =
            std::thread::available_parallelism().map_or(2, |n| n.get().min(4)) as i32;
        config.model.provider = c"cpu".as_ptr();
        config.model.model_type = c"nemo_transducer".as_ptr();
        config.decoding_method = c"greedy_search".as_ptr();
        // SAFETY: the config and its strings outlive the call, which copies them.
        let recognizer = unsafe { (api.create)(&config) };
        if recognizer.is_null() {
            return None;
        }
        let identity = ModelIdentity {
            engine: manifest.engine.clone(),
            model_id: manifest.model_id.clone(),
            model_revision: manifest.model_revision.clone(),
            manifest_hash: manifest.hash.clone(),
            sdk: manifest.sdk.clone(),
            booster: None,
            worker_build: WORKER_BUILD.into(),
        };
        Some(Sherpa {
            api,
            recognizer,
            identity,
        })
    }
}

fn text(pointer: Text) -> String {
    if pointer.is_null() {
        return String::new();
    }
    // SAFETY: the library hands out NUL-terminated strings that live as long as the result.
    unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned()
}

/// Token times from per-token starts. Where the model gives no duration, a token ends where the next
/// starts and the last ends with the audio. Non-finite times drop all timings.
pub fn timed_tokens(
    texts: Vec<String>,
    starts: &[f32],
    durations: Option<&[f32]>,
    audio_seconds: f64,
) -> Vec<Token> {
    if texts.len() != starts.len()
        || starts
            .iter()
            .chain(durations.unwrap_or(&[]))
            .any(|t| !t.is_finite())
    {
        return vec![];
    }
    let count = texts.len();
    texts
        .into_iter()
        .enumerate()
        .map(|(i, text)| {
            let start = starts[i] as f64;
            let end = match durations.and_then(|d| d.get(i)).filter(|d| **d > 0.0) {
                Some(duration) => start + *duration as f64,
                None if i + 1 < count => starts[i + 1] as f64,
                None => audio_seconds,
            };
            Token {
                text,
                start,
                end: end.max(start),
            }
        })
        .collect()
}

impl Engine for Sherpa {
    fn identity(&self) -> ModelIdentity {
        self.identity.clone()
    }

    fn recognize(&mut self, samples: &[f32]) -> Result<Recognition, EngineError> {
        let count = i32::try_from(samples.len()).map_err(|_| EngineError::InvalidAudio)?;
        // SAFETY: the recognizer lives for the process; each stream and result is destroyed once, here.
        unsafe {
            let stream = (self.api.create_stream)(self.recognizer);
            if stream.is_null() {
                return Err(EngineError::ModelUnavailable);
            }
            (self.api.accept)(stream, SAMPLE_RATE, samples.as_ptr(), count);
            (self.api.decode)(self.recognizer, stream);
            let raw = (self.api.result)(stream);
            if raw.is_null() {
                (self.api.destroy_stream)(stream);
                return Err(EngineError::Failed);
            }
            let result = &*raw;
            let tokens =
                if result.count > 0 && !result.timestamps.is_null() && !result.tokens_arr.is_null()
                {
                    let n = result.count as usize;
                    let names = std::slice::from_raw_parts(result.tokens_arr, n)
                        .iter()
                        .map(|t| text(*t))
                        .collect();
                    let starts = std::slice::from_raw_parts(result.timestamps, n);
                    let durations = (!result.durations.is_null())
                        .then(|| std::slice::from_raw_parts(result.durations, n));
                    timed_tokens(
                        names,
                        starts,
                        durations,
                        samples.len() as f64 / SAMPLE_RATE as f64,
                    )
                } else {
                    vec![]
                };
            let recognition = Recognition {
                text: text(result.text).trim().to_string(),
                tokens,
            };
            (self.api.destroy_result)(raw);
            (self.api.destroy_stream)(stream);
            Ok(recognition)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};

    /// Measured with a C compile of v2.0.1's own `c-api.h` on 2026-11-01. A wrong size here would
    /// crash inside the library, so this is the check that the blanks add up.
    #[test]
    fn layout_matches() {
        assert_eq!(size_of::<RecognizerConfig>(), 624);
        assert_eq!(size_of::<ModelConfig>(), 504);
        assert_eq!(size_of::<RawResult>(), 128);
        assert_eq!(offset_of!(RecognizerConfig, model), 8);
        assert_eq!(offset_of!(RecognizerConfig, _lm), 512);
        assert_eq!(offset_of!(RecognizerConfig, decoding_method), 528);
        assert_eq!(offset_of!(ModelConfig, tokens), 96);
        assert_eq!(offset_of!(ModelConfig, num_threads), 104);
        assert_eq!(offset_of!(ModelConfig, debug), 108);
        assert_eq!(offset_of!(ModelConfig, provider), 112);
        assert_eq!(offset_of!(ModelConfig, model_type), 120);
        assert_eq!(offset_of!(RawResult, timestamps), 8);
        assert_eq!(offset_of!(RawResult, count), 16);
        assert_eq!(offset_of!(RawResult, tokens_arr), 32);
        assert_eq!(offset_of!(RawResult, durations), 72);
    }

    #[test]
    fn token_times() {
        let names = || vec!["a".to_string(), "b".to_string()];
        let tokens = timed_tokens(names(), &[0.5, 1.0], None, 2.0);
        assert_eq!(
            (tokens[0].start, tokens[0].end, tokens[1].end),
            (0.5, 1.0, 2.0)
        );
        let tokens = timed_tokens(names(), &[0.5, 1.0], Some(&[0.25, 0.0]), 2.0);
        assert_eq!(
            (tokens[0].end, tokens[1].end),
            (0.75, 2.0),
            "a zero duration falls back"
        );
        assert!(timed_tokens(names(), &[0.5, f32::NAN], None, 2.0).is_empty());
        assert!(
            timed_tokens(names(), &[0.5], None, 2.0).is_empty(),
            "lengths differ"
        );
        assert_eq!(
            timed_tokens(vec!["a".into()], &[3.0], None, 2.0)[0].end,
            3.0,
            "never before its start"
        );
    }
}
