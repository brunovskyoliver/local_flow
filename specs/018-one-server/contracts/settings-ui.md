# Contract: Settings UI (Feature 018, macOS)

Order of sections: **Server**, General, App context, Models, Rewriting, Summaries, then the rest unchanged. iOS Settings are not changed.

## Server (new, first)

Shown always; contents depend on remote dictation enrollment (Feature 014).

| State | Content |
| --- | --- |
| Remote dictation off | One line: "Run dictation, rewriting, summaries and meetings on a LocalFlow server you run." and **Set up…** (opens the existing consent and enrollment flow) |
| Pending | Server address, "Waiting for approval", fingerprint. Every service runs on this Mac |
| Approved | Server address and "Approved", the switch **Use this server for everything** (FR-001), and one **Services** row saying where the four services run: "Everything on your server", or each place with its services, e.g. "On your server: Dictation, Rewriting, Summaries · Not offered by this server: Meetings". Places are "On your server", "On your custom server", "On this Mac" and "Not offered by this server" |
| Rejected / revoked / pin mismatch | The state in words and **Set up again…**; every service runs on this Mac |

**Check connection** (FR-006) sits on the Services row. Served services share the channel, so it times one round trip and shows "Answered in N ms", "Server unreachable", or "Nothing runs on your server" beside the button. *(Amended 2026-10-01 by the owner: the four status rows, each repeating the same answer, were folded into this row; the fingerprint moved to Advanced; the duplicate Turn off row was removed, since the Remote dictation switch does the same.)*

**Advanced** (disclosure, collapsed by default):

| Row | Choices | Extra fields when chosen |
| --- | --- | --- |
| Rewriting | Your server · This Mac · Custom server | Custom: address, secret (Keychain), the existing insecure-HTTP override |
| Summaries | Your server · This Mac · Custom server | Custom: address, model, API key (Keychain); note "Your server is used if this server fails" |
| Meetings | Your server · This Mac | — |
| Fallback threshold | the existing remote dictation threshold | — |
| Server fingerprint | the pinned fingerprint, selectable | — |

There is no migration notice: research R13 was withdrawn on 2026-10-01 and nothing becomes an override on upgrade.

## Rewriting

Keeps **Enable rewriting**, **Default mode** and style settings. The Server URL, Server secret, Connection and Advanced endpoint rows move to Server › Advanced › Rewriting › Custom server. With the switch off they render here exactly as before this feature.

## Summaries

The section holds only the Server picker and its URL, Model and API key, which move to Server › Advanced › Summaries, so with the switch on the section is hidden. With the switch off it renders as before.

## Models

Each model row gains its place: "On your server", "On this Mac", or "On this Mac (used if the server is unreachable)". While the server serves the matching service:

- Parakeet and the term booster read "On this Mac (used if the server is unreachable)": the server has its own copies, and these serve the fallback. Whisper Turbo and Speaker labels read "On your server" once the server offers meeting jobs.
- **Keep Parakeet loaded** shows the caption "Applies when dictating on this Mac" and stays editable.
- **Unload rewrite model** and **Unload during games** are hidden when the local rewrite model is stopped by the server (R10).
- Load/Unload/Test buttons for local models stay, since they test the fallback.

## Meetings list and detail

A meeting waiting for the server shows "Waiting for your server" with **Run on this Mac**. A finished meeting's info shows where its transcript, speaker labels and summary were produced.

## Accessibility

Every new control has an accessibility label naming the service; status rows are read as "Rewriting, on your server". The switch and **Run on this Mac** are reachable by keyboard.
