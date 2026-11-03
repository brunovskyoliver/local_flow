# Contract: live channel counts in `GET /v1/admin/status`

Extends the loopback admin API described in `server/cmd/flowd/admin_api.go` (ADR 0032). The listener, bearer token (`<data-dir>/admin-token`, 0600) and every existing field stay as they are.

## Response

```json
{
  "version": "…",
  "started_at": "2026-11-03T08:00:00Z",
  "counters": { "dictation": { "requests": 4, "failures": 0 }, "…": {} },
  "analysis": { "backend": "", "model": "" },
  "channels": {
    "open": 5,
    "devices": [ { "device_id": 3, "channels": 2 }, { "device_id": 5, "channels": 1 } ]
  }
}
```

| Field | Rule |
|---|---|
| `channels` | present when the remote listener runs; `null` when flowd serves without `--remote-listen` |
| `open` | every open channel, authenticated or not (`Registry.Len`) |
| `devices[]` | authenticated channels per device, from `Registry.byDevice`; devices with none are left out; ordered by `device_id`; at most 500 entries |
| `channels` per device | 1-4 (`MaxChannelsPerDevice`) |

"Connected now" on the Users page means the device appears in `devices[]`. The response carries device IDs and counts only: no user IDs, addresses, names or channel IDs.

## Reading it

- The Rust Users page reads it every 5 s while the page and its window are visible, and not at all otherwise (FR-017).
- LocalFlow Server ignores keys it doesn't know; a test checks that the new key doesn't break its decoder.
- Cost: one lock on the registry and one pass over its device index per request.
