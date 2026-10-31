//! One module per page. Each exposes `Page::new(window, cx)` and implements `Render`.
pub mod dictionary;
pub mod history;
pub mod insights;
pub mod notetaker;
pub mod onboarding;
pub mod settings;

/// The sidebar's pages, in Swift's `MainWindowRouter.Page` order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Page {
    Meetings,
    History,
    Insights,
    Dictionary,
    Settings,
}
