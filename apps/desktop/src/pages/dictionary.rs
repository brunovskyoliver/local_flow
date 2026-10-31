use flow_ui::prelude::*;

pub struct DictionaryPage;

impl DictionaryPage {
    pub fn new(_: &mut Window, _: &mut Context<Self>) -> Self {
        DictionaryPage
    }
}

impl Render for DictionaryPage {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child(t("Dictionary"))
    }
}
