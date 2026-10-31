//! `LOCALFLOW_SCENARIO=onboarding.<state>`: states the audit can't reach with real services.
use super::OnboardingPage;
use crate::core::Core;
use flow_core::onboarding::*;
use flow_ui::prelude::*;

fn ready(s: &mut Snapshot) {
    s.model_installed = true;
    s.speaker_model_installed = true;
    s.meeting_model_installed = true;
    s.microphone = Perm::Granted;
    s.input_monitoring = Perm::Granted;
    s.accessibility = Perm::Granted;
    s.system_audio = Perm::Granted;
    s.shortcut_ready = true;
    s.storage_available = true;
    s.shortcut = Shortcut::right_control();
}

impl OnboardingPage {
    pub(super) fn apply_scenario(&mut self, cx: &mut Context<Self>) {
        let Some(state) = cx.global::<Core>().scenario.as_deref().and_then(|s| s.strip_prefix("onboarding.")).map(str::to_string) else { return };
        self.frozen = true;
        let name = state.as_str();
        let (body, purpose) = match name.split_once('-') {
            Some((b, "meetings")) => (b, Purpose::Meetings),
            Some((b, "dictation")) => (b, Purpose::Dictation),
            _ => (name, Purpose::Both),
        };
        self.setup.purpose = purpose;
        cx.global_mut::<Core>().prefs.set("setup.purpose", purpose.raw());
        let (s, p) = (&mut self.setup, &mut self.snap);
        match body {
            "purpose" => s.step = Step::Purpose,
            "ai" => s.step = Step::Ai,
            "airemote" => {
                s.step = Step::Ai;
                s.ai_mode = AiMode::Remote;
            }
            "model" => {
                s.step = Step::AiDetails;
                self.memory = 16 << 30;
                self.downloaded[1] = true;
            }
            "server" => {
                s.step = Step::AiDetails;
                s.ai_mode = AiMode::Remote;
            }
            "serverlegacy" => {
                s.step = Step::AiDetails;
                s.ai_mode = AiMode::Remote;
                self.legacy_open = true;
                self.connection = Some(Err("Could not reach the server.".into()));
                self.credential_error = Some("Could not access the credential in Keychain.".into());
                cx.global_mut::<Core>().prefs.set("rewriteEndpoint", "http://studio.local:8080");
            }
            "fingerprint" | "signin" | "approved" | "pending" | "mismatch" | "consent" | "turnoff" => {
                s.step = Step::AiDetails;
                s.ai_mode = AiMode::Remote;
                let prefs = &mut cx.global_mut::<Core>().prefs;
                match body {
                    "consent" => self.remote.consent_open = true,
                    _ => {
                        prefs.set("remote.enabled", true);
                        prefs.set("remote.serverURL", "https://server.example.com");
                    }
                }
                match body {
                    "fingerprint" => self.remote.identity = Some("SHA256:synthetic-fixture-fingerprint".into()),
                    "signin" => {
                        prefs.set("remote.state", "pinned");
                        self.remote.pinned = Some("SHA256:synthetic-fixture-fingerprint".into());
                        self.remote.google = true;
                        self.remote.error = Some("Sign-in did not finish.".into());
                    }
                    "approved" => prefs.set("remote.state", "approved"),
                    "pending" => prefs.set("remote.state", "pending"),
                    "mismatch" => prefs.set("remote.state", "pin_mismatch"),
                    "turnoff" => {
                        prefs.set("remote.state", "approved");
                        self.remote.confirm_off = true;
                    }
                    _ => {}
                }
            }
            "downloads" => {
                s.step = Step::Downloads;
                s.meetings_requested = true;
                p.installing = true;
                p.progress = (210 << 20, 632 << 20);
                self.ai_phase = AiPhase::PreparingRuntime;
            }
            "downloadsoffer" => {
                s.step = Step::Downloads;
                s.ai_mode = AiMode::Off;
                p.model_installed = true;
            }
            "downloadsfailed" => {
                s.step = Step::Downloads;
                s.meetings_requested = true;
                p.model_install_error = Some("Installation failed. Check the pinned files, connection and available storage.".into());
                p.meeting_models_error = Some("Meeting models did not finish downloading. Check your connection and available storage.".into());
                self.ai_phase = AiPhase::Failed(AI_ERROR_DOWNLOAD.into());
            }
            "downloadsdone" => {
                s.step = Step::Downloads;
                s.meetings_requested = true;
                ready(p);
                self.ai_phase = AiPhase::Ready;
            }
            "permissions" => {
                s.step = Step::Permissions;
                p.model_installed = true;
                p.storage_available = true;
                p.controls_available = true;
                self.ai_phase = AiPhase::Starting;
            }
            "allowed" => {
                s.step = Step::Permissions;
                ready(p);
                self.ai_phase = AiPhase::Ready;
            }
            "personalize" => {
                s.step = Step::Personalize;
                ready(p);
                self.ai_phase = AiPhase::Ready;
            }
            "test" => {
                s.step = Step::Test;
                ready(p);
                self.ai_phase = AiPhase::Ready;
            }
            "testblocked" => {
                s.step = Step::Test;
                ready(p);
                p.microphone = Perm::Denied;
                s.test_error = Some("The speech model is unavailable. Verify the local model in Settings.".into());
                self.ai_phase = AiPhase::Ready;
            }
            "testsuccess" => {
                s.step = Step::Test;
                ready(p);
                s.test_succeeded = true;
                self.ai_phase = AiPhase::Ready;
            }
            _ => {}
        }
    }
}
