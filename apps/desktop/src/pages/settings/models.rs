//! Settings › Models. Installing and loading are Features 025 and 026: every action goes through
//! `Services::settings_action` and surfaces its failure as Swift surfaces one.
use super::*;
use flow_core::settings::Service;

pub(super) fn in_meeting(cx: &App) -> bool {
    cx.try_global::<crate::shell::Session>().and_then(|s| s.meeting.as_ref()).is_some_and(|m| m.state.is_active())
}

impl SettingsPage {
    /// The optional role, where the work runs once routing applies, and the state.
    fn detail(&self, role: Option<&str>, service: Service, state: &str, cx: &App) -> Option<String> {
        let parts = role.into_iter().chain(core::routing(prefs(cx)).model_place(service)).chain([state]).filter(|p| !p.is_empty()).collect::<Vec<_>>();
        (!parts.is_empty()).then(|| parts.join(" · "))
    }

    pub(super) fn controls_available(&self) -> bool {
        let s = &self.snapshot;
        !self.performing && !s.busy && !s.installing && s.controls_available
    }

    /// Full-hash verify, then load, run once and release.
    pub(super) fn test_model(&mut self, name: &'static str, cx: &mut Context<Self>) {
        if self.performing || self.snapshot.busy {
            return;
        }
        self.error = None;
        self.testing = Some(name);
        let started = std::time::Instant::now();
        let answer = crate::dictation::test_model(name, cx);
        let done = move |ok: bool, this: &mut Self, cx: &mut Context<Self>| {
            let result = if ok { format!("Working · {} ms", started.elapsed().as_millis()) } else { core::describe(&Failure::Other("flow_platform.Unavailable".into(), 0)) };
            this.testing = None;
            this.test_results.insert(name, result);
            cx.notify();
        };
        // The platform answers at once; the session thread when it has run the model.
        if let Ok(ok) = answer.try_recv() {
            return done(ok, self, cx);
        }
        cx.spawn(async move |this, cx| {
            let ok = cx.background_spawn(async move { answer.recv().unwrap_or(false) }).await;
            let _ = this.update(cx, |this, cx| done(ok, this, cx));
        })
        .detach();
        cx.notify();
    }

    fn status(&self, test: &'static str, fallback: &str) -> String {
        if self.testing == Some(test) { "Testing…".into() } else { self.test_results.get(test).cloned().unwrap_or_else(|| fallback.to_string()) }
    }

    fn action(id: impl Into<SharedString>, label: &'static str, action: &'static str, disabled: bool, cx: &mut Context<Self>) -> FlowButton {
        prototype_button(ElementId::Name(id.into()), label).disabled(disabled).on_click(cx.listener(move |this, _, _, cx| this.run(action, cx)))
    }

    fn test_button(&self, name: &'static str, title: &str, cx: &mut Context<Self>) -> FlowButton {
        prototype_button(SharedString::from(format!("settings.test.{name}")), "Test").a11y_label(format!("Test {title}")).disabled(self.performing || self.snapshot.busy).on_click(cx.listener(move |this, _, _, cx| this.test_model(name, cx)))
    }

    pub(super) fn models(&self, cx: &mut Context<Self>) -> Div {
        let s = self.snapshot.clone();
        let name = flow_core::onboarding::speech_model_name();
        let mut controls = h_flex().gap(px(8.));
        if s.model_installed {
            let loaded = is_loaded(&s);
            controls = controls.child(Self::action("settings.speechLoad", if loaded { "Unload" } else { "Load" }, if loaded { "unload" } else { "load" }, !self.controls_available(), cx)).child(self.test_button("speech", name, cx));
        } else if !s.installing {
            controls = controls
                .child(prototype_button("settings.speechDownload", "Download…").on_click(cx.listener(|this, _, w, cx| this.prompt_download(w, cx))))
                .child(Self::action("settings.speechImport", "Import…", "importModel", false, cx));
        }
        let speech_state = s.model_install_error.as_deref().filter(|_| !s.model_installed && !s.installing).unwrap_or(s.model_readiness());
        let speech_detail = self.detail(Some("Dictation"), Service::Dictation, &self.status("speech", speech_state), cx);
        let mut body = group(cx).child(row(name, speech_detail, controls, cx));
        if s.installing {
            let label = if s.verifying { "Verifying…" } else { "Downloading…" };
            body = body.child(
                v_flex()
                    .w_full()
                    .gap(px(8.))
                    .pb(px(12.))
                    .child(div().id("settings.installProgress").w_full().child(if s.total > 0 { Progress::new("settings.installProgressBar").value(s.completed as f32 / s.total as f32 * 100.).into_any_element() } else { Spinner::new().small().into_any_element() }).test_support())
                    .child(h_flex().w_full().justify_between().child(t(label).size(12.)).child(Self::action("settings.installCancel", "Cancel", "cancelInstall", false, cx))),
            );
        }
        let in_meeting = in_meeting(cx);
        let whisper_status = self.detail(Some("Meetings"), Service::FinalTranscript, &self.status("meeting", s.meeting_readiness(in_meeting)), cx);
        let mut whisper = h_flex().gap(px(8.));
        if !s.meeting_installed && !s.meeting_installing {
            whisper = whisper.child(Self::action("settings.meetingDownload", "Download", "downloadMeetingModel", false, cx)).child(Self::action("settings.meetingImport", "Import…", "importMeetingModel", false, cx));
        }
        if s.meeting_installed {
            whisper = whisper.child(self.test_button("meeting", "Whisper Turbo", cx));
        }
        let speaker_status = self.detail(None, Service::Diarization, &self.status("speaker", s.speaker_readiness(in_meeting)), cx);
        let mut speaker = h_flex().gap(px(8.));
        if !s.speaker_installed && !s.speaker_installing {
            speaker = speaker.child(Self::action("settings.speakerDownload", "Download", "downloadSpeakerModel", false, cx)).child(Self::action("settings.speakerImport", "Import…", "importSpeakerModel", false, cx));
        }
        if s.speaker_installed {
            speaker = speaker.child(self.test_button("speaker", "Speaker labels", cx));
        }
        let booster_detail = self.detail(None, Service::Dictation, s.boost_readiness(), cx);
        let served = core::routing(prefs(cx)).served(Service::Dictation);
        let keep_on = s.keep_model_ready;
        body = body
            .child(hairline(cx))
            .child(div().id("settings.meetingModel").w_full().child(row("Whisper Turbo", whisper_status, whisper, cx)))
            .child(hairline(cx))
            .child(div().id("settings.speakerModel").w_full().child(row("Speaker labels", speaker_status, speaker, cx)))
            .child(hairline(cx))
            .child(div().id("settings.boostModel").w_full().child(row(
                "Term booster",
                booster_detail,
                div().when(!s.boost_installed && !s.boost_installing, |d| d.child(Self::action("settings.boostDownload", "Download", "downloadBoostModel", false, cx))),
                cx,
            )))
            .child(hairline(cx))
            .child(row(
                "Keep Parakeet loaded",
                served.then(|| "Local dictation only".to_string()),
                switch("settings.keepModelReady", "Keep Parakeet loaded", keep_on, !self.controls_available(), cx.listener(|this, on: &bool, _, cx| {
                    let on = *on;
                    prefs_mut(cx).set("keepModelReady", on);
                    // Loads now if installed; the store write is the part that exists today.
                    if on && this.snapshot.model_installed {
                        this.run("load", cx);
                    } else {
                        this.refresh(cx);
                        cx.notify();
                    }
                })),
                cx,
            ));
        let p = prefs(cx);
        if p.string("rewriteEndpoint").as_deref() == Some(core::loopback_endpoint().as_str()) && !core::routing(p).local_rewrite_model_unneeded() {
            let idle = core::local_model_idle_unload(p).to_string();
            let games = core::bool_pref(p, "unloadLocalModelDuringGames");
            body = body
                .child(hairline(cx))
                .child(row("Unload rewrite model", None, picker("settings.localModelIdleUnload", "Unload rewrite model", 130., &idle, &[("Never", "0"), ("After 15 min", "900"), ("After 1 hour", "3600")], false, cx), cx))
                .child(hairline(cx))
                .child(row("Unload during games", None, switch("settings.unloadLocalModelDuringGames", "Unload during games", games, false, cx.listener(|this, on: &bool, _, cx| this.set_bool("unloadLocalModelDuringGames", *on, cx))), cx));
        }
        body
    }
}
