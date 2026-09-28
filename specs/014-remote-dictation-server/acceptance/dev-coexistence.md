# Dev build next to the installed app (T037, SC-008)

Run on 2026-09-28 on the owner's Mac. **Result: pass.** The installed app's database, defaults, Keychain item names, launch agents and models were identical before and after a dev dictation, a `kill -9` of the dev app and its uninstall.

## Conditions

- Hardware: Mac17,2, Apple M5, 32 GB. macOS 27.0 (26A428).
- Installed app: `/Applications/LocalFlow.app`, `org.localflow.LocalFlow`, CFBundleVersion 1, built from `main`. It ran throughout with its model loaded (MTPLX Qwen3.5 4B Speed, about 2.7 GB RSS).
- Dev app: `make run-dev` from branch `t3code/remote-dictation` (base `e39e86c`, uncommitted feature changes plus the fix below), Debug, signed with the development identity and no provisioning profile, so without Sign in with Apple.

## Procedure

Quickstart §2 as amended on this date: dictating in the installed app writes its database, so it happens before the "before" snapshot.

1. `make run-dev`, dev onboarding (permissions, speech model, local AI into `LocalFlow Dev`).
2. One dictation in each app, with both running.
3. `scripts/snapshot-installed-state.sh` twice, 15 s apart: identical, so the installed app was idle.
4. One more dictation in the dev app (dev history: 2 rows).
5. `pkill -9 -x "LocalFlow Dev"`: the dev MTPLX stopped within 2 s (orphan guard).
6. Uninstall: `launchctl bootout` of `org.localflow.LocalFlow.dev.flowd` and `.dev.mtplx`, then remove `/Applications/LocalFlow Dev.app`. The dev data folder was kept.
7. Snapshot again and `diff`: **no output**. The installed flowd on 8080 still reported backend `ready`.

## Both apps running (before step 5)

```
777	0	org.localflow.LocalFlow.flowd
14042	2	org.localflow.LocalFlow.dev.mtplx
75500	0	org.localflow.LocalFlow.mtplx
91852	0	application.org.localflow.LocalFlow.65367614.65367619
97769	0	org.localflow.LocalFlow.dev.flowd
14026	0	application.org.localflow.LocalFlow.dev.66855363.66855370
```

The `2` on `.dev.mtplx` is the exit status of the run that failed before the fix below; the job was running as PID 14042.

| Service | Installed | Dev |
| --- | --- | --- |
| MTPLX | 127.0.0.1:8000 | 127.0.0.1:18000 |
| flowd rewrite | 127.0.0.1:8080 | 127.0.0.1:18080 |
| Remote server (18090) | — | not started; it belongs to the server install in §3 |

Both flowd instances answered `/v1/rewrite/health` with backend `ready`, each with its own MTPLX process (about 2.7 and 2.9 GB RSS).

## Defect found and fixed

The first dev run left `org.localflow.LocalFlow.dev.mtplx` exited with status 2, so dev rewriting had no backend. The rendered launch script contained `case … in */LocalFlow Dev)`, and the unquoted space is a `sh` syntax error. The script started MTPLX and then failed when it reached the orphan check. Production renders `*/LocalFlow)` and was not affected.

- `apps/macos/LocalFlow/Resources/LocalAI/localflow-mtplx`: the pattern is now `*/"@EXECUTABLE@"`.
- `scripts/bundle-local-ai.sh`: runs `sh -n` on both rendered scripts, so a rendering that breaks the shell grammar fails the build.

Rebuilding after the template change hit an existing incremental-build issue: the run-script phase rewrote a resource Xcode had already sealed, and `codesign --verify` in `dev-macos.sh` rejected the bundle before installing it. Deleting the built product and rebuilding fixed it.
