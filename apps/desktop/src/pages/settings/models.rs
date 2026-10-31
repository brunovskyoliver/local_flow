//! Settings › Models. Installing and loading are Features 025 and 026: every action goes through
//! `Services::settings_action` and surfaces its failure as Swift surfaces one.
use super::*;
use flow_core::settings::Service;

impl SettingsPage {
    fn role(&self, role: &str, service: Service, cx: &App) -> String {
        core::routing(prefs(cx)).model_place(service).map_or(role.to_string(), |place| format!("{role} · {place}"))
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
        let result = match cx.global::<Core>().services.settings_action(&format!("test.{name}")) {
            Ok(()) => format!("Working · {} ms", started.elapsed().as_millis()),
            Err(_) => core::describe(&Failure::Other("flow_platform.Unavailable".into(), 0)),
        };
        self.testing = None;
        self.test_results.insert(name, result);
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
        let name = core::speech_name(s.speech_model);
        let mut controls = h_flex().gap(px(8.));
        if s.model_installed {
            let loaded = is_loaded(&s);
            controls = controls.child(Self::action("settings.speechLoad", if loaded { "Unload" } else { "Load" }, if loaded { "unload" } else { "load" }, !self.controls_available(), cx)).child(self.test_button("speech", name, cx));
        } else if !s.installing {
            controls = controls
                .child(prototype_button("settings.speechDownload", "Download…").on_click(cx.listener(|this, _, w, cx| this.prompt_download(false, w, cx))))
                .child(Self::action("settings.speechImport", "Import…", "importModel", false, cx));
        }
        let speech_detail = format!("{} · {}", self.role("Dictation", Service::Dictation, cx), self.status("speech", s.model_readiness()));
        let mut body = group(cx).child(row(name, Some(speech_detail), controls, cx));
        if s.installing {
            let label = if s.verifying { "Verifying…" } else { "Downloading…" };
            body = body.child(
                v_flex()
                    .w_full()
                    .gap(px(10.))
                    .pb(px(19.))
                    .child(div().id("settings.installProgress").w_full().child(if s.total > 0 { Progress::new("settings.installProgressBar").value(s.completed as f32 / s.total as f32 * 100.).into_any_element() } else { Spinner::new().small().into_any_element() }).test_support())
                    .child(h_flex().w_full().justify_between().child(t(label).size(12.)).child(Self::action("settings.installCancel", "Cancel", "cancelInstall", false, cx))),
            );
        }
        if let Some(a) = s.alternate.clone() {
            let detail = format!("{} · CC BY 4.0 · {}", self.role(a.role(), Service::Dictation, cx), a.readiness());
            let control = if a.installing {
                Self::action("settings.alternateCancel", "Cancel", "cancelAlternateSpeechModel", false, cx)
            } else if a.installed {
                let choice = a.choice;
                prototype_button("settings.alternateUse", "Use for dictation").a11y_label(format!("Use {} for dictation", a.name())).disabled(!self.controls_available()).on_click(cx.listener(move |this, _, _, cx| {
                    // Selecting goes through the model lifecycle so one model stays loaded.
                    this.run(&format!("useSpeechModel.{choice}"), cx);
                }))
            } else {
                prototype_button("settings.alternateDownload", "Download…").disabled(s.installing).on_click(cx.listener(|this, _, w, cx| this.prompt_download(true, w, cx)))
            };
            body = body.child(hairline(cx)).child(
                v_flex()
                    .id("settings.alternateSpeechModel")
                    .w_full()
                    .child(row(a.name(), Some(detail), control, cx))
                    .when(a.installing && a.total > 0, |d| d.child(div().pb(px(19.)).child(Progress::new("settings.alternateProgress").value(a.completed as f32 / a.total as f32 * 100.))))
                    .test_support(),
            );
        }
        let whisper_status = format!("{} · {}", self.role("Meeting transcripts", Service::FinalTranscript, cx), self.status("meeting", s.meeting_readiness()));
        let mut whisper = h_flex().gap(px(8.));
        if !s.meeting_installed && !s.meeting_installing {
            whisper = whisper.child(Self::action("settings.meetingDownload", "Download", "downloadMeetingModel", false, cx)).child(Self::action("settings.meetingImport", "Import…", "importMeetingModel", false, cx));
        }
        if s.meeting_installed {
            whisper = whisper.child(self.test_button("meeting", "Whisper Turbo", cx));
        }
        let speaker_status = format!("{} · {}", self.role("Who said what", Service::Diarization, cx), self.status("speaker", s.speaker_readiness()));
        let mut speaker = h_flex().gap(px(8.));
        if !s.speaker_installed && !s.speaker_installing {
            speaker = speaker.child(Self::action("settings.speakerDownload", "Download", "downloadSpeakerModel", false, cx)).child(Self::action("settings.speakerImport", "Import…", "importSpeakerModel", false, cx));
        }
        if s.speaker_installed {
            speaker = speaker.child(self.test_button("speaker", "Speaker labels", cx));
        }
        let booster_detail = format!("{} · {}", self.role("Dictionary terms in dictation", Service::Dictation, cx), s.boost_readiness());
        let served = core::routing(prefs(cx)).served(Service::Dictation);
        let keep_on = s.keep_model_ready;
        body = body
            .child(hairline(cx))
            .child(div().id("settings.meetingModel").w_full().child(row("Whisper Turbo", Some(whisper_status), whisper, cx)))
            .child(hairline(cx))
            .child(div().id("settings.speakerModel").w_full().child(row("Speaker labels", Some(speaker_status), speaker, cx)))
            .child(hairline(cx))
            .child(div().id("settings.boostModel").w_full().child(row(
                "Term booster",
                Some(booster_detail),
                div().when(!s.boost_installed && !s.boost_installing, |d| d.child(Self::action("settings.boostDownload", "Download", "downloadBoostModel", false, cx))),
                cx,
            )))
            .child(hairline(cx))
            .child(row(
                "Keep Parakeet loaded",
                served.then(|| "Applies when dictating on this Mac".to_string()),
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
