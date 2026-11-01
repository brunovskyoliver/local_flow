//! The decisions in the Windows services, kept apart from the API calls so they test on any host.

/// `CapabilityAccessManager\ConsentStore\microphone` values: the system-wide one, the user's, and
/// the user's for desktop apps. Any `Deny` wins. A desktop app has no prompt to wait for.
pub fn microphone_denied(values: &[Option<String>]) -> bool {
    values.iter().flatten().any(|v| v.eq_ignore_ascii_case("Deny"))
}

/// `InputDevice::kind` from a device's enumerator name.
pub fn input_kind(enumerator: &str) -> &'static str {
    match enumerator.to_ascii_uppercase().as_str() {
        "USB" => "usb",
        "BTH" | "BTHENUM" | "BTHHFENUM" | "BTHLE" | "BTHLEDEVICE" => "bluetooth",
        "HDAUDIO" | "INTELAUDIO" | "ACPI" => "builtIn",
        "ROOT" | "SWD" => "virtual",
        _ => "other",
    }
}

/// The `Run` value for `exe`, and whether a stored value still points at it. Quoted, because a
/// program path with a space would otherwise run the wrong file.
pub fn run_value(exe: &str) -> String {
    format!("\"{exe}\"")
}

/// Process loopback arrived in this build.
pub const PROCESS_LOOPBACK_BUILD: u32 = 20348;
pub fn process_loopback_supported(current_build: Option<&str>) -> bool {
    current_build.and_then(|b| b.trim().parse::<u32>().ok()).is_some_and(|b| b >= PROCESS_LOOPBACK_BUILD)
}

/// One 1024-sample input frame in 100 ns units, as Media Foundation counts time.
pub const fn aac_frame_ticks() -> i64 {
    1024 * 10_000_000 / 48_000
}

/// `MF_MT_AUDIO_AVG_BYTES_PER_SECOND` the Microsoft AAC encoder takes for a bit rate. It accepts
/// only 12000, 16000, 20000 and 24000.
pub fn aac_bytes_per_second(bitrate: i64) -> Option<u32> {
    [12_000, 16_000, 20_000, 24_000].contains(&(bitrate / 8)).then_some((bitrate / 8) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn consent() {
        assert!(!microphone_denied(&[None, None, None]));
        assert!(!microphone_denied(&[Some("Allow".into()), None, Some("Allow".into())]));
        assert!(microphone_denied(&[Some("Allow".into()), Some("deny".into()), None]));
    }

    #[test]
    fn kinds_and_run_value_and_build_gate() {
        assert_eq!(input_kind("USB"), "usb");
        assert_eq!(input_kind("BTHENUM"), "bluetooth");
        assert_eq!(input_kind("hdaudio"), "builtIn");
        assert_eq!(input_kind("SWD"), "virtual");
        assert_eq!(input_kind(""), "other");
        assert_eq!(run_value(r"C:\Program Files\LocalFlow\localflow.exe"), r#""C:\Program Files\LocalFlow\localflow.exe""#);
        assert!(process_loopback_supported(Some("22631")));
        assert!(process_loopback_supported(Some("20348")));
        assert!(!process_loopback_supported(Some("19045")));
        assert!(!process_loopback_supported(None));
        assert!(!process_loopback_supported(Some("x")));
    }

    #[test]
    fn aac_rates_follow_the_encoder_contract() {
        assert_eq!(aac_bytes_per_second(96_000), Some(12_000));
        assert_eq!(aac_bytes_per_second(192_000), Some(24_000));
        assert_eq!(aac_bytes_per_second(64_000), None, "the encoder has no 64 kbit/s");
        assert_eq!(aac_frame_ticks(), 213_333);
    }
}
