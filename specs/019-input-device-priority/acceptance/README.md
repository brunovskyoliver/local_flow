# Feature 019 acceptance records

Each file here records one run on real hardware. Fakes, unit tests and a build that only compiles never count as acceptance.

Every run records, at the top of its file:

- date
- Mac model
- macOS build (`sw_vers -buildVersion`)
- iPhone model and iOS build, when the run uses an iPhone
- LocalFlow build (`CFBundleVersion` and the git commit)

Files, in the order quickstart.md runs them:

| File | Quickstart | Tasks |
| --- | --- | --- |
| `spike-<date>.md` | §2, spike S1–S6 and the fallbacks chosen | T003, T004 |
| `us1-<date>.md` | §3, ranking and fallback | T030 |
| `us2-<date>.md` | §4, iPhone Microphone | T043 |
| `iphone-timing-<date>.md` | §4 step 6, cold and warm timings | T044 |
| `us3-<date>.md` | §5, plus §3 steps 2 and 4 and the US2 caption checks | T053 |
| `us4-<date>.md` | §6, meetings | T061 |
| `upgrade-<date>.md` | §7, upgrade from a pre-feature build | T063 |
| `resources-<date>.md` | §8, SC-001 and SC-006, plus the FR-017 network check | T064, T066 |

Values that were not measured stay marked unmeasured.
