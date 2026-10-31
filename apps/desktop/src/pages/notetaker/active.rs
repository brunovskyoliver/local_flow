//! `ActiveMeetingView`: the Today card when a recording needs attention or was refused. Live status
//! comes from the Mac coordinator, so in this client only a scenario can supply one.
use super::*;

#[derive(Clone, Debug)]
pub(crate) struct LiveStatus {
    pub id: String,
    pub state: String,
    pub elapsed_ms: i64,
    pub pause_reason: Option<&'static str>,
    pub microphone: String,
    pub system: String,
    pub dropped_frames: i64,
    pub storage_warning: Option<String>,
    pub notice: Option<String>,
    pub transcription_requested: bool,
    /// (text, analysis tracks) of provisional rows.
    pub segments: Vec<(String, String)>,
}
impl LiveStatus {
    pub fn scenario(name: &str) -> Self {
        let state = match name {
            "paused" | "live-paused" => "paused",
            "finalizing" => "finalizing",
            "preparing" => "preparing",
            "interrupted-card" | "notice-card" => "interrupted",
            "failed-card" => "failed",
            _ => "recording",
        };
        let segments = if name == "live" {
            vec![("Let us start with the hinge samples.".to_string(), "mic".to_string()), ("They came back on Tuesday.".to_string(), "system".to_string()), ("Two of them are too stiff.".to_string(), "system".to_string())]
        } else {
            vec![]
        };
        LiveStatus {
            id: SEED_UNTITLED.into(),
            state: state.into(),
            elapsed_ms: 83_000,
            pause_reason: (state == "paused").then_some("user"),
            microphone: if state == "failed" { "failed: device lost".into() } else if state == "interrupted" { "finalized".into() } else { "capturing".into() },
            system: if state == "failed" { "not started".into() } else if state == "interrupted" { "finalized".into() } else { "capturing".into() },
            dropped_frames: i64::from(state == "interrupted"),
            storage_warning: (name == "notice-card").then(|| "Less than 2 GB free".to_string()),
            notice: (name == "notice-card").then(|| "Recorded audio was recovered where possible.".to_string()),
            transcription_requested: name != "live-off",
            segments,
        }
    }
}

impl NotetakerPage {
    pub(crate) fn active_card(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        // `titleField.onAppear`: the draft starts from the stored title, once per meeting.
        let current = self.status.as_ref().filter(|s| !is_terminal(&s.state)).map(|s| s.id.clone());
        if current != self.title_seeded {
            let stored = current.as_ref().and_then(|id| db_of(cx).and_then(|db| meeting(db, id).ok().flatten())).and_then(|m| m.title).unwrap_or_default();
            self.active_title.update(cx, |input, cx| input.set_value(stored, window, cx));
            self.title_seeded = current;
        }
        let dismiss = |cx: &mut Context<Self>| -> Click {
            Box::new(cx.listener(|this: &mut Self, _: &ClickEvent, _, cx| {
                this.refusal = None;
                this.status = None;
                cx.notify();
            }))
        };
        let mut card = v_flex().id("meeting.card").test_support().w_full().gap(px(12.)).p(px(16.)).bg(p.tint).rounded(px(12.));
        if let Some(s) = self.status.clone() {
            let dot = dot_color(&s.state, cx);
            card = card.child(
                h_flex()
                    .w_full()
                    .gap(px(8.))
                    .child(div().id("meeting.dot").test_support().size(px(10.)).rounded_full().bg(dot))
                    .child(t(state_badge(&s.state)).font(15., 600.).id("meeting.state"))
                    .when_some(s.pause_reason.filter(|_| s.state == "paused"), |d, r| d.child(t(if r == "sleep" { "(sleep)" } else { "(user)" }).color(p.muted)))
                    .child(div().flex_1())
                    .child(t(duration_text(s.elapsed_ms)).font(22., 500.).mono_digits().id("meeting.elapsed")),
            );
            let banner = match s.state.as_str() {
                "interrupted" => Some("Recording stopped"),
                "failed" => Some("The meeting could not start"),
                _ => None,
            };
            if let Some(b) = banner {
                card = card.child(h_flex().id("meeting.banner").gap(px(6.)).child(icon("exclamationmark.triangle.fill", 13., red(cx))).child(t(b).font(13., 600.).color(red(cx))));
            }
            if let Some(w) = s.storage_warning.clone() {
                card = card.child(sf_label("externaldrive.badge.exclamationmark", w, 13., orange(cx)));
            }
            card = card.child(h_flex().gap(px(14.)).child(track_indicator("microphone", "Microphone", &s.microphone, cx)).child(track_indicator("system", "System audio", &s.system, cx)));
            if s.dropped_frames > 0 {
                card = card.child(div().id("meeting.captureLoss").test_support().child(sf_label("exclamationmark.triangle.fill", "Some audio was lost during recording. The transcript may be incomplete.", 12., orange(cx))));
            }
            if let Some(n) = s.notice.clone() {
                let permission = self.refusal.as_ref().is_some_and(|r| r.contains("System Settings"));
                card = card.child(h_flex().gap(px(8.)).child(t(n).size(13.).color(p.muted).id("meeting.notice")).when(permission, |d| {
                    d.child(settings_button(self.refusal.as_deref().unwrap_or_default()))
                }));
            }
            if let Some(line) = self.live_section.clone() {
                card = card.child(section_view(&line, &s, &self.section_scroll, cx));
            }
            card = card.child(match s.state.as_str() {
                "recording" => h_flex().gap(px(8.)).child(native_button("meeting.pause", "Pause").on_click(cx.listener(|this, _, _, cx| this.live_action("Pause", cx)))).child(prototype_button("meeting.stopCard", "Stop Meeting").fill(red(cx)).text_color(gpui::white()).on_click(cx.listener(|this, _, _, cx| this.live_action("Stop", cx)))),
                "paused" => h_flex().gap(px(8.)).child(native_button("meeting.resume", "Resume").on_click(cx.listener(|this, _, _, cx| this.live_action("Resume", cx)))).child(prototype_button("meeting.stopCard", "Stop Meeting").fill(red(cx)).text_color(gpui::white()).on_click(cx.listener(|this, _, _, cx| this.live_action("Stop", cx)))),
                "finalizing" | "preparing" | "created" => h_flex().gap(px(8.)).child(Spinner::new().small()).child(t(if s.state == "finalizing" { "Finalizing…" } else { "Starting…" }).color(p.muted)),
                _ => h_flex().child(native_button("meeting.dismiss", "Dismiss").on_click(dismiss(cx))),
            });
            if !is_terminal(&s.state) {
                let (text, color) = match self.editor.as_ref() {
                    Some(e) if e.state == SaveState::NotSaved => ("Not saved", red(cx)),
                    Some(e) if e.state == SaveState::Saving => ("Saving…", p.muted),
                    Some(e) if e.is_dirty => ("Unsaved", p.muted),
                    Some(e) if e.state == SaveState::Saved => ("Saved", p.muted),
                    _ => ("", p.muted),
                };
                let notice = self.editor.as_ref().and_then(|e| e.notice.clone());
                card = card
                    .child(h_flex().w_full().gap(px(8.)).child(div().id("meeting.title.frame").test_support().flex_1().max_w(px(360.)).child(Input::new(&self.active_title).aria_label("Title (optional)").accessibility_id("meeting.title.active"))).when_some(self.active_title_notice.clone(), |d, n| d.child(t(n).size(12.).color(red(cx)).id("meeting.title.notice"))))
                    .child(
                        v_flex()
                            .w_full()
                            .gap(px(6.))
                            .child(h_flex().w_full().child(t("Notes").font(13., 600.)).child(div().flex_1()).child(t(text).size(12.).color(color).id("meeting.notes.state")))
                            .child(div().id("meeting.notes.frame").test_support().w_full().h(px(90.)).bg(p.surface).rounded(px(8.)).child(Textarea::new(&self.thoughts).appearance(false).bordered(false).h_full().text_size(px(13.)).aria_label("Notes").accessibility_id("meeting.notes")))
                            .when_some(notice, |d, n| d.child(t(n).size(12.).color(red(cx)))),
                    );
            }
        } else if let Some(refusal) = self.refusal.clone() {
            let permission = refusal.contains("System Settings");
            if let Some(w) = self.start_warning {
                card = card.child(sf_label("externaldrive.badge.exclamationmark", w, 13., orange(cx)));
            }
            card = card.child(
                h_flex()
                    .w_full()
                    .gap(px(8.))
                    .child(div().id("meeting.notice").child(sf_label("exclamationmark.triangle", refusal.clone(), 13., p.ink)))
                    .when(permission, |d| {
                        d.child(settings_button(&refusal))
                    })
                    .child(div().flex_1())
                    .child(native_button("meeting.dismiss", "Dismiss").on_click(dismiss(cx))),
            );
        }
        card
    }
    /// `saveTitle`: Enter in the card's title field.
    pub(crate) fn save_active_title(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.status.as_ref().map(|s| s.id.clone()) else { return };
        let Some(db) = db_of(cx) else { return };
        let draft = self.active_title.read(cx).value().to_string();
        self.active_title_notice = if draft.len() > TITLE_MAX_BYTES {
            Some("Titles are limited to 256 bytes.".into())
        } else {
            let saved = meeting(db, &id).ok().flatten().and_then(|m| set_title(db, &id, &draft, m.revision, now_ms()).ok());
            if saved.is_some() {
                self.lib.refresh(db, Some(&id));
                None
            } else {
                Some("The title could not be saved.".into())
            }
        };
        cx.notify();
    }
    /// Pause, Resume and Stop go to the Mac coordinator.
    pub(crate) fn live_action(&mut self, what: &'static str, cx: &mut Context<Self>) {
        if let Err(message) = Self::worker(what, cx) {
            self.transcript_notice = Some(message.clone());
            if let Some(s) = &mut self.status {
                s.notice = Some(message);
            }
        }
        cx.notify();
    }
}

/// `refusalPermission`: which privacy pane a refusal's message points at.
pub(crate) fn refusal_permission(refusal: &str) -> flow_platform::Permission {
    if refusal.contains("Screen & System Audio") { flow_platform::Permission::SystemAudio } else { flow_platform::Permission::Microphone }
}
fn settings_button(refusal: &str) -> FlowButton {
    let kind = refusal_permission(refusal);
    native_button("meeting.openSettings", "Open System Settings").on_click(move |_, _, cx| {
        let _ = cx.global::<Core>().services.open_permission_settings(kind);
    })
}

pub(crate) fn dot_color(state: &str, cx: &App) -> Hsla {
    match state {
        "recording" => red(cx),
        "paused" => orange(cx),
        _ => pal(cx).muted,
    }
}

/// `TranscriptSectionView`: (status line, in-flight mini progress).
/// `TranscriptSectionView.timestamp`: mm:ss, or h:mm:ss from an hour on.
pub(crate) fn section_timestamp(ms: i64) -> String {
    let s = (ms / 1000).max(0);
    if s >= 3600 { format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60) } else { format!("{:02}:{:02}", s / 60, s % 60) }
}

fn section_view(line: &str, s: &LiveStatus, scroll: &ScrollHandle, cx: &App) -> impl IntoElement {
    let p = pal(cx);
    // Follows while within 190 of the bottom, as `TranscriptSectionView` does.
    let (y, max) = (-scroll.offset().y.as_f32(), scroll.max_offset().y.as_f32());
    if max - y <= 190. {
        scroll.scroll_to_bottom();
    }
    let mut list = v_flex().id("meeting.section.list").test_support().w_full().h(px(180.)).overflow_y_scroll().track_scroll(scroll).gap(px(10.)).p(px(8.)).bg(p.surface).rounded(px(8.));
    for (i, (text, _)) in s.segments.iter().enumerate() {
        // ponytail: live rows carry no start time until the worker sends them, so scenarios space them 4 s.
        list = list.child(h_flex().id(sid(format!("meeting.section.row.{i}"))).test_support().items_start().gap(px(10.)).child(t(section_timestamp(i as i64 * 4000)).size(13.).mono_digits().color(p.muted)).child(v_flex().flex_1().gap(px(3.)).child(t(text.clone()).size(13.).italic()).child(h_flex().gap(px(3.)).child(t("provisional").size(11.).italic().color(p.muted)).child(icon("circle.fill", 3., p.muted)))));
    }
    v_flex().w_full().gap(px(8.)).child(h_flex().gap(px(8.)).child(t("Transcript").font(13., 600.)).child(t(line.to_string()).size(12.).color(p.muted).id("meeting.section.status"))).child(list)
}

fn track_indicator(kind: &str, name: &'static str, text: &str, cx: &App) -> impl IntoElement {
    let p = pal(cx);
    let color = if text == "capturing" {
        green(cx)
    } else if text.starts_with("failed") {
        red(cx)
    } else if text == "not started" {
        sys(cx, 0x8E8E93, 0x8E8E93) // `.gray`
    } else {
        p.muted
    };
    h_flex().id(sid(format!("meeting.track.{kind}"))).test_support().gap(px(6.)).child(icon(if kind == "microphone" { "mic.fill" } else { "speaker.wave.2.fill" }, 12., color)).child(t(name).size(12.)).child(t(text.to_string()).size(12.).color(p.muted))
}
