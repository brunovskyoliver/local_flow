//! `flow-speech-win serve --models <dir> [--runtime <dir>] [--descriptors <dir>]`
//! `flow-speech-win provision --models <dir> [--booster] [--descriptors <dir>]`
//! The runtime libraries default to the executable's folder. `--descriptors` replaces the embedded
//! manifest with `sherpa-parakeet-v3.json` from that folder, like `flowd-speech`'s option.
use flow_speech_win::provision::{self, Manifest};
use flow_speech_win::{send_unavailable, serve, sherpa::Sherpa};
use std::path::PathBuf;

const USAGE: &str = "usage: flow-speech-win serve|provision --models <dir> [--runtime <dir>] [--booster] [--descriptors <dir>]";

fn option(arguments: &[String], name: &str) -> Option<PathBuf> {
    let index = arguments.iter().position(|a| a == name)?;
    arguments.get(index + 1).map(PathBuf::from)
}

fn main() {
    // A panic message could quote what it was working on, and stderr carries no content.
    std::panic::set_hook(Box::new(|_| eprintln!("panic")));
    std::process::exit(run());
}

fn run() -> i32 {
    let arguments: Vec<String> = std::env::args().collect();
    let (Some(mode), Some(models)) = (
        arguments.get(1).map(String::as_str),
        option(&arguments, "--models"),
    ) else {
        eprintln!("{USAGE}");
        return 64;
    };
    let manifest = match option(&arguments, "--descriptors") {
        Some(dir) => match std::fs::read_to_string(dir.join("sherpa-parakeet-v3.json"))
            .ok()
            .and_then(|text| Manifest::parse(&text))
        {
            Some(manifest) => manifest,
            None => {
                eprintln!("descriptor_missing");
                return 1;
            }
        },
        None => Manifest::embedded(),
    };
    match mode {
        "serve" => serve_mode(&arguments, &models, &manifest),
        "provision" => {
            // Windows has no term booster (spec); the flag is accepted for the shared command line.
            if arguments.iter().any(|a| a == "--meeting") {
                eprintln!("provision state=failed reason=meeting_unsupported");
                return 1;
            }
            match provision::provision(&models, &manifest) {
                Ok(_) => 0,
                Err(failure) => {
                    eprintln!(
                        "provision model={} state=failed reason={}",
                        manifest.model_id,
                        failure.label()
                    );
                    1
                }
            }
        }
        _ => {
            eprintln!("{USAGE}");
            64
        }
    }
}

fn serve_mode(arguments: &[String], models: &std::path::Path, manifest: &Manifest) -> i32 {
    let (mut input, mut output) = (std::io::stdin().lock(), std::io::stdout().lock());
    #[cfg(feature = "fake-engine")]
    if arguments.iter().any(|a| a == "--fake-engine") {
        return serve(&mut flow_speech_win::FakeEngine, &mut input, &mut output);
    }
    let Some(model_dir) = provision::model_ready(models, manifest) else {
        return send_unavailable(&mut output, "model_missing");
    };
    let runtime_dir = option(arguments, "--runtime")
        .or_else(|| std::env::current_exe().ok()?.parent().map(PathBuf::from))
        .unwrap_or_default();
    let Some(runtime) = manifest
        .runtime_here()
        .filter(|runtime| provision::runtime_verified(&runtime_dir, runtime))
    else {
        return send_unavailable(&mut output, "runtime_missing");
    };
    let Some(mut engine) = Sherpa::load(&runtime_dir, runtime, &model_dir, manifest) else {
        eprintln!("state=load_failed");
        return 1;
    };
    serve(&mut engine, &mut input, &mut output)
}
