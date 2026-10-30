# Data model: Feature 024

No schema change. `flow-core` reads and writes the tables created by `HistoryMigrations.swift` (through `usage-reporting-v21`), and fails closed on a database with migrations it doesn't know.

`preferences.json` in the data root holds the `AppPreferences` and settings keys under their Swift `UserDefaults` names.

Data root: `LOCALFLOW_DATA_ROOT` if set, otherwise a `LocalFlow GPUI Dev` folder in the platform's application data directory. It never defaults to the production or `LocalFlow Dev` folder before cutover.
