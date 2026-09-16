#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../server"
exec go run ./cmd/flowd "$@"
