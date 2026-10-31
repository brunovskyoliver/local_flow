//! Its own binary: `set_decimal_separator` is process-wide and would race the other tests.
use flow_core::insights::versus_typing;
use flow_core::onboarding::set_decimal_separator;

// parity: INS-030
#[test]
fn versus_typing_uses_the_locale_decimal() {
    set_decimal_separator(',');
    assert_eq!(versus_typing(Some(150)), "3,8×");
    assert_eq!(versus_typing(None), "–");
}
