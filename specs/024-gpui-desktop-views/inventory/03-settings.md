# Settings page parity inventory

## Page shell and shared components

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-001 | view | Page container `PrototypePage` | Appearance.swift:80-99 | ScrollView with hidden indicators. Content padding horizontal 48 (24 compact), top 48 (32 compact), bottom 64. Max width 960, centered. Base font Figtree 14, ink colour. | ui-only |
| SET-002 | view | Page title | SettingsView.swift:42 | "Settings", Figtree 26 medium, tracking -0.4. | ui-only |
| SET-003 | view | Section order | SettingsView.swift:41-130 | Server (if wired), Updates (if wired), General, Microphones (if wired), App context, Models, Rewriting, Summaries (conditional), Permissions needed (conditional), then recording error, then general error. | ui-only |
| SET-004 | view | Section title helper | SettingsView.swift:728-730 | Figtree 14 medium, padding top 29, bottom 13. | ui-only |
| SET-005 | view | Settings group helper | SettingsView.swift:732-735 | VStack spacing 0, horizontal padding 19, canvas background (light 0xF7F6F3, dark 0x1F1F1E), corner radius 12. | ui-only |
| SET-006 | view | Separator | SettingsView.swift:737 | 1 pt line colour (light 0xEEEBE3, dark 0x292928; high contrast light 0x9D9C98, dark 0x71716E). | ui-only |
| SET-007 | view | `SettingsRow` layout | SettingsView.swift:741-779 | HStack spacing 22 (10 compact), vertical padding 19. Left VStack spacing 5: title Figtree 14; detail Figtree 12 muted, line spacing 4, vertical padding 1, wraps vertically. Spacer min 0; control at fixed size. | ui-only |
| SET-008 | view | `SettingsRow` info button | SettingsView.swift:763-768 | Optional `info.circle` at 12, plain, muted, label and tooltip "Model details and verification". | ui-only |
| SET-009 | swift-note | Info button has no caller | SettingsView.swift:745 | No Settings call passes `info:` (grep across Features, UI, App). Port only if a row starts using it. | ui-only |
| SET-010 | view | `PrototypeButtonStyle` | Appearance.swift:101-115 | Figtree 13 medium, padding 12/7, radius 8, tint background (light 0xF1EEE9, dark 0x2A2A29), pressed background button colour (light 0xEEEBE3, dark 0x2E2E2C), disabled opacity 0.45, optional minimum width. Applied to the whole page at SettingsView.swift:142. | ui-only |
| SET-011 | view | `DictionaryPillButtonStyle` | DictionaryView.swift:492-510 | Normal: Figtree 13 regular, padding 12/7, button background, pressed tint. Prominent: Figtree 15 medium, padding 18/10, surface text on ink, pressed ink at 0.8. Radius 8, disabled opacity 0.45. Used in the context sheet. | ui-only |
| SET-012 | view | `RewriteInputSurface` | SettingsView.swift:782-809 | HStack spacing 10; SF symbol muted, width 16, hidden from accessibility; plain field Figtree 13, autocorrect off. Padding horizontal 12, min height 40, surface background (light 0xFCFCFB, dark 0x141414), radius 8. Border 1 line colour, focused 2 accent (light 0x247872, dark 0x68BDB0). | ui-only |
| SET-013 | view | `PillMenu` | SettingsView.swift:1040-1063 | Button-style menu, no indicator. Title plus `chevron.down` Figtree 9 semibold muted, spacing 6. Figtree 13 ink, padding 12/7, button background, radius 8, fixed size. | ui-only |
| SET-014 | view | Warning text colour | Appearance.swift:47 | Warning light 0xB43C0B, dark 0xFB923C; used for every inline error. Muted light 0x686865, dark 0x9D9C98; high contrast light 0x464544, dark 0xC8C8C2. | ui-only |
| SET-015 | behavior | Page neutral focus | SettingsView.swift:134-141 | Page is focusable with no focus ring, takes default focus so the first text field is not selected. Clicking empty page space or pressing Esc moves focus to the page. | ui-only |
| SET-016 | behavior | Refresh on appear | SettingsView.swift:143 | `.task` calls `model.refresh()`, which assigns the snapshot only if it changed (SettingsViewModel.swift:491-494). | core: settings snapshot assembly |
| SET-017 | behavior | Poll while visible | AppServices.swift:1591-1621 | `observeSettingsWhileVisible` polls `refreshSettingsState` every 500 ms while app is active and page is Settings or onboarding is incomplete. Otherwise waits for app activation or `settingsPageChanged`, then refreshes once. | mac-service: AVFoundation, CGPreflightListenEventAccess, AXIsProcessTrusted |
| SET-018 | behavior | Refresh side effects | AppServices.swift:1622-1642 | Microphone newly granted refreshes the input catalog. Reinstalls the shortcut through `shortcutRecovery` when permissions change; failure writes `setupStatus`. Resumes local AI after approval. Then refreshes the snapshot. | mac-service: CGEvent tap |
| SET-019 | behavior | Leaving the page | SettingsView.swift:144-148 | On disappear: `closeRewriteSettings` (clears draft, hides secret, cancels connection test and clears result), stops recorder, clears recorder state. | ui-only |
| SET-020 | behavior | Scroll to anchor | SettingsView.swift:24-37; MainWindowRouter.swift:25-27,78-81 | `SettingsAnchor` has one case, `.microphones`. On appear or anchor change, scrolls target to top with spring response 0.42, damping 0.86 (`PillStyle.morph`, DictationIndicator.swift:9), then clears the anchor. Triggered from a dictation failure's "Microphones…" (AppServices.swift:866). | ui-only |
| SET-021 | state | Page opens from router | LocalFlowApp.swift:351-354 | `.settings` page renders `SettingsView(model: services.settings, preferences: services.preferences, anchor:)`. | ui-only |
| SET-022 | behavior | Permissions section reused | OnboardingView.swift:1112 | Onboarding renders `SettingsView(...).permissionsSection` alone, so that section must be a reusable component. | ui-only |
| SET-023 | state | Recording error line | SettingsView.swift:124-126 | When set: warning colour, padding top 16, at page bottom. Inherits page font. | ui-only |
| SET-024 | state | General error line | SettingsView.swift:127-130 | `model.error`: warning colour, padding top 16, selectable, at page bottom. Set by `run`, cleared at each `run` or `test` start. | ui-only |
| SET-025 | behavior | `run` action wrapper | SettingsViewModel.swift:519-529 | Ignored while `performing`. Sets performing, clears error, awaits action, maps thrown error through `DictationErrorMessage.describe`, then refreshes. | core: action dispatcher |
| SET-026 | state | Error copy: shortcut failures | DictationBoundaries.swift:254-262 | "Allow Accessibility to record and prioritize shortcuts." / "Allow Input Monitoring to use the dictation shortcut." / "That shortcut is unavailable. Try another key combination." / "That shortcut is already registered. Try another combination." / "The keyboard shortcut could not start. Check permissions and try again." | core: error message mapping |
| SET-027 | state | Error copy: busy and model | DictationBoundaries.swift:279-286 | Busy "Another dictation or model operation is still running. Wait for it to finish." Model missing "The speech model is unavailable. Verify the local model in Settings." Cancelled "The operation was cancelled." | core: error message mapping |
| SET-028 | state | Error copy: server only | DictationBoundaries.swift | "Server only is on, but this Mac can't use your server. Check Settings › Server." | core: error message mapping |
| SET-029 | state | Error copy: fallback | DictationBoundaries.swift:305-306 | "Error type <reflected type>, code <NSError code>." Never includes the error description or userInfo. Cancellation: "The operation was cancelled." | core: error message mapping |
| SET-030 | state | Snapshot defaults | SettingsViewModel.swift:67-126 | Before first refresh: nothing installed, permissions `.unknown`, `shortcut` default fn/Globe, `status` "Checking local prerequisites…", `modelDetails` "Model metadata unavailable.", speech model Parakeet Ultra. | core: settings snapshot assembly |
| SET-031 | state | Permission enum labels | SettingsViewModel.swift:15-19 | unknown "Not determined", denied "Not allowed", granted "Allowed". The labels are not rendered on this page. | ui-only |
| SET-032 | behavior | Snapshot sources | AppServices.swift:1658-1709 | Microphone from `AVCaptureDevice.authorizationStatus`: authorized granted, notDetermined unknown, otherwise denied. Input Monitoring from `CGPreflightListenEventAccess`, Accessibility from `AXIsProcessTrusted`, System audio from Screen Recording grant. `busy` = coordinator busy or model command in progress. | mac-service: AVFoundation, CGPreflightListenEventAccess, AXIsProcessTrusted |
| SET-033 | state | Blocked reasons kept in the snapshot | SettingsViewModel.swift:132-164 | `meetingBlockedReason`, `testBlockedReason` strings are used outside this page ("Allow Microphone access to record.", "Local storage is not ready. Check Settings before recording.", "Finish downloading speech recognition first.", "Allow Input Monitoring to use the shortcut.", "Enable a dictation shortcut.", "Allow Accessibility for this shortcut, or choose a modifier key.", "Starting the dictation shortcut…", "Wait for the model operation to finish.", "Wait for the current dictation to finish."). Rust snapshot must carry them. | core: readiness rules |

## Server section

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-034 | view | Section title "Server" | SettingsView.swift:43-50 | Rendered only when `model.server` is set, which happens during `start()` after storage opens (AppServices.swift:615). | ui-only |
| SET-035 | state | Server section not wired | SettingsView.swift:43 | While `server` is nil the whole section is absent, and `rewriteServed` reads false. | ui-only |
| SET-036 | view | Main remote row title | RemoteDictationView.swift:231 | "Remote dictation"; "Your server" when purpose is meetings. | core: `setup.purpose` |
| SET-037 | state | Row detail, off, both or dictation purpose | RemoteDictationView.swift:238 | "Run dictation, rewriting, summaries and meetings on a LocalFlow server you run." | ui-only |
| SET-038 | state | Row detail, off, meetings purpose | RemoteDictationView.swift:235-237 | "Run meeting transcripts and notes on a LocalFlow server you run." | core: `setup.purpose` |
| SET-039 | state | Row detail, on | RemoteDictationView.swift:240-241 | `serverURL · statusText`, empties omitted, joined with " · ". | core: `remote.serverURL`, `remote.state`, `remote.notice` |
| SET-040 | view | Remote toggle | RemoteDictationView.swift:173-180 | Switch, label hidden, accessibility id `settings.remoteEnabled`. Shows `remote.enabled`. | ui-only |
| SET-041 | behavior | Toggle on | RemoteDictationView.swift:81-85,177 | `requestTurnOn`: clears error, `serverDraft` = stored `remote.serverURL`, opens consent sheet. Nothing persisted, switch stays off. | ui-only |
| SET-042 | behavior | Toggle off | RemoteDictationView.swift:156,177 | `requestTurnOff`: opens confirmation dialog. Switch stays on until confirmed. | ui-only |
| SET-043 | state | Status: update required | RemoteDictationView.swift:68 | Takes precedence over state when `remote.notice` = `update_required`: "Update LocalFlow or the server". | core: `remote.notice` |
| SET-044 | state | Status: off, checking | RemoteDictationView.swift:70 | State off and no identity: "Checking the server…". | core: `remote.state` |
| SET-045 | state | Status: off, identity fetched | RemoteDictationView.swift:70 | "Compare the fingerprint". | flowd: GET /v1/remote/identity |
| SET-046 | state | Status: signed out, pinned | RemoteDictationView.swift:71-72 | State pinned: "Sign in to finish". | core: `remote.state` |
| SET-047 | state | Status: signed out, session lost | RemoteDictationView.swift:72 | State pinned with notice `sign_in_again`: "Sign in again". | core: `remote.notice` |
| SET-048 | state | Status: pending approval | RemoteDictationView.swift:73 | "Waiting for approval". No sign-in or retry control. A pending device refreshes at dictation start (RemoteEnrollment.swift:244-247). | flowd: wss /v1/remote/channel refresh |
| SET-049 | state | Status: approved | RemoteDictationView.swift:74 | "Approved". Setup details hide unless identity or error exists. | core: `remote.state` |
| SET-050 | state | Status: rejected | RemoteDictationView.swift:75 | "Rejected". Shows Enroll Again. | core: `remote.state` |
| SET-051 | state | Status: revoked | RemoteDictationView.swift:76 | "Removed from the server". Shows Enroll Again. | core: `remote.state` |
| SET-052 | state | Status: pin mismatch | RemoteDictationView.swift:77 | "Server identity changed". Shows Enroll Again. | core: `remote.state` |
| SET-053 | state | Setup details visibility | RemoteDictationView.swift:63,182-183 | Shown when on and (state not approved, or identity present, or error present). 1 pt line above. VStack spacing 12, full width leading, vertical padding 16. | ui-only |
| SET-054 | view | Fingerprint label | RemoteDictationView.swift:186-187 | When identity fetched: "Server fingerprint", Figtree 12 medium muted. | ui-only |
| SET-055 | view | Fingerprint value | RemoteDictationView.swift:188-189 | System monospaced 13, selectable, id `settings.remoteFingerprint`. Value from server identity (`fingerprint`). | flowd: GET /v1/remote/identity |
| SET-056 | view | Fingerprint instruction | RemoteDictationView.swift:190-191 | "Compare it with `flowd admin identity` on the server before trusting it." Figtree 12 muted. SwiftUI renders the backticks as inline code. | ui-only |
| SET-057 | view | Trust button | RemoteDictationView.swift:192-193 | "Trust This Server", id `settings.remoteTrust`. | ui-only |
| SET-058 | behavior | Trust action | RemoteDictationView.swift:119-127; RemoteEnrollment.swift:160-168 | `pin(identity)`: validates key, `credentials.removeAll`, writes Keychain `server-key`, clears notice, `remote.state` = pinned, clears in-memory identity. Failure: "The server identity could not be saved." | mac-service: Keychain `<bundle id>.remote` / `server-key` |
| SET-059 | state | Pinned fingerprint line | RemoteDictationView.swift:194-197 | No identity, state not approved, pin exists: "Pinned fingerprint  <fp>" (two spaces), system monospaced 12 muted, selectable. Format: first 32 hex of SHA-256 of key in eight 4-char groups joined by "-" (RemoteProtocol.swift:92-95). | mac-service: Keychain `server-key` |
| SET-060 | state | Sign-in buttons visibility | RemoteDictationView.swift:61,198-207 | Shown when on, state pinned, identity nil. HStack spacing 8. Disabled while `busy`. | ui-only |
| SET-061 | view | Sign in with Apple | RemoteDictationView.swift:200-201 | "Sign in with Apple", id `settings.remoteSignInApple`. Always available. | mac-service: ASAuthorization |
| SET-062 | view | Sign in with Google | RemoteDictationView.swift:202-205 | "Sign in with Google", id `settings.remoteSignInGoogle`. Hidden unless Info.plist `LocalFlowGoogleClientID` is non-empty (AppServices.swift:595-598). | mac-service: ASWebAuthenticationSession |
| SET-063 | behavior | Sign-in action | RemoteDictationView.swift:129-143; RemoteEnrollment.swift:177-225 | Sets busy, clears error. Creates Secure Enclave key, opens channel with purpose enroll, nonce from channel binding (SHA-256 hex for Apple, raw base64url for Google), provider sign-in, signs `localflow-v1-enroll` + binding, sends `enroll`. On `enrolled`: writes Keychain `device-key` and optional `refresh-token`, removes `access-token`, clears notice, sets `remote.state` pending, approved or rejected. Approved refreshes tokens immediately. | flowd: wss /v1/remote/channel enroll |
| SET-064 | behavior | Google OAuth flow | RemoteEnrollment.swift:504-568 | Ephemeral `ASWebAuthenticationSession` to accounts.google.com with PKCE S256, scope "openid email", redirect `<reverse client id>:/oauth2redirect`; token exchange at oauth2.googleapis.com/token, max 65,536 bytes. | mac-service: ASWebAuthenticationSession |
| SET-065 | behavior | Apple sign-in flow | RemoteEnrollment.swift:490-502 | `ASAuthorizationController`, scope email, presented on key window. | mac-service: ASAuthorization |
| SET-066 | state | Sign-in failed error | RemoteDictationView.swift:136-137 | "Sign-in did not finish." | ui-only |
| SET-067 | state | Sign-in unreachable error | RemoteDictationView.swift:140-141 | "The server could not be reached. Try again." | ui-only |
| SET-068 | state | Sign-in pin mismatch | RemoteDictationView.swift:138-139; RemoteEnrollment.swift:221,370-375 | No error text. Removes `access-token`, `remote.state` = `pin_mismatch`, row shows "Server identity changed". | flowd: wss /v1/remote/channel |
| SET-069 | view | Enroll Again button | RemoteDictationView.swift:208-210 | "Enroll Again" when state is `pin_mismatch`, revoked or rejected. Disabled while busy. | ui-only |
| SET-070 | behavior | Enroll Again action | RemoteDictationView.swift:106-117 | `fetchIdentity`: sets busy, clears error, fetches. On success shows fingerprint and Trust. | flowd: GET /v1/remote/identity |
| SET-071 | behavior | Identity fetch | RemoteEnrollment.swift:152-157,437-454 | `GET <origin>/v1/remote/identity`, timeout 10 s, ephemeral session, no cookies, must be 200 and at most 4,096 bytes, key must validate. | flowd: GET /v1/remote/identity |
| SET-072 | state | Identity fetch error | RemoteDictationView.swift:113-116 | "The server did not answer with a LocalFlow identity. Check the address." | flowd: GET /v1/remote/identity |
| SET-073 | view | Setup error line | RemoteDictationView.swift:211-213 | Figtree 12 warning. | ui-only |
| SET-074 | swift-note | Failed identity fetch has no retry | RemoteDictationView.swift:70,208-210 | State stays off and identity nil, so the status reads "Checking the server…" though nothing is running, next to the error. Enroll Again does not show for state off; recovery is turning the switch off and on. After relaunch with state off, identity is memory-only and no fetch runs, so the line stays without an error or any control. | flowd: GET /v1/remote/identity |
| SET-075 | swift-note | `needsTrust` unused | RemoteDictationView.swift:60 | Declared, read nowhere. The view branches on `identity` directly. | ui-only |
| SET-076 | swift-note | Turn-off title in meeting-only setup | RemoteDictationView.swift:220,231 | Row is "Your server" but the dialog still says "Turn off remote dictation?". | ui-only |
| SET-077 | view | Consent sheet | RemoteDictationView.swift:218,244-269 | Padding 24, width 460, VStack leading spacing 16. Presented from `showingConsent`. | ui-only |
| SET-078 | view | Consent title | RemoteDictationView.swift:246 | "Use your LocalFlow server?", Figtree 17 medium. | ui-only |
| SET-079 | view | Server address field | RemoteDictationView.swift:247-250 | `RewriteInputSurface` symbol `server.rack`, placeholder "https://server.example.com", id `settings.remoteServerURL`, binds `serverDraft` (not persisted). | ui-only |
| SET-080 | view | Consent body | RemoteDictationView.swift:251-252 | Figtree 13, line spacing 3, wraps. Text from `currentConsentText`. | ui-only |
| SET-081 | state | Consent text: dictation | RemoteDictationView.swift:11-12,46-48 | Used when purpose not meetings and `server.only` off: "Dictation audio, transcripts, Dictionary terms and rewrite text will leave this Mac for the server below while remote dictation is on. With Use this server for everything, so will meeting audio, meeting transcripts and the text summaries are made from. The server's administrator can see audio while it is being processed. Nothing is sent until the administrator approves this device; dictation stays local whenever the server can't be reached." | core: `setup.purpose`, `server.only` |
| SET-082 | state | Consent text: meetings or server only | RemoteDictationView.swift:16-17,46-48 | "Meeting audio, meeting transcripts and the text summaries are made from will leave this Mac for the server below. The server's administrator can see audio while it is being processed. Meetings handed off to the server stay there until they are merged back, at most 7 days. Nothing is sent until the administrator approves this device; recordings wait on this Mac while the server can't be reached. If you set up dictation later, dictation audio, transcripts, Dictionary terms and rewrite text go to this server too." | core: `setup.purpose`, `server.only` |
| SET-083 | swift-note | Server-only consent wording | RemoteDictationView.swift:45-48 | A both-purpose Mac with `server.only` on gets the meeting text, which leads with meetings and says "If you set up dictation later" though dictation is already set up. Dictation still goes to the server, so the disclosure is covered but the wording is off. | ui-only |
| SET-084 | state | Consent server line | RemoteDictationView.swift:253-256 | Only when draft is a valid origin: "Server: <host>" (falls back to absolute string), Figtree 13 medium. | ui-only |
| SET-085 | state | Consent error line | RemoteDictationView.swift:257-259 | Figtree 12 warning. | ui-only |
| SET-086 | view | Consent Cancel | RemoteDictationView.swift:262 | "Cancel", Esc shortcut. | ui-only |
| SET-087 | behavior | Consent Cancel action | RemoteDictationView.swift:88-91 | Closes sheet, clears draft. No address, switch or connection stored. | ui-only |
| SET-088 | view | Consent Turn On | RemoteDictationView.swift:263-265 | "Turn On", Return shortcut, disabled when draft is not a valid origin, id `settings.remoteConsentConfirm`. | ui-only |
| SET-089 | behavior | Consent Turn On action | RemoteDictationView.swift:94-103 | Stores `remote.serverURL`, `remote.consentVersion` = 2, `remote.enabled` = true, closes sheet, then fetches identity. | core: `remote.serverURL`, `remote.consentVersion`, `remote.enabled` |
| SET-090 | behavior | Server address validation | RemoteEnrollment.swift:43-55 | Trimmed; scheme exactly `https`; non-empty host; no user, password, query or fragment; path empty or "/". Stored as lowercased host with port kept. | core: `RemoteDictationSettings.origin` |
| SET-091 | swift-note | Consent address error unreachable | RemoteDictationView.swift:95-97,264 | "Enter the server's https:// address without a path." is set only if `setRemoteServerURL` fails, but Turn On is disabled under the same validator, and Return follows the disabled button. | ui-only |
| SET-092 | view | Turn-off dialog | RemoteDictationView.swift:219-228 | Title "Turn off remote dictation?". Message "This Mac's sign-in, device key and server pin are deleted. Your history stays. You will need approval again to turn it back on." Buttons "Turn Off" (destructive), "Cancel" (cancel role). | ui-only |
| SET-093 | behavior | Turn-off Cancel | RemoteDictationView.swift:157 | Closes dialog only. | ui-only |
| SET-094 | behavior | Turn-off confirm | RemoteDictationView.swift:159-164; AppServices.swift:234-243; RemoteEnrollment.swift:394-401 | Clears identity and error. Cancels refresh. Removes four Keychain items. `resetRemote`, drops enrollment instance, closes parked rewrite channels. | mac-service: Keychain `<bundle id>.remote` |
| SET-095 | behavior | `resetRemote` | AppPreferences.swift:232-242 | `remote.enabled` false stored; removes `remote.serverURL`, `remote.state`, `remote.consentVersion`, `remote.fallbackThresholdMs`, `remote.notice`; `serverCapabilities` nil. Keeps `server.only`, `server.useForEverything`, `server.override.*`. History stays. | core: `remote.*` keys |
| SET-096 | state | Server only survives turn-off | ServerSettingsView.swift:204; AppPreferences.swift:232-242 | With `server.only` on and remote off, the "Server only" row still shows, by design of the `approved or serverOnly` condition. | core: `server.only` |
| SET-097 | behavior | Server answers mapped to state | RemoteEnrollment.swift:339-366 | revoked: remove access and refresh tokens, state revoked. notApproved: remove access token, pending unless rejected. unauthorized: remove both tokens, state pinned, notice `sign_in_again`. unsupportedVersion: notice `update_required`. tokenExpired: remove access token. | flowd: wss /v1/remote/channel error codes |
| SET-098 | behavior | Device key lost | RemoteEnrollment.swift:379-388 | Removes access, refresh and device keys, state pinned, notice `sign_in_again`. | mac-service: Secure Enclave |
| SET-099 | behavior | Token refresh | RemoteEnrollment.swift:103,258-334 | One refresh at a time, scheduled 12 min after issue over channel purpose refresh, signing `localflow-v1-refresh` + binding + token digest. Rotates `refresh-token`, writes `access-token`, clears notice, moves to approved. | flowd: wss /v1/remote/channel refresh |
| SET-100 | view | "Use this server for everything" row | ServerSettingsView.swift:195-203 | Only when approved. 1 pt line above. No detail. Row disabled when `server.only` on. | ui-only |
| SET-101 | behavior | Use for everything toggle | ServerSettingsView.swift:45-51 | Switch, id `settings.serverUseForEverything`. Reads stored value or `server.only`; unset reads as `routesToServer`. Writes `server.useForEverything`, clears check result. Routing change re-evaluates Parakeet and MTPLX residency (AppServices.swift:2325-2341, 2255-2266). | core: `server.useForEverything` |
| SET-102 | state | Approved definition | ServerSettingsView.swift:43; RemoteEnrollment.swift:38 | `enabled` with consent version at least 1, origin present, state approved. | core: `ServerRouting` |
| SET-103 | view | "Server only" row | ServerSettingsView.swift:204-215 | Shown when approved or `server.only` on. Detail "Never load models on this Mac. Without the server, dictation keeps the audio for a retry and meetings wait." Switch id `settings.serverOnly`. | ui-only |
| SET-104 | behavior | Server only toggle | ServerSettingsView.swift:54-60 | Writes `server.only`, clears check result. Forces use-for-everything and every override to server, disables pickers, forbids local models. | core: `server.only` |
| SET-105 | state | Updated consent row | ServerSettingsView.swift:217-226 | When approved, on, consent version below 2, and use-for-everything on: "Summaries and meetings", detail "Confirm the updated consent to send them to your server." | core: `remote.consentVersion` |
| SET-106 | view | Review button | ServerSettingsView.swift:223-224 | "Review…", id `settings.serverConsentUpdate`, opens update sheet. | ui-only |
| SET-107 | view | Consent update sheet | ServerSettingsView.swift:248,302-316 | Title "Send summaries and meetings to your server?" Figtree 17 medium; body `currentConsentText`, Figtree 13, line spacing 3. Padding 24, width 460, spacing 16. | ui-only |
| SET-108 | behavior | Consent update Cancel | ServerSettingsView.swift:309 | "Cancel", Esc; closes sheet, version unchanged. | ui-only |
| SET-109 | behavior | Consent update Confirm | ServerSettingsView.swift:310-312; RemoteDictationView.swift:151-154 | "Confirm", Return, id `settings.serverConsentConfirm`; writes `remote.consentVersion` = 2. | core: `remote.consentVersion` |
| SET-110 | view | "Services" row | ServerSettingsView.swift:227-241 | Only when approved. Title "Services", detail placement line, control HStack spacing 10. id `settings.serverServices`. | ui-only |
| SET-111 | behavior | Placement line | ServerSettingsView.swift:80-95 | Rows Dictation, Rewriting, Summaries, Meetings, grouped by place in order. One group starting "On ": "Everything on your server" or "Everything on your custom server" or "Everything on this Mac". Else "<place>: <rows>" joined " · ". | core: `ServerRouting.path` |
| SET-112 | state | Place values | ServerSettingsView.swift:62-71 | "On your server", "On your custom server", "On this Mac", "Not offered by this server" (approved, switch on, not offered), under server only: "Needs consent" (approved, summaries or meetings, consent old, offered) or "Unavailable". | core: `ServerRouting`, `server.capabilities` |
| SET-113 | behavior | Service routing rules | ServerRouting.swift:41-95 | Dictation: streams unless override thisMac. Others: need switch, capability offered, override server; summaries and meetings also need consent current. Capabilities: ops `dictation_start`, `rewrite`, `analysis`, `live_window`; meeting jobs `transcribe`, `diarize`, `embed`. Meetings row stands on `.finalTranscript`. | core: `ServerRouting` |
| SET-114 | view | Check connection button | ServerSettingsView.swift:234-238 | "Check connection"; "Checking…" and disabled while running. id `settings.serverCheckConnection`. | ui-only |
| SET-115 | behavior | Check connection action | ServerSettingsView.swift:165-181; RemoteDictationSession.swift:470 | If nothing routes to server: no request. Otherwise one timed `channels.roundTrip(.background)`. | flowd: wss /v1/remote/channel round trip |
| SET-116 | view | Check result text | ServerSettingsView.swift:230-233 | Figtree 12 muted, id `settings.serverCheckResult`. Cleared by any routing control here. | ui-only |
| SET-117 | state | Check: nothing on server | ServerSettingsView.swift:168 | "Nothing runs on your server" | core: `ServerRouting` |
| SET-118 | state | Check: unreachable (offline) | ServerSettingsView.swift:174 | "Server unreachable" | flowd: wss /v1/remote/channel round trip |
| SET-119 | state | Check: answered | ServerSettingsView.swift:180 | "Answered in <n> ms" | flowd: wss /v1/remote/channel round trip |
| SET-120 | view | Server Advanced disclosure | ServerSettingsView.swift:243-245 | "Advanced" disclosure, collapsed by default (view state, not persisted), Figtree 12 muted, vertical padding 14, id `settings.serverAdvanced`. Only when approved. | ui-only |
| SET-121 | view | Advanced row: Dictation | ServerSettingsView.swift:252-254 | Title "Dictation", detail "Speech recognition; rewriting follows its own row". Picker: "Your server" (`server`), "This Mac" (`thisMac`). | ui-only |
| SET-122 | behavior | Dictation override | ServerSettingsView.swift:133-139; AppPreferences.swift:289-294 | Writes `server.override.dictation`, clears check. Custom coerced to server. Reads server under `server.only`. | core: `server.override.dictation` |
| SET-123 | view | Advanced row: Rewriting | ServerSettingsView.swift:256-259 | Title "Rewriting". Picker: "Your server", "This Mac", "Custom server" (`custom`). When custom and switch applies, shows rewrite server fields below. | ui-only |
| SET-124 | behavior | Rewriting override | ServerSettingsView.swift:104-110 | Writes `server.override.rewrite`, clears check. This Mac sends rewrites to loopback flowd. | core: `server.override.rewrite` |
| SET-125 | view | Advanced row: Summaries | ServerSettingsView.swift:261-267 | Title "Summaries". Detail "Your server is used if this server fails" only when custom fields show. Picker with all three options. Shows summary server fields below when custom. | ui-only |
| SET-126 | behavior | Summaries override | ServerSettingsView.swift:113-120 | Writes `server.override.summaries`, clears check. Custom also writes `summaryServer` = remote, and picking another option does not revert that. | core: `server.override.summaries`, `summaryServer` |
| SET-127 | view | Advanced row: Meetings | ServerSettingsView.swift:269-271 | Title "Meetings", detail "Transcripts, speaker labels and voice matching". Picker: "Your server", "This Mac". | ui-only |
| SET-128 | behavior | Meetings override | ServerSettingsView.swift:123-129; AppPreferences.swift:302-307 | Writes `server.override.meetings`, clears check. Custom coerced to server. | core: `server.override.meetings` |
| SET-129 | view | Override picker style | ServerSettingsView.swift:288-300 | Label hidden, ink tint, width 150, disabled when `server.only` on. Accessibility "<service> runs on", id `settings.serverOverride.<service lowercase>`. | ui-only |
| SET-130 | view | Advanced row: Fallback threshold | ServerSettingsView.swift:273-279 | Title "Fallback threshold", detail "Dictation uses this Mac after this wait". Stepper 250...10,000 step 250, label "<n> ms" monospaced digits. Accessibility "Remote dictation fallback threshold in milliseconds", id `settings.serverFallbackThreshold`. | ui-only |
| SET-131 | behavior | Fallback threshold control | ServerSettingsView.swift:146-149 | Clamps 250...10,000, writes `remote.fallbackThresholdMs`. | core: `remote.fallbackThresholdMs` |
| SET-132 | swift-note | Fallback stepper ignored in release | AppPreferences.swift:252-257,214; ServerSettingsView.swift:273 | `remoteFallbackThreshold` returns the fixed 1,500 ms unless `allowsDeveloperSettings` (Debug or dev variant), yet the stepper shows in every build. In production it moves the number and changes nothing. It also stays enabled under `server.only`. | core: `remote.fallbackThresholdMs` |
| SET-133 | view | Advanced row: Server fingerprint | ServerSettingsView.swift:280-285 | When pinned: title "Server fingerprint", detail fingerprint, no control, selectable, id `settings.serverFingerprint`. | mac-service: Keychain `server-key` |

## Updates section

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-134 | view | Section title "Updates" | SettingsView.swift:51-54 | Rendered when `model.updater` set, assigned at start (AppServices.swift:299). Prototype button style on the section. | ui-only |
| SET-135 | state | Updates unavailable row | UpdatesSettingsSection.swift:8-16 | Title "Software updates", detail is the reason. Replaces both normal rows. | mac-service: Sparkle |
| SET-136 | state | Reason: manual build | UpdateController.swift:40-43,52-55 | "This build uses manual updates. Download the latest version from GitHub." Always in DEBUG. In release when bundle id is not `org.localflow.LocalFlow`, `LocalFlowSignedUpdates` is not true, `SUFeedURL` is not https with a host, or `SUPublicEDKey` does not decode to 32 bytes. | mac-service: Sparkle |
| SET-137 | state | Reason: updater start failed | UpdateController.swift:57-60 | "The updater could not start. Reopen LocalFlow to retry." | mac-service: Sparkle |
| SET-138 | view | View Downloads link | UpdatesSettingsSection.swift:10-15 | "View Downloads" to https://github.com/brunovskyoliver/local_flow/releases/latest, id `settings.updateDownloads`. Opens the browser. | mac-service: NSWorkspace open URL |
| SET-139 | view | "Latest version" row | UpdatesSettingsSection.swift:18-22 | Title "Latest version", detail "You choose when to install." | ui-only |
| SET-140 | view | Check for Updates button | UpdatesSettingsSection.swift:19-21 | "Check for Updates…", disabled unless `canCheck`, id `settings.checkForUpdates`. | mac-service: Sparkle |
| SET-141 | behavior | Check for Updates action | UpdateController.swift:32-36,112-115 | Calls `checkForUpdates` on Sparkle's standard controller, then rereads `canCheck`. KVO on `canCheckForUpdates` updates the button. | mac-service: Sparkle |
| SET-142 | view | "Check automatically" row | UpdatesSettingsSection.swift:24-30 | Title "Check automatically", detail "Installation waits until active work finishes." Switch, accessibility name "Check for updates automatically", id `settings.automaticUpdates`. | mac-service: Sparkle |
| SET-143 | behavior | Check automatically toggle | UpdateController.swift:20-22,95-98 | Writes `automaticallyChecksForUpdates`; Sparkle owns persistence, no LocalFlow key. | mac-service: Sparkle |
| SET-144 | behavior | Sparkle config | UpdateController.swift:102-106 | No system profile, no automatic download, release notes not downloaded. | mac-service: Sparkle |
| SET-145 | behavior | Install gate | UpdateController.swift:66-84,132-146 | Relaunch postponed while busy; rechecks every 1 s and resumes when idle. Abort clears the gate. | mac-service: Sparkle |

## General section

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-146 | view | Section title "General" | SettingsView.swift:55 | Always shown. | ui-only |
| SET-147 | state | Meeting-only variant | SettingsView.swift:57,673 | Purpose meetings shows "Set up dictation" in place of Shortcut. | core: `setup.purpose` |
| SET-148 | view | "Set up dictation" row | SettingsView.swift:58-61 | It is a normal row, not a card. Title "Set up dictation", detail "Hold a key in any app to talk. Meetings stay as they are." | ui-only |
| SET-149 | view | Set Up button | SettingsView.swift:62-65 | "Set Up", min width 99, disabled while `performing`, id `settings.setUpDictation`. | ui-only |
| SET-150 | behavior | Set Up action | SettingsView.swift:62; AppServices.swift:1871,2094-2097; OnboardingCoordinator.swift:74-79 | Writes `setup.purpose` = both. Saves Right Control to `shortcut` only if none saved, then installs saved shortcut. Install failure writes `setupStatus` only. `server.only` stays, since the meeting consent covers dictation. | mac-service: CGEvent tap |
| SET-151 | view | "Shortcut" row | SettingsView.swift:69-79 | Title "Shortcut". Button min width 99, id `settings.shortcut`, disabled when snapshot busy or performing. | ui-only |
| SET-152 | state | Shortcut idle | SettingsView.swift:71,73 | Button shows `shortcut.title`, no detail. | core: `shortcut` |
| SET-153 | state | Shortcut listening | SettingsView.swift:71,73 | Button "Listening…", detail "Press a shortcut, then release. Esc to cancel." | ui-only |
| SET-154 | behavior | Shortcut button | SettingsView.swift:711-726 | While recording: stops with no callback. Otherwise clears recording error, starts recorder. Start failure sets the recording error. Completion clears recorder and calls `configureShortcut` when a value was captured. | mac-service: CGEvent tap |
| SET-155 | behavior | Recorder start requirements | ShortcutPreference.swift:225-262 | Only one recorder at a time, else busy error. Requires `AXIsProcessTrusted`, else "Allow Accessibility to record and prioritize shortcuts." Tap at cgSessionEventTap head insert for keyDown, keyUp, flagsChanged, consuming events. Tap creation failure: "The keyboard shortcut could not start. Check permissions and try again." | mac-service: CGEvent tap, AXIsProcessTrusted |
| SET-156 | behavior | Recorder auto-cancel | ShortcutPreference.swift:239-246,268-275 | Cancels with no value at 30 s, on app resign active, on inactive event, and on tap disabled. | mac-service: CGEvent tap |
| SET-157 | behavior | Capture rules | ShortcutPreference.swift:177-208 | Esc keyDown cancels. First keyDown makes a key combination with current modifiers and physical sides. Modifier flags accumulate into modifier-only. Commits once all modifiers are up, and the key is up for a combination. Fn alone becomes `fn_globe`. Invalid candidate stays pending. | core: shortcut capture state machine |
| SET-158 | swift-note | Esc combos cannot be recorded | ShortcutPreference.swift:59,181 | `isValid` accepts Esc with modifiers, but capture cancels on any Esc keyDown regardless of modifiers. | core: shortcut capture state machine |
| SET-159 | behavior | Shortcut validation | ShortcutPreference.swift:46-61 | Version must be 1. Modifiers within cmd, control, option, shift, fn (1<<23). Device mask valid and consistent, not on fn_globe. fn_globe always valid. Modifier-only needs a modifier. Combination: keyCode under 128, not 54-63, not bare Esc (53). A bare letter with no modifier is valid. | core: `shortcut` |
| SET-160 | behavior | Shortcut title | ShortcutPreference.swift:93-109 | Not enabled "Disabled"; `fn_globe` "fn / Globe". Otherwise in order ⌃ ⌥ ⇧ ⌘, each replaced with side names when recorded ("Left Control", "Right Control", "Left Option", "Right Option", "Left Shift", "Right Shift", "Left Command", "Right Command"), then "fn", then key, joined with a space. | ui-only |
| SET-161 | behavior | Key titles | ShortcutPreference.swift:111-141 | 36 "Return", 48 "Tab", 49 "Space", 51 "⌫", 53 "Esc", 65 ".", 67 "*", 69 "+", 71 "Clear", 75 "/", 76 "Enter", 78 "−", 81 "=", keypad 82-92 digits, 114 "Help", 115 "Home", 116 "Page Up", 117 "⌦", 119 "End", 121 "Page Down", 123 "←", 124 "→", 125 "↓", 126 "↑", function codes F1-F20. Others via current layout, uppercased; fallback "Key <code>". | mac-service: TISCopyCurrentKeyboardLayoutInputSource, UCKeyTranslate |
| SET-162 | behavior | Implicit Fn filter | ShortcutPreference.swift:75-91 | Secondary Fn flag ignored for function and navigation keycodes, so an F-key does not become an Fn chord. | mac-service: CGEvent flags |
| SET-163 | behavior | Save shortcut | AppServices.swift:1877-1882; ShortcutPreference.swift:161-164 | Ignored for meeting purpose; busy throws. Installs first, saves JSON to UserDefaults `shortcut` only if install succeeded. Status "Shortcut updated." or "Shortcut disabled." | core: `shortcut`; mac-service: CGEvent tap |
| SET-164 | behavior | Install rules | ShortcutController.swift:125-139 | Invalid binding throws. Meetings purpose removes any tap. Not enabled removes tap. Needs `CGPreflightListenEventAccess`, else permission denied. | mac-service: CGEvent tap |
| SET-165 | state | Shortcut enabled flag | ShortcutPreference.swift:16,94 | The `enabled` field has no control on this page, so "Disabled" appears only from a stored value. | core: `shortcut` |
| SET-166 | view | "Appearance" row | SettingsView.swift:82-88 | Picker width 110, label hidden, ink tint, id `settings.appearance`. Options System (`system`), Light (`light`), Dark (`dark`). | ui-only |
| SET-167 | behavior | Appearance picker | AppPreferences.swift:31-33; LocalFlowApp.swift:203; AppServices.swift:1584 | Writes `appearance`, then `NSApp.appearance`: nil for System so it follows the OS, aqua, darkAqua. | core: `appearance`; mac-service: NSApp.appearance |
| SET-168 | view | "Learn corrections" row | SettingsView.swift:90-94 | Switch, no detail, id `settings.learnCorrections`. | ui-only |
| SET-169 | behavior | Learn corrections toggle | AppPreferences.swift:55-57; AppServices.swift:717 | Writes `learnCorrections`. Read by `CorrectionLearner`. Off is the default; on is consent to read back the field after insertion. | core: `learnCorrections`; mac-service: Accessibility field read |
| SET-170 | view | "Show meeting progress" row | SettingsView.swift:96-100 | Switch, no detail, id `settings.showsBackgroundProgress`. | ui-only |
| SET-171 | behavior | Show meeting progress toggle | AppPreferences.swift:51-53; AppServices.swift:1281 | Writes `showsBackgroundProgress`. Off hides the background meeting pill; dictation pill unaffected. | core: `showsBackgroundProgress` |
| SET-172 | view | "Meeting language" row | SettingsView.swift:102-108 | Picker width 210, id `settings.meetingLanguage`. Options "Automatic (English/Slovak)" (`automatic`), "Slovak" (`slovak`), "English" (`english`). | ui-only |
| SET-173 | behavior | Meeting language picker | AppPreferences.swift:63-65,362-367; MeetingLanguage.swift:43-57 | Writes `settings.meetingLanguage`. Maps to whisper `auto`, `sk`, `en`. Removed values such as "czech" read and rewrite as automatic. Change starts a new pass via pipeline tag. | core: `settings.meetingLanguage` |

## Microphones section

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-174 | state | Section not wired | SettingsView.swift:110; AppServices.swift:287 | Hidden until the catalog starts. | mac-service: CoreAudio |
| SET-175 | view | Section title "Microphones" | SettingsView.swift:111 | Scroll anchor `.microphones`. | ui-only |
| SET-176 | view | Section description | SettingsView.swift:112-114 | "LocalFlow records from the first microphone on this list that is connected." Figtree 12 muted, wraps, padding bottom 12. | ui-only |
| SET-177 | behavior | Catalog follow | MicrophonesSection.swift:51-52; MicrophonesViewModel.swift:65-73 | On appear rebuilds from snapshot. While shown, each catalog change reconciles the store and rebuilds rows. | mac-service: CoreAudio |
| SET-178 | view | Microphone row | MicrophonesSection.swift:67-76 | `SettingsRow` title name plus " · XXXX" for duplicates. Full row is hit target. List id `settings.microphones.list`. 1 pt line after every row including the last. | ui-only |
| SET-179 | state | Connected device detail | MicrophonesSection.swift:61-65 | "<kind>", plus Bluetooth note, joined " · ". Kinds "Built-in", "USB", "Bluetooth", "iPhone", "Virtual", "Other" (InputDevicePriority.swift:26-35). | mac-service: CoreAudio transport type |
| SET-180 | state | Not connected row | MicrophonesViewModel.swift:11,126; MicrophonesSection.swift:74 | Detail "<kind> · Not connected", opacity 0.55. | mac-service: CoreAudio |
| SET-181 | state | System default row | MicrophonesViewModel.swift:123-125; MicrophonesSection.swift:62,74 | Name "System default", detail "Currently: <name>", or "Currently: none" with no default input. Opacity always 1. No Remove. | mac-service: CoreAudio default input |
| SET-182 | state | Bluetooth note | MicrophonesViewModel.swift:10,134 | On every Bluetooth row: "Uses call-quality audio and lowers playback quality while recording." | ui-only |
| SET-183 | state | Duplicate name suffix | MicrophonesViewModel.swift:128,131 | Same name on more than one row: "· " + last 4 of UID. | core: `inputDevices.priority.v1` |
| SET-184 | state | Clamshell | InputDevicePriority.swift:189; MicrophonesViewModel.swift:126 | Lid closed: Built-in entry is unavailable, so it reads "Not connected". | mac-service: IOKit clamshell state |
| SET-185 | state | Empty list | InputDevicePriority.swift:343,349 | Missing or unreadable data reads as a single System default entry and is overwritten only by the next edit. | core: `inputDevices.priority.v1` |
| SET-186 | view | Remove button | MicrophonesSection.swift:69-72 | "Remove", always visible (no hover), absent on System default, id `settings.microphones.remove`. | ui-only |
| SET-187 | behavior | Remove action | MicrophonesViewModel.swift:108-111 | Removes at once with no confirmation, saves, rebuilds. | core: `inputDevices.priority.v1` |
| SET-188 | behavior | Drag reorder | MicrophonesSection.swift:17-28; MicrophonesViewModel.swift:94-100 | Row drags its UUID as a string. Drop on a row: dragged takes target's place (to index, or to + 1 moving down). Same row or unknown id no-op. Persists. | core: `inputDevices.priority.v1` |
| SET-189 | view | Drop indicator | MicrophonesSection.swift:13-16 | 2 pt accent bar at the top of the targeted row while hovering; shows top even when the row lands below it. | ui-only |
| SET-190 | behavior | Accessibility reorder | MicrophonesSection.swift:29-35; MicrophonesViewModel.swift:31-41,80-91 | Actions "Move up" (rank above 1), "Move down" (rank below count), "Remove" (not System default). Label "<name>, <kind or Currently>, <rank> of <count>[, not connected]". | ui-only |
| SET-191 | view | "Add microphone" row | MicrophonesSection.swift:38-48 | Menu "Add…" prototype style, id `settings.microphones.add`. Item title "<name> · <kind>". | ui-only |
| SET-192 | behavior | Add item list | MicrophonesViewModel.swift:137-142 | Connected inputs that are alive, unmatched by M1-M3, and whose UID is not listed. | mac-service: CoreAudio |
| SET-193 | behavior | Add action | MicrophonesViewModel.swift:102-105; InputDevicePriority.swift:240-255 | Inserted just above System default, saved, rebuilt. | core: `inputDevices.priority.v1` |
| SET-194 | swift-note | Add errors swallowed | MicrophonesViewModel.swift:103 | `try? store.add` drops `.full`, `.duplicate` and `.invalid` (empty name, bad UID), so the click does nothing with no message. | core: `inputDevices.priority.v1` |
| SET-195 | state | Add disabled: list full | MicrophonesViewModel.swift:13,143-144 | At 32 entries, detail "The list is full", menu disabled. | core: `inputDevices.priority.v1` |
| SET-196 | state | Add disabled: all listed | MicrophonesViewModel.swift:12,145-146 | No candidates, detail "All connected microphones are listed", menu disabled. | mac-service: CoreAudio |
| SET-197 | behavior | Match and reconcile rules | InputDevicePriority.swift:131-169,269-298 | M1 same UID. M2 same kind, name, model UID among the rest. M3 accepted only for exactly one entry and one device. Matched entries take current name, UID, last-seen. Last-seen alone saves at most once a minute. | core: `inputDevices.priority.v1` |
| SET-198 | behavior | List validation | InputDevicePriority.swift:216,220-238; 41-42,94-105 | Capacity 32. One System default, appended if missing. Duplicate UIDs dropped. Name trimmed, 1-128 characters. UID 1-256 bytes. Catalog keeps first 64 inputs with an input stream. | core: `inputDevices.priority.v1` |

## App context section

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-199 | view | Section title "App context" | SettingsView.swift:155 | Always shown. | ui-only |
| SET-200 | view | "Use app context" row | SettingsView.swift:157-161 | Detail "Reads the app name, window title and text around the cursor to spell names as they appear on screen. Never reads passwords, the clipboard or excluded apps." Switch id `settings.contextEnabled`. | ui-only |
| SET-201 | behavior | Use app context toggle | AppPreferences.swift:136-138 | Writes `contextEnabled`. Read fresh per press through `contextSettings()`. | core: `contextEnabled`; mac-service: Accessibility context capture |
| SET-202 | view | "Send context to rewrite server" row | SettingsView.swift:164-173 | Switch id `settings.contextRewriteEnabled`; detail is blocked reason or "Experimental". | ui-only |
| SET-203 | state | Context rewrite blocked: context off | SettingsViewModel.swift:403 | Detail "Turn on Use app context first.", switch disabled and shown off. | core: `contextEnabled` |
| SET-204 | state | Context rewrite blocked: rewriting off | SettingsViewModel.swift:404 | Detail "Turn on rewriting first.", switch disabled and shown off. | core: `rewriteEnabled` |
| SET-205 | behavior | Context rewrite toggle | SettingsView.swift:167-170 | Writes `contextRewriteEnabled`. Stored true comes back on when prerequisites return. | core: `contextRewriteEnabled` |
| SET-206 | view | "Match style to the app" row | SettingsView.swift:175-179 | Detail "Experimental". Switch id `settings.contextStyleEnabled`, disabled when context off. | ui-only |
| SET-207 | behavior | Match style toggle | AppPreferences.swift:143-145,321-327 | Writes `contextStyleEnabled`. Effective only with `contextEnabled`. | core: `contextStyleEnabled` |
| SET-208 | swift-note | Style toggle shows stale value | SettingsView.swift:165-171,176-177 | The rewrite toggle reads off while blocked and explains why. The style toggle keeps its stored value while disabled, with no reason text. | ui-only |
| SET-209 | view | "Excluded apps" row | SettingsView.swift:181-187 | Detail "1 app" or "<n> apps". Button "Edit…", id `settings.contextExclusions`, opens sheet. | ui-only |
| SET-210 | state | Excluded apps default count | AppPreferences.swift:401-408; AppCategory.swift:66-72 | Fresh install shows "10 apps": nine defaults plus LocalFlow itself. Defaults: com.apple.Passwords, com.apple.keychainaccess, com.1password.1password, com.agilebits.onepassword7, com.bitwarden.desktop, com.lastpass.LastPass, org.keepassxc.keepassxc, com.dashlane.dashlanephonefinal, com.moneymoney-app.retail. Written to defaults only on first edit. | core: `contextExcludedBundleIDs` |
| SET-211 | view | "App kinds" row | SettingsView.swift:189-196 | Detail "Built in" when no overrides, otherwise app count. Button "Edit…", id `settings.contextKinds`. | ui-only |
| SET-212 | view | Context sheet frame | SettingsView.swift:838-869 | Padding 22, width 480, spacing 18, surface background, ink text. | ui-only |
| SET-213 | view | Sheet title and description | SettingsView.swift:840-849 | Spacing 4. "Excluded apps" with "App context is never read in these apps." or "App kinds" with "Sets the kind of app used for writing style." Title Figtree 17 medium, description 13 muted. | ui-only |
| SET-214 | state | Sheet empty list | SettingsView.swift:873-878 | "No apps yet", Figtree 14 muted, vertical padding 28, 1 pt line border, radius 12. | ui-only |
| SET-215 | view | Sheet list | SettingsView.swift:880-893 | Hidden scrollbars, bounce only when needed. Height min(count x 57, 308). Radius 12, 1 pt border. Line between rows. | ui-only |
| SET-216 | behavior | Sheet list ordering | SettingsView.swift:830-836 | Exclusions by resolved name, natural order. Kinds by bundle ID. | ui-only |
| SET-217 | view | App row | SettingsView.swift:995-1036 | Height 56, padding horizontal 16, spacing 12. Icon 24x24, or tint rounded rectangle radius 6. Name Figtree 14, bundle ID 12 muted, one line each, spacing 2. | ui-only |
| SET-218 | behavior | App name and icon lookup | SettingsView.swift:952-978 | LaunchServices lookup once per ID while sheet is open. Name without ".app". Not installed: name is the ID, no icon. | mac-service: NSWorkspace urlForApplication, icon |
| SET-219 | state | Own app row | SettingsView.swift:904-905; AppPreferences.swift:166-169; ContextSettings.swift:21 | LocalFlow's own bundle ID shows "Always", Figtree 12 muted, no Remove; store refuses removal. | core: `contextExcludedBundleIDs` |
| SET-220 | view | Exclusion Remove (hover-reveal) | SettingsView.swift:1014-1018; Appearance.swift:134-143 | "Remove" pill. Opacity 0 until row hovered or button focused; always visible under VoiceOver. Stays in the tab order. Accessibility "Stop excluding <name>". | ui-only |
| SET-221 | behavior | Exclusion Remove action | AppPreferences.swift:166-169 | Removes ID, writes `contextExcludedBundleIDs`, no confirmation. | core: `contextExcludedBundleIDs` |
| SET-222 | view | Kind Remove (hover-reveal) | SettingsView.swift:1019-1023 | Same reveal rule. Accessibility "Use the built-in kind for <name>". | ui-only |
| SET-223 | behavior | Kind Remove action | AppPreferences.swift:171-178 | Removes override from `contextCategoryOverrides`. | core: `contextCategoryOverrides` |
| SET-224 | view | Row kind menu | SettingsView.swift:1024-1028 | `PillMenu` with current kind. Options "Email" (`email`), "Work chat" (`work_chat`), "Personal chat" (`personal_chat`), "Code" (`code`), "Terminal" (`terminal`), "Document" (`document`), "Other" (`other`). | ui-only |
| SET-225 | behavior | Row kind change | SettingsView.swift:899-902 | Writes `contextCategoryOverrides`. | core: `contextCategoryOverrides` |
| SET-226 | view | Running app menu | SettingsView.swift:910-918 | `PillMenu` "Running app". Add row spacing 8. | ui-only |
| SET-227 | behavior | Running app list | SettingsViewModel.swift:432-450 | Regular activation policy with a bundle ID, natural name sort. Exclusions sheet omits already excluded. | mac-service: NSWorkspace runningApplications |
| SET-228 | behavior | Running app pick | SettingsView.swift:914-916 | Exclusions: adds at once. Kinds: only fills the Bundle ID draft. | core: `contextExcludedBundleIDs` |
| SET-229 | view | Bundle ID field | SettingsView.swift:919-926 | Placeholder "Bundle ID", plain, Figtree 13, padding 10/7, surface, radius 8, 1 pt line border, id `settings.contextBundleID`. Return adds. | ui-only |
| SET-230 | view | Add-row kind menu | SettingsView.swift:927-933 | Kinds sheet only; default "Work chat". View state. | ui-only |
| SET-231 | view | Add button | SettingsView.swift:934-936 | "Add" pill, disabled when draft is blank after trimming spaces. | ui-only |
| SET-232 | behavior | Add action | SettingsView.swift:940-948; SettingsViewModel.swift:409-429 | Exclusions: `addContextExclusion`. Kinds: `setContextCategory`. Clears draft on success. | core: `contextExcludedBundleIDs`, `contextCategoryOverrides` |
| SET-233 | behavior | Bundle ID validation | AppPreferences.swift:157-185,316-318 | Trimmed, non-empty, at most 255 UTF-8 bytes, no whitespace or newline. Limit 200 per list. Adding an existing exclusion succeeds. | core: `contextExcludedBundleIDs`, `contextCategoryOverrides` |
| SET-234 | state | Exclusion error | SettingsViewModel.swift:414; SettingsView.swift:852-856 | "Enter a bundle ID such as com.example.App. At most 200 apps can be excluded." Figtree 12 warning. | ui-only |
| SET-235 | state | Kind error | SettingsViewModel.swift:428 | "Enter a bundle ID such as com.example.App. At most 200 apps can have a kind." | ui-only |
| SET-236 | swift-note | Sheet errors outlive the sheet | SettingsViewModel.swift:407,420 | The errors live on the view model and clear only on the next add attempt, so reopening the sheet shows the old error. | ui-only |
| SET-237 | view | Done button | SettingsView.swift:857-862 | "Done", prominent pill, right aligned, Return. Dismisses. | ui-only |
| SET-238 | behavior | Effective kind order | AppCategory.swift:75-82 | Override, then built-in map, then `com.jetbrains.` prefix is code, else other. Port the 32-entry `builtIn` map. | core: `AppCategory` |

## Models section

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-239 | view | Section title "Models" | SettingsView.swift:479 | Always shown, including under `server.only`. | ui-only |
| SET-240 | view | Model row format | SettingsView.swift:638-653 | Detail "<role> · <result or status>". Controls HStack spacing 8: extras then Test. | ui-only |
| SET-241 | state | Role place suffix | SettingsView.swift:634-636; ServerSettingsView.swift:152-157 | Before approval: role alone. Approved: "<role> · On your server", "· On this Mac", "· Unavailable", or for dictation "· On this Mac (used if the server is unreachable)". | core: `ServerRouting` |
| SET-242 | view | Test button | SettingsView.swift:646-650 | "Test", only when installed. Disabled while performing or busy. Accessibility "Test <name>". | ui-only |
| SET-243 | behavior | Test action | SettingsViewModel.swift:499-517; AppServices.swift:1795-1815 | Full-hash verify of the model, then `lifecycle.smokeTest` loads, runs once, releases. | core: model provisioner and smoke test |
| SET-244 | state | Test running | SettingsView.swift:642 | Status slot "Testing…". | ui-only |
| SET-245 | state | Test passed | SettingsViewModel.swift:510 | "Working · <ms> ms", kept until next test. | core: model smoke test |
| SET-246 | state | Test failed | SettingsViewModel.swift:512 | Mapped error message in the status slot, not at the page bottom. | core: error message mapping |
| SET-247 | view | Current speech model row | SettingsView.swift:481-495 | Title `speechModel.displayName` ("Parakeet Ultra" or "Parakeet v3"), role "Dictation". | ui-only |
| SET-248 | state | Speech status | SettingsViewModel.swift:95-102 | "Not installed", "Preparing…", "Unloading…", "Ready", "Unloaded". | core: model lifecycle state |
| SET-249 | view | Load or Unload button | SettingsView.swift:486-490 | "Unload" when loaded, else "Load". Disabled unless `modelControlsAvailable`: not performing, not busy, not installing, runtime controls available. | ui-only |
| SET-250 | behavior | Load action | AppServices.swift:1752-1758,1729-1744 | Throws busy if installing, command active, dictation busy or unsaved. `prepareModel` calls `lifecycle.loadIfIdle`. Status "Speech model ready. Hold the shortcut to dictate." | core: model lifecycle |
| SET-251 | behavior | Unload action | AppServices.swift:1770-1776 | `lifecycle.unloadIfIdle`. | core: model lifecycle |
| SET-252 | view | Speech Download button | SettingsView.swift:491-493 | "Download…", when not installed and not installing. Opens dialog. | ui-only |
| SET-253 | view | Speech download dialog | SettingsView.swift:573-583 | Title "Download <name>?". Message "<size>" or "Download size unavailable.", newline, attribution. Buttons "Download", "Cancel". | ui-only |
| SET-254 | state | Attribution copy | SpeechModelChoice.swift:47-54 | v3: "NVIDIA parakeet-tdt-0.6b-v3, Core ML conversion by FluidInference. License: CC BY 4.0." Ultra: "Moondream parakeet-ultra (post-trained from NVIDIA parakeet-tdt-0.6b-v3), Core ML conversion by FluidInference. License: CC BY 4.0." | ui-only |
| SET-255 | behavior | Speech download action | AppServices.swift:2139-2143 | Starts background install, returns at once, so `performing` ends and `snapshot.installing` takes over. | core: model provisioner |
| SET-256 | view | Speech Import button | SettingsView.swift:493 | "Import…". | ui-only |
| SET-257 | behavior | Speech import action | AppServices.swift:2125-2137 | `NSOpenPanel`, folders only, single. Cancel returns with no change. | mac-service: NSOpenPanel |
| SET-258 | view | Install progress | SettingsView.swift:655-670 | VStack spacing 10, Figtree 12, padding bottom 19. Determinate bar when total known, else small spinner. Line "Downloading…" or "Verifying…" with "Cancel" at right. | ui-only |
| SET-259 | behavior | Install Cancel | AppServices.swift:1751,2145 | Cancels the install task. | core: model provisioner |
| SET-260 | view | Alternate speech model row | SettingsView.swift:601-631 | Shown when another manifest exists. Detail "<role> · CC BY 4.0 · <readiness>". id `settings.alternateSpeechModel`. | ui-only |
| SET-261 | state | Alternate role | SettingsViewModel.swift:62-65 | Ultra: "Default for new setups". v3: "Alternative dictation model". | ui-only |
| SET-262 | state | Alternate readiness | SettingsViewModel.swift:55-60 | "Downloading…", "Installed", or "Not installed · <size>". | core: model provisioner |
| SET-263 | view | Alternate Cancel | SettingsView.swift:609-610 | "Cancel" while downloading; cancels the task. | ui-only |
| SET-264 | view | Use for dictation | SettingsView.swift:611-616 | "Use for dictation" when installed. Disabled unless model controls available. Accessibility "Use <name> for dictation". | ui-only |
| SET-265 | behavior | Use for dictation action | AppServices.swift:2012-2039 | Refuses while busy. Selects through lifecycle so one model is loaded. Writes `speechModel`. Status "Dictation now uses <name>." Reloads if keep-loaded applies. | core: `speechModel` |
| SET-266 | view | Alternate Download | SettingsView.swift:617-620 | "Download…", disabled while main install runs. Opens dialog. | ui-only |
| SET-267 | view | Alternate download dialog | SettingsView.swift:584-596 | Title "Download <name>?" (fallback "speech model"). Message "<size> from Hugging Face, verified against pinned hashes.", attribution, "Dictation keeps using <current> until you switch." Buttons "Download", "Cancel". | ui-only |
| SET-268 | behavior | Alternate download action | AppServices.swift:2044-2074 | Runs outside the lifecycle gate; progress polled every 100 ms. Status "<name> downloaded and verified.", "<name> download cancelled.", or "<name> download failed. Check the connection and available storage." | core: model provisioner |
| SET-269 | state | Alternate progress | SettingsView.swift:622-628 | Determinate bar only when total above 0; padding bottom 19. | ui-only |
| SET-270 | view | "Whisper Turbo" row | SettingsView.swift:504-514 | Role "Meeting transcripts", id `settings.meetingModel`. | ui-only |
| SET-271 | state | Whisper status | SettingsViewModel.swift:79-82 | "Installing…", "Ready", "Not installed · 1.63 GB". | core: model provisioner |
| SET-272 | view | Whisper Download and Import | SettingsView.swift:509-512 | "Download" with no confirmation, "Import…". Hidden when installed or installing. | ui-only |
| SET-273 | behavior | Whisper install | AppServices.swift:1825-1834,1891-1906 | Import panel message "Choose a folder containing ggml-large-v3-turbo.bin and silero-vad.bin." Busy while another meeting install runs. Status "Whisper Turbo verified. Final meeting transcripts use it locally." | mac-service: NSOpenPanel |
| SET-274 | view | "Speaker labels" row | SettingsView.swift:516-526 | Role "Who said what", id `settings.speakerModel`. | ui-only |
| SET-275 | state | Speaker status | SettingsViewModel.swift:85-88 | "Installing…", "Ready", "Not installed". | core: model provisioner |
| SET-276 | view | Speaker Download and Import | SettingsView.swift:521-524 | "Download", "Import…". Hidden when installed or installing. | ui-only |
| SET-277 | behavior | Speaker install | AppServices.swift:1842-1850,1910-1925 | Folder panel with no message. Status "Speaker labeling model verified." | mac-service: NSOpenPanel |
| SET-278 | view | "Term booster" row | SettingsView.swift:528-537 | Detail "Dictionary terms in dictation · <status>". No Test, Import or Cancel. id `settings.boostModel`. | ui-only |
| SET-279 | state | Booster status | SettingsViewModel.swift:91-94 | "Installing…", "Ready", "Not installed · 103 MB". | core: model provisioner |
| SET-280 | view | Booster Download | SettingsView.swift:533-535 | "Download". Hidden when installed or installing. | ui-only |
| SET-281 | behavior | Booster install | AppServices.swift:1929-1938 | Through the lifecycle gate, which releases the speech runtime. Status "Term booster verified. Dictionary terms are checked against your speech." | core: model provisioner |
| SET-282 | swift-note | No cancel or progress for three installs | SettingsView.swift:509,521,533; SettingsViewModel.swift:78 | Whisper, speaker and booster show only "Installing…". `meetingProgress` is in the snapshot but no view reads it, and there is no Cancel. | core: model provisioner |
| SET-283 | swift-note | Install buttons not disabled by other installs | SettingsView.swift:510,522,534 | These Downloads ignore `installing`. During another install they throw busy and show the generic busy message at the page bottom. | ui-only |
| SET-284 | swift-note | Install failure not on the row | SettingsViewModel.swift:71,77 | `modelInstallError` is read only by `testBlockedReason` and `meetingModelsError` by nothing here. A failed speech download goes to `setupStatus`, which this page does not show. | ui-only |
| SET-285 | view | "Keep Parakeet loaded" row | SettingsView.swift:539-552 | Switch, disabled unless model controls available. Detail "Applies when dictating on this Mac" when dictation is served by server, otherwise none. | ui-only |
| SET-286 | behavior | Keep Parakeet toggle | AppServices.swift:1759-1769,2269-2273 | Writes `keepModelReady`. Keeps loaded only if local models allowed and dictation not served. Loads now if installed. | core: `keepModelReady` |
| SET-287 | state | Rewrite model rows visibility | SettingsView.swift:553-555 | Shown only when `rewriteEndpoint` equals `http://127.0.0.1:<flowd port>` and rewrite model not stopped by routing. | core: `rewriteEndpoint`, `ServerRouting` |
| SET-288 | view | "Unload rewrite model" row | SettingsView.swift:557-563 | Picker width 130, id `settings.localModelIdleUnload`. Options "Never" (0), "After 15 min" (900), "After 1 hour" (3600). | ui-only |
| SET-289 | behavior | Unload picker | AppPreferences.swift:43-45; LocalAIRuntime.swift:700 | Writes `localModelIdleUnload` integer seconds. | core: `localModelIdleUnload` |
| SET-290 | view | "Unload during games" row | SettingsView.swift:565-569 | Switch, id `settings.unloadLocalModelDuringGames`. | ui-only |
| SET-291 | behavior | Unload during games toggle | AppPreferences.swift:46-48; LocalAIRuntime.swift:549,655 | Writes `unloadLocalModelDuringGames`. Unloads 60 s after a game comes to the front. | mac-service: frontmost-game detection |
| SET-292 | swift-note | Dead actions | SettingsViewModel.swift:21-22; AppServices.swift:1859-1870 | `.showLocation` and `.requestSystemAudio` have no caller on this page. `modelDetails`, `location`, `installedBytes`, `modelIdentity` are collected but not rendered. | ui-only |

## Rewriting section

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-293 | view | Section title "Rewriting" | SettingsView.swift:208 | Always shown. | ui-only |
| SET-294 | state | Unencrypted warning | SettingsViewModel.swift:204-209; SettingsView.swift:209-213 | With an override on: "Transcripts and the credential travel unencrypted to <host>. Authentication does not encrypt them. Use this only on a network you trust." Figtree 12 warning, wraps, padding bottom 12, above the group. id `settings.rewriteWarning`. | ui-only |
| SET-295 | behavior | Warning announcement | SettingsView.swift:270-278 | Posts a VoiceOver announcement with medium priority on change and on first show. | mac-service: NSAccessibility announcement |
| SET-296 | view | "Enable rewriting" row | SettingsView.swift:215-224 | Switch id `settings.rewriteEnabled`, detail blocked reason. Tooltip bypass note. Disabled only if blocked and off, so a blocked-on switch can still go off. | ui-only |
| SET-297 | behavior | Enable rewriting toggle | SettingsViewModel.swift:228-231 | Writes `rewriteEnabled` = requested and not blocked. | core: `rewriteEnabled` |
| SET-298 | state | Bypass tooltip | SettingsViewModel.swift:249-253 | "Hold Shift on release to skip rewriting once." or, with Shift in the shortcut, "Shift bypass is unavailable because Shift is in your shortcut." | core: `shortcut` |
| SET-299 | state | Blocked: insecure | SettingsViewModel.swift:455-456 | "Allow the unencrypted connection to this server first, or use https://." Checked first. | core: `rewriteInsecureOverrides` |
| SET-300 | state | Blocked: no credential | SettingsViewModel.swift:457 | "Set a credential for this server first." Checked second. | mac-service: Keychain `<bundle id>.rewrite` |
| SET-301 | state | Blocked: invalid endpoint | SettingsViewModel.swift:454 | "Enter a valid http:// or https:// endpoint first." Default state, since `rewriteEndpoint` starts empty. | core: `rewriteEndpoint` |
| SET-302 | swift-note | Blocked toggle with hidden fields | SettingsViewModel.swift:199-201; RewriteSettings.swift:45-58; SettingsView.swift:236 | `capture` never sets `viaRemoteChannel`. An approved Mac with the switch on and an empty or credential-less stored endpoint has its server fields hidden, yet the toggle reports this endpoint or credential reason, though rewrites use the channel. The switch cannot turn on from here. | core: `RewriteSettings` |
| SET-303 | view | "Default mode" row | SettingsView.swift:226-234 | Picker width 120, id `settings.rewriteDefaultMode`. Options Exact (`exact`), Clean (`clean`), Polished (`polished`), Concise (`concise`). Tooltip and accessibility hint are the definition. | ui-only |
| SET-304 | behavior | Default mode picker | SettingsViewModel.swift:232-235 | Writes `rewriteDefaultMode`. | core: `rewriteDefaultMode` |
| SET-305 | state | Mode definitions | SettingsViewModel.swift:462-473 | Exact "Insert the saved transcript unchanged. No request is sent." Clean "Keep wording and meaning; fix punctuation, grammar and capitalization, and remove fillers, stutters and self-corrections." Polished "Restructure sentences into natural professional writing while keeping every fact and action." Concise "Remove repetition and clutter while keeping every fact and action." | ui-only |
| SET-306 | state | Server fields placement | SettingsView.swift:204,236-239 | Inline unless switch applies; then only in Server › Advanced › Rewriting › Custom server. | core: `ServerRouting.switchApplies` |
| SET-307 | view | Server URL field | SettingsView.swift:284-292 | Label "Server URL" Figtree 12 medium muted; symbol `link`; placeholder "http://127.0.0.1:8080"; spacing 8; padding top 18, bottom 14. Accessibility "Rewrite server endpoint", id `settings.rewriteEndpoint`. | ui-only |
| SET-308 | behavior | Server URL edit | SettingsViewModel.swift:210-227 | Each keystroke writes raw text to `rewriteEndpoint`. Origin change clears overrides for old and new origin, hides the secret, clears its error. Always invalidates the test and disables rewriting if now blocked. Also clears edit mode (SettingsView.swift:267-269). | core: `rewriteEndpoint` |
| SET-309 | swift-note | Mid-edit disables rewriting | SettingsViewModel.swift:225,319-321 | Clearing or retyping the address makes it invalid for a moment, which writes `rewriteEnabled` false. A valid address does not restore it. | core: `rewriteEnabled` |
| SET-310 | behavior | Endpoint validation | RewriteSettings.swift:109-124,138-147 | Trimmed, at most 2,048 bytes, http or https, host, no user or password, port 1-65535, origin `scheme://host:port` at most 255 bytes. Loopback: localhost, 127.0.0.0/8, ::1 needs neither credential nor override. | core: `RewriteSettings` |
| SET-311 | view | Server secret header | SettingsView.swift:322-329 | "Server secret" Figtree 12 medium muted; "Saved in Keychain" with `checkmark.shield` Figtree 11 when present. Section padding bottom 18, spacing 8. | mac-service: Keychain `<bundle id>.rewrite` |
| SET-312 | state | Secret saved | SettingsView.swift:331-340 | Symbol `key`, "••••••••••••" tracking 2, accessibility "Server secret saved". Button "Edit", accessibility "Edit rewrite server credential". | mac-service: Keychain `<bundle id>.rewrite` |
| SET-313 | state | Secret entry | SettingsView.swift:342-354 | Secure field, or text field when revealed; placeholder "Enter server secret"; accessibility "Rewrite server credential", id `settings.rewriteCredential`. Return saves. | ui-only |
| SET-314 | view | Save secret | SettingsView.swift:355-359 | "Save", disabled when draft is empty or endpoint invalid. Accessibility "Set rewrite server credential". | ui-only |
| SET-315 | behavior | Save secret action | SettingsViewModel.swift:255-264; RewriteCredentialStore.swift:35-49 | Keychain generic password, service `<bundle id>.rewrite`, account = origin, when-unlocked-this-device. Clears draft and edit mode, invalidates test. | mac-service: Keychain `<bundle id>.rewrite` |
| SET-316 | view | Reveal or hide secret | SettingsView.swift:363-372 | Only when one is saved. "Reveal saved secret" / "Hide saved secret". Borderless, Figtree 12, spacing 12. | ui-only |
| SET-317 | behavior | Reveal action | SettingsViewModel.swift:265-272 | Reads Keychain into draft. Hide clears draft. | mac-service: Keychain `<bundle id>.rewrite` |
| SET-318 | view | Remove secret | SettingsView.swift:374-378 | "Remove", destructive role, no confirmation. Accessibility "Remove rewrite server credential". | ui-only |
| SET-319 | behavior | Remove action | SettingsViewModel.swift:277-283 | Deletes Keychain item; rewriting turns off if now blocked. | mac-service: Keychain `<bundle id>.rewrite` |
| SET-320 | view | Cancel edit | SettingsView.swift:379-382 | "Cancel"; hides secret, leaves edit mode. | ui-only |
| SET-321 | state | Credential errors | SettingsViewModel.swift:257,311-318 | "Enter a valid endpoint before setting a credential." "Enter a credential first." "The credential must be no more than 4,096 bytes." "Remove surrounding whitespace and line breaks." "Could not access the credential in Keychain." Figtree 12 warning. | mac-service: Keychain `<bundle id>.rewrite` |
| SET-322 | behavior | Credential validation | RewriteSettings.swift:152-159 | Non-empty, at most 4,096 bytes, no surrounding whitespace, no newlines. | core: credential validation |
| SET-323 | view | "Allow unencrypted connection" row | SettingsView.swift:294-304 | Only for http to a non-loopback host. Switch accessibility "Allow unencrypted connection to this server (insecure)", id `settings.rewriteInsecureOverride`. | ui-only |
| SET-324 | behavior | Insecure toggle | SettingsViewModel.swift:240-248; AppPreferences.swift:122-131 | Writes `rewriteInsecureOverrides[origin]`, only for http non-loopback. Invalidates the test. | core: `rewriteInsecureOverrides` |
| SET-325 | view | "Connection" row | SettingsView.swift:306-312 | Button "Test connection", "Testing…" while running. Disabled while testing or endpoint invalid. Detail is result text. id `settings.rewriteTestConnection`. | ui-only |
| SET-326 | behavior | Test connection action | SettingsViewModel.swift:333-369; RewriteClient.swift:88 | Preflight sends nothing. Then health request, 10 s timeout. Connected runs analysis health. Stale results are dropped by revision. | flowd: GET /v1/rewrite/health |
| SET-327 | state | Connection results | RewriteProtocol.swift:423-436 | "Connected." "The server rejected the credential." "Could not reach the server." "This endpoint does not provide the LocalFlow rewrite service." "The rewrite model is not available on the server." "The server does not support rewrite protocol version 1." "Set a credential for this server first." "Allow the unencrypted connection to this server first, or use https://." | flowd: GET /v1/rewrite/health |
| SET-328 | state | Analysis status line | SettingsViewModel.swift:373-386; SettingsView.swift:313-317 | "Meeting analysis: available (model <m>)." "Meeting analysis: available." "This server does not offer meeting analysis." "Meeting analysis could not be checked." Figtree 12 muted, id `settings.analysisStatus`. | flowd: GET /v1/analysis/health |
| SET-329 | view | Rewriting Advanced disclosure | SettingsView.swift:241,264 | "Advanced", collapsed, Figtree 12 muted, vertical padding 14. | ui-only |
| SET-330 | view | "Timeout" row | SettingsView.swift:242-248 | Stepper 5...60, label "<n> seconds" monospaced digits. Accessibility "Rewrite timeout in seconds", id `settings.rewriteTimeout`. | ui-only |
| SET-331 | behavior | Timeout stepper | AppPreferences.swift:110-116; RewriteSettings.swift:103-105 | Writes `rewriteTimeoutSeconds` as given, clamped on read. | core: `rewriteTimeoutSeconds` |
| SET-332 | state | Server identity block | SettingsView.swift:249-254; RewriteProtocol.swift:438-450 | After connected with fields inline. Figtree 12 muted, selectable, padding bottom 12. Lines "Server: <name> <version>", "Backend: <kind> · <model>", "Prompts: clean: n, polished: n, concise: n", "Shield: <n>", "Protocol: <versions>"; missing values "Unknown". id `settings.rewriteIdentity`. | flowd: GET /v1/rewrite/health |
| SET-333 | state | Developer diagnostics (Debug) | SettingsView.swift:255-262; SettingsViewModel.swift:389-392 | Debug build with a result: disclosure "Developer diagnostics", Figtree 11 monospaced, selectable: "connection_test=<category> code=<diagnostic>". | ui-only |

## Summaries section

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-334 | state | Section visibility | SettingsView.swift:122; ServerSettingsView.swift:100 | Hidden while switch applies. | core: `ServerRouting.switchApplies` |
| SET-335 | view | Section title "Summaries" | SettingsView.swift:394 | Same title style. | ui-only |
| SET-336 | view | "Server" picker row | SettingsView.swift:396-402 | Picker width 110, id `settings.summaryServer`. Options "Remote" (`remote`), "This Mac" (`local`). | ui-only |
| SET-337 | behavior | Summary server picker | AppPreferences.swift:80-82 | Writes `summaryServer`. Fields appear on Remote. | core: `summaryServer` |
| SET-338 | view | Summary fields container | SettingsView.swift:413-455 | VStack spacing 14, vertical padding 18. Labels Figtree 12 medium muted. | ui-only |
| SET-339 | view | Summary Server URL | SettingsView.swift:415-419 | "Server URL", symbol `link`, placeholder "http://host:8000/v1", id `settings.summaryServerURL`. | ui-only |
| SET-340 | behavior | Summary URL edit | AppPreferences.swift:83-85 | Writes `summaryServerURL` each keystroke, no validation. | core: `summaryServerURL` |
| SET-341 | view | Summary Model | SettingsView.swift:420-424 | "Model", symbol `cpu`, placeholder "Model", id `settings.summaryServerModel`. | ui-only |
| SET-342 | behavior | Summary model edit | AppPreferences.swift:86-88 | Writes `summaryServerModel` each keystroke. | core: `summaryServerModel` |
| SET-343 | state | API key saved | SettingsView.swift:426-434 | Label "API key"; "••••••••••••" tracking 2, accessibility "API key saved"; "Edit". | mac-service: Keychain `<bundle id>.rewrite` / `summary-server` |
| SET-344 | state | API key entry | SettingsView.swift:436-449 | Secure field, placeholder "API key", id `settings.summaryServerKey`. Return saves. "Save" disabled when empty. "Cancel" only if already saved. | ui-only |
| SET-345 | behavior | Save API key | SettingsViewModel.swift:289-300; SettingsView.swift:461-465 | Keychain service `<bundle id>.rewrite`, account `summary-server`. Clears draft and edit mode on success. Same bounds as the rewrite credential. | mac-service: Keychain `<bundle id>.rewrite` / `summary-server` |
| SET-346 | state | API key error | SettingsView.swift:451-453 | Figtree 12 warning. Same copy set as credential errors. | ui-only |
| SET-347 | swift-note | No way to delete the API key | SettingsView.swift:426-450 | There is no Remove control and an empty save is refused, so a saved key stays until replaced. | mac-service: Keychain `<bundle id>.rewrite` / `summary-server` |
| SET-348 | behavior | Summary routing headers | AnalysisClient.swift:19-43 | Remote with URL and model sends `X-LocalFlow-Primary-URL`, `X-LocalFlow-Primary-Model`, optional `X-LocalFlow-Primary-Key`. Custom path adds `X-LocalFlow-Primary-Only: 1` (AppServices.swift:2298-2302). | flowd: POST /v1/analysis/meeting |

## Permissions needed section

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-349 | state | Meeting-only variant | SettingsView.swift:677-681 | Microphone not granted: title "Permissions needed" and a Microphone row only. | mac-service: AVFoundation |
| SET-350 | state | All permissions granted | SettingsView.swift:676-700 | Section absent. | ui-only |
| SET-351 | state | Missing permissions | SettingsView.swift:682-698 | Rows in order Microphone, Input Monitoring, Accessibility, only for those not granted, with a separator between shown rows. | mac-service: AVFoundation, CGPreflightListenEventAccess, AXIsProcessTrusted |
| SET-352 | view | Permission row | SettingsView.swift:703-709 | Title name. Button "Allow…", min width 99, disabled while performing. Accessibility "Allow <name>". | ui-only |
| SET-353 | behavior | Allow Microphone | AppServices.swift:1861-1866,2098-2103 | Denied opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`. Otherwise system prompt. | mac-service: AVFoundation |
| SET-354 | state | Permission refused: Microphone | AppServices.swift:1694-1698,1862-1863 | Row stays, button opens System Settings. Status "Microphone permission is needed for dictation." | mac-service: AVFoundation |
| SET-355 | behavior | Allow Input Monitoring | AppServices.swift:1872-1875,2104-2108 | Ignored for meetings. `CGRequestListenEventAccess`, reinstall shortcut; still denied opens `Privacy_ListenEvent`. | mac-service: CGRequestListenEventAccess |
| SET-356 | behavior | Allow Accessibility | AppServices.swift:2109-2124 | `AXIsProcessTrustedWithOptions` with prompt. Not trusted: reveals app in Finder and opens `Privacy_Accessibility`. Status "Enable LocalFlow in Accessibility settings. The app is shown in Finder if you need to add it." | mac-service: AXIsProcessTrustedWithOptions |
| SET-357 | swift-note | Screen Recording not offered here | SettingsViewModel.swift:117,127-129 | `systemAudio` is collected but not in this section; meetings record microphone alone when refused. | mac-service: Screen Recording |

## Known Speakers (model only, no view exists)

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-358 | swift-note | No Known Speakers view | KnownSpeakersModel.swift:5; AppServices.swift:108,1113; SettingsView.swift:39-131 | The doc comment says "Settings › Known speakers" and AppServices creates the model, but no view reads it and Settings has no such section. Nothing here is reachable by a user today. Port the data, or decide to add UI; rows below are model behavior only. | core: `known_speakers`, `voice_samples` |
| SET-359 | behavior | Load list | KnownSpeakersModel.swift:34-43; IdentityStore.swift:53-60 | Sets `isLoading`. Reads rows sorted by name, created_at, id, with active sample count; reloads samples for the expanded row. Error "Known speakers could not be loaded." | core: `known_speakers`, `voice_samples` |
| SET-360 | state | Sample count text | KnownSpeakersModel.swift:47-49 | "1 voice sample" or "<n> voice samples". | core: `voice_samples` |
| SET-361 | state | Needs re-enrollment | KnownSpeakersModel.swift:51-53 | True when state is `.needsReenrollment`. | core: `known_speakers` |
| SET-362 | state | Sample source text | KnownSpeakersModel.swift:56-62 | "<title> · <day>", or "Source meeting deleted · <day>". Abbreviated date. Fallback title from `fallbackTitle(createdAt:)`. | core: `voice_samples`, `meetings` |
| SET-363 | state | Sample duration and quality | KnownSpeakersModel.swift:64-73 | "<rounded s> s" from `(speechMs + 500) / 1000`. Quality "Good" or "Fair". No vector, score or audio control. | core: `voice_samples` |
| SET-364 | behavior | Begin and cancel rename | KnownSpeakersModel.swift:77-83 | Sets `renaming` and draft to current name; cancel clears `renaming`. | ui-only |
| SET-365 | state | Rename validation | KnownSpeakersModel.swift:85-92; DiarizationRun.swift:273-289 | Trimmed. Blank "Enter a name." Over 80 Unicode scalars "Use 80 characters or fewer." Control character "Remove the control character." | core: `SpeakerNames` |
| SET-366 | behavior | Commit rename | KnownSpeakersModel.swift:94-105 | Invalid does nothing. Unchanged name does nothing. Otherwise store rename with expected revision. | core: `known_speakers` |
| SET-367 | behavior | Recognition switch | KnownSpeakersModel.swift:109-116 | `setRecognition` with expected revision. | core: `known_speakers.recognition_enabled` |
| SET-368 | state | Delete confirmation copy | KnownSpeakersModel.swift:13-15 | "Delete <name>? Voice samples are removed and future meetings will no longer recognize this voice. Past meetings keep the name." | ui-only |
| SET-369 | behavior | Delete flow | KnownSpeakersModel.swift:118-129 | Request sets `pendingDelete`; cancel clears; confirm deletes with revision, collapses, drops samples. | core: `known_speakers`, `voice_samples` |
| SET-370 | behavior | Expand samples | KnownSpeakersModel.swift:131-142 | One row expanded at a time; toggle collapses. Error "Voice samples could not be loaded." | core: `voice_samples` |
| SET-371 | behavior | Remove sample | KnownSpeakersModel.swift:144-152 | Removes then reloads. Error "The voice sample could not be removed." | core: `voice_samples` |
| SET-372 | state | Edit notices | KnownSpeakersModel.swift:11,154-166 | Stale revision "Known speakers changed elsewhere; the list was reloaded." Invalid "That name can't be used." Other "The change could not be saved." Always reloads. | core: `known_speakers` |

## Usage reporting (no Settings UI exists)

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-373 | swift-note | Usage has no Settings control | AppServices.swift:59,600-614; UsageReportingModel.swift | `usageReporting` is created with `automaticEnrollment: true`, and nothing outside AppServices reads it. There is no toggle, status text or delete control. An approved device enrolls and reports without any visible surface. `notice`, `disable` and `incomplete` have no UI. | flowd: wss /v1/remote/channel op `usage` |
| SET-374 | behavior | Automatic enrollment | UsageReportingModel.swift:107-127; UsageReportingStore.swift:69-88 | Needs enabled, approved, device key present. Origin + SHA-256 of device key is the identity. No binding enrolls. An inactive binding stays off. A changed server or key wipes days and enrolls again. | core: `usage_reporting_state`, `usage_reporting_days`, `usage_reporting_completions` |
| SET-375 | behavior | Report loop | UsageReportingModel.swift:195-212 | First sync at 0 s, then every 300 s. On failure backs off double, min 30, max 3,600 s. | flowd: wss /v1/remote/channel op `usage` |
| SET-376 | state | Usage notices (not displayed) | UsageReportingModel.swift:8,56-68,106,190,214-219 | "Usage sharing is off." "Sharing stopped. Waiting to confirm the change with your server." "Sharing is on. Some usage could not be counted." "Sharing daily counts and audio duration." "Usage storage is unavailable. Dictation is unaffected." "Sharing stopped for this session; its setting could not be saved. Retry before quitting." "Sharing stopped. Hosted removal is still pending." "Usage sharing stopped because this device no longer has server approval." "Usage reporting is unavailable on this server. Your dictations remain available." "Usage could not be sent. It will retry while sharing is on." | core: `usage_reporting_state` |

## Preference keys and stored items

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SET-377 | state | `appearance` | AppPreferences.swift:31-33,372 | UserDefaults string; default `system`; unknown reads default. | core: `appearance` |
| SET-378 | state | `keepModelReady` | AppPreferences.swift:34-36,373 | UserDefaults bool; default false. | core: `keepModelReady` |
| SET-379 | state | `speechModel` | AppPreferences.swift:39-41,374-380 | UserDefaults string `parakeet-v3` or `parakeet-ultra`. Missing: Ultra if `setupVersion` is 0, otherwise v3. Unknown stored reads v3. | core: `speechModel` |
| SET-380 | state | `localModelIdleUnload` | AppPreferences.swift:43-45,381-382 | UserDefaults int 0, 900, 3600; default 0 (never). | core: `localModelIdleUnload` |
| SET-381 | state | `unloadLocalModelDuringGames` | AppPreferences.swift:46-48,383-384 | UserDefaults bool; default true. | core: `unloadLocalModelDuringGames` |
| SET-382 | state | `showsBackgroundProgress` | AppPreferences.swift:51-53,386 | UserDefaults bool; default true. | core: `showsBackgroundProgress` |
| SET-383 | state | `learnCorrections` | AppPreferences.swift:55-57,385 | UserDefaults bool; default false. | core: `learnCorrections` |
| SET-384 | state | `settings.meetingLanguage` | MeetingLanguage.swift:59; AppPreferences.swift:362-367 | UserDefaults string; default `automatic`. | core: `settings.meetingLanguage` |
| SET-385 | state | Always-on, not persisted | AppPreferences.swift:59,68,71,74 | `meetingTranscriptionEnabled`, `meetingDiarizationEnabled`, `meetingSummariesAutomatic`, `speakerIdentificationEnabled` all true at launch. | core: fixed flags |
| SET-386 | behavior | Retired keys removed at launch | AppPreferences.swift:76-79,358-360 | Deletes `meetingTranscriptionEnabled`, `meetingDiarizationEnabled`, `settings.meetingSummariesAutomatic`, `settings.speakerIdentificationEnabled`. | core: migration |
| SET-387 | state | `summaryServer` | AnalysisClient.swift:13; AppPreferences.swift:368-369 | UserDefaults string; default `local`. | core: `summaryServer` |
| SET-388 | state | `summaryServerURL` | AnalysisClient.swift:14; AppPreferences.swift:370 | UserDefaults string; default empty. | core: `summaryServerURL` |
| SET-389 | state | `summaryServerModel` | AnalysisClient.swift:15; AppPreferences.swift:371 | UserDefaults string; default empty. | core: `summaryServerModel` |
| SET-390 | state | `setup.purpose` | AppPreferences.swift:90-92,387 | UserDefaults string `dictation`, `meetings`, `both`; missing reads `both`. | core: `setup.purpose` |
| SET-391 | state | `setupVersion` | AppPreferences.swift:28,95,388,417-421 | UserDefaults int; default 0; complete at 1. | core: `setupVersion` |
| SET-392 | state | `rewriteEnabled` | AppPreferences.swift:100-102,389 | UserDefaults bool; default false. | core: `rewriteEnabled` |
| SET-393 | state | `rewriteEndpoint` | AppPreferences.swift:103-105,390 | UserDefaults string; default empty; raw text stored. | core: `rewriteEndpoint` |
| SET-394 | state | `rewriteDefaultMode` | AppPreferences.swift:106-108,391-392 | UserDefaults string; default `clean`. | core: `rewriteDefaultMode` |
| SET-395 | state | `rewriteTimeoutSeconds` | AppPreferences.swift:110-116,393-395; RewriteSettings.swift:8-10 | UserDefaults int; default 20; clamped 5-60 on read. | core: `rewriteTimeoutSeconds` |
| SET-396 | state | `rewriteInsecureOverrides` | AppPreferences.swift:118-120,396-397 | UserDefaults dictionary origin to bool; default empty. | core: `rewriteInsecureOverrides` |
| SET-397 | state | `contextEnabled` | AppPreferences.swift:136-138,398 | UserDefaults bool; default false. | core: `contextEnabled` |
| SET-398 | state | `contextRewriteEnabled` | AppPreferences.swift:140-142,399 | UserDefaults bool; default false. | core: `contextRewriteEnabled` |
| SET-399 | state | `contextStyleEnabled` | AppPreferences.swift:143-145,400 | UserDefaults bool; default false. | core: `contextStyleEnabled` |
| SET-400 | state | `contextExcludedBundleIDs` | AppPreferences.swift:147-149,401-408 | UserDefaults string array, sorted; default set plus own ID. Invalid dropped, capped 200 including own. | core: `contextExcludedBundleIDs` |
| SET-401 | state | `contextCategoryOverrides` | AppPreferences.swift:150-155,409-414 | UserDefaults dictionary ID to raw category; default empty; capped 200; unknown category dropped. | core: `contextCategoryOverrides` |
| SET-402 | state | `remote.enabled` | AppPreferences.swift:198-200,332 | UserDefaults bool; default false. | core: `remote.enabled` |
| SET-403 | state | `remote.serverURL` | AppPreferences.swift:202-204,333-335 | UserDefaults string; default empty; revalidated on load; invalid text never stored. | core: `remote.serverURL` |
| SET-404 | state | `remote.state` | AppPreferences.swift:205-207,336-337; RemoteEnrollment.swift:8-11 | UserDefaults string `off`, `pinned`, `pending`, `approved`, `rejected`, `revoked`, `pin_mismatch`; default `off`. | core: `remote.state` |
| SET-405 | state | `remote.notice` | AppPreferences.swift:208-210,338; RemoteEnrollment.swift:14-19 | UserDefaults optional string `sign_in_again`, `update_required`. | core: `remote.notice` |
| SET-406 | state | `remote.consentVersion` | AppPreferences.swift:190-192,211-213,339 | UserDefaults int; default 0. Current 2. Dictation and enrollment need at least 1. | core: `remote.consentVersion` |
| SET-407 | state | `remote.fallbackThresholdMs` | AppPreferences.swift:215-217,340-341 | UserDefaults int; default 1,500. | core: `remote.fallbackThresholdMs` |
| SET-408 | state | `server.useForEverything` | AppPreferences.swift:276-282,342 | UserDefaults optional bool; unset reads as `routesToServer`. | core: `server.useForEverything` |
| SET-409 | state | `server.only` | AppPreferences.swift:285-287,343 | UserDefaults bool; default false. | core: `server.only` |
| SET-410 | state | `server.override.dictation` | AppPreferences.swift:289-294,344-348 | UserDefaults string `server` or `thisMac`; default `server`; `custom` coerced. | core: `server.override.dictation` |
| SET-411 | state | `server.override.rewrite` | AppPreferences.swift:295-297,349 | UserDefaults string `server`, `thisMac`, `custom`; default `server`. | core: `server.override.rewrite` |
| SET-412 | state | `server.override.summaries` | AppPreferences.swift:298-300,350 | UserDefaults string `server`, `thisMac`, `custom`; default `server`. | core: `server.override.summaries` |
| SET-413 | state | `server.override.meetings` | AppPreferences.swift:302-307,351-352 | UserDefaults string `server` or `thisMac`; default `server`; `custom` coerced. | core: `server.override.meetings` |
| SET-414 | state | `server.capabilities` | AppPreferences.swift:309-314,353-355 | UserDefaults JSON data; nil falls back to `.feature014`. | core: `server.capabilities` |
| SET-415 | state | `shortcut` | ShortcutPreference.swift:8-18,153-164 | UserDefaults JSON data: version 1, kind, enabled, keyCode, modifiers, optional deviceModifiers. Missing or invalid reads as fn/Globe. Onboarding default Right Control. | core: `shortcut` |
| SET-416 | state | `inputDevices.priority.v1` | InputDevicePriority.swift:310-316 | UserDefaults JSON data `{ "version": 1, "entries": [...] }`. Entry: id, kind, uid, modelUID, name, lastSeenAt. Default a single System default. | core: `inputDevices.priority.v1` |
| SET-417 | state | Keychain: rewrite secrets | RewriteCredentialStore.swift:4-16 | Generic password, service `<bundle id>.rewrite`, account = origin. Presence cached per origin, cache cap 16. | mac-service: Keychain `<bundle id>.rewrite` |
| SET-418 | state | Keychain: summary key | AnalysisClient.swift:17 | Service `<bundle id>.rewrite`, account `summary-server`. | mac-service: Keychain `<bundle id>.rewrite` / `summary-server` |
| SET-419 | state | Keychain: remote items | RemoteCredentialStore.swift:4-8; RemoteBoundaries.swift:35-40; AppServices.swift:82-84 | Service `<bundle id>.remote`; accounts `device-key`, `server-key`, `refresh-token`, `access-token`; when-unlocked-this-device; at most 16,384 bytes. | mac-service: Keychain `<bundle id>.remote` |
| SET-420 | state | Sparkle automatic-check setting | UpdateController.swift:95-98 | Owned and stored by Sparkle. | mac-service: Sparkle |
| SET-421 | state | Database tables behind this page | HistoryMigrations.swift:471-495; UsageReportingStore.swift:19-35 | `known_speakers` and `voice_samples` (model only); `usage_reporting_state`, `usage_reporting_days`, `usage_reporting_completions` (no UI). All visible Settings controls use UserDefaults or Keychain. | core: named tables |
| SET-422 | state | Bundle ID and ports | AppIdentity.swift:15-18,74-82 | Keychain services and the loopback endpoint derive from `AppIdentity`: flowd port is port base + 80, `http://127.0.0.1:<flowd port>`. The dev variant uses separate services. | core: `AppIdentity` |
