//! The main window: onboarding gate, sidebar, content card and router.
use crate::core::Core;
use crate::pages::{Page, dictionary::DictionaryPage, history::HistoryPage, insights::InsightsPage, notetaker::NotetakerPage, onboarding::OnboardingPage, settings::SettingsPage};
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

impl Render for Shell {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
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
        div().size_full().bg(p.canvas).text_color(p.ink).child(page).into_any_element()
    }
}
