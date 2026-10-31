use flow_ui::prelude::*;

pub struct NotetakerPage;

impl NotetakerPage {
    pub fn new(_: &mut Window, _: &mut Context<Self>) -> Self {
        NotetakerPage
    }
}

impl Render for NotetakerPage {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child(t("Notetaker"))
    }
}
