//! Headless view tests: a real window, seeded in-memory data, fake OS services.
use crate::core::Core;
use flow_ui::prelude::*;
use flow_ui::test::TestAppContext;

/// Boots flow-ui and `Core` in a test context. Change `Core` afterwards through `cx.update`.
pub fn boot(cx: &mut TestAppContext, mode: Mode) {
    flow_ui::probe::start();
    cx.update(|cx| {
        flow_ui::init_test(mode, cx);
        cx.set_global(Core::for_test());
    });
}

/// Whether some text laid out since the last `flow_ui::probe::clear` contains `needle`.
pub fn saw(needle: &str) -> bool {
    flow_ui::probe::seen().iter().any(|t| t.contains(needle))
}

#[track_caller]
pub fn assert_saw(needles: &[&str]) {
    let seen = flow_ui::probe::seen();
    for n in needles {
        assert!(seen.iter().any(|t| t.contains(n)), "{n:?} not rendered; saw {seen:?}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pages::settings::SettingsPage;
    use flow_ui::test::TestWindowExt;

    // A proof the harness works: a real window renders Txt into the probe and finds its text.
    #[flow_ui::gpui::test]
    async fn harness_renders_a_page(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = cx.add_window(|w, cx| SettingsPage::new(w, cx));
        cx.run_until_parked();
        cx.update_window(window.into(), |_, w, cx| w.render_frame(cx)).unwrap();
        assert_saw(&["Settings"]);
    }
}
