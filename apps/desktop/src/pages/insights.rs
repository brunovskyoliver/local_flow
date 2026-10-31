//! Insights page: dictation pace, fixes, volume, where dictation goes, and the daily streak.
use crate::core::Core;
use crate::pages::Page;
use crate::shell::Session;
use flow_core::history::{local, now_ms};
use flow_core::insights::*;
use flow_ui::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Tab {
    Usage,
    Voice,
}

/// `InsightTip`: a dark note, or a light card for a calendar day.
#[derive(Clone, PartialEq, Debug)]
enum Tip {
    Note { title: String, detail: Option<String> },
    Day { day: i64, words: i64, apps: i64, top: Option<String> },
}

impl Tip {
    fn note(title: impl Into<String>) -> Tip {
        Tip::Note { title: title.into(), detail: None }
    }
    fn spoken(&self) -> String {
        match self {
            Tip::Note { title, detail } => note_spoken(title, detail.as_deref()),
            Tip::Day { day, words, apps, top } => day_spoken(*day, *words, *apps, top.as_deref()),
        }
    }
}

type Anchors = Rc<RefCell<HashMap<String, Bounds<Pixels>>>>;
const LAYER: &str = "layer";
/// Puts 11.5 caps on a 29 heading's first baseline; `Txt` reports no baseline to flex.
const CAPS_ON_HEADING: f32 = 15.5;
/// Measured against Swift: its grid sits 2 lower under the streak heading than `.padding(.top, 24)` gives here.
const BASELINE_ROW: f32 = 2.;
/// swift-note: the cell's `.aspectRatio(1, .fit)` in a row of unconstrained height collapses in
/// SwiftUI's layout pass. Measured at 2x on the reference: the first row 3 pt, the second 2 pt, the
/// rest 0. The inventory (INS-077) says square cells, see INS-114; this matches what Swift renders.
const HEAT_DOT: [f32; 7] = [3., 2., 0., 0., 0., 0., 0.];

pub struct InsightsPage {
    insights: Option<Insights>,
    error: Option<String>,
    tab: Tab,
    /// `StreakCard.page`: how many 19-week pages back.
    page: i64,
    hovered_hour: Option<usize>,
    /// What the bars animate from.
    previous_hour: Option<usize>,
    tip: Option<(String, Tip)>,
    anchors: Anchors,
    focus: FocusHandle,
    _session_sub: Subscription,
}

// ponytail: `AppName.display` needs NSWorkspace; the fallback is Swift's for an uninstalled app.
fn app_name(bundle: &str) -> String {
    fallback_app_name(bundle)
}

/// `dataScale[1]` at rest; the hovered bar `dataScale[0]`, the others `dataScale[2]`; empty hours stay empty.
fn hour_fill(p: &Palette, words: i64, h: usize, hovered: Option<usize>) -> Hsla {
    if words == 0 {
        return p.heat_empty;
    }
    match hovered {
        None => p.data_scale[1],
        Some(x) if x == h => p.data_scale[0],
        Some(_) => p.data_scale[2],
    }
}

fn mix(a: Hsla, b: Hsla, t: f32) -> Hsla {
    let lerp = |x: f32, y: f32| x + (y - x) * t;
    Hsla { h: lerp(a.h, b.h), s: lerp(a.s, b.s), l: lerp(a.l, b.l), a: lerp(a.a, b.a) }
}

impl InsightsPage {
    pub fn new(_: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut shown = cx.try_global::<Session>().map(|s| s.selection);
        let mut revision = cx.try_global::<Session>().map_or(0, |s| s.history_revision);
        // `.task`: refreshes on every appearance, and not while shown.
        let _session_sub = cx.observe_global::<Session>(move |this, cx| {
            let now = Some(cx.global::<Session>().selection);
            if now != shown && now == Some(Page::Insights) && cx.global::<Core>().scenario.is_none() {
                this.refresh(cx);
                cx.notify();
            }
            shown = now;
            // A new dictation refreshes Insights only while it is the selected page.
            let latest = cx.global::<Session>().history_revision;
            if latest != revision && now == Some(Page::Insights) {
                this.refresh(cx);
                cx.notify();
            }
            revision = latest;
        });
        let mut page = InsightsPage { insights: None, error: None, tab: Tab::Usage, page: 0, hovered_hour: None, previous_hour: None, tip: None, anchors: Default::default(), focus: cx.focus_handle(), _session_sub };
        page.refresh(cx);
        let scenario = cx.global::<Core>().scenario.clone().unwrap_or_default();
        match scenario.as_str() {
            "insights.voice" => page.tab = Tab::Voice,
            "insights.error" => {
                page.insights = None;
                page.error = Some(ERROR.into());
            }
            "insights.empty" => page.insights = Some(Insights::default()),
            "insights.voice-empty" => {
                page.insights = Some(Insights::default());
                page.tab = Tab::Voice;
            }
            _ => {}
        }
        page
    }

    /// `.task { refresh() }`. A failure keeps the last insights and shows the error.
    fn refresh(&mut self, cx: &mut Context<Self>) {
        match cx.global::<Core>().db.as_ref().map(load) {
            Some(Ok(i)) => {
                self.insights = Some(i);
                self.error = None;
            }
            _ => self.error = Some(ERROR.into()),
        }
    }

    fn tabs(&self, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let mut row = h_flex().w_full().gap(px(16.)).pt(px(26.)).relative().items_center();
        for (item, label, id) in [(Tab::Usage, "Your usage", "insights.tab.usage"), (Tab::Voice, "Your voice", "insights.tab.voice")] {
            let on = self.tab == item;
            row = row.child(
                FlowButton::new(id, ButtonKind::Plain, label)
                    .a11y_selected(on)
                    .content(v_flex().gap(px(6.)).child(t(label).font(15., if on { 500. } else { 400. }).color(if on { p.ink } else { p.muted }).a11y_hidden()).child(div().h(px(2.)).w_full().when(on, |d| d.bg(p.ink))))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.tab = item;
                        this.tip = None;
                        cx.notify();
                    })),
            );
        }
        row.child(div().absolute().bottom_0().left_0().right_0().h(px(1.)).bg(p.line))
    }

    /// `.insightTip`: reports its bounds and hover; the hover detail is also its accessibility value.
    fn target(&self, id: String, tip: Option<Tip>, child: impl IntoElement, cx: &mut Context<Self>) -> Stateful<Div> {
        let anchors = self.anchors.clone();
        let key = id.clone();
        let hover_key = id.clone();
        let spoken = tip.as_ref().map(|t| t.spoken()).unwrap_or_default();
        div()
            .id(SharedString::from(id))
            .relative()
            .aria_value(spoken)
            .child(child)
            .child(
                canvas(
                    move |b, _, _| {
                        anchors.borrow_mut().insert(key.clone(), b);
                    },
                    |_, _, _, _| {},
                )
                .absolute()
                .top_0()
                .left_0()
                .size_full(),
            )
            .on_hover(cx.listener(move |this, inside: &bool, _, cx| {
                match (&tip, *inside) {
                    (Some(t), true) => this.tip = Some((hover_key.clone(), t.clone())),
                    _ if this.tip.as_ref().is_some_and(|(k, _)| k == &hover_key) => this.tip = None,
                    _ => {}
                }
                if let Some(h) = hover_key.strip_prefix("insights.hour.").and_then(|h| h.parse().ok()) {
                    if *inside {
                        this.previous_hour = this.hovered_hour;
                        this.hovered_hour = Some(h);
                    } else if this.hovered_hour == Some(h) {
                        this.previous_hour = this.hovered_hour;
                        this.hovered_hour = None;
                    }
                }
                cx.notify();
            }))
    }

    fn info(&self, id: &str, text: &str, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let m = pal(cx).muted;
        self.target(format!("insights.info.{id}"), Some(Tip::note(text)), icon("info.circle", 13., m), cx).aria_label(text.to_string()).test_support()
    }

    // ponytail: the long label's 9.8 stands in for `.minimumScaleFactor`, measured at 1180 wide; compact cards fit it unscaled.
    fn stat(&self, value: String, label: &str, help: Option<(&str, &str)>, cx: &mut Context<Self>) -> Div {
        let (has_help, long) = (help.is_some(), label.len() > 20 && !cx.global::<Flow>().compact);
        let info = help.map(|(id, h)| self.info(id, h, cx));
        v_flex()
            .gap(px(9.))
            .child(t(value).font(28., 500.).mono_digits().tracking(-0.5).lines(1))
            .child(h_flex().gap(px(6.)).when(long, |d| d.mb(px(-1.))).when(has_help, |d| d.h(px(15.))).child(caps(label, pal(cx).muted, if long { 9.8 } else { 11.5 })).when_some(info, |d, i| d.child(i)))
    }

    fn usage(&self, i: &Insights, cx: &mut Context<Self>) -> Div {
        let pace = insight_card(cx)
            .id("insights.pace")
            .test_support()
            .child(self.stat(i.words_per_minute().map_or("–".to_string(), |w| w.to_string()), "Words per minute", Some(("pace", "Your dictation pace, against typing at 40 words per minute")), cx))
            .child(dial(dial_fraction(i.words_per_minute()), versus_typing(i.words_per_minute()), cx));
        let row = |value: i64, label: &str, id: &str, help: &str, this: &Self, cx: &mut Context<Self>| {
            h_flex().w_full().justify_between().gap(px(6.)).child(t(format!("{} {label}", grouped(value))).size(14.5).lines(1)).child(this.info(id, help, cx))
        };
        let fixes = insight_card(cx)
            .id("insights.fixes")
            .test_support()
            .child(self.stat(grouped(i.words_corrected + i.dictionary_fixes), "Fixes made by LocalFlow", None, cx))
            .child(rule(cx))
            .child(
                v_flex()
                    .w_full()
                    .gap(px(12.))
                    .child(row(i.words_corrected, "words corrected", "corrected", "Words your rewrites changed before inserting", self, cx))
                    .child(row(i.dictionary_fixes, "dictionary fixes", "fixes", "Words spelled from your dictionary", self, cx)),
            );
        let p = pal(cx);
        let volume = insight_card(cx)
            .id("insights.volume")
            .test_support()
            .child(self.stat(grouped(i.total_words), "Total words dictated", None, cx))
            .child(rule(cx))
            .child(
                h_flex()
                    .w_full()
                    .items_end()
                    .justify_between()
                    .gap(px(8.))
                    .child(v_flex().gap(px(8.)).child(h_flex().gap(px(8.)).child(div().w(px(21.)).child(icon("desktopcomputer", 15., p.ink))).child(t("Desktop").size(14.5))).child(t(format!("{} words", grouped(i.total_words))).size(14.5)))
                    .child(t(format!("{} dictations", grouped(i.dictations))).size(14.5).color(p.muted)),
            );
        let apps = self.apps(i, cx);
        let streak = self.streak(i, cx);
        v_flex()
            .w_full()
            .gap(px(24.))
            .child(card_row(cx).child(div().flex_1().min_w_0().flex().flex_row().items_stretch().gap(px(24.)).child(pace).child(fixes)).child(div().flex_1().min_w_0().flex().items_stretch().child(volume)))
            .child(card_row(cx).child(apps).child(streak))
    }

    fn voice(&self, i: &Insights, cx: &mut Context<Self>) -> Div {
        let a = insight_card(cx).child(self.stat(talk_time(i.spoken_seconds), "Time spoken", None, cx));
        let b = insight_card(cx).child(self.stat(grouped(i.average_words()), "Words per dictation", None, cx));
        let c = insight_card(cx).child(self.stat(grouped(i.longest_words), "Longest dictation", None, cx));
        let hours = self.hours(i, cx);
        v_flex().w_full().gap(px(24.)).child(card_row(cx).child(a).child(b).child(c)).child(hours)
    }

    fn apps(&self, i: &Insights, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let p = pal(cx);
        let compact = cx.global::<Flow>().compact;
        let mut rows = v_flex().gap(px(16.)).pt(px(26.));
        for (n, (cat, count)) in i.category_rows().into_iter().enumerate() {
            let share = i.share(count);
            let (fill, label) = if count == 0 {
                (p.data_quiet, p.on_data_quiet)
            } else if n == 0 {
                (p.data_strong, p.on_data_strong)
            } else {
                (p.data_scale[1], p.on_data)
            };
            let tip = (count > 0).then(|| {
                let words = i.category_words[Category::ALL.iter().position(|c| *c == cat).unwrap_or(0)];
                Tip::Note { title: counted(words, "word", "words"), detail: i.top_app_in(cat).map(|a| format!("Most in {}", app_name(a))) }
            });
            let bar = div()
                .w(px((share * if compact { 150. } else { 300. }).max(35.)))
                .h(px(28.))
                .flex()
                .items_center()
                .justify_center()
                .bg(fill)
                .rounded(px(4.))
                .child(t(format!("{}%", (share * 100.).round() as i64)).font(12., 500.).mono_digits().tracking(0.7).color(label));
            rows = rows.child(
                h_flex()
                    .gap(px(14.))
                    .child(div().w(px(24.)).flex().justify_center().child(icon(cat.symbol(), 18., p.ink)))
                    .child(self.target(format!("insights.bar.{}", cat.label()), tip, bar, cx).test_support())
                    .child(caps(&format!("{} {}", grouped(count), cat.label()), p.ink, 12.5)),
            );
        }
        insight_card(cx)
            .id("insights.apps")
            .test_support()
            .child(h_flex().w_full().justify_between().items_start().gap(px(8.)).child(t("Desktop usage").font(29., 500.).tracking(-0.6).lines(1)).child(div().pt(px(CAPS_ON_HEADING)).child(caps(&format!("Total apps used | {}", i.apps_used), p.ink, 11.5))))
            .child(rows)
    }

    fn streak(&self, i: &Insights, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let p = pal(cx);
        let today = cx.global::<Core>().db.as_ref().map_or(0, |db| local(db, now_ms()).day_number());
        let streaks = streaks(&i.days, today);
        let cols = columns(today, self.page);
        let limits = i.thresholds();
        let earliest = i.days.keys().next().copied();
        let chevron = |id: &'static str, symbol: &'static str, label: &'static str, enabled: bool, delta: i64, cx: &mut Context<Self>| {
            FlowButton::new(id, ButtonKind::Plain, label)
                .disabled_opacity(0.35)
                .disabled(!enabled)
                .content(div().size(px(18.)).flex().items_center().justify_center().child(icon(symbol, 12., p.muted)))
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.page += delta;
                    this.tip = None;
                    cx.notify();
                }))
        };
        let mut months = h_flex().w_full().gap(px(8.)).relative().pb(px(14.)).child(div().w(px(34.)).flex_none().flex().items_start().child(chevron("insights.earlierWeeks", "chevron.left", "Earlier weeks", earliest.is_some_and(|e| e < cols[0]), 1, cx)));
        for w in &cols {
            // The label overflows its column, as `.fixedSize()` does in Swift's overlay.
            months = months.child(div().flex_1().min_w_0().h(px(16.)).relative().when_some(month_label(*w), |d, l: String| d.child(div().absolute().left_0().top_0().w(px(30.)).child(t(l).size(11.).color(p.muted)))));
        }
        months = months.child(div().absolute().right_0().top_0().bg(p.card).child(chevron("insights.laterWeeks", "chevron.right", "Later weeks", self.page > 0, -1, cx)));
        let mut grid = v_flex().w_full().gap(px(8.)).pt(px(24.)).child(months);
        for wd in 0..7i64 {
            let mut r = h_flex().w_full().h(px(13.)).gap(px(8.)).child(div().w(px(34.)).flex_none().child(t(weekday_label(wd)).size(11.).color(p.muted)));
            for w in &cols {
                let day = w + wd;
                let usage = i.days.get(&day);
                let count = usage.map_or(0, |u| u.words);
                let fill = if day > today {
                    p.heat_empty.opacity(0.45)
                } else if count == 0 {
                    p.heat_empty
                } else {
                    p.data_scale[level(count, &limits)]
                };
                let tip = (day <= today).then(|| Tip::Day { day, words: count, apps: usage.map_or(0, |u| u.apps.len() as i64), top: usage.and_then(|u| u.top_app()).map(app_name) });
                let cell = div().size(px(HEAT_DOT[wd as usize])).rounded(px(3.)).bg(fill).when(HEAT_DOT[wd as usize] > 0. && streaks.current_days.contains(&day), |d| d.border(px(1.5_f32.min(HEAT_DOT[wd as usize] / 2.))).border_color(p.streak_outline));
                r = r.child(div().flex_1().min_w_0().flex().justify_center().child(self.target(format!("insights.day.{day}"), tip, cell, cx).test_support()));
            }
            grid = grid.child(r);
        }
        let swatch = |c: Hsla| div().size(px(16.)).rounded(px(3.)).bg(c);
        let mut legend = h_flex().w_full().gap(px(8.)).pt(px(26.)).child(t("More").size(13.).color(p.muted));
        for c in p.data_scale {
            legend = legend.child(swatch(c));
        }
        legend = legend
            .child(t("Less").size(13.).color(p.muted))
            .child(div().flex_1())
            .child(div().size(px(16.)).rounded(px(3.)).border(px(1.2)).border_color(p.streak_outline))
            .child(t("Current streak").size(13.).color(p.muted));
        insight_card(cx)
            .id("insights.streak")
            .test_support()
            .child(
                h_flex()
                    .w_full()
                    .pb(px(BASELINE_ROW))
                    .justify_between()
                    .items_start()
                    .gap(px(8.))
                    .child(t(format!("{} day streak", streaks.current)).font(29., 500.).tracking(-0.6).lines(1))
                    .child(div().pt(px(CAPS_ON_HEADING)).child(caps(&format!("Longest streak | {} {}", streaks.longest, if streaks.longest == 1 { "day" } else { "days" }), p.ink, 11.5))),
            )
            .child(grid)
            .child(legend)
    }

    fn hours(&self, i: &Insights, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let p = pal(cx);
        let peak = i.hours.iter().copied().max().unwrap_or(0).max(1);
        let mut bars = h_flex().w_full().h(px(130.)).items_end().gap(px(6.)).mt(px(26.));
        for h in 0..24usize {
            let (from, fill) = (hour_fill(&p, i.hours[h], h, self.previous_hour), hour_fill(&p, i.hours[h], h, self.hovered_hour));
            let height = (130. * i.hours[h] as f32 / peak as f32).max(5.);
            // `.animation(.easeOut(duration: 0.12), value: hovered)`, restarted when the hover changes.
            let bar = div().w_full().h(px(height)).rounded(px(3.)).bg(fill).with_animation(
                SharedString::from(format!("insights.hour.fill.{h}.{:?}", self.hovered_hour)),
                Animation::new(Duration::from_millis(120)).with_easing(|t| 1. - (1. - t) * (1. - t)),
                move |d, delta| d.bg(mix(from, fill, delta)),
            );
            let target = self
                .target(format!("insights.hour.{h}"), Some(hour_tip(i, h)), div().w_full().h(px(130.)).flex().items_end().child(bar), cx).test_support()
                .flex_1()
                .min_w_0();
            bars = bars.child(target);
        }
        let mut labels = h_flex().w_full().h(px(24.)).pt(px(10.));
        for h in [0, 6, 12, 18] {
            labels = labels.child(div().flex_1().child(t(hour_label(h)).size(12.).color(p.muted)));
        }
        insight_card(cx).id("insights.hours").test_support().child(t("When you dictate").font(29., 500.).tracking(-0.6)).child(bars).child(labels)
    }

    /// The tip layer: drawn over the cards, positioned from the target's bounds, ignores the mouse.
    fn tip_layer(&self, cx: &App) -> Option<Div> {
        let (key, tip) = self.tip.clone()?;
        let anchors = self.anchors.borrow();
        let (target, layer) = (*anchors.get(&key)?, *anchors.get(LAYER)?);
        let p = pal(cx);
        let gap = 8.;
        let bottom = f32::from(layer.bottom() - target.top()) + gap;
        let mid = f32::from(target.center().x - layer.left());
        let width = f32::from(layer.size.width);
        let (content, est): (AnyElement, f32) = match &tip {
            Tip::Note { title, detail } => {
                let long = detail.iter().flat_map(|d| d.split('\n')).map(|l| l.chars().count() as f32 * 6.).fold(title.chars().count() as f32 * 7., f32::max);
                (note_bubble(title.clone(), detail.clone(), cx).into_any_element(), long + 22.)
            }
            Tip::Day { day, words, apps, top } => {
                let row = |l: &str, v: String| h_flex().w_full().justify_between().gap(px(12.)).child(t(l.to_string()).size(12.5).color(p.ink)).child(t(v).font(12.5, 500.).color(p.ink).lines(1));
                (
                    v_flex()
                        .w(px(250.))
                        .p(px(14.))
                        .bg(p.surface)
                        .rounded(px(10.))
                        .border_1()
                        .border_color(p.card_line)
                        .shadow(vec![day_tip_shadow()])
                        .child(div().pb(px(14.)).child(t(long_date(*day)).font(13., 500.).color(p.ink)))
                        .child(v_flex().gap(px(10.)).child(row("Total words", grouped(*words))).child(row("Total apps used", grouped(*apps))).when_some(top.clone(), |d, a| d.child(row("Top app", a))))
                        .into_any_element(),
                    250.,
                )
            }
        };
        let content = div().id("insights.tip").test_support().child(content);
        // ponytail: a note's width is estimated only to pick an edge; centered otherwise.
        let wrap = if mid - est / 2. < 0. {
            div().absolute().left_0().child(content)
        } else if mid + est / 2. > width {
            div().absolute().right_0().child(content)
        } else {
            div().absolute().left(px(mid)).w(px(0.)).flex().justify_center().child(div().flex_none().child(content))
        };
        let arrow = matches!(tip, Tip::Note { .. }).then(|| {
            // `TipArrow`: a 12 by 6 triangle under the note.
            let ink = p.ink;
            div().id("insights.tip.arrow").test_support().child(canvas(
                |_, _, _| {},
                move |b, _, w, _| {
                    let o = b.origin;
                    let mut path = PathBuilder::fill();
                    path.move_to(o);
                    path.line_to(point(o.x + px(12.), o.y));
                    path.line_to(point(o.x + px(6.), o.y + px(6.)));
                    path.close();
                    if let Ok(path) = path.build() {
                        w.paint_path(path, ink);
                    }
                },
            ).size_full())
            .absolute()
            .left(px(mid - 6.))
            .bottom(px(bottom - 6.5))
            .w(px(12.))
            .h(px(6.))
        });
        Some(div().absolute().inset_0().child(wrap.bottom(px(bottom))).children(arrow))
    }
}

/// `InsightTips`' note: its text over `ink`.
fn note_bubble(title: String, detail: Option<String>, cx: &App) -> Div {
    let p = pal(cx);
    v_flex()
        .gap(px(3.))
        .px(px(11.))
        .py(px(8.))
        .bg(p.ink)
        .rounded(px(7.))
        .child(t(title).font(13., 500.).color(p.surface))
        .when_some(detail, |d, x| d.child(t(x).size(11.5).color(p.surface).opacity(0.75)))
}

fn hour_tip(i: &Insights, h: usize) -> Tip {
    let range = format!("{} – {}", hour_time(h as i64), hour_time((h as i64 + 1) % 24));
    let words = i.hours[h];
    if words == 0 {
        return Tip::Note { title: "No dictation".into(), detail: Some(range) };
    }
    let mut detail = format!("{range} · {}", counted(i.hour_dictations[h], "dictation", "dictations"));
    if let Some(top) = top_of(&i.hour_apps[h]) {
        detail.push_str(&format!("\nMost in {}", app_name(top)));
    }
    Tip::Note { title: counted(words, "word", "words"), detail: Some(detail) }
}

fn day_tip_shadow() -> flow_ui::gpui::BoxShadow {
    flow_ui::gpui::BoxShadow { color: flow_ui::gpui::black().opacity(0.12), offset: point(px(0.), px(5.)), blur_radius: px(14.), spread_radius: px(0.), inset: false }
}

fn caps(text: &str, color: Hsla, size: f32) -> Txt {
    t(text.to_uppercase()).font(size, 500.).tracking(size * 0.12).color(color).lines(1)
}

fn insight_card(cx: &App) -> Div {
    let p = pal(cx);
    v_flex().flex_1().min_w_0().items_start().px(px(17.)).py(px(17.)).bg(p.card).rounded(px(6.)).border_1().border_color(p.card_line)
}

fn rule(cx: &App) -> Div {
    div().w_full().py(px(17.)).child(div().h(px(1.)).w_full().bg(pal(cx).rule.opacity(0.6)))
}

/// `cardRow`: side by side with equal heights, stacked in a compact window.
fn card_row(cx: &App) -> Div {
    let compact = cx.global::<Flow>().compact;
    div().w_full().flex().gap(px(24.)).items_stretch().when(compact, |d| d.flex_col()).when(!compact, |d| d.flex_row())
}

/// The dial runs to 200 words per minute; no pace yet is an empty dial.
fn dial_fraction(pace: Option<i64>) -> f32 {
    (pace.unwrap_or(0) as f32 / 200.).clamp(0., 1.)
}

/// `Dial`: a little over a half circle with round caps.
fn dial(fraction: f32, center: String, cx: &App) -> impl IntoElement + use<> {
    let p = pal(cx);
    let (track, fill) = (p.heat_empty, p.data_strong);
    div()
        .relative()
        .mt(px(16.))
        .w(px(156.))
        .h(px(156. / 2. + 8. + 4.))
        .child(
            canvas(
                |_, _, _| {},
                move |b, _, w, _| {
                    let c = point(b.origin.x + px(78.), b.origin.y + px(78.));
                    arc(c, 70., 8., 177., 186., track, w);
                    if fraction > 0. {
                        arc(c, 70., 8., 177., 186. * fraction, fill, w);
                    }
                },
            )
            .absolute()
            .size_full(),
        )
        .child(
            v_flex()
                .absolute()
                .top(px(32.))
                .w_full()
                .items_center()
                .gap(px(3.))
                .child(t("vs typing").size(15.).color(p.muted))
                .child(t(center).font(19., 500.).mono_digits()),
        )
}

/// A round-capped stroke as one filled outline; `start` and `sweep` in degrees, clockwise.
fn arc(c: Point<Pixels>, r: f32, half: f32, start: f32, sweep: f32, color: Hsla, w: &mut Window) {
    let at = |deg: f32, radius: f32, about: Point<f32>| {
        let a = deg.to_radians();
        point(about.x + radius * a.cos(), about.y + radius * a.sin())
    };
    let o = point(0f32, 0f32);
    let px_pt = |p: Point<f32>| point(c.x + px(p.x), c.y + px(p.y));
    let mut pts = vec![];
    for i in 0..=96 {
        pts.push(at(start + sweep * i as f32 / 96., r + half, o));
    }
    let end = at(start + sweep, r, o);
    for i in 1..24 {
        pts.push(at(start + sweep + 180. * i as f32 / 24., half, end));
    }
    for i in (0..=96).rev() {
        pts.push(at(start + sweep * i as f32 / 96., r - half, o));
    }
    let begin = at(start, r, o);
    for i in 1..24 {
        pts.push(at(start + 180. + 180. * i as f32 / 24., half, begin));
    }
    let mut path = PathBuilder::fill();
    path.move_to(px_pt(pts[0]));
    for p in &pts[1..] {
        path.line_to(px_pt(*p));
    }
    path.close();
    if let Ok(path) = path.build() {
        w.paint_path(path, color);
    }
}

impl Render for InsightsPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let mut col = v_flex().w_full().child(t("Insights").font(26., 500.).tracking(-0.4)).child(self.tabs(cx));
        if let Some(e) = self.error.clone() {
            col = col.child(div().id("insights.errorLine").test_support().pt(px(24.)).child(t(e).size(13.).color(p.warning)));
        }
        if let Some(i) = self.insights.clone() {
            let body = match self.tab {
                Tab::Usage => self.usage(&i, cx),
                Tab::Voice => self.voice(&i, cx),
            };
            let tip = self.tip_layer(cx);
            let anchors = self.anchors.clone();
            col = col.child(
                div()
                    .w_full()
                    .mt(px(48.))
                    .relative()
                    .child(body)
                    .child(
                        canvas(
                            move |b, _, _| {
                                anchors.borrow_mut().insert(LAYER.into(), b);
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .top_0()
                        .left_0()
                        .size_full(),
                    )
                    .children(tip),
            );
        }
        super::dictionary::ui::under_card_border(prototype_page("insights.page", 1142., cx, col))
            .id("insights.root")
            .track_focus(&self.focus)
            // No Kit `Root` in this shell, so Tab is bound per page (DICT row actions do the same).
            .on_key_down(cx.listener(|_, e: &KeyDownEvent, w, cx| {
                if e.keystroke.key == "tab" {
                    if e.keystroke.modifiers.shift { w.focus_prev(cx) } else { w.focus_next(cx) }
                }
            }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{assert_saw, boot, saw};
    use flow_ui::test::{TestAppContext, TestWindowExt};

    fn open(cx: &mut TestAppContext) -> WindowHandle<InsightsPage> {
        boot(cx, Mode::Light);
        let w = cx.add_window(|w, cx| InsightsPage::new(w, cx));
        frame(cx, w);
        w
    }

    fn frame(cx: &mut TestAppContext, w: WindowHandle<InsightsPage>) {
        cx.run_until_parked();
        flow_ui::probe::clear();
        cx.update_window(w.into(), |_, w, cx| w.render_frame(cx)).unwrap();
    }

    fn click(cx: &mut TestAppContext, w: WindowHandle<InsightsPage>, id: &'static str) {
        cx.update_window(w.into(), |_, win, cx| win.click(id, cx)).unwrap();
        frame(cx, w);
    }

    // parity: INS-003 INS-006 INS-023 INS-029 INS-031 INS-032 INS-038 INS-039 INS-043 INS-045 INS-051 INS-064 INS-068 INS-089
    #[flow_ui::gpui::test]
    async fn usage_tab_shows_every_card(cx: &mut TestAppContext) {
        let _w = open(cx);
        assert_saw(&["Insights", "Your usage", "Your voice", "WORDS PER MINUTE", "vs typing", "FIXES MADE BY LOCALFLOW", "words corrected", "dictionary fixes", "TOTAL WORDS DICTATED", "Desktop", "dictations", "Desktop usage", "TOTAL APPS USED | ", "DOCUMENTS", "day streak", "LONGEST STREAK | ", "Mon", "Sun", "More", "Less", "Current streak"]);
    }

    // parity: INS-100
    /// The animation's timing is not observable here; this pins the fills and that hovering switches them.
    #[flow_ui::gpui::test]
    async fn the_hovered_hour_is_darkest_and_the_others_lightest(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "insights.tab.voice");
        let hours = w.update(cx, |this, _, _| this.insights.as_ref().unwrap().hours).unwrap();
        let on = hours.iter().position(|h| *h > 0).unwrap();
        let id = SharedString::from(format!("insights.hour.{on}"));
        cx.update_window(w.into(), |_, win, cx| win.hover(id, cx)).unwrap();
        frame(cx, w);
        w.update(cx, |this, _, cx| {
            let p = pal(cx);
            assert_eq!(this.hovered_hour, Some(on));
            assert_eq!(hour_fill(&p, 5, on, this.hovered_hour), p.data_scale[0]);
            assert_eq!(hour_fill(&p, 5, on + 1, this.hovered_hour), p.data_scale[2]);
            assert_eq!(hour_fill(&p, 0, on + 1, this.hovered_hour), p.heat_empty);
            assert_eq!(hour_fill(&p, 5, on, None), p.data_scale[1]);
        })
        .unwrap();
    }

    // parity: INS-008 INS-016 INS-090 INS-092 INS-094 INS-096 INS-100 INS-102 INS-103 INS-104
    #[flow_ui::gpui::test]
    async fn voice_tab_shows_stats_and_hours(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "insights.tab.voice");
        assert_saw(&["TIME SPOKEN", "WORDS PER DICTATION", "LONGEST DICTATION", "When you dictate", "00", "18"]);
        assert!(!saw("Desktop usage"));
        // The seed is relative to now, so look the hours up.
        let hours = w.update(cx, |this, _, _| this.insights.as_ref().unwrap().hours).unwrap();
        let empty = hours.iter().position(|h| *h == 0).unwrap();
        let active = hours.iter().position(|h| *h > 0).unwrap();
        for (hour, text) in [(empty, "No dictation"), (active, " word")] {
            let id = SharedString::from(format!("insights.hour.{hour}"));
            cx.update_window(w.into(), |_, win, cx| win.hover(id, cx)).unwrap();
            frame(cx, w);
            w.update(cx, |this, _, _| assert_eq!(this.hovered_hour, Some(hour))).unwrap();
            frame(cx, w);
            assert_saw(&[text]);
        }
    }

    // parity: INS-071 INS-074
    #[flow_ui::gpui::test]
    async fn chevrons_are_18_square_and_later_sits_at_the_trailing_edge(cx: &mut TestAppContext) {
        let w = open(cx);
        let get = |cx: &mut TestAppContext, id: &'static str| {
            cx.update_window(w.into(), |_, win, _| win.find(id).bounds())
                .unwrap()
        };
        let (earlier, later) = (
            get(cx, "insights.earlierWeeks"),
            get(cx, "insights.laterWeeks"),
        );
        assert_eq!(earlier.size, size(px(18.), px(18.)));
        assert_eq!(later.size, size(px(18.), px(18.)));
        assert!(later.left() > earlier.right() + px(300.), "{later:?}");
    }

    // parity: INS-072 INS-073 INS-075 INS-076
    #[flow_ui::gpui::test]
    async fn chevrons_page_the_heat_map(cx: &mut TestAppContext) {
        let w = open(cx);
        // Without older days the chevron stays disabled.
        click(cx, w, "insights.earlierWeeks");
        w.update(cx, |this, _, _| assert_eq!(this.page, 0)).unwrap();
        // At page 0 the later chevron is disabled too.
        click(cx, w, "insights.laterWeeks");
        w.update(cx, |this, _, _| assert_eq!(this.page, 0)).unwrap();
        w.update(cx, |this, _, cx| {
            this.insights.as_mut().unwrap().days.insert(1, Default::default());
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        click(cx, w, "insights.earlierWeeks");
        w.update(cx, |this, _, _| assert_eq!(this.page, 1)).unwrap();
        click(cx, w, "insights.laterWeeks");
        w.update(cx, |this, _, _| assert_eq!(this.page, 0)).unwrap();
    }

    // parity: INS-084
    #[flow_ui::gpui::test]
    async fn hovering_a_day_shows_its_card(cx: &mut TestAppContext) {
        let w = open(cx);
        let m = monday(cx);
        hover(cx, w, &format!("insights.day.{m}"));
        assert_saw(&["Total words", "Total apps used", &long_date(m)]);
    }

    // parity: INS-009 INS-012
    #[flow_ui::gpui::test]
    async fn load_failure_shows_the_error(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let db = cx.update(|cx| cx.global_mut::<Core>().db.take());
        let w = cx.add_window(|w, cx| InsightsPage::new(w, cx));
        frame(cx, w);
        assert_saw(&[ERROR]);
        cx.update(|cx| cx.global_mut::<Core>().db = db);
        w.update(cx, |p, _, cx| p.refresh(cx)).unwrap();
        frame(cx, w);
        assert!(!saw(ERROR), "a later success clears the error");
    }

    // parity: INS-013
    #[flow_ui::gpui::test]
    async fn empty_store_shows_zero_values(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| cx.global_mut::<Core>().scenario = Some("insights.empty".into()));
        let w = cx.add_window(|w, cx| InsightsPage::new(w, cx));
        frame(cx, w);
        assert_saw(&["0 day streak", "\u{2013}"]);
        click(cx, w, "insights.tab.voice");
        assert_saw(&["0s"]);
    }

    fn hover(cx: &mut TestAppContext, w: WindowHandle<InsightsPage>, id: &str) {
        let id = SharedString::from(id.to_string());
        cx.update_window(w.into(), |_, win, cx| win.hover(id, cx)).unwrap();
        frame(cx, w);
        frame(cx, w);
    }

    fn bounds(cx: &mut TestAppContext, w: WindowHandle<InsightsPage>, id: &str) -> Bounds<Pixels> {
        let id = SharedString::from(id.to_string());
        cx.update_window(w.into(), |_, win, _| win.find(id).bounds()).unwrap()
    }

    fn monday(cx: &mut TestAppContext) -> i64 {
        cx.update(|cx| week_start(local(cx.global::<Core>().db.as_ref().unwrap(), now_ms()).day_number()))
    }

    // parity: INS-011
    #[flow_ui::gpui::test]
    async fn before_the_first_result_only_title_and_tabs_show(cx: &mut TestAppContext) {
        let w = open(cx);
        w.update(cx, |t, _, cx| {
            t.insights = None;
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        assert_saw(&["Your usage", "Your voice"]);
        assert!(!saw("Top apps") && !saw("Total words"));
    }

    // parity: INS-024 INS-086 INS-087
    #[flow_ui::gpui::test]
    async fn a_note_tip_sits_8_above_its_target_and_centered(cx: &mut TestAppContext) {
        let w = open(cx);
        hover(cx, w, "insights.info.pace");
        assert_saw(&["Your dictation pace, against typing at 40 words per minute"]);
        let (target, tip) = (bounds(cx, w, "insights.info.pace"), bounds(cx, w, "insights.tip"));
        assert_eq!(tip.bottom() + px(8.), target.top());
        // Near the card's left edge it clamps to the container.
        let layer = w.update(cx, |t, _, _| t.anchors.borrow()[LAYER]).unwrap();
        assert_eq!(tip.left(), layer.left());
        // Leaving removes it.
        cx.update_window(w.into(), |_, win, cx| win.hover("insights.tab.usage", cx)).unwrap();
        frame(cx, w);
        frame(cx, w);
        assert!(!saw("Your dictation pace, against"));
    }

    // parity: INS-033 INS-034
    #[flow_ui::gpui::test]
    async fn fixes_tips_read_as_in_swift(cx: &mut TestAppContext) {
        let w = open(cx);
        hover(cx, w, "insights.info.corrected");
        assert_saw(&["Words your rewrites changed before inserting"]);
        hover(cx, w, "insights.info.fixes");
        assert_saw(&["Words spelled from your dictionary"]);
        // Clear of the edges it centers on the target.
        let (target, tip) = (bounds(cx, w, "insights.info.fixes"), bounds(cx, w, "insights.tip"));
        assert!((f32::from(tip.center().x) - f32::from(target.center().x)).abs() <= 1., "{tip:?} {target:?}");
    }

    // parity: INS-083
    #[flow_ui::gpui::test]
    async fn a_day_tip_is_a_250_card(cx: &mut TestAppContext) {
        let w = open(cx);
        let m = monday(cx);
        hover(cx, w, &format!("insights.day.{m}"));
        assert_saw(&["Total words", &long_date(m)]);
        assert_eq!(bounds(cx, w, "insights.tip").size.width, px(250.));
    }

    // parity: INS-067 INS-077 INS-114
    #[flow_ui::gpui::test]
    async fn heat_cells_are_the_dots_swift_renders(cx: &mut TestAppContext) {
        let w = open(cx);
        let m = monday(cx);
        for (offset, side) in [(0, 3.), (1, 2.), (2, 0.), (6, 0.)] {
            let b = bounds(cx, w, &format!("insights.day.{}", m + offset));
            assert_eq!(b.size, size(px(side), px(side)), "weekday {offset}");
        }
    }

    // parity: INS-048
    #[flow_ui::gpui::test]
    async fn personal_messages_has_its_bar(cx: &mut TestAppContext) {
        let w = open(cx);
        let _ = w;
        assert_saw(&["PERSONAL MESSAGES"]);
        assert_eq!((Category::Personal.label(), Category::Personal.symbol()), ("Personal messages", "bubble.left"));
    }

    // A fake region: Sunday first, numbers through it.
    #[test]
    fn first_weekday_comes_from_the_region() {
        fn date(_: i64, template: &str, _: bool) -> Option<String> {
            Some(format!("T:{template}"))
        }
        fn number(v: f64, _: u8) -> Option<String> {
            Some(format!("N{v}"))
        }
        flow_core::history::set_region(flow_core::history::Region { date, number, first_weekday: 1 });
        // 2026-10-31 is a Saturday; with Sunday first its week starts on the 25th, six days earlier.
        assert_eq!(week_start(20757), 20757 - (20757 + 5 - 1_i64).rem_euclid(7));
        assert_eq!(grouped(1234), "N1234");
    }

    // parity: SHELL-074 INS-010
    /// A new dictation refreshes Insights only while it is the selected page.
    #[flow_ui::gpui::test]
    async fn history_change_refreshes_only_the_selected_page(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(crate::shell::ensure_session);
        let w = cx.add_window(|w, cx| InsightsPage::new(w, cx));
        frame(cx, w);
        let count = |cx: &mut TestAppContext| w.update(cx, |p, _, _| p.insights.as_ref().map(|i| i.dictations)).unwrap();
        let before = count(cx);
        let remove = |cx: &mut TestAppContext, n: i64| {
            cx.update(|cx| {
                let db = cx.global::<Core>().db.as_ref().unwrap();
                let id = flow_core::history::seed_id(n);
                let revision = flow_core::history::get(db, &id).unwrap().map_or(0, |e| e.revision);
                flow_core::history::delete_confirmed(db, &id, revision).unwrap();
                crate::shell::history_changed(cx);
            });
            cx.run_until_parked();
        };
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::History));
        remove(cx, 20);
        assert_eq!(count(cx), before, "not selected");
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Insights));
        cx.run_until_parked();
        let shown = count(cx);
        assert!(shown < before, "appearing re-reads");
        remove(cx, 21);
        assert!(count(cx) < shown, "selected re-reads");
    }

    fn tip_state(cx: &mut TestAppContext, w: WindowHandle<InsightsPage>) -> Option<Tip> {
        w.update(cx, |t, _, _| t.tip.as_ref().map(|x| x.1.clone())).unwrap()
    }

    fn has(cx: &mut TestAppContext, w: WindowHandle<InsightsPage>, id: &str) -> bool {
        let id = SharedString::from(id.to_string());
        cx.update_window(w.into(), |_, win, _| win.try_find(id).is_some()).unwrap()
    }

    fn label_of(cx: &mut TestAppContext, w: WindowHandle<InsightsPage>, id: &str) -> Option<String> {
        let id = SharedString::from(id.to_string());
        cx.update_window(w.into(), |_, win, _| win.find(id).label().map(str::to_string)).unwrap()
    }

    // parity: INS-105
    /// Tab reaches both tabs and both chevrons, with no shortcut of its own.
    #[flow_ui::gpui::test]
    async fn tab_reaches_the_tabs_and_chevrons(cx: &mut TestAppContext) {
        let w = open(cx);
        w.update(cx, |t, win, cx| {
            t.page = 1;
            t.insights.as_mut().unwrap().days.insert(1, Default::default());
            t.focus.focus(win, cx);
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        let mut reached = std::collections::HashSet::new();
        for _ in 0..12 {
            cx.update_window(w.into(), |_, win, cx| win.press("tab", cx)).unwrap();
            frame(cx, w);
            for id in ["insights.tab.usage", "insights.tab.voice", "insights.earlierWeeks", "insights.laterWeeks"] {
                if cx.update_window(w.into(), |_, win, _| win.find(id).focused()).unwrap() == Some(true) {
                    reached.insert(id);
                }
            }
        }
        assert_eq!(reached.len(), 4, "{reached:?}");
    }

    // parity: INS-011
    /// A real first load that fails: load is synchronous, so this is the only way to have no result.
    #[flow_ui::gpui::test]
    async fn with_no_result_only_title_tabs_and_the_error_show(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let db = cx.update(|cx| cx.global_mut::<Core>().db.take());
        let w = cx.add_window(|w, cx| InsightsPage::new(w, cx));
        frame(cx, w);
        assert_saw(&["Insights", "Your usage", "Your voice"]);
        for card in ["insights.pace", "insights.fixes", "insights.volume", "insights.apps", "insights.streak"] {
            assert!(!has(cx, w, card), "{card}");
        }
        assert!(!saw("WORDS PER MINUTE"));
        cx.update(|cx| cx.global_mut::<Core>().db = db);
        w.update(cx, |p, _, cx| p.refresh(cx)).unwrap();
        frame(cx, w);
        assert!(has(cx, w, "insights.pace"), "the check above can fail");
    }

    // parity: INS-012
    /// 13 warning, top padding 24, and the previous cards stay under it.
    #[flow_ui::gpui::test]
    async fn a_failed_refresh_keeps_the_cards_under_the_error(cx: &mut TestAppContext) {
        let w = open(cx);
        assert!(!saw(ERROR));
        let db = cx.update(|cx| cx.global_mut::<Core>().db.take());
        w.update(cx, |p, _, cx| {
            p.refresh(cx);
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        let (s, warning) = (flow_ui::probe::style_of(ERROR).unwrap(), cx.update(|cx| pal(cx).warning));
        assert_eq!((s.size, s.color), (13., warning));
        assert_eq!(bounds(cx, w, "insights.errorLine").size.height, px(24. + 14.));
        assert!(has(cx, w, "insights.pace"));
        assert_saw(&["WORDS PER MINUTE"]);
        cx.update(|cx| cx.global_mut::<Core>().db = db);
    }

    // parity: INS-028
    #[test]
    fn the_dial_runs_to_200_clamped_and_empty_without_a_pace() {
        assert_eq!(dial_fraction(None), 0., "no pace");
        assert_eq!(dial_fraction(Some(100)), 0.5);
        assert_eq!(dial_fraction(Some(200)), 1.);
        assert_eq!(dial_fraction(Some(400)), 1., "clamped");
    }

    // parity: INS-009
    #[flow_ui::gpui::test]
    async fn coming_back_to_the_page_reads_the_store_again(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(crate::shell::ensure_session);
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = crate::pages::Page::Insights));
        let w = cx.add_window(|w, cx| InsightsPage::new(w, cx));
        frame(cx, w);
        let dictations = |cx: &mut TestAppContext| w.update(cx, |p, _, _| p.insights.as_ref().unwrap().dictations).unwrap();
        let before = dictations(cx);
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = crate::pages::Page::History));
        cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute("DELETE FROM transcriptions WHERE id=?", [flow_core::history::seed_id(1)]).unwrap());
        frame(cx, w);
        assert_eq!(dictations(cx), before, "away: no read");
        cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = crate::pages::Page::Insights));
        frame(cx, w);
        assert_eq!(dictations(cx), before - 1);
    }

    // parity: INS-067
    #[flow_ui::gpui::test]
    async fn the_heat_map_is_19_columns_of_7_rows_8_apart(cx: &mut TestAppContext) {
        let w = open(cx);
        let m = monday(cx);
        let cells = (m - 133..m + 7)
            .filter(|d| cx.update_window(w.into(), |_, win, _| win.try_find(SharedString::from(format!("insights.day.{d}"))).is_some()).unwrap())
            .count();
        assert_eq!(cells, 19 * 7);
        let center = |b: Bounds<Pixels>| b.origin + point(b.size.width / 2., b.size.height / 2.);
        let (a, down) = (center(bounds(cx, w, &format!("insights.day.{m}"))), center(bounds(cx, w, &format!("insights.day.{}", m + 1))));
        assert_eq!(down.y - a.y, px(13. + 8.), "rows 13 tall, 8 apart");
        let left = center(bounds(cx, w, &format!("insights.day.{}", m - 7)));
        let slot = a.x - left.x - px(8.);
        assert!(slot > px(0.), "columns share the width, 8 apart");
        assert_eq!(bounds(cx, w, &format!("insights.day.{m}")).size.width, px(3.));
    }

    // parity: INS-094
    #[flow_ui::gpui::test]
    async fn the_longest_dictation_is_grouped(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "insights.tab.voice");
        w.update(cx, |p, _, cx| {
            p.insights.as_mut().unwrap().longest_words = 12_345;
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        assert_saw(&["LONGEST DICTATION", &grouped(12_345)]);
        assert_ne!(grouped(12_345), "12345", "grouped for the locale");
    }

    // parity: INS-008
    #[flow_ui::gpui::test]
    async fn the_tab_starts_on_usage_and_is_not_remembered(cx: &mut TestAppContext) {
        let w = open(cx);
        assert_saw(&["WORDS PER MINUTE"]);
        assert!(!saw("TIME SPOKEN"));
        click(cx, w, "insights.tab.voice");
        assert_saw(&["TIME SPOKEN"]);
        let again = cx.add_window(|w, cx| InsightsPage::new(w, cx));
        frame(cx, again);
        assert_saw(&["WORDS PER MINUTE"]);
        assert!(!saw("TIME SPOKEN"));
    }

    // parity: INS-013
    /// Every zero the row names, drawn from a really empty store.
    #[flow_ui::gpui::test]
    async fn a_store_with_no_rows_shows_every_zero(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute("DELETE FROM transcriptions", []).unwrap());
        let w = cx.add_window(|w, cx| InsightsPage::new(w, cx));
        frame(cx, w);
        assert_saw(&["0 day streak", "\u{2013}", "0 words corrected", "0 dictionary fixes", "0 words", "0 dictations", "TOTAL APPS USED | 0", "0 OTHER TASKS", "0 DOCUMENTS"]);
        assert!(flow_ui::probe::seen().iter().filter(|t| t.as_str() == "0%").count() >= 6, "six 0% bars");
        click(cx, w, "insights.tab.voice");
        assert_saw(&["0s"]);
    }

    // parity: INS-046 INS-047 INS-048 INS-049 INS-050 INS-051
    /// All six rows through the page: the caps label and its symbol, in the drawn tree.
    #[flow_ui::gpui::test]
    async fn every_category_row_draws_its_label_and_symbol(cx: &mut TestAppContext) {
        let _w = open(cx);
        let symbols = flow_ui::probe::symbols();
        for (label, symbol) in [("OTHER TASKS", "infinity"), ("AI PROMPTS", "cpu"), ("PERSONAL MESSAGES", "bubble.left"), ("EMAILS", "envelope"), ("WORK MESSAGES", "text.bubble"), ("DOCUMENTS", "doc.text")] {
            assert_saw(&[label]);
            assert!(symbols.iter().any(|s| s == symbol), "{symbol}");
        }
    }

    // parity: INS-061 INS-084 INS-104 INS-103
    /// The tips' copy from the page's real hover, with the fallback app name.
    #[flow_ui::gpui::test]
    async fn tips_read_their_counts_and_top_app(cx: &mut TestAppContext) {
        let w = open(cx);
        let i = w.update(cx, |t, _, _| t.insights.clone().unwrap()).unwrap();
        // A category with dictations: its words, and "Most in".
        let (cat, _) = *i.category_rows().iter().find(|(c, n)| *n > 0 && i.top_app_in(*c).is_some()).unwrap();
        hover(cx, w, &format!("insights.bar.{}", cat.label()));
        let words = i.category_words[Category::ALL.iter().position(|c| *c == cat).unwrap()];
        assert_saw(&[&counted(words, "word", "words"), &format!("Most in {}", fallback_app_name(i.top_app_in(cat).unwrap()))]);
        // None at count 0.
        w.update(cx, |t, _, cx| {
            t.insights.as_mut().unwrap().categories[Category::ALL.iter().position(|c| *c == Category::Work).unwrap()] = 0;
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        hover(cx, w, &format!("insights.bar.{}", Category::Work.label()));
        assert_eq!(tip_state(cx, w), None);
        // A day with a top app, and one without. Only the first two weekday rows have area to hover.
        let day = monday(cx);
        let mut usage = Day::default();
        usage.words = 7;
        usage.apps.insert("md.obsidian".into(), 7);
        let held = usage.clone();
        w.update(cx, |t, _, cx| {
            t.insights.as_mut().unwrap().days.insert(day, held);
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        hover(cx, w, &format!("insights.day.{day}"));
        assert_saw(&["Total words", "7", "Total apps used", "Top app", &fallback_app_name("md.obsidian")]);
        let empty_day = w.update(cx, |t, _, cx| columns(local(cx.global::<Core>().db.as_ref().unwrap(), now_ms()).day_number(), t.page)[0]).unwrap();
        assert!(!i.days.contains_key(&empty_day));
        hover(cx, w, &format!("insights.day.{empty_day}"));
        assert_saw(&["Total words"]);
        assert!(!saw("Top app"));
        // Hours: active with "Most in", then the empty hour's range.
        click(cx, w, "insights.tab.voice");
        let h = (0..24).find(|h| i.hours[*h] > 0 && !i.hour_apps[*h].is_empty()).unwrap();
        hover(cx, w, &format!("insights.hour.{h}"));
        let range = format!("{} – {}", hour_time(h as i64), hour_time((h as i64 + 1) % 24));
        assert_saw(&[&counted(i.hours[h], "word", "words"), &range, &counted(i.hour_dictations[h], "dictation", "dictations"), &format!("Most in {}", fallback_app_name(top_of(&i.hour_apps[h]).unwrap()))]);
        let quiet = (0..24).find(|h| i.hours[*h] == 0).unwrap();
        hover(cx, w, &format!("insights.hour.{quiet}"));
        let range = format!("{} – {}", hour_time(quiet as i64), hour_time((quiet as i64 + 1) % 24));
        assert_saw(&["No dictation", &range]);
    }

    // parity: INS-083
    /// Width, the styles of date, label and value, and the shadow the view paints.
    #[flow_ui::gpui::test]
    async fn the_day_tip_has_swifts_type_and_shadow(cx: &mut TestAppContext) {
        let w = open(cx);
        let m = monday(cx);
        hover(cx, w, &format!("insights.day.{m}"));
        let ink = cx.update(|cx| pal(cx).ink);
        let date = flow_ui::probe::style_of(&long_date(m)).unwrap();
        assert_eq!((date.size, date.weight, date.color), (13., 500., ink));
        let name = flow_ui::probe::style_of("Total words").unwrap();
        assert_eq!((name.size, name.weight, name.color), (12.5, 400., ink));
        assert_eq!(bounds(cx, w, "insights.tip").size.width, px(250.));
        let s = day_tip_shadow();
        assert_eq!((s.color, s.offset, s.blur_radius), (flow_ui::gpui::black().opacity(0.12), point(px(0.), px(5.)), px(14.)));
    }

    // parity: INS-086 INS-087
    /// 13 medium over 11.5, `surface` on `ink`; clamped at either edge, last anchor wins.
    #[flow_ui::gpui::test]
    async fn a_note_tip_has_its_type_and_clamps_at_both_edges(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "insights.tab.voice");
        let surface = cx.update(|cx| pal(cx).surface);
        let i = w.update(cx, |t, _, _| t.insights.clone().unwrap()).unwrap();
        let h = (0..24).find(|h| i.hours[*h] == 0).unwrap();
        hover(cx, w, &format!("insights.hour.{h}"));
        let title = flow_ui::probe::style_of("No dictation").unwrap();
        assert_eq!((title.size, title.weight, title.color), (13., 500., surface));
        let range = format!("{} – {}", hour_time(h as i64), hour_time((h as i64 + 1) % 24));
        let detail = flow_ui::probe::style_of(&range).unwrap();
        assert_eq!((detail.size, detail.color), (11.5, surface.opacity(0.75)));
        // The arrow is 12 by 6 and centered on the target.
        let (arrow, target) = (bounds(cx, w, "insights.tip.arrow"), bounds(cx, w, &format!("insights.hour.{h}")));
        assert_eq!((arrow.size.width, arrow.size.height), (px(12.), px(6.)));
        assert!((arrow.center().x - target.center().x).abs() < px(0.5), "{arrow:?} over {target:?}");
        // Last anchor wins: the tip replaces the one before.
        hover(cx, w, "insights.hour.23");
        let tip = bounds(cx, w, "insights.tip");
        let layer = w.update(cx, |t, _, _| t.anchors.borrow()[LAYER]).unwrap();
        assert_eq!(tip.right(), layer.right(), "clamped at the right");
        assert_eq!(tip.bottom() + px(8.), bounds(cx, w, "insights.hour.23").top().max(tip.bottom() + px(8.)));
        hover(cx, w, "insights.hour.0");
        assert_eq!(bounds(cx, w, "insights.tip").left(), layer.left(), "clamped at the left");
    }

    // parity: INS-088
    /// The tip's text is the target's accessibility value.
    #[flow_ui::gpui::test]
    async fn targets_expose_their_tip_as_a_value(cx: &mut TestAppContext) {
        let w = open(cx);
        let value = |cx: &mut TestAppContext, id: String| cx.update_window(w.into(), |_, win, _| win.find(SharedString::from(id)).value().map(str::to_string)).unwrap();
        assert_eq!(value(cx, "insights.info.pace".into()).as_deref(), Some("Your dictation pace, against typing at 40 words per minute"));
        let m = monday(cx);
        let i = w.update(cx, |t, _, _| t.insights.clone().unwrap()).unwrap();
        let (words, apps, top) = i.days.get(&m).map_or((0, 0, None), |u| (u.words, u.apps.len() as i64, u.top_app().map(fallback_app_name)));
        assert_eq!(value(cx, format!("insights.day.{m}")), Some(day_spoken(m, words, apps, top.as_deref())));
    }

    // parity: INS-086
    /// Headless frames can't read paint, so this reads the style the bubble was built with.
    #[flow_ui::gpui::test]
    async fn a_note_bubble_has_its_padding_radius_spacing_and_ink(cx: &mut TestAppContext) {
        let _ = open(cx);
        let ink = cx.update(|cx| pal(cx).ink);
        let mut bubble = cx.update(|cx| note_bubble("t".into(), None, cx));
        let s = bubble.style();
        let length = |l: Option<DefiniteLength>| l.expect("set");
        assert_eq!((length(s.padding.left), length(s.padding.right)), (px(11.).into(), px(11.).into()));
        assert_eq!((length(s.padding.top), length(s.padding.bottom)), (px(8.).into(), px(8.).into()));
        assert_eq!(s.corner_radii.top_left, Some(px(7.).into()));
        assert_eq!(s.gap.height, Some(px(3.).into()));
        assert_eq!(s.background, Some(ink.into()));
    }

    // parity: INS-071 INS-073 INS-074 INS-076 INS-070
    /// Labels, symbols, disabled state, and which weeks a page shows.
    #[flow_ui::gpui::test]
    async fn chevrons_read_their_label_and_disable_at_the_ends(cx: &mut TestAppContext) {
        let w = open(cx);
        assert_eq!(label_of(cx, w, "insights.earlierWeeks").as_deref(), Some("Earlier weeks"));
        assert_eq!(label_of(cx, w, "insights.laterWeeks").as_deref(), Some("Later weeks"));
        let symbols = flow_ui::probe::symbols();
        assert!(symbols.iter().any(|s| s == "chevron.left") && symbols.iter().any(|s| s == "chevron.right"));
        let off = |cx: &mut TestAppContext, id: &'static str| cx.update_window(w.into(), |_, win, _| win.find(id).disabled()).unwrap();
        assert_eq!(off(cx, "insights.laterWeeks"), Some(true), "page 0");
        assert_eq!(off(cx, "insights.earlierWeeks"), Some(true), "no older day");
        let m = monday(cx);
        let older = m - 18 * 7 - 1;
        w.update(cx, |t, _, cx| {
            t.insights.as_mut().unwrap().days.insert(older, Default::default());
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        assert_ne!(off(cx, "insights.earlierWeeks"), Some(true));
        // The newest column holds this week; a page back holds the week 19 before it.
        assert!(has(cx, w, &format!("insights.day.{m}")));
        click(cx, w, "insights.earlierWeeks");
        assert!(!has(cx, w, &format!("insights.day.{m}")));
        assert!(has(cx, w, &format!("insights.day.{}", m - 19 * 7)));
        assert!(has(cx, w, &format!("insights.day.{}", m - 37 * 7)));
        assert_ne!(off(cx, "insights.laterWeeks"), Some(true));
        assert_eq!(off(cx, "insights.earlierWeeks"), Some(true), "nothing older now");
    }

    // parity: INS-007 INS-006
    #[flow_ui::gpui::test]
    async fn tab_items_read_selected_or_not(cx: &mut TestAppContext) {
        let w = open(cx);
        let (ink, muted) = cx.update(|cx| (pal(cx).ink, pal(cx).muted));
        let on = flow_ui::probe::style_of("Your usage").unwrap();
        let off = flow_ui::probe::style_of("Your voice").unwrap();
        assert_eq!((on.size, on.weight, on.color), (15., 500., ink));
        assert_eq!((off.size, off.weight, off.color), (15., 400., muted));
        assert_eq!(label_of(cx, w, "insights.tab.usage").as_deref(), Some("Your usage"));
        click(cx, w, "insights.tab.voice");
        assert_eq!(flow_ui::probe::style_of("Your voice").unwrap().color, ink);
        assert_eq!(flow_ui::probe::style_of("Your usage").unwrap().color, muted);
    }
}
