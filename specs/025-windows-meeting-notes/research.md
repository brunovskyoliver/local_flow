# Research: Feature 025

## R1 `windows` crate (Microsoft, MIT or Apache-2.0)
Needed for WASAPI, Media Foundation, NCrypt, Credential Manager and registry calls on Windows. Already compiled through GPUI, so no new supply-chain party. Hand-written FFI would be more code and less checked. Windows-only target dependency of `flow-platform`.

## R2 Hand-written FFI on macOS
Security.framework calls follow the existing pattern in `crates/flow-platform/src/macos.rs`. No new crate.

## R3 Process loopback
`ActivateAudioInterfaceAsync` with `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`, `PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE`, on our own PID. Microsoft lists build 20348 as minimum; Phase 0 verified exclusion in the VM (below -97 dBFS) and failed mic alignment there. Alignment on real hardware stays open.

## R4 TPM
`NCryptOpenStorageProvider(MS_PLATFORM_CRYPTO_PROVIDER)`, `NCRYPT_ECDSA_P256_ALGORITHM`, persisted, no export policy set. Output is raw r||s and flowd expects DER, so a pure converter lives in `flow-core` and is tested against known values. `BCRYPT_ECCPUBLIC_BLOB` is converted to the 65-byte X9.63 form `fixtures/remote/pairing-vectors.json` uses.

## R5 Installer
Inno Setup, modified BSD-style licence, is a build-time tool that doesn't ship in the product and supports `PrivilegesRequired=lowest`. It needs Windows or Wine, so it isn't built here. Velopack would add updates too, but that's Feature 028's choice. Rejected for now, to avoid deciding twice.

## R6 Google client
Google's desktop client type uses a loopback redirect and a non-secret `client_secret`. The Mac's iOS-type client with a reverse-DNS scheme doesn't apply to Windows. Registering a client needs the owner. Without one the Google row is hidden, and pairing still works.

## R7 Licence review
| Item | Licence | Use |
|---|---|---|
| `windows`, `windows-core` | MIT or Apache-2.0 | linked, Windows only |
| Inno Setup | Inno Setup licence (BSD-like) | build tool only |
