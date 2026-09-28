#!/usr/bin/env bash
# Prints a content-free snapshot of the installed LocalFlow app's state (Feature 014, SC-008):
# database file hashes, a hash of its defaults, the names (never values) of its Keychain
# items, its launch agent rows and a hash listing of its models. Run before and after a dev
# build cycle and diff the two outputs; they must be identical.
#   scripts/snapshot-installed-state.sh > "$TMPDIR/before.txt"
set -euo pipefail
id=org.localflow.LocalFlow
support="$HOME/Library/Application Support/LocalFlow"

echo "## database"
if [[ -d "$support" ]]; then
  find "$support" -maxdepth 1 -type f \( -name '*.sqlite' -o -name '*.sqlite-wal' -o -name '*.sqlite-shm' \) \
    -print0 | sort -z | xargs -0 -r shasum -a 256 | sed "s|$support/||"
fi

echo "## defaults"
defaults export "$id" - 2>/dev/null | shasum -a 256 | cut -d' ' -f1

echo "## keychain"
# Attributes only: dump-keychain without -d never reads a secret.
security dump-keychain 2>/dev/null | awk -v id="$id" '
  /^keychain: / { if (svc != "") print svc "  " acct; svc = ""; acct = "" }
  /"svce"<blob>=/ { s = $0; sub(/.*"svce"<blob>="/, "", s); sub(/"$/, "", s); svc = s }
  /"acct"<blob>=/ { a = $0; sub(/.*"acct"<blob>="/, "", a); sub(/"$/, "", a); acct = a }
  END { if (svc != "") print svc "  " acct }
' | awk -v id="$id" 'index($1, id) == 1 && index($1, id ".dev") != 1' | sort -u

echo "## launch agents"
launchctl list | awk -v id="$id" '$3 == id ".flowd" || $3 == id ".mtplx" { print $3, $1, $2 }' | sort

echo "## models"
if [[ -d "$support/Models" ]]; then
  (cd "$support/Models" && find . -type f -print0 | sort -z | xargs -0 -r shasum -a 256)
fi
