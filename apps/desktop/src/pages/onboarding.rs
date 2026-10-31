use flow_ui::prelude::*;

pub struct OnboardingPage;

impl OnboardingPage {
    pub fn new(_: &mut Window, _: &mut Context<Self>) -> Self {
        OnboardingPage
    }
}

impl Render for OnboardingPage {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child(t("Onboarding"))
    }
}
