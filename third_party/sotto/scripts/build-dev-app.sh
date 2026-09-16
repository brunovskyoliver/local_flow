#!/bin/bash
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
exec "$project_dir/scripts/build-app.sh" --dev "$@"
