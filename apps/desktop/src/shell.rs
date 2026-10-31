//! The main window: onboarding gate, sidebar, content card and router.
use crate::core::Core;
use crate::pages::{Page, dictionary::DictionaryPage, history::HistoryPage, insights::InsightsPage, notetaker::NotetakerPage, onboarding::OnboardingPage, settings::SettingsPage};
use flow_ui::components::prototype_nav;
use flow_ui::prelude::*;

pub struct Shell {
    pub selection: Page,
    meetings: Entity<NotetakerPage>,
    history: Entity<HistoryPage>,
    insights: Entity<InsightsPage>,
    dictionary: Entity<DictionaryPage>,
    settings: Entity<SettingsPage>,
    onboarding: Entity<OnboardingPage>,
}

impl Shell {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let selection = landing_page(cx.global::<Core>());
        Shell {
            selection,
            meetings: cx.new(|cx| NotetakerPage::new(window, cx)),
            history: cx.new(|cx| HistoryPage::new(window, cx)),
            insights: cx.new(|cx| InsightsPage::new(window, cx)),
            dictionary: cx.new(|cx| DictionaryPage::new(window, cx)),
            settings: cx.new(|cx| SettingsPage::new(window, cx)),
            onboarding: cx.new(|cx| OnboardingPage::new(window, cx)),
        }
    }
    pub fn onboarded(cx: &App) -> bool {
        cx.global::<Core>().prefs.int_or("setupVersion", 0) >= 1
    }
}

/// `preferences.landingPage`: Notetaker when `purpose == .meetings`, otherwise Transcriptions.
pub fn landing_page(core: &Core) -> Page {
    if let Some(p) = std::env::var("LOCALFLOW_PAGE").ok().as_deref().and_then(page_named) {
        return p;
    }
    match core.prefs.string("setup.purpose").as_deref() {
        Some("meetings") => Page::Meetings,
        _ => Page::History,
    }
}

fn page_named(n: &str) -> Option<Page> {
    Some(match n {
        "meetings" => Page::Meetings,
        "history" => Page::History,
        "insights" => Page::Insights,
        "dictionary" => Page::Dictionary,
        "settings" => Page::Settings,
        _ => return None,
    })
}

impl Shell {
    fn nav_item(&self, page: Page, title: &'static str, symbol: &'static str, id: &'static str, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let selected = self.selection == page;
        prototype_nav(id, title, symbol, selected, p.tint, p.ink)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.selection = page;
                cx.notify();
            }))
    }

    fn sidebar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        v_flex()
            .h_full()
            .px(px(12.))
            .child(
                h_flex()
                    .gap(px(6.))
                    .px(px(8.))
                    .pt(px(70.))
                    .pb(px(36.))
                    .items_center()
                    .child(icon("chart.bar.xaxis", 19., p.ink))
                    .child(t("LocalFlow").size(22.).bold().tracking(-0.6)),
            )
            .child(
                v_flex()
                    .gap(px(5.))
                    .child(self.nav_item(Page::Meetings, "Notetaker", "record.circle", "navigation.notetaker", cx))
                    .child(self.nav_item(Page::History, "Transcriptions", "mic", "navigation.transcriptions", cx))
                    .child(self.nav_item(Page::Insights, "Insights", "chart.bar", "navigation.insights", cx))
                    .child(self.nav_item(Page::Dictionary, "Dictionary", "text.book.closed", "navigation.dictionary", cx)),
            )
            .child(div().flex_1())
            .child(hairline(cx).mb(px(8.)))
            .child(div().pb(px(12.)).child(self.nav_item(Page::Settings, "Settings", "gearshape", "navigation.settings", cx)))
    }
}

impl Render for Shell {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        if !Self::onboarded(cx) {
            return div().size_full().bg(p.canvas).text_color(p.ink).child(self.onboarding.clone()).into_any_element();
        }
        let page: AnyView = match self.selection {
            Page::Meetings => self.meetings.clone().into(),
            Page::History => self.history.clone().into(),
            Page::Insights => self.insights.clone().into(),
            Page::Dictionary => self.dictionary.clone().into(),
            Page::Settings => self.settings.clone().into(),
        };
        let compact = window.viewport_size().width <= px(800.);
        cx.global_mut::<Flow>().compact = compact;
        h_flex()
            .id("shell.library")
            .size_full()
            .bg(p.canvas)
            .text_color(p.ink)
            .child(div().w(px(if compact { 180. } else { 216. })).h_full().flex_none().child(self.sidebar(cx)))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .pt(px(44.))
                    .pr(px(8.))
                    .pb(px(8.))
                    .child(
                        div()
                            .size_full()
                            .bg(p.surface)
                            .border_1()
                            .border_color(p.line)
                            .rounded(px(16.))
                            .overflow_hidden()
                            .child(page),
                    ),
            )
            .into_any_element()
    }
}
