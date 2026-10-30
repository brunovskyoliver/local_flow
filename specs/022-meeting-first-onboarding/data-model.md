# Data model: Meeting-first onboarding

- **`AppPreferences.Purpose`**: `dictation`, `meetings` or `both`, stored per device in `UserDefaults` under `setup.purpose`. A missing value means `both`, so existing installs don't change.

No database, protocol or file format change.
