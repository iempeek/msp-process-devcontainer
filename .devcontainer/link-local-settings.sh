#!/usr/bin/env bash
# =============================================================================
# .devcontainer/link-local-settings.sh
#
# Layers local dev settings into the BACKEND checkout (postStartCommand, before
# infra-up.sh). The REAL files live in .devcontainer/local/backend-settings/, which
# mirrors the backend repo layout; each file gets a relative SYMLINK at the
# matching path under the backend checkout. Same inode on host and in the
# container (the workspace is one bind mount), so edits apply live - no
# rebuild, no re-link.
#
# Add a new local file: drop it at .devcontainer/local/backend-settings/<repo/path>
# and re-run this script (or restart the container).
#
# Every linked name matches a "local developer settings" pattern in the BACKEND
# repo's .gitignore - nothing reaches git there.
# =============================================================================
set -euo pipefail
trap 'echo "[ERROR] link-local-settings.sh failed at line $LINENO while running: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# The link TARGETS live in the backend checkout (a sibling of this devcontainer
# inside the workspace), the SOURCES here in the devcontainer repo. So the
# relative symlinks below now cross out of the backend repo - fine, because
# every target is gitignored there and this script recreates them on start.
BACKEND_ROOT="$WS_ROOT/${BACKEND_DIR_NAME:-MSPProcess}"
SRC_ROOT="$SCRIPT_DIR/local/backend-settings"

[ -d "$BACKEND_ROOT" ] || { echo "[ERROR] link-local-settings: no backend checkout at $BACKEND_ROOT (set BACKEND_DIR_NAME)." >&2; exit 1; }

[ -d "$SRC_ROOT" ] || { echo "[INFO] link-local-settings: no backend-settings dir, nothing to do."; exit 0; }

find "$SRC_ROOT" -type f | while IFS= read -r src; do
  rel="${src#"$SRC_ROOT"/}"
  target="$BACKEND_ROOT/$rel"

  # Never clobber a real file someone placed there by hand - only manage
  # missing targets and our own (symlink) targets.
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "[WARNING] link-local-settings: $rel exists as a real file - leaving it alone." >&2
    continue
  fi

  mkdir -p "$(dirname "$target")"
  ln -sfn --relative "$src" "$target"
  echo "[INFO] linked $rel"
done

# Seed .env with the env-var secrets the backend needs but that must never be
# committed anywhere. local-stack.sh sources this file into the environment of
# each dotnet/func host it starts (there is no docker --env-file any more).
# Only appends keys that are absent - existing values are never touched.
ENV_FILE="$WS_ROOT/.env"
touch "$ENV_FILE"
for key in MSPPROCESS_AZURE_KV_CLIENTSECRET MSPPROCESS_AZURE_AUTH_KV_CLIENTSECRET; do
  if ! grep -q "^${key}=" "$ENV_FILE"; then
    echo "${key}=[REQUIRED]" >> "$ENV_FILE"
    echo "[INFO] seeded ${key}=[REQUIRED] in .env - fill in the real dev value."
  fi
done
