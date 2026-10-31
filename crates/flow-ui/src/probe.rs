//! What `Txt` laid out in the last frames, so headless tests can assert copy. Empty outside tests.
use std::cell::RefCell;

thread_local! {
    static SEEN: RefCell<Option<Vec<String>>> = const { RefCell::new(None) };
    static SYMBOLS: RefCell<Vec<String>> = const { RefCell::new(vec![]) };
    static STYLES: RefCell<Vec<(String, TextStyle)>> = const { RefCell::new(vec![]) };
    static SYMBOL_COLORS: RefCell<Vec<(String, gpui_kit::Hsla)>> = const { RefCell::new(vec![]) };
}

/// What `Txt` resolved for a text: its first run's weight and colour, its size.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextStyle {
    pub size: f32,
    pub weight: f32,
    pub color: gpui_kit::Hsla,
}

/// Starts recording on this thread.
pub fn start() {
    SEEN.with(|s| *s.borrow_mut() = Some(vec![]));
    SYMBOLS.with(|s| s.borrow_mut().clear());
    STYLES.with(|s| s.borrow_mut().clear());
}

pub(crate) fn record(text: &str) {
    SEEN.with(|s| {
        if let Some(v) = s.borrow_mut().as_mut() {
            v.push(text.to_string());
        }
    });
}

/// All text laid out since the last `start`, in order.
pub fn seen() -> Vec<String> {
    SEEN.with(|s| s.borrow().clone().unwrap_or_default())
}

/// Clears the record; call before rendering the state under test.
pub fn clear() {
    start();
}

#[cfg(any(test, feature = "test-support"))]
pub(crate) fn record_symbol(symbol: &str) {
    SYMBOLS.with(|s| s.borrow_mut().push(symbol.to_string()));
}

#[cfg(any(test, feature = "test-support"))]
pub(crate) fn record_symbol_color(symbol: &str, color: gpui_kit::Hsla) {
    SYMBOL_COLORS.with(|s| s.borrow_mut().push((symbol.to_string(), color)));
}

/// The colour `icon` last drew this symbol in, so a test can assert a red trash or an orange warning.
pub fn symbol_color(symbol: &str) -> Option<gpui_kit::Hsla> {
    SYMBOL_COLORS.with(|s| s.borrow().iter().rev().find(|(n, _)| n == symbol).map(|(_, c)| *c))
}

/// SF Symbol names `icon` drew since the last `start`, so a test can assert a row's symbol.
pub fn symbols() -> Vec<String> {
    SYMBOLS.with(|s| s.borrow().clone())
}

pub(crate) fn record_style(text: &str, style: TextStyle) {
    SEEN.with(|s| {
        if s.borrow().is_some() {
            STYLES.with(|styles| styles.borrow_mut().push((text.to_string(), style)));
        }
    });
}

/// How the text exactly equal to `text` was last laid out since the last `start`.
pub fn style_of(text: &str) -> Option<TextStyle> {
    STYLES.with(|s| s.borrow().iter().rev().find(|(t, _)| t == text).map(|(_, style)| *style))
}
