//! The system locale's date and number formats, through CoreFoundation (what `formatted()` reads).
use crate::Formats;
use std::ffi::c_void;

type Cf = *const c_void;
const UTF8: u32 = 0x0800_0100;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFDateFormatterTimeZone: Cf;
    static kCFNumberFormatterMinFractionDigits: Cf;
    static kCFNumberFormatterMaxFractionDigits: Cf;
    fn CFRelease(o: Cf);
    fn CFLocaleCopyCurrent() -> Cf;
    fn CFStringCreateWithBytes(a: Cf, bytes: *const u8, n: isize, encoding: u32, bom: bool) -> Cf;
    fn CFStringGetLength(s: Cf) -> isize;
    fn CFStringGetMaximumSizeForEncoding(n: isize, encoding: u32) -> isize;
    fn CFStringGetCString(s: Cf, buffer: *mut std::ffi::c_char, size: isize, encoding: u32) -> bool;
    fn CFDateFormatterCreate(a: Cf, locale: Cf, date_style: isize, time_style: isize) -> Cf;
    fn CFDateFormatterCreateDateFormatFromTemplate(a: Cf, template: Cf, options: usize, locale: Cf) -> Cf;
    fn CFDateFormatterSetFormat(f: Cf, format: Cf);
    fn CFDateFormatterSetProperty(f: Cf, key: Cf, value: Cf);
    fn CFDateFormatterCreateStringWithAbsoluteTime(a: Cf, f: Cf, at: f64) -> Cf;
    fn CFTimeZoneCreateWithTimeIntervalFromGMT(a: Cf, seconds: f64) -> Cf;
    fn CFNumberFormatterCreate(a: Cf, locale: Cf, style: isize) -> Cf;
    fn CFNumberFormatterSetProperty(f: Cf, key: Cf, value: Cf);
    fn CFNumberFormatterCreateStringWithValue(a: Cf, f: Cf, kind: isize, value: *const c_void) -> Cf;
    fn CFNumberCreate(a: Cf, kind: isize, value: *const c_void) -> Cf;
    fn CFCalendarCopyCurrent() -> Cf;
    fn CFCalendarGetFirstWeekday(c: Cf) -> isize;
}

/// Reads and releases an owned CFString.
unsafe fn take(s: Cf) -> Option<String> {
    if s.is_null() {
        return None;
    }
    // SAFETY: `s` is a live CFString owned by this call; the buffer is sized for its UTF-8 form.
    unsafe {
        let size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), UTF8) + 1;
        let mut buffer = vec![0u8; size as usize];
        let ok = CFStringGetCString(s, buffer.as_mut_ptr().cast(), size, UTF8);
        CFRelease(s);
        if !ok {
            return None;
        }
        buffer.truncate(buffer.iter().position(|b| *b == 0).unwrap_or(0));
        String::from_utf8(buffer).ok()
    }
}

/// A template such as "dMMM" under the current locale; "short-time" is `time: .shortened`.
/// With `utc` the date's fields are read as written, for a calendar day or an hour on no date.
fn date(ms: i64, template: &str, utc: bool) -> Option<String> {
    const SECONDS_TO_2001: f64 = 978_307_200.0;
    // SAFETY: every object created here is released here; each is used as its function documents.
    unsafe {
        let locale = CFLocaleCopyCurrent();
        let short = template == "short-time";
        let f = CFDateFormatterCreate(std::ptr::null(), locale, 0, if short { 1 } else { 0 });
        if !short {
            let t = CFStringCreateWithBytes(std::ptr::null(), template.as_ptr(), template.len() as isize, UTF8, false);
            let format = CFDateFormatterCreateDateFormatFromTemplate(std::ptr::null(), t, 0, locale);
            CFDateFormatterSetFormat(f, format);
            CFRelease(format);
            CFRelease(t);
        }
        if utc {
            let zone = CFTimeZoneCreateWithTimeIntervalFromGMT(std::ptr::null(), 0.0);
            CFDateFormatterSetProperty(f, kCFDateFormatterTimeZone, zone);
            CFRelease(zone);
        }
        let out = take(CFDateFormatterCreateStringWithAbsoluteTime(std::ptr::null(), f, ms as f64 / 1000.0 - SECONDS_TO_2001));
        CFRelease(f);
        CFRelease(locale);
        out
    }
}

/// `.number` with exactly `digits` fraction digits.
fn number(value: f64, digits: u8) -> Option<String> {
    const DECIMAL_STYLE: isize = 1;
    const INT_TYPE: isize = 9;
    const DOUBLE_TYPE: isize = 13;
    // SAFETY: as in `date`; `value` and `count` outlive the calls that read them.
    unsafe {
        let locale = CFLocaleCopyCurrent();
        let f = CFNumberFormatterCreate(std::ptr::null(), locale, DECIMAL_STYLE);
        let count = digits as i32;
        let n = CFNumberCreate(std::ptr::null(), INT_TYPE, (&raw const count).cast());
        CFNumberFormatterSetProperty(f, kCFNumberFormatterMinFractionDigits, n);
        CFNumberFormatterSetProperty(f, kCFNumberFormatterMaxFractionDigits, n);
        let out = take(CFNumberFormatterCreateStringWithValue(std::ptr::null(), f, DOUBLE_TYPE, (&raw const value).cast()));
        CFRelease(n);
        CFRelease(f);
        CFRelease(locale);
        out
    }
}

pub fn formats() -> Formats {
    // SAFETY: the calendar is owned here and released after the read.
    let first_weekday = unsafe {
        let c = CFCalendarCopyCurrent();
        let day = CFCalendarGetFirstWeekday(c);
        CFRelease(c);
        day as i64
    };
    Formats { date, number, first_weekday }
}

#[cfg(test)]
mod tests {
    #[test]
    fn formats_a_known_instant_and_number() {
        // 2026-10-31 13:05 UTC; the locale decides the order, not the fields.
        let at = 1_793_451_900_000;
        let day = super::date(at, "yMMMMd", true).unwrap();
        assert!(day.contains("2026") && day.contains("31"), "{day}");
        let time = super::date(at, "short-time", true).unwrap();
        assert!(time.contains("05"), "{time}");
        let n = super::number(1234.5, 1).unwrap();
        assert!(n.starts_with('1') && n.ends_with('5') && n.contains("234"), "{n}");
        assert!((1..=7).contains(&super::formats().first_weekday));
    }
}
