use flow_ui::prelude::*;

pub struct HistoryPage;

impl HistoryPage {
    pub fn new(_: &mut Window, _: &mut Context<Self>) -> Self {
        HistoryPage
    }
}

impl Render for HistoryPage {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child(t("History"))
    }
}
