# LocalFlow

A privacy-first, local-first macOS voice productivity project. Native Swift handles local speech and user data; an optional lightweight Go service connects to a separate self-hosted LLM process.

The macOS app translates the approved HTML prototype into SwiftUI over existing local capture, FluidAudio speech recognition, safe insertion and SQLite storage. Feature 001 remains in progress; its task list records incomplete UI and acceptance work. The Go server provides optional text rewriting through a separate self-hosted inference process. Speech recognition remains local.

## Development

Requires macOS with Xcode (validated with 26.4.1), Go >= 1.23 and Python 3 for repository validation only. The application embeds neither Python nor Node. Run `make check` for JSON/link checks, shell syntax, plist validation, Go tests/vet and deterministic XCTest suites. `make macos` builds the app; `make server` prints the flowd version. No signing team or model downloads are needed for these checks.

## Spec-driven workflow

Codex skills are installed in `.agents/skills/`. The current feature is `specs/003-server-rewriting`, selected through `.specify/feature.json`. Start/restart Codex in this repository if skills are not yet visible. The feature pointer is machine-local and intentionally ignored by Git. On a fresh checkout, launch Codex from a shell with `export SPECIFY_FEATURE_DIRECTORY="$PWD/specs/001-local-dictation"`; `make check` supplies this default for its own validation.

The spec and plan reflect the approved HTML appearance with offline Mac speech. Continue the open tasks through `$speckit-analyze`, `$speckit-implement`, and `$speckit-converge`. For subsequent features start with `$speckit-specify`; use `$speckit-constitution` for governed amendments.

Spec Kit was initialized from upstream commit `1d5106f59e1b148ee23ab136638932dd790ff1b6` (CLI `1.0.8.dev0`) using:

```sh
uvx --from git+https://github.com/github/spec-kit.git@1d5106f59e1b148ee23ab136638932dd790ff1b6 specify init --here --integration codex --integration-options='--skills' --script sh --non-interactive
```

The vendored scripts and skills work without a persistent CLI install. Do not rerun initialization with force over project changes. Git was initialized separately; this Spec Kit version selects feature directories without requiring feature branches.

## Repository map

```text
.agents/skills/speckit-*/       Codex workflows, including converge
.specify/                      constitution, templates, workflow and scripts
specs/001-local-dictation/      spec, prepared plan, research, data model, contracts, checklist
apps/macos/                    Xcode app and native menu-bar shell
server/                        Go module and flowd rewrite API
protocol/                      versioned rewrite API and shared JSON schemas
docs/architecture/             client, audio, lifecycle, storage and server boundaries
docs/adr/                      architecture decisions, including Sotto UI reuse
docs/performance/              memory targets and 20-cycle benchmark procedure
fixtures/audio/                fixture provenance policy
scripts/                       validation, server runner and bounded RSS sampler
```

Read the [constitution](.specify/memory/constitution.md), [architecture](docs/architecture/overview.md), [Feature 001](specs/001-local-dictation/spec.md) and [roadmap](docs/roadmap.md). Future directories are created when they contain useful code rather than tracked empty placeholders.

Resource acceptance remains outstanding; see the feature acceptance artifacts for measurements actually collected. Initial defaults and compatibility probes are explicit in the feature plan. Meetings, speaker identification, backup, semantic search and sync are deferred to separate specifications. MIT is the initial project license; upstream toolkit and future model/dependency licenses remain separate. See THIRD_PARTY_NOTICES.md.

Sotto source is pinned at `third_party/sotto`; selected presentation code is adapted under its MIT license. Its server and inference worker are not part of the LocalFlow build. The HTML prototype is the current visual reference, superseding the earlier Sotto appearance. See [the design handoff](specs/001-local-dictation/design/README.md), [ADR 0010](docs/adr/0010-sotto-ui-local-speech.md) and [third-party notices](THIRD_PARTY_NOTICES.md).

For interactive development, use `make run`. It builds with the development signing
identity and installs and opens `/Applications/LocalFlow.app`, so rebuilds use the
same identity and location as the app authorized in System Settings. `make macos`
and `make check` remain unsigned build/test commands; do not use their app bundle
for permission acceptance. Override `LOCALFLOW_SIGNING_IDENTITY` for another local
signing certificate. macOS still owns grants; if Input Monitoring is denied, enable
it for the installed app and return to Settings to re-arm the shortcut.

Debug builds prefer the verified installation in Application Support. If it is
missing, they automatically import the pinned model from
`build/model-downloads/parakeet-v3-<sourceRevision>` in the source checkout, using
normal hash verification and lifecycle exclusion. `LOCALFLOW_DEVELOPMENT_MODEL_SOURCE`
can override that directory when launching from a development environment. This
fallback neither downloads nor loads the runtime and is excluded from Release.
The open main window appears in the Dock and window overview; closing it returns
to menu-bar operation, while minimizing keeps its Dock presence.

AeroSpace 0.19.2 on macOS 26 can classify the main window as a floating dialog
because macOS exposes no `AXFullScreenButton`, even when the window is resizable.
To tile it automatically, add this rule to your AeroSpace configuration and run
`aerospace reload-config`, then close and reopen the main window:

```toml
[[on-window-detected]]
if.app-id = 'org.localflow.LocalFlow'
if.window-title-regex-substring = '^LocalFlow$'
run = 'layout tiling'
```

The title restriction keeps file pickers and dictation overlays out of the rule.
This rule is configured on Oliver's development computer. Merely appearing in
`aerospace list-windows` does not prove a window is tiled.

In Settings, enable **Keep model ready** to prepare the installed model at launch
and retain it between dictations. This uses more idle memory. Turn it off to
restore the 30-second idle release, or choose Unload to free the model immediately.
Startup preparation uses verified local files and does not open the microphone.

Shortcut transitions, cancellation reasons, model preparation time and capture
failures are available locally with:

```sh
/usr/bin/log show --last 10m --style compact --info --predicate 'subsystem == "org.localflow.LocalFlow"'
```

These diagnostics exclude audio and transcript text. XCTest also uses this
subsystem; filter by the running app's process identifier when investigating a
live session.

## Optional server rewriting

Rewriting is opt-in. Configure your self-hosted flowd endpoint and credential in Settings, then use Test connection to check authentication, protocol compatibility and backend readiness. Choose Clean, Polished or Concise; Exact keeps the faithful transcript. Hold Shift when releasing the dictation shortcut to bypass rewriting for that dictation.

The app saves the faithful transcript before sending text and inserts it if rewriting fails or is cancelled. History retains attempts and lets you retry or explicitly insert a chosen result. Off-loopback plain HTTP requires a per-server insecure override and continues to warn that authentication does not encrypt transcripts. Credentials are stored in Keychain.

See the [server instructions](server/README.md) and [rewrite validation guide](specs/003-server-rewriting/quickstart.md). Quality, latency, privacy and memory acceptance are recorded under [Feature 003 acceptance](specs/003-server-rewriting/acceptance/baseline.md); passing repository tests alone does not establish those results.
