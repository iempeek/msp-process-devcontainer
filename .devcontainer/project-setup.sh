#!/usr/bin/env bash
# =============================================================================
# .devcontainer/project-setup.sh
#
# Restores .NET dependencies for the backend solution. Called from
# post-create.sh. This devcontainer is shared, so it is a no-op when the
# workspace has no backend checkout (a frontend-only clone).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_ROOT="$WS_ROOT/${BACKEND_DIR_NAME:-MSPProcess}"

if [ ! -d "$BACKEND_ROOT" ]; then
  echo "[INFO] project-setup: no backend checkout at $BACKEND_ROOT - skipping dotnet restore."
  exit 0
fi

dotnet restore "$BACKEND_ROOT"
