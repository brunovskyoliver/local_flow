use flow_ui::prelude::*;

pub struct InsightsPage;

impl InsightsPage {
    pub fn new(_: &mut Window, _: &mut Context<Self>) -> Self {
        InsightsPage
    }
}

impl Render for InsightsPage {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child(t("Insights"))
    }
}
