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

// MARK: Keyboard

use flow_core::settings::{FLAG_COMMAND, FLAG_CONTROL, FLAG_OPTION, FLAG_SHIFT, FN, KeyEvent, Shortcut};

/// Stands for any key with no Mac code, so a press of it can still cancel a modifier-only hold.
pub const UNMAPPED: u32 = 127;
const LLKHF_INJECTED: u32 = 0x10;
/// The left Control that some layouts fake in front of AltGr carries this in its scan code.
const FAKE_ALTGR_SCAN: u32 = 0x200;
const VK_LCONTROL: u32 = 0xA2;

/// Windows VK, Mac key code, device bit, CGEvent flag. The Windows key is Command's place.
const MODIFIER_KEYS: [(u32, u32, u64, u64); 8] = [
    (0xA0, 56, 0x2, FLAG_SHIFT),
    (0xA1, 60, 0x4, FLAG_SHIFT),
    (0xA2, 59, 0x1, FLAG_CONTROL),
    (0xA3, 62, 0x2000, FLAG_CONTROL),
    (0xA4, 58, 0x20, FLAG_OPTION),
    (0xA5, 61, 0x40, FLAG_OPTION),
    (0x5B, 55, 0x8, FLAG_COMMAND),
    (0x5C, 54, 0x10, FLAG_COMMAND),
];

/// US-position virtual keys and the Mac key codes the shared shortcut format stores.
/// ponytail: Enter on the numpad reads as Return, since both are VK_RETURN.
const KEYS: &[(u32, u32)] = &[
    (0x41, 0), (0x53, 1), (0x44, 2), (0x46, 3), (0x48, 4), (0x47, 5), (0x5A, 6), (0x58, 7), (0x43, 8), (0x56, 9), (0x42, 11), (0x51, 12), (0x57, 13), (0x45, 14), (0x52, 15), (0x59, 16), (0x54, 17),
    (0x31, 18), (0x32, 19), (0x33, 20), (0x34, 21), (0x36, 22), (0x35, 23), (0xBB, 24), (0x39, 25), (0x37, 26), (0xBD, 27), (0x38, 28), (0x30, 29), (0xDD, 30), (0x4F, 31), (0x55, 32), (0xDB, 33), (0x49, 34), (0x50, 35),
    (0x0D, 36), (0x4C, 37), (0x4A, 38), (0xDE, 39), (0x4B, 40), (0xBA, 41), (0xDC, 42), (0xBC, 43), (0xBF, 44), (0x4E, 45), (0x4D, 46), (0xBE, 47), (0x09, 48), (0x20, 49), (0xC0, 50), (0x08, 51), (0x1B, 53),
    (0x6E, 65), (0x6A, 67), (0x6B, 69), (0x0C, 71), (0x6F, 75), (0x6D, 78), (0x60, 82), (0x61, 83), (0x62, 84), (0x63, 85), (0x64, 86), (0x65, 87), (0x66, 88), (0x67, 89), (0x68, 91), (0x69, 92),
    (0x70, 122), (0x71, 120), (0x72, 99), (0x73, 118), (0x74, 96), (0x75, 97), (0x76, 98), (0x77, 100), (0x78, 101), (0x79, 109), (0x7A, 103), (0x7B, 111), (0x7C, 105), (0x7D, 107), (0x7E, 113), (0x7F, 106), (0x80, 64), (0x81, 79), (0x82, 80), (0x83, 90),
    (0x2D, 114), (0x24, 115), (0x21, 116), (0x2E, 117), (0x23, 119), (0x22, 121), (0x25, 123), (0x27, 124), (0x28, 125), (0x26, 126),
];

pub fn mac_key(vk: u32) -> Option<u32> {
    KEYS.iter().find(|k| k.0 == vk).map(|k| k.1)
}

/// The virtual key to poll for a stored Mac key code.
pub fn vk_for(mac: u32) -> Option<u32> {
    KEYS.iter().find(|k| k.1 == mac).map(|k| k.0)
}

/// A PC has no Globe or fn key that reaches a hook.
pub fn shortcut_possible(shortcut: &Shortcut) -> bool {
    shortcut.kind != "fn_globe" && shortcut.modifiers & FN == 0
}

/// Turns hook events into the events the shared machine reads, with its flag bits.
pub struct KeyTracker {
    down: [bool; 256],
}
impl Default for KeyTracker {
    fn default() -> Self {
        KeyTracker { down: [false; 256] }
    }
}
impl KeyTracker {
    fn flags(&self) -> u64 {
        MODIFIER_KEYS.iter().filter(|m| self.down[m.0 as usize]).fold(0, |flags, m| flags | m.2 | m.3)
    }
    /// `None` for events the machine mustn't see: our own insertion's synthetic keys, the fake
    /// Control of AltGr, and a modifier's auto-repeat.
    pub fn receive(&mut self, vk: u32, scan: u32, flags: u32, up: bool) -> Option<(KeyEvent, u32, u64, bool)> {
        if flags & LLKHF_INJECTED != 0 || vk >= 256 || (vk == VK_LCONTROL && scan & FAKE_ALTGR_SCAN != 0) {
            return None;
        }
        let was_down = std::mem::replace(&mut self.down[vk as usize], !up);
        if let Some(modifier) = MODIFIER_KEYS.iter().find(|m| m.0 == vk) {
            return (was_down == up).then_some((KeyEvent::Flags, modifier.1, self.flags(), false));
        }
        let kind = if up { KeyEvent::Up } else { KeyEvent::Down };
        Some((kind, mac_key(vk).unwrap_or(UNMAPPED), self.flags(), !up && was_down))
    }
    /// Takes the modifiers from physical state, in case a key-up was dropped, and returns the flags.
    pub fn sync(&mut self, pressed: impl Fn(u32) -> bool) -> u64 {
        for modifier in MODIFIER_KEYS {
            self.down[modifier.0 as usize] = pressed(modifier.0);
        }
        self.flags()
    }
}

#[cfg(test)]
mod keyboard_tests {
    use super::*;
    use flow_core::dictation::hotkey::{Event, Machine};
    use flow_core::settings::key_title;

    const RCTRL: u32 = 0xA3;

    #[test]
    fn key_table_is_one_to_one_and_agrees_with_the_shared_names() {
        let mut vks: Vec<u32> = KEYS.iter().map(|k| k.0).chain(MODIFIER_KEYS.map(|m| m.0)).collect();
        let mut macs: Vec<u32> = KEYS.iter().map(|k| k.1).chain(MODIFIER_KEYS.map(|m| m.1)).collect();
        let total = vks.len();
        vks.sort();
        vks.dedup();
        macs.sort();
        macs.dedup();
        assert_eq!((vks.len(), macs.len()), (total, total));
        assert!(!macs.contains(&UNMAPPED));
        for (vk, title) in [(0x70, "F1"), (0x83, "F20"), (0x1B, "Esc"), (0x20, "Space"), (0x0D, "Return"), (0x25, "←"), (0x26, "↑"), (0x2E, "⌦")] {
            assert_eq!(key_title(mac_key(vk).unwrap()), title);
        }
        assert_eq!(vk_for(mac_key(0x41).unwrap()), Some(0x41));
        assert_eq!(mac_key(0xFF), None);
    }

    #[test]
    fn tracker_makes_flags_repeats_and_drops_what_it_must() {
        let mut t = KeyTracker::default();
        assert_eq!(t.receive(RCTRL, 0x1D, 1, false), Some((KeyEvent::Flags, 62, FLAG_CONTROL | 0x2000, false)));
        assert_eq!(t.receive(RCTRL, 0x1D, 1, false), None, "a held modifier's repeat");
        assert_eq!(t.receive(0x41, 0x1E, 0, false), Some((KeyEvent::Down, 0, FLAG_CONTROL | 0x2000, false)));
        assert_eq!(t.receive(0x41, 0x1E, 0, false), Some((KeyEvent::Down, 0, FLAG_CONTROL | 0x2000, true)), "a key's repeat");
        assert_eq!(t.receive(0x41, 0x1E, 0, true), Some((KeyEvent::Up, 0, FLAG_CONTROL | 0x2000, false)));
        assert_eq!(t.receive(RCTRL, 0x1D, 1, true), Some((KeyEvent::Flags, 62, 0, false)));
        assert_eq!(t.receive(0x56, 0x2F, LLKHF_INJECTED, false), None, "our own paste");
        assert_eq!(t.receive(VK_LCONTROL, 0x21D, 0, false), None, "AltGr's fake Control");
        assert_eq!(t.receive(0xE7, 0, 0, false).unwrap().1, UNMAPPED);
    }

    #[test]
    fn sync_clears_a_modifier_whose_up_was_dropped() {
        let mut t = KeyTracker::default();
        t.receive(RCTRL, 0x1D, 1, false);
        assert_eq!(t.sync(|_| false), 0);
        assert_eq!(t.sync(|vk| vk == 0xA4), FLAG_OPTION | 0x20);
    }

    #[test]
    fn right_control_drives_the_shared_machine_and_globe_is_refused() {
        let mut t = KeyTracker::default();
        let mut m = Machine::new(Shortcut::right_control());
        let (kind, key, flags, repeat) = t.receive(RCTRL, 0x1D, 1, false).unwrap();
        assert_eq!(m.receive(kind, key, flags, repeat).event, Some(Event::Pressed));
        let (kind, key, flags, repeat) = t.receive(RCTRL, 0x1D, 1, true).unwrap();
        assert_eq!(m.receive(kind, key, flags, repeat).event, Some(Event::Released { bypass_rewrite: false }));
        assert!(!shortcut_possible(&Shortcut::default()));
        assert!(shortcut_possible(&Shortcut::right_control()));
    }
}
