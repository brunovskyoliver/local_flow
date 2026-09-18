# Settings connection walkthrough

Date: 2026-09-17. Status: signed-app walkthrough pending by owner instruction.

| Settings status | Live Settings observation |
| --- | --- |
| Connected | Not observed |
| Authentication failed | Not observed |
| Server unreachable | Not observed |
| Rewrite service unavailable | Not observed |
| LLM backend unavailable | Not observed |
| Incompatible server/protocol version | Not observed |
| Missing credential | Not observed |
| Unencrypted connection blocked | Not observed |

The corpus runner authenticated to a separate loopback flowd and observed a ready backend. That is HTTP evidence, not the Settings walkthrough. The off-loopback override sequence and owner overlay address were not exercised. Whether NSAllowsLocalNetworking alone covers that address remains unverified; no ATS setting was changed. T073 remains open.
