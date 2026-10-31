# Quickstart validation: Feature 027

Never use `~/Library/Application Support/LocalFlow Server`, port 8080/8090 or production labels here. Use a temp data directory and `--dev`.

1. **Automated**: `make check`, then `cd server && go test -race ./...`.
2. **Migration**: `go test ./internal/accounts -run V3`. A v2 fixture migrates, keeps its devices and leaves a pre-v3 copy.
3. **End to end, in process**: `go test ./internal/remote -run Pair`. Covers create, redeem, session, revoke within 1 s; double redemption; lost reply; wrong-key server; spoofed headers; a reverse proxy in front of the listener.
4. **CLI**: `flowd admin --data-dir "$TMP/d" --dev init`, then `token create --label test --json`, `token list`, `token revoke 1`. The value appears only in the create output, and `sqlite3 "$TMP/d/flowd-remote.sqlite"` and the log hold none of it.
5. **Client**: XCTest for token parsing, address table, pairing state and address edit, using fakes. iOS runs on the existing "iPhone 18 Pro" Simulator through `make check`.
6. **Log scan**: `scripts/check-remote-logs.sh` rejects `lfp_`.

Owner hardware acceptance, recorded in `acceptance/` and never claimed from the above: pairing a real iPhone and a second Mac over LAN, Tailscale and a real reverse proxy; latency on each route; RSS with client and server on one Mac; firewall and Local Network prompts on a signed build.
