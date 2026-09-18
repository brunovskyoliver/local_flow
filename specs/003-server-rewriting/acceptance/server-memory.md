# Flowd memory evidence

Date: 2026-09-17. Hardware: Mac17,2 (Apple M5), 32 GiB. macOS 26.6.2 (25G83). Working tree based on `4680c54d526750fbbc73d06b35ae09003d808d5a`, with uncommitted Features 002/003 changes. HTTP measurements use a freshly built flowd 0.2.0 (Go 1.23.4); no app build participates. Backend: separately running MTPLX 2.11.3 at `127.0.0.1:8000/v1`, model `youssofal-qwen3.5-4b-mtplx-optimized-speed`. Clean prompt 5, Polished 3, Concise 3; protocol 1; shield 1 when on, 0 when off. Loopback HTTP, separate app/backend credentials, backend timeout 20 s and first-token timeout 5 s. The backend was already serving requests; cold-start state was not measured. The planned 9B model was not served. Raw outputs remain in private ignored directories.

## Conditions and results

A fresh temporary flowd process (PID 79123) listened on loopback port 49822 with shielding on, the backend/model above and default timeout flags. Health had returned ready before the idle sample. `ps -o rss= -p PID` sampled only flowd; KiB was multiplied by 1,024 and reported below in decimal MB. The separate MTPLX inference process is excluded.

| Condition | RSS | Target | Verdict |
| --- | --- | --- | --- |
| Idle after start and warm health probe | 12.517 MB | ≤100 MB | PASS |
| Maximum sampled during ordinary request | 12.845 MB | ≤250 MB | PASS |
| Settled 30 s after 20 sequential requests | 16.499 MB | Reported; below idle target | PASS |

The request used public corpus item `en-10`, 30 whitespace tokens, Clean mode. Sampling began with the request and repeated every second while it ran. The request finished before the second sample, so this is one RSS observation, not a continuously measured peak. All 21 requests (one sampled plus 20 sequential) ended in `result`. The backend was warm from the corpus run. The temporary server was stopped; the installed service and backend were left running.

Raw measurements: `build/phase11/server-memory.json`; server log: `build/phase11/server-memory.log`. These results apply to this build, model, request and loopback setup, not client memory or a general load test.
