#!/usr/bin/env bash
# Compatibility entry point. Keep the implementation in download-packages.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/download-packages.sh" "$@"
