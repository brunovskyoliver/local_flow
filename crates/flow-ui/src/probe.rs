//! What `Txt` laid out in the last frames, so headless tests can assert copy. Empty outside tests.
use std::cell::RefCell;

thread_local! {
    static SEEN: RefCell<Option<Vec<String>>> = const { RefCell::new(None) };
    static SYMBOLS: RefCell<Vec<String>> = const { RefCell::new(vec![]) };
}

/// Starts recording on this thread.
pub fn start() {
    SEEN.with(|s| *s.borrow_mut() = Some(vec![]));
    SYMBOLS.with(|s| s.borrow_mut().clear());
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

/// SF Symbol names `icon` drew since the last `start`, so a test can assert a row's symbol.
pub fn symbols() -> Vec<String> {
    SYMBOLS.with(|s| s.borrow().clone())
}
