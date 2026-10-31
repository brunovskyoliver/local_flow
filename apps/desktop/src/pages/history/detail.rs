//! The Details sheet: status, transcript stages, processing evidence, context and rewrites.
use super::{HistoryPage, detail_card};
use flow_core::history::*;
use flow_ui::prelude::*;
use flow_ui::prelude::Context;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Stage {
    Normalized,
    Assembled,
    Raw,
}

const SEGMENT_OFF: f32 = 0.08;
const SEGMENT_ON: f32 = 0.21;
const SEGMENT_RULE: f32 = 0.33;

/// The default macOS `Button`: 24 high, radius 6, the fill the system gives it inside a sheet.
fn native_button(id: impl Into<ElementId>, label: &'static str, cx: &App) -> FlowButton {
    let p = pal(cx);
    // `Plain` has no padding and no fill of its own: a native button is 24 high with a tighter corner.
    FlowButton::new(id, ButtonKind::Plain, label).disabled_opacity(0.45).content(div().h(px(24.)).px(px(12.)).rounded(px(6.)).bg(p.ink.opacity(SEGMENT_ON)).flex().items_center().child(t(label).size(13.).color(p.ink).a11y_hidden()))
}

fn stage_text(text: &str) -> Txt {
    t(if text.is_empty() { "(Empty stage)".to_string() } else { text.to_string() }).size(14.).selectable().no_widow()
}

fn meta(label: String, value: String, cx: &App) -> impl IntoElement {
    v_flex().id(SharedString::from(format!("history.meta.{label}"))).test_support().gap(px(2.)).child(t(label).size(13.).color(pal(cx).muted).selectable()).child(t(value).size(13.).selectable())
}

fn lines(items: Vec<Line>, cx: &App) -> Div {
    let mut col = v_flex().gap(px(8.));
    for l in items {
        col = col.child(match l {
            Line::Meta(a, b) => meta(a, b, cx).into_any_element(),
            Line::Heading(h) => t(h).font(14., 600.).selectable().into_any_element(),
            Line::Plain(s) => t(s).size(13.).selectable().into_any_element(),
        });
    }
    col
}

impl HistoryPage {
    /// SwiftUI's `DisclosureGroup`: a chevron and title that shows `body` when open.
    fn disclosure(&self, key: &str, title: String, size: f32, body: impl FnOnce(&Self, &mut Context<Self>) -> AnyElement, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let on = self.open.contains(key);
        let k = key.to_string();
        v_flex()
            .w_full()
            .items_start()
            .child(
                FlowButton::new(SharedString::from(key.to_string()), ButtonKind::Plain, title.clone())
                    .a11y_selected(on)
                    // The native indicator: chevron centered 4 from the leading edge, title at 12.
                    .content(h_flex().py(px(3.5)).child(div().w(px(8.)).flex().justify_center().child(icon(if on { "chevron.down" } else { "chevron.right" }, 11., if p.ink.l > 0.5 { p.ink } else { p.muted }))).child(div().w(px(4.))).child(t(title).size(size).a11y_hidden()))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if !this.open.remove(&k) {
                            this.open.insert(k.clone());
                        }
                        cx.notify();
                    })),
            )
            .when(on, |d| d.child(body(self, cx)))
    }

    pub(super) fn detail_sheet(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let body: AnyElement = if self.model.detail_loading {
            div().w_full().p(px(40.)).flex().justify_center().child(Spinner::new()).into_any_element()
        } else if let Some(e) = self.model.detail_error.clone() {
            v_flex()
                .gap(px(8.))
                .child(t(e).color(pal(cx).warning))
                .child(prototype_button("history.detail.retry", "Retry").on_click(cx.listener(|this, _, _, cx| {
                    if let Some(db) = cx.global::<crate::core::Core>().db.as_ref() {
                        this.model.retry_detail(db);
                    }
                    cx.notify();
                })))
                .into_any_element()
        } else if let Some(env) = self.model.envelope.clone() {
            self.envelope_view(&env, cx).into_any_element()
        } else {
            div().into_any_element()
        };
        detail_card(cx)
            .h(px(560.))
            .p(px(24.))
            .gap(px(16.))
            .text_size(px(14.))
            .child(
                h_flex().w_full().justify_between().child(t("Details").font(20., 500.)).child(prototype_button("history.detail.close", "Done").on_click(cx.listener(|this, _, _, cx| {
                    this.model.clear_detail();
                    cx.notify();
                }))),
            )
            .child(div().id("history.detail.scroll").test_support().flex_1().min_h_0().w_full().overflow_y_scroll().track_scroll(&self.detail_scroll).child(body))
            .into_any_element()
    }

    fn envelope_view(&mut self, env: &Envelope, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = pal(cx);
        let e = &env.entry;
        // Swift's spacing 4 over 15.6 lines is 19.6 apart; `Txt` rounds a line to 16, so 3 keeps the pitch.
        let status = v_flex()
            .id("history.detail.status")
            .test_support()
            .gap(px(3.))
            .child(t(format!("Completeness: {}", e.quality_label().unwrap_or("Complete"))).size(13.).selectable())
            .child(t(format!("Recognized: {}", e.path_label(true).unwrap_or_else(|| "Local".into()))).size(13.).selectable())
            .child(t(format!("Delivery: {}", spaced(&e.delivery_state))).size(13.).selectable())
            .child(t(format!("Stopped: {}", spaced(&e.stop_reason))).size(13.).selectable())
            .child(t(e.microphone_label()).id("history.detail.microphone").size(13.).selectable());
        let mut col = v_flex().id("history.detail").w_full().gap(px(14.)).child(status);
        if let Some(d) = env.detail.clone() {
            col = col.child(self.stage_picker(cx));
            match self.stage {
                Stage::Normalized => col = col.child(stage_text(&e.text)),
                Stage::Assembled => col = col.child(stage_text(d["assembledText"].as_str().unwrap_or(""))),
                Stage::Raw => {
                    col = col.child(t("Exact received windows in order. Overlapping windows can repeat words.").size(12.).color(p.muted).selectable());
                    let windows = d["rawWindows"].as_array().cloned().unwrap_or_default();
                    if windows.is_empty() {
                        col = col.child(t("No raw windows were retained.").color(p.muted).selectable());
                    }
                    for w in windows {
                        let (seq, start, count) = (w["sequence"].as_i64().unwrap_or(0), w["sampleStart"].as_i64().unwrap_or(0), w["sampleCount"].as_i64().unwrap_or(0));
                        col = col.child(v_flex().gap(px(6.)).child(t(format!("Window {} · samples {}–{}", seq + 1, start, start + count)).size(12.).color(p.muted).selectable()).child(stage_text(w["text"].as_str().unwrap_or(""))));
                    }
                }
            }
            let (d2, hash) = (d.clone(), env.content_hash.clone());
            col = col.child(self.disclosure(
                "history.detail.processing",
                "Processing details".into(),
                14.,
                move |this, cx| {
                    let hashes = hash_lines(&d2, &hash);
                    v_flex()
                        .pt(px(10.))
                        .gap(px(8.))
                        .child(div().id("history.detail.processing.lines").test_support().child(lines(processing_lines(&d2), cx)))
                        .child(this.disclosure("history.detail.hashes", "Evidence hashes".into(), 13., move |_, cx| div().pt(px(8.)).child(lines(hashes, cx)).into_any_element(), cx))
                        .into_any_element()
                },
                cx,
            ));
        } else {
            col = col
                .child(t(LEGACY_DETAIL).id("history.detail.legacy").size(13.).color(p.muted).selectable())
                .child(t("Saved text").font(14., 600.).selectable())
                .child(stage_text(&e.text));
        }
        let context = self.context_section(env, cx);
        let rewrite = self.rewrite_section(env, cx);
        col.child(context).child(rewrite)
    }

    /// `.pickerStyle(.segmented)`, drawn: GPUI Kit has no native segmented control. Measured on the
    /// reference: label, gap 9, three equal 121 by 24 segments, radius 6, a 1 pt rule between two
    /// segments when neither is selected.
    fn stage_picker(&self, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let items = [(Stage::Normalized, "Normalized", "history.detail.stage.normalized"), (Stage::Assembled, "Assembled", "history.detail.stage.assembled"), (Stage::Raw, "Raw recognition", "history.detail.stage.raw")];
        let mut row = h_flex().id("history.detail.stage").relative().bg(p.ink.opacity(SEGMENT_OFF)).rounded(px(6.));
        for (n, (s, label, id)) in items.into_iter().enumerate() {
            let on = self.stage == s;
            row = row.child(
                FlowButton::new(id, ButtonKind::Plain, label)
                    .a11y_selected(on)
                    .content(div().w(px(121.)).h(px(24.)).flex().items_center().justify_center().rounded(px(6.)).when(on, |d| d.bg(p.ink.opacity(SEGMENT_ON))).child(t(label).size(14.).color(p.ink).a11y_hidden()))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.stage = s;
                        cx.notify();
                    })),
            );
            if n < 2 && !on && self.stage != items[n + 1].0 {
                row = row.child(div().absolute().left(px(121. * (n as f32 + 1.))).top(px(5.)).w(px(1.)).h(px(14.)).bg(p.ink.opacity(SEGMENT_RULE)));
            }
        }
        h_flex().gap(px(9.)).child(t("Transcript stage").size(14.)).child(row)
    }

    fn context_section(&self, env: &Envelope, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = pal(cx);
        let c = env.context.as_ref();
        let mut col = v_flex()
            .id("history.detail.context")
            .w_full()
            .gap(px(8.))
            .child(hairline(cx))
            .child(t("App context").font(14., 600.).selectable())
            .child(t(context_label(c)).id("history.detail.context.outcome").size(13.).selectable());
        if let Some(line) = context_rewrite_line(c, self.model.attempts.last()) {
            col = col.child(t(line).id("history.detail.context.rewrite").size(13.).color(p.muted).selectable());
        }
        let Some(c) = c else { return col };
        for s in &c.spelling_changes {
            col = col.child(t(format!("“{}” → “{}” · on screen ({})", s.original, s.replacement, part_label(&s.source_part).to_lowercase())).size(13.).selectable());
        }
        if let Some(before) = c.pre_spelling_text.clone() {
            col = col.child(self.disclosure("history.detail.context.before", "Text before context spelling".into(), 13., move |_, _| t(before).size(13.).selectable().into_any_element(), cx));
        }
        if let Some(snapshot) = c.snapshot.clone() {
            let body = move |_: &Self, cx: &mut Context<Self>| {
                let mut v = v_flex().pt(px(8.)).gap(px(8.));
                for (a, b) in snapshot_lines(&snapshot) {
                    v = v.child(meta(a, b, cx));
                }
                v.into_any_element()
            };
            col = col.child(self.disclosure("history.detail.context.snapshot", "Context as captured".into(), 13., body, cx));
        }
        col
    }

    fn rewrite_section(&self, env: &Envelope, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = pal(cx);
        let m = &self.model;
        let entry = env.entry.clone();
        let text_col = |id: &str, title: String, caption: &'static str, body: String, e: Entry, cx: &mut Context<Self>| {
            let (copy_text, ins_text) = (body.clone(), body.clone());
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(6.))
                .child(t(title.clone()).size(12.).selectable())
                .child(t(caption).size(12.).color(p.muted).selectable())
                .child(t(body).size(14.).selectable().no_widow())
                .child(
                    h_flex()
                        .gap(px(8.))
                        .child(native_button(format!("history.detail.copy.{id}"), "Copy", cx).a11y_label(format!("Copy {title}")).on_click(cx.listener(move |this, _, _, cx| this.copy(copy_text.clone(), cx))))
                        .child(native_button(format!("history.detail.insert.{id}"), "Insert…", cx).a11y_label(format!("Insert {title}")).on_click(cx.listener(move |this, _, _, cx| this.insert(&e, ins_text.clone(), cx)))),
                )
        };
        let mut texts = h_flex().w_full().items_start().gap(px(16.)).child(text_col("saved", "Saved text".into(), "The faithful transcript.", entry.text.clone(), entry.clone(), cx));
        if let Some(cur) = m.current_rewrite().cloned() {
            if let Some(out) = cur.output_text.clone() {
                texts = texts.child(text_col("current", format!("Current rewrite ({})", mode_title(&cur.mode)), "AI-generated rewrite, not the transcript.", out, entry.clone(), cx));
            }
        }
        let mode = m.rewrite_mode;
        let page = cx.entity().downgrade();
        // A native `Picker` in a 180 frame: its label and 99 wide popup, centered.
        let chip = h_flex().w(px(99.)).h(px(24.)).pl(px(12.)).pr(px(8.)).justify_between().bg(p.ink.opacity(SEGMENT_ON)).rounded(px(6.)).child(t(mode.title()).size(14.).color(p.ink).a11y_hidden()).child(icon("chevron.up.chevron.down", 10., p.ink));
        let popup = Button::new("history.detail.rewrite.mode").ghost().p_0().h(px(24.)).w(px(99.)).accessibility_label("Mode").child(chip).dropdown_menu(move |mut menu, _, _| {
            for item in RewriteMode::ALL {
                let page = page.clone();
                menu = menu.item(PopupMenuItem::new(item.title()).on_click(move |_, _, cx| {
                    page.update(cx, |this, cx| {
                        this.model.rewrite_mode = item;
                        cx.notify();
                    })
                    .ok();
                }));
            }
            menu
        });
        let picker = h_flex().w(px(180.)).justify_center().gap(px(8.)).child(t("Mode").size(14.)).child(popup);
        let mut col = v_flex()
            .id("history.detail.rewrite")
            .w_full()
            .gap(px(10.))
            .child(hairline(cx))
            .child(t("Rewrite").font(14., 600.).selectable())
            .child(t(m.rewrite_state_line()).size(13.).color(p.muted).selectable())
            .child(t(m.delivered_line()).id("history.detail.rewrite.delivered").size(13.).selectable())
            .when_some(m.rewrite_notice.clone(), |d, n| d.child(t(n).id("history.detail.rewrite.notice").size(13.).color(p.muted).selectable()))
            .when_some(m.rewrite_limit_explanation(), |d, n| d.child(t(n).size(13.).color(p.muted).selectable()))
            .child(texts)
            .child(
                h_flex()
                    .gap(px(8.))
                    .child(picker)
                    .child(native_button("history.detail.rewrite.retry", if m.attempts.is_empty() { "Rewrite" } else { "Retry" }, cx).disabled(!m.can_request_rewrite()).on_click(cx.listener(|this, _, _, cx| this.request_rewrite(cx))))
                    .when(m.pending_rewrite().is_some(), |d| {
                        d.child(native_button("history.detail.rewrite.cancel", "Cancel rewrite", cx).on_click(cx.listener(|this, _, _, cx| {
                            if let Some(db) = cx.global::<crate::core::Core>().db.as_ref() {
                                this.model.cancel_rewrite(db);
                            }
                            cx.notify();
                        })))
                    }),
            );
        if m.attempts.is_empty() {
            col = col.child(t("No rewrite attempts.").size(13.).color(p.muted).selectable());
        }
        for a in m.attempts.clone() {
            let e = entry.clone();
            let key = format!("history.detail.rewrite.attempt.{}", a.ordinal);
            let title = a.title();
            col = col.child(self.disclosure(
                &key,
                title,
                13.,
                move |_, cx| attempt_body(a, e, cx),
                cx,
            ));
        }
        col
    }
}

fn attempt_body(a: Attempt, e: Entry, cx: &mut Context<HistoryPage>) -> AnyElement {
    let p = pal(cx);
    let n = a.ordinal;
    let mut v = v_flex().w_full().pt(px(8.)).gap(px(8.)).child(t(a.summary()).size(13.).color(p.muted).selectable());
    if a.failure_category.as_deref() == Some("context_copied") {
        v = v.child(t(rewrite_notice("context_copied")).size(13.).selectable());
    }
    v = v.child(t("Input snapshot").size(12.).selectable()).child(t(a.input_text.clone()).size(13.).selectable());
    if let Some(out) = a.output_text.clone() {
        let copy = out.clone();
        let deliverable = a.deliverable().map(str::to_string);
        let enabled = deliverable.is_some();
        v = v
            .child(t("AI-generated rewrite, not the transcript.").size(12.).selectable())
            .child(t(out).size(13.).selectable())
            .child(
                h_flex()
                    .gap(px(8.))
                    .child(native_button(format!("history.detail.attempt.copy.{n}"), "Copy", cx).a11y_label(format!("Copy rewrite attempt {n}")).on_click(cx.listener(move |this, _, _, cx| this.copy(copy.clone(), cx))))
                    .child(
                        native_button(format!("history.detail.attempt.insert.{n}"), "Insert…", cx).a11y_label(format!("Insert rewrite attempt {n}")).disabled(!enabled).on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(text) = deliverable.clone() {
                                this.insert(&e, text, cx);
                            }
                        })),
                    ),
            );
    }
    v.into_any_element()
}
