# Rewrite latency with context (SC-006)

Date: 2026-09-24. Same identity as [evaluation.md](evaluation.md): Mac17,2, flowd 0.3.0 on loopback, MTPLX `youssofal-qwen3.5-4b-mtplx-optimized-speed`, clean prompt 5, context prompt version 1.

**SC-006: unmeasured.** SC-006 uses the Feature 003 SC-011 definition (faithful transcript saved to rewritten text handed to insertion, in the app). No app run with context was made, so there is no verdict for the short median ≤ 1.5 s or ordinary p95 ≤ 3.0 s gates.

HTTP evidence from the evaluation runner (request start to terminal event, loopback, excludes app persistence and insertion). All 131 successful items per half fall in the short bucket; the ordinary and long buckets have no samples.

| Half | Short n | Median | p95 | Backend first-token median |
| --- | --- | --- | --- | --- |
| v1, no context | 131 | 481 ms | 629 ms | 343 ms |
| v2, context | 131 | 617 ms | 784 ms | 470 ms |

Context adds about 136 ms to the HTTP median, mostly before the first token (prompt prefill of the rules block and the snapshot). These figures do not establish SC-006.
