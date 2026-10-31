//! What `Txt` laid out in the last frames, so headless tests can assert copy. Empty outside tests.
use std::cell::RefCell;

thread_local! {
    static SEEN: RefCell<Option<Vec<String>>> = const { RefCell::new(None) };
}

/// Starts recording on this thread.
pub fn start() {
    SEEN.with(|s| *s.borrow_mut() = Some(vec![]));
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
