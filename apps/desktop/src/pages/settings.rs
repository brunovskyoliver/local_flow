use flow_ui::prelude::*;

pub struct SettingsPage;

impl SettingsPage {
    pub fn new(_: &mut Window, _: &mut Context<Self>) -> Self {
        SettingsPage
    }
}

impl Render for SettingsPage {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child(t("Settings"))
    }
}
