//! `LOCALFLOW_SCENARIO=settings.<state>`: states that need a Mac service or a server to reach.
//! Tests and the audit use them; production never sets the variable.
use super::*;
use flow_core::prefs::Prefs;
use flow_core::settings::{Alternate, ConnectedInput, InputEntry};

pub(super) fn seed(s: &str, p: &mut Prefs) {
    let approved = |p: &mut Prefs, consent: i64| {
        p.set("remote.enabled", true);
        p.set("remote.serverURL", "https://flow.example.com");
        p.set("remote.state", "approved");
        p.set("remote.consentVersion", consent);
    };
    let remote = |p: &mut Prefs, state: &str| {
        approved(p, 2);
        p.set("remote.state", state);
    };
    match s {
        "approved" | "advanced" | "turn-off" => approved(p, 2),
        "consent-update" | "consent-update-sheet" => approved(p, 1),
        "server-only" => {
            approved(p, 2);
            p.set("server.only", true);
        }
        "summary-remote" => p.set("summaryServer", "remote"),
        "custom" => {
            approved(p, 2);
            p.set("server.override.rewrite", "custom");
            p.set("server.override.summaries", "custom");
            p.set("summaryServer", "remote");
        }
        "checking" | "consent-on" => remote(p, "off"),
        "pending" | "pinned" | "rejected" | "revoked" => remote(p, s),
        "pin-mismatch" => remote(p, "pin_mismatch"),
        "sign-in-again" => {
            remote(p, "pinned");
            p.set("remote.notice", "sign_in_again");
        }
        "update-required" => {
            remote(p, "pending");
            p.set("remote.notice", "update_required");
        }
        "meeting-only" => p.set("setup.purpose", "meetings"),
        "rewrite-loopback" => p.set("rewriteEndpoint", "http://127.0.0.1:8080"),
        "rewrite-insecure" => {
            p.set("rewriteEndpoint", "http://10.0.0.5:8080");
            core::set_insecure_override(p, "http://10.0.0.5:8080", true);
        }
        _ => {}
    }
}

pub(super) fn apply_snapshot(s: &str, n: &mut Snapshot) {
    let all = |n: &mut Snapshot, state| {
        n.microphone = state;
        n.input_monitoring = state;
        n.accessibility = state;
    };
    match s {
        "installed" => n.model_installed = true,
        "loaded" => {
            n.model_installed = true;
            n.runtime = Runtime::Ready;
        }
        "installing" => {
            n.installing = true;
            n.completed = 40;
            n.total = 100;
        }
        "verifying" => {
            n.installing = true;
            n.verifying = true;
        }
        "all-installed" => {
            n.model_installed = true;
            n.meeting_installed = true;
            n.speaker_installed = true;
            n.boost_installed = true;
        }
        "others-installing" => {
            n.meeting_installing = true;
            n.speaker_installing = true;
            n.boost_installing = true;
        }
        "alternate" | "alt-download" => n.alternate = Some(Alternate { choice: "parakeet-ultra", installed: false, installing: false, completed: 0, total: 0, bytes: 2_500_000_000 }),
        "alt-downloading" => n.alternate = Some(Alternate { choice: "parakeet-ultra", installed: false, installing: true, completed: 30, total: 100, bytes: 2_500_000_000 }),
        "alt-installed" => n.alternate = Some(Alternate { choice: "parakeet-ultra", installed: true, installing: false, completed: 0, total: 0, bytes: 2_500_000_000 }),
        "permissions-granted" => all(n, Perm::Granted),
        "permissions-refused" => all(n, Perm::Denied),
        _ => {}
    }
}

fn demo_input(id: u32, uid: &str, name: &str, kind: &str) -> ConnectedInput {
    ConnectedInput { device_id: id, uid: uid.into(), model_uid: None, name: name.into(), kind: kind.into(), alive: true }
}

pub(super) fn apply_view(page: &mut SettingsPage, window: &mut Window, cx: &mut Context<SettingsPage>) {
    // The audit window can't be scrolled from outside, so captures of lower sections ask for it.
    if let Some(y) = std::env::var("LOCALFLOW_SETTINGS_SCROLL").ok().and_then(|y| y.parse::<f32>().ok()) {
        page.scroll_handle().set_offset(point(px(0.), px(-y)));
    }
    match page.scenario.as_str() {
        "updates-sparkle" => page.updates = Updates::Sparkle { automatic: true, can_check: true },
        "updates-failed" => page.updates = Updates::Failed,
        "shortcut-listening" => page.recording = true,
        "advanced" | "custom" => page.server_advanced = true,
        "test-passed" => {
            page.test_results.insert("speech", "Working · 412 ms".into());
        }
        "consent" => {
            page.server_draft.read(cx).focus_handle(cx).focus(window, cx);
            page.modal = Some(Modal::Consent);
        }
        "turn-off" => page.prompt_turn_off(window, cx),
        "consent-update-sheet" => page.modal = Some(Modal::ConsentUpdate),
        "download" => page.prompt_download(false, window, cx),
        "alt-download" => page.prompt_download(true, window, cx),
        "exclusions" => page.modal = Some(Modal::Context(ContextKind::Exclusions)),
        "kinds" => page.modal = Some(Modal::Context(ContextKind::Kinds)),
        "microphones" | "voice-over" => {
            page.voice_over = page.scenario == "voice-over";
            let snapshot = InputSnapshot {
                inputs: vec![demo_input(1, "BuiltInMicrophoneDevice", "MacBook Pro Microphone", "builtIn"), demo_input(2, "usb-AAAA-1111", "Blue Yeti", "usb"), demo_input(3, "bt-XXXX-3F2A", "AirPods Pro", "bluetooth")],
                default_input: Some(1),
                clamshell: false,
            };
            let entries = vec![
                InputEntry { id: "e-usb".into(), kind: "usb".into(), uid: Some("usb-AAAA-1111".into()), model_uid: None, name: "Blue Yeti".into(), last_seen_at: None },
                InputEntry { id: "e-gone".into(), kind: "usb".into(), uid: Some("usb-gone".into()), model_uid: None, name: "Studio Mic".into(), last_seen_at: None },
                InputEntry::system_default(),
            ];
            page.mics = Some(Mics { entries, snapshot });
        }
        _ => {}
    }
}
