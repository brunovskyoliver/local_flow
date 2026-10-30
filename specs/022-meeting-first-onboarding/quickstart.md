# Quickstart: Meeting-first onboarding

1. `make check`
2. `scripts/dev-macos.sh --dev` installs `LocalFlow Dev` beside the installed app, with its own data.
3. For a first run, remove the dev app's defaults (`defaults delete org.localflow.LocalFlow.dev`). Move `build/model-downloads` aside first, because debug builds install a model from it.
4. Walk each row of the path table in `plan.md`. The server path can use `make server`.
