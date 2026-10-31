# Feature 025: hardware acceptance

Items that need real hardware or a signed install. None of them has been run.

| # | Item | Source | Expected | Result |
|---|---|---|---|---|
| 1 | Mac: `device_key_create`, `device_key_public_key` and `device_key_sign` on a signed build with a real Secure Enclave | T004 | A 65-byte public key; flowd accepts the signature once converted to DER | not run |
| 2 | Mac cutover: with `KEYCHAIN_PREFIX` set to the bundle ID, a signed build reads the Swift app's `server-key`, `device-key`, tokens and rewrite credentials | T003, T004 | Same items and handle, no re-enrollment, no Keychain prompt with the same signing team | not run |
| 3 | Mac: an unsigned or ad hoc build's `device_key_create` | T004 | Succeeds or reports unavailable, never a software key or a prompt | not run |
| 4 | Windows: Credential Manager write, read, remove, and refusal over 2,560 bytes | T005 | Round trip; the item shows under Generic Credentials; the large write fails with nothing stored | not run |
| 5 | Windows: TPM key create, public key, sign, delete on a TPM 2.0 PC | T005 | A 72-byte blob that converts to X9.63; flowd accepts the DER signature; key can't be exported; gone after delete | not run |
| 6 | Windows: TPM missing or disabled | T005, spec edge case | `device_key_create` reports unavailable; no software fallback | not run |
| 7 | Mac and Windows: pair a real device key with a token against a real flowd, through the Settings sheet of a signed build | T010, T013 | Approved; the admin list shows the device's name; refresh works after 12 minutes and after sleep | not run |
| 8 | Opening a `localflow://pair` link in a browser, once the Rust app registers the scheme at the cutover | T013 | The sheet opens filled in, nothing spent. Pasting a link works today | not run |
