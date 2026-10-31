//! The step bodies, in `OnboardingView`'s order.
use super::OnboardingPage;
use super::parts::*;
use super::parts::t;
use flow_core::onboarding::*;
use flow_platform::Permission;
use flow_ui::gpui::base::TestSupportExt;
use flow_ui::prelude::*;

type Body = Vec<AnyElement>;

fn any(e: impl IntoElement) -> AnyElement {
    e.into_any_element()
}

impl OnboardingPage {
    pub(super) fn content(&mut self, cx: &mut Context<Self>) -> Body {
        let mut body = match self.setup.step {
            Step::Introduction => self.introduction(cx),
            Step::Purpose => self.purpose_choice(cx),
            Step::Ai => self.ai_choice(cx),
            Step::AiDetails if self.setup.ai_mode == AiMode::Remote => self.remote_server(cx),
            Step::AiDetails => self.model_picker(cx),
            Step::Downloads => self.downloads(cx),
            Step::Permissions => self.permissions(cx),
            Step::Personalize => self.personalize(cx),
            Step::Test => self.test_step(cx),
            Step::Complete => {
                let copy = if self.meeting_only() { "Start a meeting in Notetaker." } else { "Hold your shortcut in any app to dictate." };
                vec![any(headline("You're ", "all set", ".")), any(t(copy).color(pal(cx).muted))]
            }
        };
        if self.setup.ai_mode == AiMode::Local && self.ai_phase != AiPhase::Ready && matches!(self.setup.step, Step::Permissions | Step::Personalize | Step::Test) {
            let retry = self.click(cx, |this, cx| this.start_local_ai(cx));
            let row = download_row("sparkles", "On-device AI", self.selected_model().name.to_string(), ai_state(&self.ai_phase), Some(retry), cx);
            body.push(any(setup_card(cx).child(row)));
        }
        body
    }

    fn introduction(&mut self, cx: &mut Context<Self>) -> Body {
        let a = pal(cx).accent;
        let word = self.word(cx);
        let mac = |s: &str| s.replace("Mac", word);
        vec![
            any(h_flex().justify_center().size(px(68.)).bg(a.opacity(0.12)).rounded(px(18.)).child(icon("waveform", 33., a))),
            any(headline("Your voice, written ", &mac("on this Mac"), ".")),
            any(lede(mac("Hold a key in any app, talk, and let go, or record a meeting and get notes. LocalFlow turns speech into clean text right here on your Mac."), cx)),
            any(setup_card(cx)
                .child(feature_row("lock.shield", "Private by design", mac("Speech recognition runs on this Mac. Audio leaves it only if you connect a LocalFlow server you run."), cx))
                .child(feature_row("keyboard", "Works in every app", "Hold Right Control, speak, release. The text lands where your cursor is.".into(), cx))
                .child(feature_row("person.2.wave.2", "Meeting notes", "Records your calls, then writes a transcript with speaker labels and notes.".into(), cx))
                .child(feature_row("sparkles", "Tidies up as you go", "Optional AI fixes punctuation, drops the ums and ahs, and writes meeting notes.".into(), cx))),
        ]
    }

    fn purpose_card(&mut self, purpose: Purpose, symbol: &str, title: &str, badge_text: Option<&'static str>, detail: &str, cx: &mut Context<Self>) -> FlowButton {
        let choose = self.click(cx, move |this, cx| {
            this.setup.purpose = purpose;
            cx.notify();
        });
        let label = choice_label(symbol, title, badge_text, detail.to_string(), cx);
        let name = [Some(title), badge_text, Some(detail)].into_iter().flatten().collect::<Vec<_>>().join(", ");
        selectable_card(SharedString::from(format!("onboarding.purpose.{}", purpose.raw())), name, self.setup.purpose == purpose, true, choose, label, cx)
    }

    fn purpose_choice(&mut self, cx: &mut Context<Self>) -> Body {
        vec![
            any(headline("What is LocalFlow ", "for", "?")),
            any(lede("Setup only asks for what your choice needs. You can add dictation later in Settings.".into(), cx)),
            any(v_flex()
                .w_full()
                .gap(px(10.))
                .child(self.purpose_card(Purpose::Both, "square.stack", "Both", Some("Recommended"), "Dictation in every app, and notes from your meetings.", cx))
                .child(self.purpose_card(Purpose::Dictation, "keyboard", "Dictation", None, "Hold a key in any app and talk. Meeting notes stay optional.", cx))
                .child(self.purpose_card(Purpose::Meetings, "person.2.wave.2", "Meeting notes", None, "Record calls and get transcripts and notes. No shortcut or keyboard permissions.", cx))),
        ]
    }

    fn ai_choice(&mut self, cx: &mut Context<Self>) -> Body {
        let word = self.word(cx);
        let mac = |s: &str| s.replace("Mac", word);
        let meeting = self.meeting_only();
        let mut body = if meeting {
            vec![
                any(eyebrow("Meeting notes", cx)),
                any(headline("Where should ", "meetings", " run?")),
                any(lede(mac("Recordings are always saved on this Mac first. Choose what turns them into notes."), cx)),
            ]
        } else {
            vec![
                any(eyebrow("Optional", cx)),
                any(headline("Add ", "AI", " rewriting.")),
                any(lede("A language model can polish each dictation and turn meetings into notes. Choose where it runs.".into(), cx)),
            ]
        };
        let local = self.click(cx, |this, cx| {
            this.setup.ai_mode = AiMode::Local;
            cx.notify();
        });
        let remote = self.click(cx, |this, cx| {
            this.setup.ai_mode = AiMode::Remote;
            cx.notify();
        });
        let on_this = mac("On this Mac");
        let (local_title, remote_title) = if meeting { ("This computer", "Your server") } else { (on_this.as_str(), "On your server") };
        let local_detail = mac(if meeting {
            "Nothing leaves this Mac. LocalFlow downloads speech, Whisper and speaker models, about 2.3 GB, then offers a language model for summaries."
        } else {
            "Private and offline. LocalFlow installs MTPLX, an open-source engine for Apple Silicon, and a model you pick."
        });
        let remote_detail = mac(if meeting {
            "Meeting audio, transcripts and summary text go to a LocalFlow server you run. Nothing downloads to this Mac. Its administrator approves this Mac once."
        } else {
            "Use a LocalFlow server on another computer you run, for bigger models. Its administrator approves this Mac once."
        });
        let mode = self.setup.ai_mode;
        body.push(any(v_flex()
            .w_full()
            .gap(px(10.))
            .child(selectable_card("onboarding.ai.local", format!("{local_title}, Recommended, {local_detail}"), mode == AiMode::Local, true, local, choice_label("laptopcomputer", local_title, Some("Recommended"), local_detail.clone(), cx), cx))
            .child(selectable_card("onboarding.ai.remote", format!("{remote_title}, {remote_detail}"), mode == AiMode::Remote, true, remote, choice_label("server.rack", remote_title, None, remote_detail.clone(), cx), cx))));
        if mode == AiMode::Remote {
            body.push(any(note("info.circle", mac(if meeting {
                "Once the server approves this Mac, meeting recordings and their text go to it. Until then, and whenever it can't be reached, recordings wait on this Mac."
            } else {
                "Once the server approves this Mac, dictation audio, meeting recordings and their text go to it. Until then, and whenever it can't be reached, dictation is transcribed on this Mac."
            }), cx)));
        } else {
            body.push(any(setup_card(cx)
                .child(feature_row("cpu", "MTPLX engine", "About 550 MB, kept in LocalFlow's folder. No Homebrew or Python setup.".into(), cx))
                .child(feature_row("square.stack.3d.up", "A language model", format!("You choose one next. The recommended model is {}.", bytes(CATALOG[0].download_bytes)), cx))
                .child(feature_row("bolt.horizontal", "Two background services", mac("They start at login and only accept connections from this Mac."), cx))));
            body.push(any(note("checkmark.shield", mac("Your text never leaves this Mac. Every download is pinned to an exact version and checksum."), cx)));
        }
        if meeting {
            body.push(any(div().id("onboarding.meetingSkip").w_full().child(note("text.badge.xmark", mac("Skip for now to keep meetings on this Mac without a language model. You still get transcripts with speaker labels, but summaries won't be available."), cx)).test_support()));
        }
        body
    }

    fn model_picker(&mut self, cx: &mut Context<Self>) -> Body {
        let word = self.word(cx);
        let p = pal(cx);
        let mut list = v_flex().w_full().gap(px(10.));
        for (i, m) in CATALOG.iter().enumerate() {
            let available = m.fits(self.memory);
            let downloaded = self.downloaded[i];
            let choose = self.click(cx, move |this, cx| {
                this.selection = i;
                cx.notify();
            });
            let row = h_flex()
                .flex_1()
                .min_w_0()
                .items_start()
                .gap(px(14.))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(4.))
                        .child(h_flex().gap(px(8.)).child(t(m.name).font(15., 600.)).when(i == 0, |d| d.child(badge("Recommended", cx))))
                        .child(t(m.detail).size(13.).color(p.muted)),
                )
                .child(
                    v_flex()
                        .flex_none()
                        .pl(px(26.))
                        .items_end()
                        .gap(px(3.))
                        .child(t(if downloaded { "Downloaded".to_string() } else { bytes(m.download_bytes) }).font(13., 500.).mono_digits().color(if downloaded { p.accent } else { p.ink }))
                        .child(if available { t(format!("Uses about {} GB", m.peak())).size(12.).color(p.muted) } else { t(format!("Needs {} GB memory", m.minimum_gb)).size(12.).color(p.warning) }),
                );
            list = list.child(selectable_card(SharedString::from(format!("onboarding.model.{i}")), m.name.to_string(), self.selection == i, available, choose, row, cx));
        }
        vec![
            any(headline("Choose a ", "model", ".")),
            any(lede(format!("This {word} has {} of memory. Larger models write better meeting notes but take longer on each dictation.", memory(self.memory)), cx)),
            any(list),
        ]
    }

    fn downloads(&mut self, cx: &mut Context<Self>) -> Body {
        let word = self.word(cx);
        let meeting = self.meeting_only();
        let remote = self.setup.ai_mode == AiMode::Remote;
        let snap = self.snap.clone();
        let speech_retry = self.click(cx, |this, cx| this.start_speech(cx));
        let speech = download_row(
            "waveform",
            "Speech recognition",
            format!("{} · {}{}", snap.speech_model, bytes(snap.download_bytes.unwrap_or(SPEECH_FALLBACK_BYTES)), if remote { " · used when the server can't be reached" } else { "" }),
            speech_state(&snap, self.error.as_deref()),
            Some(speech_retry),
            cx,
        );
        let mut first = setup_card(cx).child(speech);
        match self.setup.ai_mode {
            AiMode::Local => {
                let m = self.selected_model();
                let detail = if self.downloaded[self.selection] { format!("{} · already on this {word}", m.name) } else { format!("{} · {}", m.name, bytes(m.download_bytes)) };
                let retry = self.click(cx, |this, cx| this.start_local_ai(cx));
                first = first.child(download_row("sparkles", "On-device AI", detail, ai_state(&self.ai_phase), Some(retry), cx));
            }
            AiMode::Remote => {
                let prefs = &self.core(cx).prefs;
                let enrolled_now = enrolled(prefs);
                let detail = if enrolled_now {
                    server_host(&prefs.string("remote.serverURL").unwrap_or_default())
                } else {
                    rewrite_origin(&prefs.string("rewriteEndpoint").unwrap_or_default()).map(|o| origin_host(&o)).unwrap_or_else(|| "Remote".into())
                };
                let state = if enrolled_now && remote_state(prefs) != "approved" { RowState::Waiting("Waiting for approval".into()) } else { RowState::Done };
                first = first.child(download_row("server.rack", "Your server", detail, state, None, cx));
            }
            AiMode::Off => {}
        }
        let second = if self.setup.meetings_requested || snap.meeting_pack_installed() {
            let retry = self.click(cx, |this, cx| {
                this.setup.retry_meeting_models();
                this.after(cx);
            });
            setup_card(cx).child(download_row("person.2.wave.2", "Meeting transcription", format!("Whisper Turbo and speaker labels · {}", bytes(MEETING_BYTES)), meeting_state(&snap), Some(retry), cx))
        } else {
            let press = self.click(cx, |this, cx| {
                this.setup.download_meeting_models();
                this.after(cx);
            });
            setup_card(cx).child(
                h_flex()
                    .w_full()
                    .items_start()
                    .gap(px(14.))
                    .child(row_icon("person.2.wave.2", cx))
                    .child(title_detail("Meeting transcription", format!("Whisper Turbo and speaker labels, {}. Only needed for meeting notes.", bytes(MEETING_BYTES)), cx))
                    .child(v_flex().flex_none().pl(px(26.)).items_end().gap(px(4.)).child(prototype_button("onboarding.meetingDownload", "Download").on_click(press)).child(t("or skip for now").size(12.).color(pal(cx).muted))),
            )
        };
        vec![
            any(headline("Getting ", "everything", " ready.")),
            any(lede(if meeting { format!("Meeting notes on this {word} need these models, so setup waits for them.") } else { "Downloads keep going in the background, so you can continue while they finish.".into() }, cx)),
            any(first),
            any(second),
        ]
    }

    fn access_row(&mut self, symbol: &str, title: &'static str, detail: &str, state: Perm, permission: Permission, cx: &mut Context<Self>) -> Div {
        let a = pal(cx).accent;
        let control = if state == Perm::Granted {
            any(h_flex().gap(px(8.)).child(icon("checkmark.circle.fill", 13., a)).child(t("Allowed").font(12., 500.).color(a)))
        } else {
            let press = self.click(cx, move |this, cx| this.allow(permission, cx));
            any(prototype_button(SharedString::from(format!("onboarding.allow.{title}")), "Allow…").a11y_label(format!("Allow {title}")).disabled(self.performing).on_click(press))
        };
        // Swift's `HStack(spacing: 14)` puts 14 on both sides of `Spacer(minLength: 12)`: 40 from text to control.
        h_flex().w_full().items_start().gap(px(14.)).child(row_icon(symbol, cx)).child(title_detail(title, detail.to_string(), cx)).child(div().flex_none().pl(px(26.)).child(control))
    }

    fn system_audio_row(&mut self, cx: &mut Context<Self>) -> Div {
        self.access_row(
            "speaker.wave.2",
            "System audio",
            "Records the other people on a call. macOS calls this Screen Recording and may ask you to reopen LocalFlow. Without it, meetings record your microphone only.",
            self.snap.system_audio,
            Permission::SystemAudio,
            cx,
        )
    }

    fn group_row(&mut self, name: &'static str, permission: Permission, cx: &mut Context<Self>) -> Div {
        let press = self.click(cx, move |this, cx| this.allow(permission, cx));
        let button = prototype_button(SharedString::from(format!("onboarding.allow.{name}")), "Allow…").min_width(99.).a11y_label(format!("Allow {name}")).disabled(self.performing).on_click(press);
        settings_row(name, None, button, cx)
    }

    fn permissions(&mut self, cx: &mut Context<Self>) -> Body {
        let mut body = vec![any(headline("Allow ", "access", "."))];
        if self.meeting_only() {
            body.push(any(lede("LocalFlow records your microphone and the other people on a call.".into(), cx)));
            let mic = self.access_row("mic", "Microphone", "Needed to record a meeting.", self.snap.microphone, Permission::Microphone, cx);
            let audio = self.system_audio_row(cx);
            body.push(any(setup_card(cx).child(mic).child(audio)));
            if self.snap.microphone == Perm::Granted && self.snap.system_audio == Perm::Granted {
                body.push(any(allowed_label(cx)));
            }
            return body;
        }
        body.push(any(lede("Microphone and Input Monitoring let LocalFlow hear you while you hold the shortcut. Accessibility lets it type the text for you and record a custom shortcut; without it, you paste the text yourself.".into(), cx)));
        if self.snap.has_missing_permissions() {
            // Settings' `permissionsSection`, whose title pads 29 above and 13 below.
            let (mic, input, access) = (self.snap.microphone != Perm::Granted, self.snap.input_monitoring != Perm::Granted, self.snap.accessibility != Perm::Granted);
            let mut group = v_flex().w_full().px(px(19.)).bg(pal(cx).canvas).rounded(px(12.));
            if mic {
                group = group.child(self.group_row("Microphone", Permission::Microphone, cx));
            }
            if input {
                if mic {
                    group = group.child(hairline(cx));
                }
                group = group.child(self.group_row("Input Monitoring", Permission::InputMonitoring, cx));
            }
            if access {
                if mic || input {
                    group = group.child(hairline(cx));
                }
                group = group.child(self.group_row("Accessibility", Permission::Accessibility, cx));
            }
            body.push(any(v_flex().w_full().child(div().pt(px(29.)).pb(px(13.)).child(t("Permissions needed").font(14., 500.))).child(group)));
        } else {
            body.push(any(allowed_label(cx)));
        }
        if self.setup.purpose == Purpose::Both {
            let audio = self.system_audio_row(cx);
            body.push(any(setup_card(cx).child(audio)));
        }
        body
    }

    fn set_appearance_click(&mut self, value: &'static str, cx: &mut Context<Self>) -> Click {
        self.click(cx, move |this, cx| {
            cx.global_mut::<crate::core::Core>().prefs.set("appearance", value);
            super::apply_native_appearance(cx);
            crate::shell::apply_appearance(cx);
            this.after(cx);
        })
    }

    fn personalize(&mut self, cx: &mut Context<Self>) -> Body {
        let meeting = self.meeting_only();
        let current = self.core(cx).prefs.string("appearance").unwrap_or_else(|| "system".into());
        let (system, light, dark) = (self.set_appearance_click("system", cx), self.set_appearance_click("light", cx), self.set_appearance_click("dark", cx));
        let mut body = vec![
            any(headline("Make it ", "yours", ".")),
            any(lede(if meeting { "Pick a look. You can change it later in Settings." } else { "Pick a look and the key you hold to dictate. Both can change later in Settings." }.into(), cx)),
            any(field_label("Appearance", cx)),
            any(h_flex()
                .w_full()
                .gap(px(12.))
                .items_start()
                .child(theme_card("onboarding.theme.system", "Match system", "Match system appearance", Mini::System, current == "system", system, cx))
                .child(theme_card("onboarding.theme.light", "Light", "Light", Mini::Light, current == "light", light, cx))
                .child(theme_card("onboarding.theme.dark", "Dark", "Dark", Mini::Dark, current == "dark", dark, cx))),
        ];
        if !meeting {
            body.push(any(field_label("Dictation shortcut", cx)));
            body.push(any(self.shortcut_choice(cx)));
        }
        body
    }

    fn shortcut_choice(&mut self, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let record = self.click(cx, |this, cx| this.toggle_recording(cx));
        let mut chips = h_flex().gap(px(8.));
        for (i, (preset, name)) in [(Shortcut::right_control(), "Right Control"), (Shortcut::right_option(), "Right Option"), (Shortcut::fn_globe(), "fn / Globe")].into_iter().enumerate() {
            let selected = self.snap.shortcut == preset;
            let value = preset.clone();
            let press = self.click(cx, move |this, cx| this.configure_shortcut(value.clone(), cx));
            let fg = if selected { p.accent } else { p.ink };
            chips = chips.child(
                plain_button(SharedString::from(format!("onboarding.preset.{i}")), name)
                    .toggled(selected)
                    .disabled(self.performing || self.recording)
                    .on_click(press)
                    .content(div().px(px(11.)).py(px(6.)).rounded_full().bg(if selected { p.accent.opacity(0.12) } else { p.tint }).child(t(name).font(12., 500.).color(fg).a11y_hidden())),
            );
        }
        setup_card(cx)
            .child(
                h_flex()
                    .w_full()
                    .gap(px(16.))
                    .child(div().flex_none().px(px(16.)).py(px(10.)).bg(p.canvas).rounded(px(10.)).border_1().border_color(p.rule).child(t(self.snap.shortcut.title()).font(17., 600.)))
                    .child(div().flex_1().min_w_0().child(t("Hold to talk, let go to insert.").size(13.).color(p.muted)))
                    .child(prototype_button("onboarding.recordShortcut", if self.recording { "Press your keys…" } else { "Record shortcut" }).disabled(self.performing).on_click(record)),
            )
            .child(chips)
            .when_some(self.recording_error.clone().or_else(|| self.error.clone()), |d, e| d.child(t(e).size(12.).color(p.warning)))
    }

    fn test_step(&mut self, cx: &mut Context<Self>) -> Body {
        let p = pal(cx);
        let s = &self.setup;
        let title = if s.preparing_test {
            "Preparing speech model…"
        } else if s.test_armed {
            "Listening for your shortcut…"
        } else {
            "Start test"
        };
        let disabled = !(self.snap.ready_for_test() && !self.performing) || s.preparing_test || s.test_armed || s.test_succeeded;
        let succeeded = s.test_succeeded;
        let error = s.test_error.clone().or_else(|| self.error.clone());
        let mut body = vec![
            any(headline("Try ", "it", ".")),
            any(lede(if succeeded { "Your first transcript is saved in Transcriptions.".to_string() } else { format!("Press the button, then hold {} and say a short sentence. Release to transcribe.", self.snap.shortcut.title()) }, cx)),
        ];
        if !succeeded {
            body.push(any(t("This test is optional. You can start dictating after setup.").size(13.).color(p.muted)));
        }
        if let Some(reason) = self.snap.test_blocked_reason() {
            body.push(any(t(reason).size(14.).color(p.warning)));
        }
        let press = self.click(cx, |this, cx| this.arm_test(cx));
        body.push(any(prototype_button("onboarding.startTest", title).disabled(disabled).on_click(press)));
        if let Some(e) = error {
            body.push(any(t(e).size(13.).color(p.warning)));
        }
        body
    }
}
