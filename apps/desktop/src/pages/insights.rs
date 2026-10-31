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

#[derive(Clone, Copy, PartialEq, Debug)]
enum Tab {
    Usage,
    Voice,
}

/// `InsightTip`: a dark note, or a light card for a calendar day.
#[derive(Clone, PartialEq, Debug)]
enum Tip {
    Note {
        title: String,
        detail: Option<String>,
    },
    Day {
        day: i64,
        words: i64,
        apps: i64,
        top: Option<String>,
    },
}

impl Tip {
    fn note(title: impl Into<String>) -> Tip {
        Tip::Note {
            title: title.into(),
            detail: None,
        }
    }
    fn spoken(&self) -> String {
        match self {
            Tip::Note { title, detail } => note_spoken(title, detail.as_deref()),
            Tip::Day {
                day,
                words,
                apps,
                top,
            } => day_spoken(*day, *words, *apps, top.as_deref()),
        }
    }
}

type Anchors = Rc<RefCell<HashMap<String, Bounds<Pixels>>>>;
const LAYER: &str = "layer";
/// Puts 11.5 caps on a 29 heading's first baseline; `Txt` reports no baseline to flex.
const CAPS_ON_HEADING: f32 = 15.5;
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
    tip: Option<(String, Tip)>,
    anchors: Anchors,
    _session_sub: Subscription,
}

// ponytail: `AppName.display` needs NSWorkspace; the fallback is Swift's for an uninstalled app.
fn app_name(bundle: &str) -> String {
    fallback_app_name(bundle)
}

impl InsightsPage {
    pub fn new(_: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut shown = cx.try_global::<Session>().map(|s| s.selection);
        let mut revision = cx.try_global::<Session>().map_or(0, |s| s.history_revision);
        // `.task`: refreshes on every appearance, and not while shown.
        let _session_sub = cx.observe_global::<Session>(move |this, cx| {
            let now = Some(cx.global::<Session>().selection);
            if now != shown && now == Some(Page::Insights) && cx.global::<Core>().scenario.is_none()
            {
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
        let mut page = InsightsPage {
            insights: None,
            error: None,
            tab: Tab::Usage,
            page: 0,
            hovered_hour: None,
            tip: None,
            anchors: Default::default(),
            _session_sub,
        };
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
        let mut row = h_flex()
            .w_full()
            .gap(px(16.))
            .pt(px(26.))
            .relative()
            .items_center();
        for (item, label, id) in [
            (Tab::Usage, "Your usage", "insights.tab.usage"),
            (Tab::Voice, "Your voice", "insights.tab.voice"),
        ] {
            let on = self.tab == item;
            row = row.child(
                FlowButton::new(id, ButtonKind::Plain, label)
                    .a11y_selected(on)
                    .content(
                        v_flex()
                            .gap(px(6.))
                            .child(
                                t(label)
                                    .font(15., if on { 500. } else { 400. })
                                    .color(if on { p.ink } else { p.muted })
                                    .a11y_hidden(),
                            )
                            .child(div().h(px(2.)).w_full().when(on, |d| d.bg(p.ink))),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.tab = item;
                        this.tip = None;
                        cx.notify();
                    })),
            );
        }
        row.child(
            div()
                .absolute()
                .bottom_0()
                .left_0()
                .right_0()
                .h(px(1.))
                .bg(p.line),
        )
    }

    /// `.insightTip`: reports its bounds and hover; the hover detail is also its accessibility value.
    fn target(
        &self,
        id: String,
        tip: Option<Tip>,
        child: impl IntoElement,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
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
                if let Some(h) = hover_key
                    .strip_prefix("insights.hour.")
                    .and_then(|h| h.parse().ok())
                {
                    if *inside {
                        this.hovered_hour = Some(h);
                    } else if this.hovered_hour == Some(h) {
                        this.hovered_hour = None;
                    }
                }
                cx.notify();
            }))
    }

    fn info(&self, id: &str, text: &str, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let m = pal(cx).muted;
        self.target(
            format!("insights.info.{id}"),
            Some(Tip::note(text)),
            icon("info.circle", 13., m),
            cx,
        )
        .aria_label(text.to_string())
        .test_support()
    }

    // ponytail: the long label's 9.8 stands in for `.minimumScaleFactor`, measured at 1180 wide; compact cards fit it unscaled.
    fn stat(
        &self,
        value: String,
        label: &str,
        help: Option<(&str, &str)>,
        cx: &mut Context<Self>,
    ) -> Div {
        let info = help.map(|(id, h)| self.info(id, h, cx));
        v_flex()
            .gap(px(8.))
            .child(
                t(value)
                    .font(28., 500.)
                    .mono_digits()
                    .tracking(-0.5)
                    .lines(1),
            )
            .child(
                h_flex()
                    .gap(px(6.))
                    .child(caps(
                        label,
                        pal(cx).muted,
                        if label.len() > 20 && !cx.global::<Flow>().compact {
                            9.8
                        } else {
                            11.5
                        },
                    ))
                    .when_some(info, |d, i| d.child(i)),
            )
    }

    fn usage(&self, i: &Insights, cx: &mut Context<Self>) -> Div {
        let pace = insight_card(cx)
            .id("insights.pace")
            .child(
                self.stat(
                    i.words_per_minute()
                        .map_or("–".to_string(), |w| w.to_string()),
                    "Words per minute",
                    Some((
                        "pace",
                        "Your dictation pace, against typing at 40 words per minute",
                    )),
                    cx,
                ),
            )
            .child(dial(
                i.words_per_minute().unwrap_or(0) as f32 / 200.,
                versus_typing(i.words_per_minute()),
                cx,
            ));
        let row =
            |value: i64, label: &str, id: &str, help: &str, this: &Self, cx: &mut Context<Self>| {
                h_flex()
                    .w_full()
                    .justify_between()
                    .gap(px(6.))
                    .child(t(format!("{} {label}", grouped(value))).size(14.5).lines(1))
                    .child(this.info(id, help, cx))
            };
        let fixes = insight_card(cx)
            .id("insights.fixes")
            .child(self.stat(
                grouped(i.words_corrected + i.dictionary_fixes),
                "Fixes made by LocalFlow",
                None,
                cx,
            ))
            .child(rule(cx))
            .child(
                v_flex()
                    .w_full()
                    .gap(px(12.))
                    .child(row(
                        i.words_corrected,
                        "words corrected",
                        "corrected",
                        "Words your rewrites changed before inserting",
                        self,
                        cx,
                    ))
                    .child(row(
                        i.dictionary_fixes,
                        "dictionary fixes",
                        "fixes",
                        "Words spelled from your dictionary",
                        self,
                        cx,
                    )),
            );
        let p = pal(cx);
        let volume = insight_card(cx)
            .id("insights.volume")
            .child(self.stat(grouped(i.total_words), "Total words dictated", None, cx))
            .child(rule(cx))
            .child(
                h_flex()
                    .w_full()
                    .items_end()
                    .justify_between()
                    .gap(px(8.))
                    .child(
                        v_flex()
                            .gap(px(8.))
                            .child(
                                h_flex()
                                    .gap(px(8.))
                                    .child(div().w(px(21.)).child(icon(
                                        "desktopcomputer",
                                        15.,
                                        p.ink,
                                    )))
                                    .child(t("Desktop").size(14.5)),
                            )
                            .child(t(format!("{} words", grouped(i.total_words))).size(14.5)),
                    )
                    .child(
                        t(format!("{} dictations", grouped(i.dictations)))
                            .size(14.5)
                            .color(p.muted),
                    ),
            );
        let apps = self.apps(i, cx);
        let streak = self.streak(i, cx);
        v_flex()
            .w_full()
            .gap(px(24.))
            .child(
                card_row(cx)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_row()
                            .items_stretch()
                            .gap(px(24.))
                            .child(pace)
                            .child(fixes),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .items_stretch()
                            .child(volume),
                    ),
            )
            .child(card_row(cx).child(apps).child(streak))
    }

    fn voice(&self, i: &Insights, cx: &mut Context<Self>) -> Div {
        let a =
            insight_card(cx).child(self.stat(talk_time(i.spoken_seconds), "Time spoken", None, cx));
        let b = insight_card(cx).child(self.stat(
            grouped(i.average_words()),
            "Words per dictation",
            None,
            cx,
        ));
        let c = insight_card(cx).child(self.stat(
            grouped(i.longest_words),
            "Longest dictation",
            None,
            cx,
        ));
        let hours = self.hours(i, cx);
        v_flex()
            .w_full()
            .gap(px(24.))
            .child(card_row(cx).child(a).child(b).child(c))
            .child(hours)
    }

    fn apps(&self, i: &Insights, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = pal(cx);
        let compact = cx.global::<Flow>().compact;
        let mut rows = v_flex().gap(px(16.)).pt(px(25.));
        for (n, (cat, count)) in i.category_rows().into_iter().enumerate() {
            let share = if i.dictations == 0 {
                0.
            } else {
                count as f32 / i.dictations as f32
            };
            let (fill, label) = if count == 0 {
                (p.data_quiet, p.on_data_quiet)
            } else if n == 0 {
                (p.data_strong, p.on_data_strong)
            } else {
                (p.data_scale[1], p.on_data)
            };
            let tip = (count > 0).then(|| {
                let words =
                    i.category_words[Category::ALL.iter().position(|c| *c == cat).unwrap_or(0)];
                Tip::Note {
                    title: counted(words, "word", "words"),
                    detail: i
                        .top_app_in(cat)
                        .map(|a| format!("Most in {}", app_name(a))),
                }
            });
            let bar = div()
                .w(px((share * if compact { 150. } else { 300. }).max(35.)))
                .h(px(28.))
                .flex()
                .items_center()
                .justify_center()
                .bg(fill)
                .rounded(px(4.))
                .child(
                    t(format!("{}%", (share * 100.).round() as i64))
                        .font(12., 500.)
                        .mono_digits()
                        .tracking(0.7)
                        .color(label),
                );
            rows = rows.child(
                h_flex()
                    .gap(px(14.))
                    .child(div().w(px(24.)).flex().justify_center().child(icon(
                        cat.symbol(),
                        18.,
                        p.ink,
                    )))
                    .child(self.target(format!("insights.bar.{}", cat.label()), tip, bar, cx))
                    .child(caps(
                        &format!("{} {}", grouped(count), cat.label()),
                        p.ink,
                        12.5,
                    )),
            );
        }
        insight_card(cx)
            .id("insights.apps")
            .child(
                h_flex()
                    .w_full()
                    .justify_between()
                    .items_start()
                    .gap(px(8.))
                    .child(t("Desktop usage").font(29., 500.).tracking(-0.6).lines(1))
                    .child(div().pt(px(CAPS_ON_HEADING)).child(caps(
                        &format!("Total apps used | {}", i.apps_used),
                        p.ink,
                        11.5,
                    ))),
            )
            .child(rows)
    }

    fn streak(&self, i: &Insights, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = pal(cx);
        let today = cx
            .global::<Core>()
            .db
            .as_ref()
            .map_or(0, |db| local(db, now_ms()).day_number());
        let streaks = streaks(&i.days, today);
        let cols = columns(today, self.page);
        let limits = i.thresholds();
        let earliest = i.days.keys().next().copied();
        let chevron = |id: &'static str,
                       symbol: &'static str,
                       label: &'static str,
                       enabled: bool,
                       delta: i64,
                       cx: &mut Context<Self>| {
            FlowButton::new(id, ButtonKind::Plain, label)
                .disabled_opacity(0.35)
                .disabled(!enabled)
                .content(
                    div()
                        .size(px(18.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(icon(symbol, 12., p.muted)),
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.page += delta;
                    this.tip = None;
                    cx.notify();
                }))
        };
        let mut months = h_flex().w_full().gap(px(8.)).relative().pb(px(14.)).child(
            div()
                .w(px(34.))
                .flex_none()
                .flex()
                .items_start()
                .child(chevron(
                    "insights.earlierWeeks",
                    "chevron.left",
                    "Earlier weeks",
                    earliest.is_some_and(|e| e < cols[0]),
                    1,
                    cx,
                )),
        );
        for w in &cols {
            // The label overflows its column, as `.fixedSize()` does in Swift's overlay.
            months = months.child(div().flex_1().min_w_0().h(px(16.)).relative().when_some(
                month_label(*w),
                |d, l: String| {
                    d.child(
                        div()
                            .absolute()
                            .left_0()
                            .top_0()
                            .w(px(30.))
                            .child(t(l).size(11.).color(p.muted)),
                    )
                },
            ));
        }
        months = months.child(div().absolute().right_0().top_0().bg(p.card).child(chevron(
            "insights.laterWeeks",
            "chevron.right",
            "Later weeks",
            self.page > 0,
            -1,
            cx,
        )));
        let mut grid = v_flex().w_full().gap(px(8.)).pt(px(24.)).child(months);
        for wd in 0..7i64 {
            let mut r = h_flex().w_full().h(px(13.)).gap(px(8.)).child(
                div()
                    .w(px(34.))
                    .flex_none()
                    .child(t(weekday_label(wd)).size(11.).color(p.muted)),
            );
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
                let tip = (day <= today).then(|| Tip::Day {
                    day,
                    words: count,
                    apps: usage.map_or(0, |u| u.apps.len() as i64),
                    top: usage.and_then(|u| u.top_app()).map(app_name),
                });
                let cell = div()
                    .size(px(HEAT_DOT[wd as usize]))
                    .rounded(px(3.))
                    .bg(fill)
                    .when(
                        HEAT_DOT[wd as usize] > 0. && streaks.current_days.contains(&day),
                        |d| {
                            d.border(px(1.5_f32.min(HEAT_DOT[wd as usize] / 2.)))
                                .border_color(p.streak_outline)
                        },
                    );
                r = r.child(
                    div().flex_1().min_w_0().flex().justify_center().child(
                        self.target(format!("insights.day.{day}"), tip, cell, cx)
                            .test_support(),
                    ),
                );
            }
            grid = grid.child(r);
        }
        let swatch = |c: Hsla| div().size(px(16.)).rounded(px(3.)).bg(c);
        let mut legend = h_flex()
            .w_full()
            .gap(px(8.))
            .pt(px(26.))
            .child(t("More").size(13.).color(p.muted));
        for c in p.data_scale {
            legend = legend.child(swatch(c));
        }
        legend = legend
            .child(t("Less").size(13.).color(p.muted))
            .child(div().flex_1())
            .child(
                div()
                    .size(px(16.))
                    .rounded(px(3.))
                    .border(px(1.2))
                    .border_color(p.streak_outline),
            )
            .child(t("Current streak").size(13.).color(p.muted));
        insight_card(cx)
            .id("insights.streak")
            .child(
                h_flex()
                    .w_full()
                    .justify_between()
                    .items_start()
                    .gap(px(8.))
                    .child(
                        t(format!("{} day streak", streaks.current))
                            .font(29., 500.)
                            .tracking(-0.6)
                            .lines(1),
                    )
                    .child(div().pt(px(CAPS_ON_HEADING)).child(caps(
                        &format!(
                            "Longest streak | {} {}",
                            streaks.longest,
                            if streaks.longest == 1 { "day" } else { "days" }
                        ),
                        p.ink,
                        11.5,
                    ))),
            )
            .child(grid)
            .child(legend)
    }

    fn hours(&self, i: &Insights, cx: &mut Context<Self>) -> Stateful<Div> {
        let p = pal(cx);
        let peak = i.hours.iter().copied().max().unwrap_or(0).max(1);
        let mut bars = h_flex()
            .w_full()
            .h(px(130.))
            .items_end()
            .gap(px(6.))
            .mt(px(26.));
        for h in 0..24usize {
            let fill = if i.hours[h] == 0 {
                p.heat_empty
            } else {
                match self.hovered_hour {
                    None => p.data_scale[1],
                    Some(x) if x == h => p.data_scale[0],
                    Some(_) => p.data_scale[2],
                }
            };
            let height = (130. * i.hours[h] as f32 / peak as f32).max(5.);
            let bar = div().w_full().h(px(height)).rounded(px(3.)).bg(fill);
            let target = self
                .target(
                    format!("insights.hour.{h}"),
                    Some(hour_tip(i, h)),
                    div().w_full().h(px(130.)).flex().items_end().child(bar),
                    cx,
                )
                .test_support()
                .flex_1()
                .min_w_0();
            bars = bars.child(target);
        }
        let mut labels = h_flex().w_full().pt(px(10.));
        for h in [0, 6, 12, 18] {
            labels = labels.child(
                div()
                    .flex_1()
                    .child(t(hour_label(h)).size(12.).color(p.muted)),
            );
        }
        insight_card(cx)
            .id("insights.hours")
            .child(t("When you dictate").font(29., 500.).tracking(-0.6))
            .child(bars)
            .child(labels)
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
                let long = detail
                    .iter()
                    .flat_map(|d| d.split('\n'))
                    .map(|l| l.chars().count() as f32 * 6.)
                    .fold(title.chars().count() as f32 * 7., f32::max);
                (
                    v_flex()
                        .gap(px(3.))
                        .px(px(11.))
                        .py(px(8.))
                        .bg(p.ink)
                        .rounded(px(7.))
                        .child(t(title.clone()).font(13., 500.).color(p.surface))
                        .when_some(detail.clone(), |d, x| {
                            d.child(t(x).size(11.5).color(p.surface).opacity(0.75))
                        })
                        .into_any_element(),
                    long + 22.,
                )
            }
            Tip::Day {
                day,
                words,
                apps,
                top,
            } => {
                let row = |l: &str, v: String| {
                    h_flex()
                        .w_full()
                        .justify_between()
                        .gap(px(12.))
                        .child(t(l.to_string()).size(12.5).color(p.ink))
                        .child(t(v).font(12.5, 500.).color(p.ink).lines(1))
                };
                (
                    v_flex()
                        .w(px(250.))
                        .p(px(14.))
                        .bg(p.surface)
                        .rounded(px(10.))
                        .border_1()
                        .border_color(p.card_line)
                        .shadow_lg()
                        .child(
                            div()
                                .pb(px(14.))
                                .child(t(long_date(*day)).font(13., 500.).color(p.ink)),
                        )
                        .child(
                            v_flex()
                                .gap(px(10.))
                                .child(row("Total words", grouped(*words)))
                                .child(row("Total apps used", grouped(*apps)))
                                .when_some(top.clone(), |d, a| d.child(row("Top app", a))),
                        )
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
            div()
                .absolute()
                .left(px(mid))
                .w(px(0.))
                .flex()
                .justify_center()
                .child(div().flex_none().child(content))
        };
        let arrow = matches!(tip, Tip::Note { .. }).then(|| {
            // `TipArrow`: a 12 by 6 triangle under the note.
            let ink = p.ink;
            canvas(
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
            )
            .absolute()
            .left(px(mid - 6.))
            .bottom(px(bottom - 6.5))
            .w(px(12.))
            .h(px(6.))
        });
        Some(
            div()
                .absolute()
                .inset_0()
                .child(wrap.bottom(px(bottom)))
                .children(arrow),
        )
    }
}

fn hour_tip(i: &Insights, h: usize) -> Tip {
    let range = format!(
        "{} – {}",
        hour_time(h as i64),
        hour_time((h as i64 + 1) % 24)
    );
    let words = i.hours[h];
    if words == 0 {
        return Tip::Note {
            title: "No dictation".into(),
            detail: Some(range),
        };
    }
    let mut detail = format!(
        "{range} · {}",
        counted(i.hour_dictations[h], "dictation", "dictations")
    );
    if let Some(top) = top_of(&i.hour_apps[h]) {
        detail.push_str(&format!("\nMost in {}", app_name(top)));
    }
    Tip::Note {
        title: counted(words, "word", "words"),
        detail: Some(detail),
    }
}

fn caps(text: &str, color: Hsla, size: f32) -> Txt {
    t(text.to_uppercase())
        .font(size, 500.)
        .tracking(size * 0.12)
        .color(color)
        .lines(1)
}

fn insight_card(cx: &App) -> Div {
    let p = pal(cx);
    v_flex()
        .flex_1()
        .min_w_0()
        .items_start()
        .p(px(18.))
        .bg(p.card)
        .rounded(px(6.))
        .border_1()
        .border_color(p.card_line)
}

fn rule(cx: &App) -> Div {
    div()
        .w_full()
        .py(px(16.))
        .child(div().h(px(1.)).w_full().bg(pal(cx).rule.opacity(0.6)))
}

/// `cardRow`: side by side with equal heights, stacked in a compact window.
fn card_row(cx: &App) -> Div {
    let compact = cx.global::<Flow>().compact;
    div()
        .w_full()
        .flex()
        .gap(px(24.))
        .items_stretch()
        .when(compact, |d| d.flex_col())
        .when(!compact, |d| d.flex_row())
}

/// `Dial`: a little over a half circle with round caps.
fn dial(fraction: f32, center: String, cx: &App) -> impl IntoElement + use<> {
    let p = pal(cx);
    let (track, fill) = (p.heat_empty, p.data_strong);
    let fraction = fraction.clamp(0., 1.);
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
        let mut col = v_flex()
            .w_full()
            .child(t("Insights").font(26., 500.).tracking(-0.4))
            .child(self.tabs(cx));
        if let Some(e) = self.error.clone() {
            col = col.child(div().pt(px(24.)).child(t(e).size(13.).color(p.warning)));
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
        cx.update_window(w.into(), |_, w, cx| w.render_frame(cx))
            .unwrap();
    }

    fn click(cx: &mut TestAppContext, w: WindowHandle<InsightsPage>, id: &'static str) {
        cx.update_window(w.into(), |_, win, cx| win.click(id, cx))
            .unwrap();
        frame(cx, w);
    }

    // parity: INS-003 INS-006 INS-023 INS-029 INS-031 INS-032 INS-038 INS-039 INS-043 INS-045 INS-051 INS-064 INS-068 INS-089
    #[flow_ui::gpui::test]
    async fn usage_tab_shows_every_card(cx: &mut TestAppContext) {
        let _w = open(cx);
        assert_saw(&[
            "Insights",
            "Your usage",
            "Your voice",
            "WORDS PER MINUTE",
            "vs typing",
            "FIXES MADE BY LOCALFLOW",
            "words corrected",
            "dictionary fixes",
            "TOTAL WORDS DICTATED",
            "Desktop",
            "dictations",
            "Desktop usage",
            "TOTAL APPS USED | ",
            "DOCUMENTS",
            "day streak",
            "LONGEST STREAK | ",
            "Mon",
            "Sun",
            "More",
            "Less",
            "Current streak",
        ]);
    }

    // parity: INS-008 INS-016 INS-090 INS-092 INS-094 INS-096 INS-100 INS-102 INS-103 INS-104
    #[flow_ui::gpui::test]
    async fn voice_tab_shows_stats_and_hours(cx: &mut TestAppContext) {
        let w = open(cx);
        click(cx, w, "insights.tab.voice");
        assert_saw(&[
            "TIME SPOKEN",
            "WORDS PER DICTATION",
            "LONGEST DICTATION",
            "When you dictate",
            "00",
            "18",
        ]);
        assert!(!saw("Desktop usage"));
        // The seed is relative to now, so look the hours up.
        let hours = w
            .update(cx, |this, _, _| this.insights.as_ref().unwrap().hours)
            .unwrap();
        let empty = hours.iter().position(|h| *h == 0).unwrap();
        let active = hours.iter().position(|h| *h > 0).unwrap();
        for (hour, text) in [(empty, "No dictation"), (active, " word")] {
            let id = SharedString::from(format!("insights.hour.{hour}"));
            cx.update_window(w.into(), |_, win, cx| win.hover(id, cx))
                .unwrap();
            frame(cx, w);
            w.update(cx, |this, _, _| assert_eq!(this.hovered_hour, Some(hour)))
                .unwrap();
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
            this.insights
                .as_mut()
                .unwrap()
                .days
                .insert(1, Default::default());
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
        cx.update_window(w.into(), |_, win, cx| win.hover(id, cx))
            .unwrap();
        frame(cx, w);
        frame(cx, w);
    }

    fn bounds(cx: &mut TestAppContext, w: WindowHandle<InsightsPage>, id: &str) -> Bounds<Pixels> {
        let id = SharedString::from(id.to_string());
        cx.update_window(w.into(), |_, win, _| win.find(id).bounds())
            .unwrap()
    }

    fn monday(cx: &mut TestAppContext) -> i64 {
        cx.update(|cx| {
            week_start(local(cx.global::<Core>().db.as_ref().unwrap(), now_ms()).day_number())
        })
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
        let (target, tip) = (
            bounds(cx, w, "insights.info.pace"),
            bounds(cx, w, "insights.tip"),
        );
        assert_eq!(tip.bottom() + px(8.), target.top());
        // Near the card's left edge it clamps to the container.
        let layer = w.update(cx, |t, _, _| t.anchors.borrow()[LAYER]).unwrap();
        assert_eq!(tip.left(), layer.left());
        // Leaving removes it.
        cx.update_window(w.into(), |_, win, cx| win.hover("insights.tab.usage", cx))
            .unwrap();
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
        let (target, tip) = (
            bounds(cx, w, "insights.info.fixes"),
            bounds(cx, w, "insights.tip"),
        );
        assert!(
            (f32::from(tip.center().x) - f32::from(target.center().x)).abs() <= 1.,
            "{tip:?} {target:?}"
        );
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
        assert_eq!(
            (Category::Personal.label(), Category::Personal.symbol()),
            ("Personal messages", "bubble.left")
        );
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
        flow_core::history::set_region(flow_core::history::Region {
            date,
            number,
            first_weekday: 1,
        });
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
        let count = |cx: &mut TestAppContext| {
            w.update(cx, |p, _, _| p.insights.as_ref().map(|i| i.dictations))
                .unwrap()
        };
        let before = count(cx);
        let remove = |cx: &mut TestAppContext, n: i64| {
            cx.update(|cx| {
                let db = cx.global::<Core>().db.as_ref().unwrap();
                let id = flow_core::history::seed_id(n);
                let revision = flow_core::history::get(db, &id)
                    .unwrap()
                    .map_or(0, |e| e.revision);
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
}
