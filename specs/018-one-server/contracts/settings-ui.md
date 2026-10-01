# Contract: Settings UI (Feature 018, macOS)

Order of sections: **Server**, General, App context, Models, Rewriting, Summaries, then the rest unchanged. iOS Settings are not changed.

## Server (new, first)

Shown always; contents depend on remote dictation enrollment (Feature 014).

| State | Content |
| --- | --- |
| Remote dictation off | One line: "Run dictation, rewriting, summaries and meetings on a LocalFlow server you run." and **Set up…** (opens the existing consent and enrollment flow) |
| Pending | Server address, "Waiting for approval", fingerprint. Every service runs on this Mac |
| Approved | Server address, "Approved", fingerprint, the switch **Use this server for everything** (FR-001), and a status row per service: Dictation, Rewriting, Summaries, Meetings, each "On your server", "On this Mac" or "Not offered by this server" |
| Rejected / revoked / pin mismatch | The state in words and **Set up again…**; every service runs on this Mac |

Below the rows: **Check connection** (FR-006) runs one request per served service on its real path and shows per row "Answered in N ms" or why it fell back.

**Advanced** (disclosure, collapsed by default):

| Row | Choices | Extra fields when chosen |
| --- | --- | --- |
| Rewriting | Your server · This Mac · Custom server | Custom: address, secret (Keychain), the existing insecure-HTTP override |
| Summaries | Your server · This Mac · Custom server | Custom: address, model, API key (Keychain); note "Your server is used if this server fails" |
| Meetings | Your server · This Mac | — |
| Fallback threshold | the existing remote dictation threshold | — |
| Turn off remote dictation | existing destructive action | — |

The migration notice (research R13) appears once at the top of the Server section: "Kept your summaries server ai-vm … as a custom server for Summaries."

## Rewriting

Keeps **Enable rewriting**, **Default mode** and style settings. The Server URL, Server secret, Connection and Advanced endpoint rows move to Server › Advanced › Rewriting › Custom server. With the switch off they render here exactly as before this feature.

## Summaries

Keeps its behaviour settings. The Server picker, URL, Model and API key move to Server › Advanced › Summaries. With the switch off they render here as before.

## Models

Each model row gains its place: "On your server", "On this Mac", or "On this Mac (used if the server is unreachable)". While the server serves the matching service:

- **Keep Parakeet loaded** shows the caption "Applies when dictating on this Mac" and stays editable.
- **Unload rewrite model** and **Unload during games** are hidden when the local rewrite model is stopped by the server (R10).
- Load/Unload/Test buttons for local models stay, since they test the fallback.

## Meetings list and detail

A meeting waiting for the server shows "Waiting for your server" with **Run on this Mac**. A finished meeting's info shows where its transcript, speaker labels and summary were produced.

## Accessibility

Every new control has an accessibility label naming the service; status rows are read as "Rewriting, on your server". The switch and **Run on this Mac** are reachable by keyboard.
